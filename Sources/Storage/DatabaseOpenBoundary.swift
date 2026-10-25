import Core
import Darwin
import Foundation
import SQLite3

/// The entry grants a directory, or explicitly authorizes the live switch.
public enum DatabaseOpenScope: Equatable {
  case directory(URL, excluding: [URL] = [])
  case liveSwitch

  /// App data may be separate from a database override, but never inside an exclusion.
  public func validateAppDataPath(_ url: URL) throws {
    try FileLocation.validate(url)
    guard TestPathGuard.permits(url) else { throw StorageError("Protected app data refused") }
    if case .directory(_, let excluded) = self {
      for exclusion in excluded where try FileLocation.contains(url, in: exclusion) {
        throw StorageError("Protected app data refused")
      }
    }
  }

  /// Share the path grant with entry preflight without opening a database.
  public func validatePath(_ url: URL) throws {
    _ = try FileLocation.resolve(url)
    precondition(TestPathGuard.permits(url), "Tests must never open the real app-data folder")
    if case .directory(let root, let excluded) = self {
      guard try FileLocation.contains(url, in: root, includingRoot: false, granting: true) else {
        throw StorageError("Database outside approved directory")
      }
      for exclusion in excluded where try FileLocation.contains(url, in: exclusion) {
        throw StorageError("Database outside approved directory")
      }
    }
  }
}

enum DatabaseOpenBoundary {
  // A failing seam lets command tests prove they cannot reach SQLite by another route.
  static var beforeOpen: ((URL, DatabaseOpenScope) throws -> Void)?

  static func open(_ url: URL, scope: DatabaseOpenScope, readOnly: Bool, immutable: Bool,
    handle: inout OpaquePointer?) throws -> Int32 {
    try scope.validatePath(url)
    let file = OperationalDirectory.systemURL(url)
    let directory = try OperationalDirectory(file.deletingLastPathComponent()), leaf = file.lastPathComponent
    try directory.validate(leaf)
    for suffix in ["-wal", "-shm", "-journal", ".recorder-lock"] {
      try directory.validate(leaf + suffix)
      if immutable && suffix != ".recorder-lock", try directory.exists(leaf + suffix) {
        throw StorageError("Source is not frozen")
      }
    }
    try beforeOpen?(file, scope)
    let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
      | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW | (immutable ? SQLITE_OPEN_URI : 0)
    let path = immutable ? file.absoluteString + "?immutable=1" : file.path
    return withExtendedLifetime(directory) { sqlite3_open_v2(path, &handle, flags, nil) }
  }
}
