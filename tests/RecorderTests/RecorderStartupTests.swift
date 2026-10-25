import Foundation
import XCTest
@testable import Shell
@testable import Storage

final class RecorderStartupTests: XCTestCase {
  var root: URL!
  var paths: AppPaths!
  override func setUpWithError() throws {
    root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ACTIVITYPROBE_TEST_ROOT"] ?? NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    paths = AppPaths(userHome: root.appendingPathComponent("user"), appData: root.appendingPathComponent("data"),
      database: root.appendingPathComponent("invented.sqlite"), appBinary: root.appendingPathComponent("ActivityProbe"),
      queryHelper: root.appendingPathComponent("ActivityQueryServer"))
  }
  override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
  // Ideal: reject old schemas before creating app directories or changing even one source byte.
  func testOldDatabaseIsRejectedBeforeAnyWriterOrAppDirectory() throws {
    do {
      let old = try SQLiteConnection(url: paths.database, scope: paths.databaseScope)
      try old.run("CREATE TABLE old_samples (ts INTEGER)")
      try old.run("INSERT INTO old_samples VALUES (120)")
    }
    let before = try Data(contentsOf: paths.database)
    XCTAssertThrowsError(try RecorderStartupGuard(paths: paths))
    XCTAssertEqual(try Data(contentsOf: paths.database), before)
    XCTAssertFalse(FileManager.default.fileExists(atPath: paths.appData.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: paths.database.path + "-wal"))
  }
  // Ideal: either generation blocks a start; unrelated reused PIDs do not.
  func testBothGenerationsUnknownAndReusedProcessIdentity() throws {
    try FileManager.default.createDirectory(at: paths.appData, withIntermediateDirectories: true)
    let pidFile = paths.appData.appendingPathComponent("collector.pid")
    try "123".write(to: pidFile, atomically: true, encoding: .utf8)
    for identity in [RecorderProcessIdentity.recorder, .unknown] {
      XCTAssertThrowsError(try RecorderStartupGuard(paths: paths, identity: { pid in
        XCTAssertEqual(pid, 123); return identity
      }))
      XCTAssertEqual(try String(contentsOf: pidFile), "123")
    }
    for identity in [RecorderProcessIdentity.gone, .other] {
      var guardOwner: RecorderStartupGuard? = try RecorderStartupGuard(paths: paths, ownPID: 456, identity: { _ in identity })
      XCTAssertThrowsError(try RecorderStartupGuard(paths: paths, identity: { _ in .gone }))
      try guardOwner?.publish()
      XCTAssertEqual(try String(contentsOf: pidFile), "456")
      guardOwner = nil
      XCTAssertFalse(FileManager.default.fileExists(atPath: pidFile.path))
      try "123".write(to: pidFile, atomically: true, encoding: .utf8)
    }
  }
  func testNewStorageRecorderLockRejectsAnotherRecorder() throws {
    let first = try ActivityStorage(url: paths.database, appDataDirectory: paths.appData, role: .recorder, databaseScope: paths.databaseScope)
    XCTAssertThrowsError(try ActivityStorage(url: paths.database, appDataDirectory: paths.appData, role: .recorder, databaseScope: paths.databaseScope))
    withExtendedLifetime(first) {}
  }
  func testUnreadablePIDDoesNotBecomeAnAbsentPublication() throws {
    try FileManager.default.createDirectory(at: paths.appData, withIntermediateDirectories: true)
    let pid = paths.appData.appendingPathComponent("collector.pid")
    try Data("123".utf8).write(to: pid)
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: pid.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pid.path) }
    XCTAssertThrowsError(try RecorderStartupGuard(paths: paths, identity: { _ in
      XCTFail("An unreadable PID must never reach process inspection"); return .gone
    }))
  }

}
