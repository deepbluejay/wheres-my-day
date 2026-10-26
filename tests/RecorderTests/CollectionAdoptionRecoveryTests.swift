import Core
import Darwin
import Foundation
import Shell
import SQLite3
import XCTest
@testable import Storage

final class CollectionAdoptionRecoveryTests: XCTestCase {
  func testAdoptionCrashFixture() throws {
    guard let path = ProcessInfo.processInfo.environment["AP_ADOPTION_CRASH_ROOT"],
      let point = ProcessInfo.processInfo.environment["AP_ADOPTION_CRASH_POINT"] else { return }
    let root = URL(fileURLWithPath: path)
    let connection = try SQLiteConnection(url: root.appendingPathComponent("invented.sqlite"), scope: .directory(root))
    if point == "before-commit" {
      sqlite3_set_authorizer(connection.handle, { _, action, name, value, _, _ in
        if action == SQLITE_PRAGMA, let name, let value,
          String(cString: name) == "user_version", String(cString: value) == "14" { _exit(73) }
        return SQLITE_OK
      }, nil)
    }
    try connection.createSchema()
    _exit(73)
  }

  func testInterruptedAdoptionRetriesAtomicallyAndRecorderImmediatelyResumes() throws {
    let scratch = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ACTIVITYPROBE_TEST_ROOT"] ?? NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    for point in ["before-commit", "after-commit"] {
      let root = scratch.appendingPathComponent(point)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let url = root.appendingPathComponent("invented.sqlite")
      // An invented migration-boundary fixture, not a claim to recreate actual main's schema.
      do {
        let seed = try ActivityStorage(url: url, appDataDirectory: root, databaseScope: .directory(root))
        try seed.saveSettings(StorageSettings(excludedApps: []))
        try seed.appendSamples([TimeSample(ts: 50, app: "Invented historical")])
        try seed.connection.run("DROP TABLE sample_observations")
        try seed.connection.run("DROP TRIGGER screen_payload_delete")
        try seed.connection.run("DROP TABLE screen_payloads")
        try seed.connection.run("PRAGMA user_version=9")
      }
      let child = Process()
      child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
      child.arguments = ["-XCTest", "RecorderTests.CollectionAdoptionRecoveryTests/testAdoptionCrashFixture", Bundle(for: Self.self).bundleURL.path]
      var environment = ProcessInfo.processInfo.environment
      environment["AP_ADOPTION_CRASH_ROOT"] = root.path; environment["AP_ADOPTION_CRASH_POINT"] = point
      child.environment = environment; child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
      try child.run(); child.waitUntilExit(); XCTAssertEqual(child.terminationStatus, 73)
      do {
        let check = try SQLiteConnection(url: url, scope: .directory(root))
        XCTAssertEqual(try check.integer("PRAGMA user_version"), point == "before-commit" ? 9 : 14)
        XCTAssertEqual(try check.integer("SELECT count(*) FROM sqlite_master WHERE name='sample_observations'"), point == "before-commit" ? 0 : 1)
        XCTAssertEqual(try check.integer("SELECT count(*) FROM samples WHERE ts=50"), 1)
      }
      let adopted = try ActivityStorage(url: url, appDataDirectory: root, databaseScope: .directory(root))
      XCTAssertEqual(try adopted.connection.integer("PRAGMA user_version"), 14)
      let clock = FakeClock(), sources = FakeSources(); sources.clock = clock; clock.now = 100
      let loop = RecorderLoop(clock: clock, input: sources, front: sources, secure: sources, awake: sources,
        screen: sources, storage: adopted, maintenanceStorage: adopted, ownBundleID: "invented.own")
      loop.tick(); loop.stop()
      XCTAssertEqual(try adopted.samples(in: TimeRange(0, 101)).map(\.ts), [50, 100])
      XCTAssertEqual(try adopted.connection.integer("SELECT count(*) FROM screen_payloads"), 1)
      XCTAssertEqual(try adopted.connection.integer("SELECT count(*) FROM pragma_foreign_key_check"), 0)
      var integrity = ""; try adopted.connection.namedRows("PRAGMA integrity_check") { integrity = try $0.text("integrity_check") }
      XCTAssertEqual(integrity, "ok")
      let finished = expectation(description: "Adopted recorder finished")
      loop.finishMaintenance { finished.fulfill() }; wait(for: [finished], timeout: 60)
    }
  }
}
