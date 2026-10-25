import Core
import Foundation
@testable import Inbound
import Shell
import XCTest
import Darwin

struct InventedFileVault: FileVaultStatusSource {
  func fileVaultStatus() -> FileVaultStatus { .unknown }
}

final class SecurityHealthTests: XCTestCase {
  func testFixedFileVaultSentencesAndExitStatus() throws {
    let cases: [(String, Int32, FileVaultStatus)] = [
      ("FileVault is On.\n", 0, .on), ("FileVault is Off.\n", 0, .off),
      ("Encryption in progress: Percent completed = 25", 0, .unknown),
      ("Invented unknown", 0, .unknown), ("FileVault is On.", 1, .unknown),
      ("FileVault is On.\nInvented extra", 0, .unknown)]
    for (text, status, expected) in cases {
      let reader = FileVaultReader(run: { XCTAssertEqual($0.path, "/usr/bin/fdesetup"); XCTAssertEqual($1, ["status"]); return (text, status) })
      XCTAssertEqual(reader.fileVaultStatus(), expected)
      let task = SecurityHealthTask(fileVault: reader, storage: StorageSecurityHealth(backupExclusionFailure: .backupExclusionFailed))
      try task.maintenanceTask.run(1)
      XCTAssertEqual(task.health.fileVault, expected)
      XCTAssertEqual(task.health.backupExclusionFailure?.rawValue, "backup_exclusion_failed")
    }
    XCTAssertEqual(FileVaultReader(run: { _, _ in throw NSError(domain: "invented", code: 1) }).fileVaultStatus(), .unknown)
  }
  func testFileVaultDeadlineKillsHungChildAndMaintenanceContinues() throws {
    XCTAssertEqual(FileVaultReader.statusTimeoutSeconds, 10)
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ACTIVITYPROBE_TEST_ROOT"] ?? NSTemporaryDirectory())
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for closeOutput in [false, true] {
      let executable = URL(fileURLWithPath: "/bin/sh")
      let pidFile = root.appendingPathComponent("pid")
      let termFile = root.appendingPathComponent("term")
      let script = "trap 'echo term > \"\(termFile.path)\"; exit 0' TERM\necho $$ > '\(pidFile.path)'\nprintf 'FileVault is On.'\n\(closeOutput ? "exec 1>&-" : "")\nwhile :; do :; done\n"
      let reader = FileVaultReader(run: { _, _ in
        try FileVaultReader.runStatus(executable, arguments: ["-c", script], timeout: 0.5)
      })
      let task = SecurityHealthTask(fileVault: reader, storage: StorageSecurityHealth())
      let started = ProcessInfo.processInfo.systemUptime
      try task.maintenanceTask.run(0)
      XCTAssertEqual(task.health.fileVault, .unknown)
      XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 2)
      let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile).trimmingCharacters(in: .whitespacesAndNewlines)))
      XCTAssertEqual(kill(pid, 0), -1)
      XCTAssertEqual(errno, ESRCH)
      XCTAssertFalse(FileManager.default.fileExists(atPath: termFile.path))
      var continued = false
      try RecorderMaintenanceTask(name: "invented-next") { _ in continued = true }.run(0)
      XCTAssertTrue(continued)
    }
  }
  func testFileVaultReadsAtMostOnceAnHourIncludingUnknown() throws {
    var reads = 0
    let reader = FileVaultReader(run: { _, _ in
      reads += 1
      return (reads == 1 ? "Invented unknown" : "FileVault is On.", 0)
    })
    let task = SecurityHealthTask(fileVault: reader, storage: StorageSecurityHealth())
    for now in [100, 100, 400, 3699] { try task.maintenanceTask.run(now) }
    XCTAssertEqual(reads, 1)
    XCTAssertEqual(task.health.fileVault, .unknown)
    try task.maintenanceTask.run(3700)
    XCTAssertEqual(reads, 2)
    XCTAssertEqual(task.health.fileVault, .on)
    try task.maintenanceTask.run(7299)
    XCTAssertEqual(reads, 2)
  }
  // Ideal: after a backward jump the old timestamp cannot defer a read for a day.
  func testFileVaultReadsWithinAnHourAfterClockMovesBack() throws {
    var reads = 0
    let reader = FileVaultReader(run: { _, _ in
      reads += 1
      return (reads == 1 ? "Invented unknown" : "FileVault is On.", 0)
    })
    let task = SecurityHealthTask(fileVault: reader, storage: StorageSecurityHealth())
    try task.maintenanceTask.run(1_000_000)
    for now in [900_000, 900_000, 903_599] { try task.maintenanceTask.run(now) }
    XCTAssertEqual(reads, 1)
    XCTAssertEqual(task.health.fileVault, .unknown)
    try task.maintenanceTask.run(903_600)
    XCTAssertEqual(reads, 2)
    XCTAssertEqual(task.health.fileVault, .on)
    for now in stride(from: 907_200, through: 999_000, by: 3_600) {
      let before = reads
      try task.maintenanceTask.run(now)
      XCTAssertEqual(reads, before + 1)
    }
  }
  func testConnectionsPassExpectedAppFolderToBothStorageRoles() throws {
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ACTIVITYPROBE_TEST_ROOT"] ?? NSTemporaryDirectory())
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let expected = root.appendingPathComponent("expected", isDirectory: true)
    try FileManager.default.createDirectory(at: expected, withIntermediateDirectories: true)
    let connections = try RecorderConnections(database: root.appendingPathComponent("override.sqlite"),
      appDataDirectory: expected, userHome: root.path, processes: InventedProcesses(), fileVault: InventedFileVault(), databaseScope: .directory(root))
    for store in [connections.recorder, connections.client] {
      XCTAssertEqual(store.securityHealth.backupExclusionFailure?.rawValue, "backup_exclusion_skipped_override")
    }
    XCTAssertEqual(connections.securityTask.health.backupExclusionFailure?.rawValue, "backup_exclusion_skipped_override")
    XCTAssertNotEqual(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    XCTAssertNotEqual(try expected.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
  }
  func testAppDataOverrideUnifiesCallerAndLogExclusion() throws {
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ACTIVITYPROBE_TEST_ROOT"] ?? NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = ToolLogFiles(tool: .codex, userHome: root.appendingPathComponent("person").path,
      processes: InventedProcesses(), appDataDirectory: root.appendingPathComponent("override"))
    XCTAssertEqual(source.excludedSummaryHome, AppDataPaths.summaryCodexHome(in: root.appendingPathComponent("override")).resolvingSymlinksInPath().standardizedFileURL)
  }
}
