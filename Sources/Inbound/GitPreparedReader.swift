import Core
import CryptoKit
import Foundation

public final class GitSHA256Digest: GitPreparationDigest {
  private var hash = SHA256()
  public init() {}
  public func consume(_ bytes: Data) { hash.update(data: bytes) }
  public func finish() -> String { hash.finalize().map { String(format: "%02x", $0) }.joined() }
  public func block(_ bytes: Data) -> Data { Data(SHA256.hash(data: bytes)) }
}

extension GitRepositoryReader {
  public func preparedLocation(_ folder: String) throws -> GitPreparedRepositoryLocation {
    let location = try directoryLocation(folder)
    var branch: GitMaskedText?
    do {
      try maskedTokens(at: folder, ["symbolic-ref", "--quiet", "--short", "HEAD"], separator: 10) { _, text, _ in
        guard branch == nil else { throw GitReadError.malformed }
        branch = text
      }
    } catch GitReadError.failed { }
    return GitPreparedRepositoryLocation(location: location,
      branch: try branch ?? GitMaskedText.prepare("", in: FileManager.default.temporaryDirectory))
  }
  /// Only a bounded machine prefix is decoded before the text preparation receipt.
  /// Both passes read Git directly; the disposable recipe has no raw source text.
  private func maskedTokens(at path: String, _ arguments: [String], separator: UInt8 = 0,
    prefixSeparator: UInt8 = 9, prefixes: () -> Int = { 0 },
    validate: ([String], Int) throws -> Void = { _, _ in },
    decorate: @escaping ([String]) -> (String, String) = { _ in ("", "") },
    visit: ([String], GitMaskedText, String) throws -> Void) throws {
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("activityprobe-git-plan-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { GitScratchCleanup.discard(scratch, cancellation: taskCancellation) }
    var total = 0
    for pass in 0..<2 {
      var index = 0
      var current: GitPreparedTokenPass?
      func token() throws -> GitPreparedTokenPass {
        if let current { return current }
        let directory = scratch.appendingPathComponent(String(index))
        let next = try GitPreparedTokenPass(directory: directory, replay: pass == 1,
          prefixes: pass == 0 ? prefixes() : 0, separator: prefixSeparator, decorate: decorate,
          cancellation: taskCancellation,
          check: { try self.checkReadCancellation() })
        current = next
        return next
      }
      func finish() throws {
        let next = try token()
        if pass == 0 { try next.seal(validate: validate) }
        else {
          let text = try next.finishReplay()
          try visit(next.fields, text, next.identity)
        }
        current = nil; index += 1
      }
      try run(at: path, arguments) { chunk in
        try self.beforePreparedChunk?(chunk.count)
        var start = chunk.startIndex
        while let end = chunk[start...].firstIndex(of: separator) {
          try token().consume(Data(chunk[start..<end]))
          try finish(); start = end + 1
        }
        if start < chunk.endIndex { try token().consume(Data(chunk[start...])) }
        try self.afterPreparedUnit?(pass == 0 ? "preparation" : "replay")
        try self.checkReadCancellation()
      }
      if current != nil { try finish() }
      if pass == 0 { total = index }
      else if total != index { throw GitReadError.malformed }
    }
  }
  public func preparedCommit(at common: String, hash: String) throws -> GitPreparedMetadata {
    guard Self.validHash(hash) else { throw GitReadError.malformed }
    var index = 0, author: Int?, committed: Int?, fields: [GitMaskedText] = []
    try maskedTokens(at: common, ["show", "--no-show-signature", "--no-textconv", "--no-ext-diff", "-s",
      "--format=%H%x00%at%x00%ct%x00%an%x00%ae%x00%B%x00", hash, "--"]) { _, text, _ in
      defer { index += 1 }
      switch index {
      case 0: guard try text.smallText() == hash else { throw GitReadError.malformed }
      case 1: author = try text.smallText().flatMap(Int.init)
      case 2: committed = try text.smallText().flatMap(Int.init)
      case 3...5: fields.append(text)
      case 6: guard try text.smallText() == "\n" else { throw GitReadError.malformed }
      default: throw GitReadError.malformed
      }
    }
    guard index == 7, let author, let committed else { throw GitReadError.malformed }
    return GitPreparedMetadata(hash: hash, authorTime: author, commitTime: committed, fields: fields)
  }
  public func preparedRefs(at common: String, contains: String? = nil,
    visit: (GitMaskedText, String, String) throws -> Void) throws {
    var args = ["for-each-ref", "--format=%(objectname)%09%(refname)"]
    if let contains { args.append("--contains=" + contains) }
    try maskedTokens(at: common, args, separator: 10, prefixes: { 1 }, validate: { fields, _ in
      guard fields.count == 1, Self.validHash(fields[0]) else { throw GitReadError.malformed }
    }) { fields, text, identity in try visit(text, fields[0], identity) }
  }
  public func preparedWorktreeHeads(at common: String, contains: String? = nil,
    visit: (GitMaskedText, String, String) throws -> Void) throws {
    var folder: (GitMaskedText, String)?
    try maskedTokens(at: common, ["worktree", "list", "--porcelain", "-z"], prefixSeparator: 32,
      prefixes: { 1 }, validate: { fields, _ in
        guard fields.count == 1, ["", "worktree", "HEAD", "branch", "detached", "bare", "locked", "prunable"].contains(fields[0]) else { throw GitReadError.malformed }
      }, decorate: { $0.first == "worktree" ? ("worktree:", ":HEAD") : ("", "") }) { fields, text, identity in
      if fields[0] == "worktree" { folder = (text, identity) }
      if fields[0] == "HEAD" {
        guard let head = try text.smallText(), Self.validHash(head), !head.allSatisfy({ $0 == "0" }) else { return }
        if let contains {
          do { try run(at: common, ["merge-base", "--is-ancestor", contains, head]) { _ in } }
          catch GitReadError.failed { return }
        }
        guard let folder else { throw GitReadError.malformed }
        try visit(folder.0, head, folder.1)
      }
    }
  }
  public func preparedFiles(at common: String, hash: String, visit: (GitPreparedChangedFile) throws -> Void) throws {
    guard Self.validHash(hash) else { throw GitReadError.malformed }
    let parent = try? boundedValue(at: common, ["rev-parse", "--verify", hash + "^1"])
    let revisions = parent.map { [$0, hash] } ?? ["--root", hash]
    var renameTokens = 0
    var counts: (Int?, Int?)?
    var old: GitMaskedText?
    try maskedTokens(at: common, ["diff-tree", "-r", "--no-commit-id", "--numstat", "-z", "-M",
      "--no-textconv", "--no-ext-diff"] + revisions + ["--"], prefixes: { renameTokens == 0 ? 2 : 0 },
      validate: { fields, bytes in
        if renameTokens > 0 { renameTokens -= 1; return }
        guard fields.count == 2, (Int(fields[0]) != nil && Int(fields[1]) != nil) || fields == ["-", "-"] else { throw GitReadError.malformed }
        if bytes == 0 { renameTokens = 2 }
      }) { fields, text, _ in
        if let currentCounts = counts {
          if let before = old {
            try visit(GitPreparedChangedFile(oldPath: before, path: text, added: currentCounts.0, deleted: currentCounts.1))
            old = nil
          } else { old = text; return }
        } else {
          guard fields.count == 2 else { throw GitReadError.malformed }
          let next = (Int(fields[0]), Int(fields[1]))
          if text.byteCount == 0 { counts = next; return }
          try visit(GitPreparedChangedFile(oldPath: nil, path: text, added: next.0, deleted: next.1)); return
        }
        counts = nil
      }
    guard counts == nil, old == nil else { throw GitReadError.malformed }
  }
  private func boundedValue(at path: String, _ arguments: [String]) throws -> String {
    var value = Data()
    try run(at: path, arguments) {
      guard value.count + $0.count <= 1024 else { throw GitReadError.malformed }
      value.append($0)
    }
    return String(decoding: value, as: UTF8.self).trimmingCharacters(in: .newlines)
  }
}

private final class GitPreparedTokenPass {
  private struct Prefix: Codable { var count: Int; var fields: [String] }
  private let directory: URL
  private let text: GitTextPreparation
  private let replay: Bool
  private let prefixCount: Int
  private let separator: UInt8
  private let decorate: ([String]) -> (String, String)
  private var prefix = Data()
  private var started = false
  private var suffixCount = 0
  private var expected: [String] = []
  private(set) var fields: [String] = []
  var identity: String { text.identity }
  init(directory: URL, replay: Bool, prefixes: Int, separator: UInt8, decorate: @escaping ([String]) -> (String, String), cancellation: GitTaskCancellation?, check: @escaping () throws -> Void) throws {
    self.directory = directory; self.replay = replay; self.separator = separator; self.decorate = decorate
    if replay {
      let saved = try JSONDecoder().decode(Prefix.self, from: Data(contentsOf: directory.appendingPathComponent("prefix")))
      prefixCount = saved.count; expected = saved.fields
      text = try GitTextPreparation(replaying: directory, digest: GitSHA256Digest(), cancellation: cancellation, check: check)
    } else { prefixCount = prefixes; text = try GitTextPreparation(directory: directory, digest: GitSHA256Digest(), cancellation: cancellation, check: check) }
  }
  private func feed(_ bytes: Data) throws {
    if replay { try text.replay(bytes) } else { try text.consume(bytes) }
  }
  private func start() throws {
    guard !started else { return }
    started = true; try feed(Data(decorate(fields).0.utf8))
  }
  func consume(_ bytes: Data) throws {
    var at = bytes.startIndex
    while fields.count < prefixCount {
      if let end = bytes[at...].firstIndex(of: separator) {
        guard prefix.count + end - at <= 128 else { throw GitReadError.malformed }
        prefix.append(contentsOf: bytes[at..<end]); fields.append(String(decoding: prefix, as: UTF8.self)); prefix = Data()
        at = end + 1
      } else {
        guard prefix.count + bytes.count - at <= 128 else { throw GitReadError.malformed }
        prefix.append(contentsOf: bytes[at...]); return
      }
    }
    try start()
    if at < bytes.endIndex { let suffix = Data(bytes[at...]); suffixCount += suffix.count; try feed(suffix) }
  }
  private func finish() throws {
    if fields.count < prefixCount { fields.append(String(decoding: prefix, as: UTF8.self)); prefix = Data() }
    guard fields.count == prefixCount else { throw GitReadError.malformed }
    try start(); try feed(Data(decorate(fields).1.utf8))
  }
  func seal(validate: ([String], Int) throws -> Void) throws {
    try finish(); try validate(fields, suffixCount); try text.seal()
    let data = try JSONEncoder().encode(Prefix(count: prefixCount, fields: fields))
    let file = directory.appendingPathComponent("prefix")
    guard FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
  }
  func finishReplay() throws -> GitMaskedText {
    try finish(); guard fields == expected else { throw GitReadError.malformed }
    return try text.finishReplay()
  }
}
