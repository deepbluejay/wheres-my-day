import Core
import Darwin
import Foundation

/// Shared by startup and storage so the database stays owned through startup and drain.
public final class RecorderDatabaseLock {
  private let file: Int32
  private let database: URL
  public init(database: URL, scope: DatabaseOpenScope) throws {
    try scope.validatePath(database)
    self.database = OperationalDirectory.systemURL(database)
    let directory = try OperationalDirectory(database.deletingLastPathComponent())
    let descriptor = try directory.open(database.lastPathComponent + ".recorder-lock", flags: O_CREAT | O_RDWR)!
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      Darwin.close(descriptor); throw StorageError("A recorder already owns this database")
    }
    file = descriptor
  }
  func validate(database: URL) throws {
    guard try FileLocation.same(self.database, database) else { throw StorageError("Recorder lock database mismatch") }
  }
  deinit { flock(file, LOCK_UN); Darwin.close(file) }
}

public extension ActivityStorage {
  /// Inspect an existing file with SQLite's read-only flags before any writer or backup marker.
  static func validateRecorderDatabase(at url: URL, scope: DatabaseOpenScope) throws {
    try scope.validatePath(url)
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    let connection = try SQLiteConnection.originPreflight(url: url, scope: scope)
    _ = try connection.validateSchemaOrigin()
  }
}
