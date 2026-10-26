import Darwin
import Foundation

/// Numeric operational diagnostics contain no collected identities or content.
struct CollectionOperationalHealth: Codable {
  var acquisition = 0
  var staging = 0
  var persistence = 0
  var initialization = 0

  static func read(database: URL) throws -> CollectionOperationalHealth {
    let directory = try OperationalDirectory(database.deletingLastPathComponent())
    guard let data = try directory.readStrict(database.lastPathComponent + ".collection-health") else { return Self() }
    return try JSONDecoder().decode(Self.self, from: data)
  }
  static func increment(_ phase: Int, database: URL) throws {
    let journal = try ModelCallJournal(database: database)
    try journal.withLock {
      var value = try read(database: database)
      switch phase {
      case 0: value.acquisition += 1
      case 1: value.staging += 1
      case 2: value.persistence += 1
      default: value.initialization += 1
      }
      let leaf = database.lastPathComponent + ".collection-health", temporary = leaf + ".tmp-" + UUID().uuidString
      let directory = journal.directory
      let descriptor = try directory.open(temporary, flags: O_CREAT | O_EXCL | O_WRONLY)!
      let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
      defer { try? handle.close(); unlinkat(directory.descriptor, temporary, 0) }
      try handle.write(contentsOf: JSONEncoder().encode(value)); try handle.synchronize()
      try directory.validate(leaf)
      guard renameat(directory.descriptor, temporary, directory.descriptor, leaf) == 0,
        fsync(directory.descriptor) == 0 else { throw StorageError("Collection diagnostics not synchronized") }
    }
  }
}

/// Publication can proceed during an SQL write outage. Numeric refusal attempts
/// therefore use a synchronized sidecar; commit refusals remain transactional SQL.
struct CollectionPolicyHealth {
  static func read(storage: ActivityStorage) throws -> [String: Int] {
    let directory = try OperationalDirectory(storage.url.deletingLastPathComponent())
    guard let bytes = try directory.readStrict(storage.url.lastPathComponent + ".collection-policy") else { return [:] }
    return try JSONDecoder().decode([String: Int].self, from: bytes)
  }
  static func count(_ refusals: [String: Int], storage: ActivityStorage) throws {
    guard !refusals.isEmpty else { return }
    var totals = try read(storage: storage)
    for (reason, count) in refusals { totals[reason, default: 0] += count }
    try storage.atomicCollectionWrite(JSONEncoder().encode(totals), leaf: storage.url.lastPathComponent + ".collection-policy",
      directory: OperationalDirectory(storage.url.deletingLastPathComponent()))
  }
}
