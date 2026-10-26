import Darwin
import Foundation
import Storage

public struct RecorderControl {
  public var wait: () -> Void
  public var uptime: () -> TimeInterval
  public var timeout: TimeInterval
  public init(wait: @escaping () -> Void = { Thread.sleep(forTimeInterval: 0.05) },
    uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, timeout: TimeInterval = 60) {
    self.wait = wait; self.uptime = uptime; self.timeout = timeout
  }
  var beforeSettingsPatch: () throws -> Void = {}
  private func lockFile(_ paths: AppPaths, create: Bool = false) throws -> Int32? {
    try paths.databaseScope.validatePath(paths.database)
    if create {
      try paths.databaseScope.validateAppDataPath(paths.appData)
      try OperationalDirectory.validatePath(paths.appData)
      try FileManager.default.createDirectory(at: paths.appData, withIntermediateDirectories: true)
    }
    let directory = try OperationalDirectory(paths.database.deletingLastPathComponent())
    return try directory.open(paths.database.lastPathComponent + ".recorder-lock", flags: O_RDWR | (create ? O_CREAT : 0), missingAllowed: !create)
  }
  private func released(_ file: Int32) throws -> Bool {
    if flock(file, LOCK_EX | LOCK_NB) == 0 { return true }
    guard errno == EWOULDBLOCK else { throw AppCommandError.recorder }
    return false
  }
  public func stop(paths: AppPaths) throws -> AppCommandResult {
    let file = try lockFile(paths, create: true)!
    defer { Darwin.close(file) }
    try beforeSettingsPatch()
    let store = try ActivityStorage(url: paths.database, appDataDirectory: paths.appData, databaseScope: paths.databaseScope)
    _ = try store.patchSettings(.edit(.recording(false), ownBundleID: AppPaths.bundleID, now: Int(Date().timeIntervalSince1970)))
    let deadline = uptime() + timeout
    // The recorder observes the setting, drains maintenance, and releases its lifetime lock.
    while try !released(file) {
      guard uptime() < deadline else { return AppCommandResult(1, "stop_timed_out") }
      wait()
    }
    return AppCommandResult(0, "stopped")
  }
  public func isRunning(paths: AppPaths) throws -> Bool {
    let file = try lockFile(paths)
    defer { if let file { Darwin.close(file) } }
    return try file.map { try !released($0) } ?? false
  }
  public func status(paths: AppPaths) throws -> AppCommandResult {
    let running = try isRunning(paths: paths)
    let store = try ActivityStorage(url: paths.database, appDataDirectory: paths.appData, readOnly: true, databaseScope: paths.databaseScope)
    let settings = try store.settings()
    return AppCommandResult(0, "running=\(running ? 1 : 0) recording=\(settings.recordingEnabled ? 1 : 0) paused_until=\(settings.pausedUntil ?? 0) forgotten_ranges=\(try store.deletionsSoFar()) summary_unavailable_until=\(Int(try store.summaryUnavailableUntil() ?? 0)) \(try store.axProbeStatus()) \(try store.collectionStatus())")
  }
}
