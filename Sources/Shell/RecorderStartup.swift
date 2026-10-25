import Core
import Darwin
import Foundation
import Storage

public enum RecorderStartupError: Error { case recorderRunning, processUnavailable, invalidPID, summaryAlreadyConfigured, isolationRequired }
public enum RecorderProcessIdentity { case gone, recorder, other, unknown }

/// Retained for the recorder lifetime. Never signals a process or replaces another owner's PID.
public final class RecorderStartupGuard {
  public let recorderLock: RecorderDatabaseLock
  private let descriptor: Int32
  private let directory: OperationalDirectory
  private let ownPID: Int32
  private var published = false
  public init(paths: AppPaths, ownPID: Int32 = getpid(),
    identity: (Int32) -> RecorderProcessIdentity = RecorderStartupGuard.identity) throws {
    guard TestPathGuard.permits(paths.appData) else { throw RecorderStartupError.isolationRequired }
    try paths.databaseScope.validateAppDataPath(paths.appData)
    try OperationalDirectory.validatePath(paths.appData)
    try ActivityStorage.validateRecorderDatabase(at: paths.database, scope: paths.databaseScope)
    try FileManager.default.createDirectory(at: paths.appData, withIntermediateDirectories: true)
    directory = try OperationalDirectory(paths.appData); self.ownPID = ownPID
    descriptor = try directory.open("recorder-start.lock", flags: O_CREAT | O_RDWR)!
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      Darwin.close(descriptor); throw RecorderStartupError.recorderRunning
    }
    do {
      if try directory.exists("collector.pid") {
        guard let bytes = try directory.read("collector.pid") else { throw RecorderStartupError.processUnavailable }
        let value = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pid = Int32(value), pid > 0 else { throw RecorderStartupError.invalidPID }
        switch identity(pid) {
        case .recorder: throw RecorderStartupError.recorderRunning
        case .unknown: throw RecorderStartupError.processUnavailable
        case .gone, .other: break
        }
      }
      recorderLock = try RecorderDatabaseLock(database: paths.database, scope: paths.databaseScope)
    } catch { flock(descriptor, LOCK_UN); Darwin.close(descriptor); throw error }
  }
  public func publish() throws {
    let file = try directory.open("collector.pid", flags: O_CREAT | O_WRONLY | O_TRUNC)!
    let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
    defer { try? handle.close() }
    try handle.write(contentsOf: Data(String(ownPID).utf8)); published = true
  }
  deinit {
    if published, let bytes = try? directory.read("collector.pid"), String(decoding: bytes, as: UTF8.self) == String(ownPID) {
      unlinkat(directory.descriptor, "collector.pid", 0)
    }
    flock(descriptor, LOCK_UN); Darwin.close(descriptor)
  }
  public static func identity(_ pid: Int32) -> RecorderProcessIdentity {
    guard kill(pid, 0) == 0 || errno == EPERM else { return errno == ESRCH ? .gone : .unknown }
    var path = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return .unknown }
    return URL(fileURLWithPath: String(cString: path)).lastPathComponent == "ActivityProbe"
      ? .recorder : .other
  }
}
