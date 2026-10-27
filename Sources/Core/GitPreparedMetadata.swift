import Foundation

/// Masked-only text in bounded memory or a private disposable file.
public final class GitMaskedText {
  private enum Backing { case memory(Data), file(URL) }
  public let byteCount: Int
  private let backing: Backing
  private let ownedDirectory: URL?
  private let cancellation: GitTaskCancellation?

  // Core sanitizers create these receipts. Tests may inject invented, already-masked files.
  init(maskedFile: URL, byteCount: Int, ownedDirectory: URL? = nil, cancellation: GitTaskCancellation? = nil) {
    backing = .file(maskedFile); self.byteCount = byteCount; self.ownedDirectory = ownedDirectory
    self.cancellation = cancellation
  }
  private init(maskedBytes: Data) {
    backing = .memory(maskedBytes); byteCount = maskedBytes.count; ownedDirectory = nil; cancellation = nil
  }
  deinit {
    // This receipt owns one text file. Unlink that bounded filesystem unit even
    // after stop, so only numeric/hash recipes can await deferred disposal.
    if let ownedDirectory { GitScratchCleanup.discard(ownedDirectory) }
  }

  /// Compatibility for String callers. Production Git reads use GitTextPreparation receipts.
  public static func prepare(_ value: String, in parent: URL) throws -> GitMaskedText {
    let masked = Redaction.apply(AgentLogEventParser.safeString(value)).text
    if masked.utf8.count <= 65536 { return GitMaskedText(maskedBytes: Data(masked.utf8)) }
    let directory = parent.appendingPathComponent("masked-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    var transferred = false
    defer { if !transferred { try? FileManager.default.removeItem(at: directory) } }
    let file = directory.appendingPathComponent("text")
    guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
      throw CocoaError(.fileWriteUnknown)
    }
    let output = try FileHandle(forWritingTo: file)
    defer { try? output.close() }
    var chunk = Data()
    for byte in masked.utf8 {
      chunk.append(byte)
      if chunk.count == 65536 {
        try autoreleasepool { try output.write(contentsOf: chunk) }
        chunk.removeAll(keepingCapacity: true)
      }
    }
    if !chunk.isEmpty { try output.write(contentsOf: chunk) }
    try output.close()
    transferred = true
    return GitMaskedText(maskedFile: file, byteCount: masked.utf8.count, ownedDirectory: directory)
  }
  public func forEachChunk(_ consume: (Data) throws -> Void) throws {
    try cancellation?.check()
    if case .memory(let bytes) = backing {
      if !bytes.isEmpty { try consume(bytes) }
      return
    }
    guard case .file(let file) = backing else { return }
    let input = try FileHandle(forReadingFrom: file)
    defer { try? input.close() }
    var count = 0
    while try autoreleasepool(invoking: { () throws -> Bool in
      try cancellation?.check()
      guard let bytes = try input.read(upToCount: 65536), !bytes.isEmpty else { return false }
      count += bytes.count
      guard count <= byteCount else { throw CocoaError(.fileReadCorruptFile) }
      try consume(bytes)
      return true
    }) {}
    guard count == byteCount else { throw CocoaError(.fileReadCorruptFile) }
  }
  public func smallText() throws -> String? {
    guard byteCount <= 65536 else { return nil }
    var bytes = Data()
    try forEachChunk { bytes.append($0) }
    return String(decoding: bytes, as: UTF8.self)
  }
}

public struct GitPreparedMetadata {
  public let hash: String
  public let authorTime: Int
  public let commitTime: Int
  public let fields: [GitMaskedText]
  public init(hash: String, authorTime: Int, commitTime: Int, fields: [GitMaskedText]) {
    precondition(fields.count == 3)
    self.hash = hash; self.authorTime = authorTime; self.commitTime = commitTime; self.fields = fields
  }
}

public struct GitPreparedChangedFile {
  public var oldPath: GitMaskedText?
  public var path: GitMaskedText
  public var added: Int?
  public var deleted: Int?
  public init(oldPath: GitMaskedText?, path: GitMaskedText, added: Int?, deleted: Int?) {
    self.oldPath = oldPath; self.path = path; self.added = added; self.deleted = deleted
  }
}

public struct GitPreparedRepositoryLocation {
  public var location: GitRepositoryLocation
  public var branch: GitMaskedText
  public init(location: GitRepositoryLocation, branch: GitMaskedText) { self.location = location; self.branch = branch }
}
