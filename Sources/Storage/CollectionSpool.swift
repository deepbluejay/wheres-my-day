import Core
import CryptoKit
import Darwin
import Foundation

extension ActivityStorage {
  var collectionDirectory: URL { URL(fileURLWithPath: url.path + ".collection", isDirectory: true) }
  var collectionQuarantine: URL { collectionDirectory.appendingPathComponent("quarantine", isDirectory: true) }

  // Enumerators and payloads never escape a visit.
  func forEachCollectionFile(in folder: URL? = nil, includingTemporaries: Bool = false, _ visit: (URL) throws -> Void) throws {
    let folder = folder ?? collectionDirectory
    guard FileManager.default.fileExists(atPath: folder.path) else { return }
    let directory = try OperationalDirectory(folder)
    var enumerationError: Error?
    guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil,
      options: [.skipsSubdirectoryDescendants], errorHandler: { _, error in enumerationError = error; return false }) else { throw StorageError("Collection spool unavailable") }
    for case let file as URL in enumerator {
      collectionEnumerationVisits += 1
      var info = stat()
      guard fstatat(directory.descriptor, file.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
        if errno == ENOENT { continue }
        throw StorageError("Collection leaf unavailable")
      }
      if info.st_mode & S_IFMT == S_IFDIR { continue }
      if file.lastPathComponent.hasPrefix(".") && !(includingTemporaries && file.lastPathComponent.hasPrefix(".tmp-")) { continue }
      try directory.validate(file.lastPathComponent)
      try visit(file)
    }
    if let enumerationError { throw enumerationError }
  }
  func collectionFiles(limit: Int? = nil) throws -> [URL] {
    var selected: [URL] = []
    try forEachCollectionFile { file in
      guard file.pathExtension == "json" else { return }
      selected.append(file)
      if let limit, selected.count > limit {
        selected.sort { $0.lastPathComponent < $1.lastPathComponent }; selected.removeLast()
      }
    }
    return selected.sorted { $0.lastPathComponent < $1.lastPathComponent }
  }
  func collectionRecoverySequence() throws -> UInt64 {
    guard FileManager.default.fileExists(atPath: collectionDirectory.path) else { return 0 }
    let directory = try OperationalDirectory(collectionDirectory)
    guard let data = try directory.readStrict(".sequence") else { return 0 }
    guard let value = UInt64(String(decoding: data, as: UTF8.self)) else { throw StorageError("Collection sequence damaged") }
    return value
  }
  func collectionRecoveryCursor() throws -> CollectionFileCursor {
    let cursor = try CollectionFileCursor()
    try forEachCollectionFile(includingTemporaries: true) { file in
      if file.lastPathComponent.hasPrefix(".tmp-") {
        try incrementSpoolCounter(".interrupted-temporaries")
        try removeCollectionFile(file)
      } else if file.pathExtension == "json" { try cursor.add(file.lastPathComponent) }
    }
    return cursor
  }
  func atomicCollectionWrite(_ bytes: Data, leaf: String, directory: OperationalDirectory,
    publication: Bool = false) throws {
    let temporary = ".tmp-" + UUID().uuidString
    let descriptor = try directory.open(temporary, flags: O_CREAT | O_EXCL | O_WRONLY)!
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close(); unlinkat(directory.descriptor, temporary, 0) }
    if publication { try collectionPublicationFault?("before-write") }
    let middle = bytes.count / 2
    try handle.write(contentsOf: bytes.prefix(middle))
    if publication { try collectionPublicationFault?("during-write") }
    try handle.write(contentsOf: bytes.suffix(bytes.count - middle))
    if publication { try collectionPublicationFault?("file-sync") }
    try handle.synchronize()
    if publication { try collectionPublicationFault?("before-rename") }
    try directory.validate(leaf)
    guard renameat(directory.descriptor, temporary, directory.descriptor, leaf) == 0 else { throw StorageError("Collection publication unavailable") }
    if publication { try collectionPublicationFault?("after-rename") }
    if publication { try collectionPublicationFault?("directory-sync") }
    guard fsync(directory.descriptor) == 0 else { throw StorageError("Collection directory not synchronized") }
    if publication { try collectionPublicationFault?("after-sync") }
  }
  func removeCollectionFile(_ file: URL) throws {
    let directory = try OperationalDirectory(file.deletingLastPathComponent())
    try directory.validate(file.lastPathComponent)
    guard unlinkat(directory.descriptor, file.lastPathComponent, 0) == 0 || errno == ENOENT,
      fsync(directory.descriptor) == 0 else { throw StorageError("Collection erasure not synchronized") }
  }
  private func incrementSpoolCounter(_ name: String) throws {
    let directory = try OperationalDirectory(collectionDirectory)
    let previous = try directory.readStrict(name).flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
    try atomicCollectionWrite(Data(String(previous + 1).utf8), leaf: name, directory: directory)
  }
  func recoverCollectionSpool() throws {
    guard FileManager.default.fileExists(atPath: collectionDirectory.path) else { return }
    let directory = try OperationalDirectory(collectionDirectory)
    // These leaves were never published. Ready records and quarantine remain privacy-visible.
    guard let names = FileManager.default.enumerator(at: collectionDirectory, includingPropertiesForKeys: nil,
      options: [.skipsSubdirectoryDescendants]) else { throw StorageError("Collection recovery unavailable") }
    for case let file as URL in names where file.lastPathComponent.hasPrefix(".tmp-") {
      try directory.validate(file.lastPathComponent)
      try incrementSpoolCounter(".interrupted-temporaries")
      try removeCollectionFile(file)
    }
  }
  private func quarantineCollection(_ file: URL) throws {
    try OperationalDirectory.validatePath(collectionQuarantine)
    if !FileManager.default.fileExists(atPath: collectionQuarantine.path) {
      try FileManager.default.createDirectory(at: collectionQuarantine, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    let source = try OperationalDirectory(collectionDirectory), target = try OperationalDirectory(collectionQuarantine)
    try source.validate(file.lastPathComponent)
    var leaf = file.lastPathComponent
    if try target.exists(leaf) { leaf += "." + UUID().uuidString }
    try target.validate(leaf)
    try incrementSpoolCounter(".quarantined-total")
    guard renameat(source.descriptor, file.lastPathComponent, target.descriptor, leaf) == 0,
      fsync(target.descriptor) == 0, fsync(source.descriptor) == 0 else { throw StorageError("Collection quarantine unavailable") }
  }
  func quarantineUnrecoverableCollection(_ file: URL) throws {
    // Count durably before relinquishing the ready owner. As with publication
    // refusals, a failed rename can make this an at-least-once attempt count.
    try incrementSpoolCounter(".unrecoverable-total")
    try quarantineCollection(file)
    try clearCollectionRetry(file)
  }
  private func collectionRetryLeaf(_ file: URL) -> String {
    ".unproven-" + probeHash(file.lastPathComponent)
  }
  func countUnprovenCollection(_ file: URL) throws -> Int {
    let leaf = collectionRetryLeaf(file)
    try incrementSpoolCounter(leaf)
    let directory = try OperationalDirectory(collectionDirectory)
    guard let bytes = try directory.readStrict(leaf), let count = Int(String(decoding: bytes, as: UTF8.self)) else {
      throw StorageError("Collection retry counter unavailable")
    }
    return count
  }
  func clearCollectionRetry(_ file: URL) throws {
    let leaf = collectionRetryLeaf(file)
    guard try OperationalDirectory(collectionDirectory).exists(leaf) else { return }
    try removeCollectionFile(collectionDirectory.appendingPathComponent(leaf))
  }
  func readReadyCollection(_ file: URL, quarantineOnFailure: Bool = true) throws -> CollectionRecord? {
    let data: Data
    let record: CollectionRecord
    do {
      let directory = try OperationalDirectory(file.deletingLastPathComponent())
      let descriptor = try directory.open(file.lastPathComponent, flags: O_RDONLY)!
      let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
      defer { try? handle.close() }
      data = try handle.readToEnd() ?? Data()
      collectionPeakReadBytes = max(collectionPeakReadBytes, data.count)
      record = try JSONDecoder().decode(CollectionRecord.self, from: data)
      try record.validate()
    } catch {
      if quarantineOnFailure { try quarantineCollection(file) }
      return nil
    }
    return record
  }
  private func nextCollectionSequence(_ directory: OperationalDirectory) throws -> UInt64 {
    var maximum: UInt64 = 0
    if let data = try directory.readStrict(".sequence") {
      guard let value = UInt64(String(decoding: data, as: UTF8.self)) else { throw StorageError("Collection sequence damaged") }
      maximum = value
    } else {
      try forEachCollectionFile { file in
        if file.lastPathComponent.hasPrefix("r-"), let value = UInt64(file.deletingPathExtension().lastPathComponent.dropFirst(2)) { maximum = max(maximum, value) }
      }
    }
    guard maximum < UInt64.max else { throw StorageError("Collection sequence exhausted") }
    let next = maximum + 1
    try atomicCollectionWrite(Data(String(next).utf8), leaf: ".sequence", directory: directory)
    return next
  }
  @discardableResult func stageCollection(_ original: CollectionRecord) throws -> Bool {
    var record = original
    return try stageCollection(&record)
  }
  @discardableResult func stageCollection(_ record: inout CollectionRecord) throws -> Bool {
    let journal = try ModelCallJournal(database: url)
    return try journal.withLock {
      try collectionPublicationFault?("policy-read")
      let admission = try locked { try connection.transaction(write: false) { try admitCollection(record) } }
      // Refusal accounting must be durable before releasing the last accepted copy.
      // It is an at-least-once attempt count if publication later fails.
      try CollectionPolicyHealth.count(admission.refusals, storage: self)
      record = admission.record
      guard admission.hasWork else { return false }
      try OperationalDirectory.validatePath(collectionDirectory)
      try FileManager.default.createDirectory(at: collectionDirectory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      let directory = try OperationalDirectory(collectionDirectory)
      if record.enqueueSequence == nil { record.enqueueSequence = try nextCollectionSequence(directory) }
      let leaf = String(format: "r-%020llu.json", record.enqueueSequence!)
      let bytes = try JSONEncoder().encode(record)
      try atomicCollectionWrite(bytes, leaf: leaf, directory: directory, publication: true)
      return true
    }
  }
  /// External ordered manifest, one decoded record and a 64 KiB hash chunk.
  /// Preview and erasure use the same stable ordering under the journal barrier.
  private func orderedCollectionFiles(in folder: URL? = nil, includingTemporaries: Bool = false, yielding: Bool = false,
    _ visit: (URL) throws -> Void) throws {
    let cursor = try CollectionFileCursor()
    var visited = 0
    func checkpoint() throws {
      visited += 1
      if yielding && visited % 64 == 0 { try connection.collectionMaintenanceYield?() }
    }
    try forEachCollectionFile(in: folder, includingTemporaries: includingTemporaries) { file in
      if folder == nil && file.pathExtension != "json" && !file.lastPathComponent.hasPrefix(".tmp-") { return }
      try cursor.add(file.lastPathComponent)
      try checkpoint()
    }
    let root = folder ?? collectionDirectory
    try cursor.visit {
      // Recovery can acknowledge or quarantine a leaf while maintenance yields.
      if try !yielding || OperationalDirectory(root).exists($0) { try visit(root.appendingPathComponent($0)) }
      try checkpoint()
    }
  }
  func digestStagedCollection(in range: TimeRange, into digest: inout SHA256) throws -> Int {
    var count = 0
    digest.update(data: Data("collection-ordered-v1".utf8))
    try visitStagedCollection(in: range) { file, _ in
      count += 1
      let scope = file.deletingLastPathComponent() == collectionDirectory ? "ready" : "quarantine"
      let leaf = file.lastPathComponent
      digest.update(data: Data("\(scope):\(leaf.utf8.count):\(leaf):".utf8))
      var hash = SHA256()
      let directory = try OperationalDirectory(file.deletingLastPathComponent())
      if let descriptor = try? directory.open(leaf, flags: O_RDONLY) {
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        while let bytes = try handle.read(upToCount: 65536), !bytes.isEmpty { hash.update(data: bytes) }
      } else {
        // Unknown-time unreadable leaves still overlap every range. Exact stat
        // timestamps invalidate approval if their unreadable content changes.
        var info = stat()
        guard fstatat(directory.descriptor, leaf, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw StorageError("Collection identity unavailable") }
        hash.update(data: Data("unreadable:\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)".utf8))
      }
      digest.update(data: Data(hash.finalize()))
    }
    digest.update(data: Data("count:\(count)".utf8))
    return count
  }
  func visitStagedCollection(in range: TimeRange, yielding: Bool = false, _ visit: (URL, CollectionRecord?) throws -> Void) throws {
    // Preview is read-only, including malformed ready leaves and interrupted writes.
    // The writer quarantines damage on recovery; either namespace overlaps every range.
    try orderedCollectionFiles(includingTemporaries: true, yielding: yielding) { file in
      if file.lastPathComponent.hasPrefix(".tmp-") { try visit(file, nil); return }
      let record = try readReadyCollection(file, quarantineOnFailure: false)
      if record == nil || record!.overlaps(range) { try visit(file, record) }
    }
    // An unknown timestamp must never exempt damaged work from forget or retention.
    try orderedCollectionFiles(in: collectionQuarantine, yielding: yielding) { try visit($0, nil) }
  }
  func eraseStagedCollection(in range: TimeRange) throws {
    try visitStagedCollection(in: range, yielding: true) { file, value in
      guard let record = value else { try removeCollectionFile(file); return }
      let admission = try locked { try connection.transaction(write: false) { try admitCollection(record, refusing: range) } }
      try CollectionPolicyHealth.count(admission.refusals, storage: self)
      if !admission.hasWork { try removeCollectionFile(file); return }
      try atomicCollectionWrite(JSONEncoder().encode(admission.record), leaf: file.lastPathComponent, directory: OperationalDirectory(collectionDirectory))
    }
    // Judge each freshly read leaf while the journal is still held. A cumulative
    // remaining count could become stale if recovery acknowledges it in a gap.
    try visitStagedCollection(in: range, yielding: true) { _, _ in throw StorageError("Staged collection remains") }
  }
}
