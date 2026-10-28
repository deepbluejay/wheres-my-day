import Core
import Foundation
import SQLite3
import XCTest
@testable import Storage

/// The probe gate reuses stored policy inputs. Every privacy change, from this
/// connection or another one, must apply to the very next check.
extension StorageTests {
  private func gateFixture() throws -> (ActivityStorage, ActivityStorage, AXProbeRequest) {
    let store = try ActivityStorage(url: url, appDataDirectory: folder, databaseScope: .directory(folder))
    try store.saveSettings(StorageSettings(excludedApps: []), at: 0)
    let run = try store.enableAXProbe(at: 10000)
    let other = try ActivityStorage(url: url, appDataDirectory: folder, databaseScope: .directory(folder))
    let request = AXProbeRequest(run: run, attemptID: UUID().uuidString, time: 10001,
      window: WindowIdentity(processID: 10, windowID: 20), bundleID: "invented.editor", isBrowser: false)
    // Two checks: the second is answered from the stored inputs.
    XCTAssertTrue(try store.axProbeAllowed(request, at: 10001))
    XCTAssertTrue(try store.axProbeAllowed(request, at: 10001))
    return (store, other, request)
  }
  private func edit(_ store: ActivityStorage, _ change: (inout StorageSettings) -> Void) throws {
    var settings = try store.settings(); change(&settings); try store.saveSettings(settings, at: 10001)
  }
  func testProbeGateAppliesPauseAndRecordingOffFromEitherConnectionAtOnce() throws {
    let (store, other, request) = try gateFixture()
    try edit(store) { $0.pausedUntil = 20000 }
    XCTAssertFalse(try store.axProbeAllowed(request, at: 10001))
    try edit(store) { $0.pausedUntil = nil }
    XCTAssertTrue(try store.axProbeAllowed(request, at: 10001))
    try edit(other) { $0.pausedUntil = 20000 }
    XCTAssertFalse(try store.axProbeAllowed(request, at: 10001))
    XCTAssertEqual(try store.settings().pausedUntil, 20000)
    try edit(other) { $0.pausedUntil = nil; $0.recordingEnabled = false }
    XCTAssertFalse(try store.axProbeAllowed(request, at: 10001))
    XCTAssertFalse(try store.settings().recordingEnabled)
  }
  func testProbeGateAppliesExclusionFromAnotherConnectionAtOnce() throws {
    let (store, other, request) = try gateFixture()
    try edit(other) { $0.excludedApps = ["invented.editor"] }
    XCTAssertFalse(try store.axProbeAllowed(request, at: 10001))
    XCTAssertEqual(try store.settings().excludedApps, ["invented.editor"])
  }
  func testProbeGateChecksExclusionForEachApplicationOfTheSameAttempt() throws {
    let (store, _, request) = try gateFixture()
    try edit(store) { $0.excludedApps = ["invented.secret"] }
    XCTAssertTrue(try store.axProbeAllowed(request, at: 10001))
    var secret = request; secret.bundleID = "invented.secret"
    XCTAssertFalse(try store.axProbeAllowed(secret, at: 10001))
    var other = request; other.run.start += 1
    XCTAssertFalse(try store.axProbeAllowed(other, at: 10001))
  }
  func testProbeGateAppliesForgetAndRunCancellationFromAnotherConnectionAtOnce() throws {
    let (store, other, request) = try gateFixture()
    let preview = try other.previewDeletion(in: TimeRange(10001, 10002))
    _ = try other.deleteRecords(in: preview.range, confirmation: preview.confirmation)
    XCTAssertFalse(try store.axProbeAllowed(request, at: 10001))
    var later = request; later.time = 10003
    XCTAssertTrue(try store.axProbeAllowed(later, at: 10003))
    try other.disableAXProbe(at: 10003)
    XCTAssertFalse(try store.axProbeAllowed(later, at: 10003))
  }
  func testProbeGateAppliesReviewLeaseFromAnotherConnectionAtOnce() throws {
    let (store, other, request) = try gateFixture()
    let continuous = AXProbeReviewLease.continuous()
    let lease = #"{"boot":"\#(AXProbeReviewLease.bootID())","sessionStart":\#(continuous - 1),"issued":\#(continuous - 1),"deadline":\#(continuous + 9),"issuedWall":10000,"deadlineWall":10009}"#
    try other.connection.run("INSERT OR REPLACE INTO settings(key,value) VALUES('general.axProbe.reviewActive','1'),('general.axProbe.reviewLease',?)", [.key(lease)])
    XCTAssertFalse(try store.axProbeAllowed(request, at: 10001))
  }
  func testProbeGateAppliesRunCancellationThroughSameConnectionAtOnce() throws {
    let (store, _, request) = try gateFixture()
    // A counter write in between is not a policy change and keeps the gate open.
    try store.countAXProbeEvent(runID: request.run.id, event: .eligible)
    XCTAssertTrue(try store.axProbeAllowed(request, at: 10001))
    try store.connection.run("UPDATE ax_probe_runs SET cancelled=1 WHERE id=?", [.key(request.run.id)])
    XCTAssertFalse(try store.axProbeAllowed(request, at: 10001))
  }
  func testRolledBackSettingsReadInsideTransactionAreNotReused() throws {
    let (store, _, request) = try gateFixture()
    try edit(store) { $0.pausedUntil = 20000 }
    XCTAssertFalse(try store.axProbeAllowed(request, at: 10001))
    struct Abandon: Error {}
    XCTAssertThrowsError(try store.locked {
      try store.connection.transaction {
        var settings = try store.settings(); settings.pausedUntil = nil
        try store.writeSettings(settings)
        // Uncommitted: open inside this transaction only.
        XCTAssertTrue(try store.axProbeAllowed(request, at: 10001))
        throw Abandon()
      }
    })
    XCTAssertEqual(try store.settings().pausedUntil, 20000)
    XCTAssertFalse(try store.axProbeAllowed(request, at: 10001))
  }

  // The review's scratch scenarios, and the write patterns the revision now tells apart.
  private func sqlite3(_ sql: String) throws {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    child.arguments = [url.path, sql]
    try child.run(); child.waitUntilExit()
    XCTAssertEqual(child.terminationStatus, 0)
  }
  func testProbeGateAppliesChangesWrittenByAnotherProcessAtOnce() throws {
    let (store, _, request) = try gateFixture()
    let changes = [
      ("UPDATE settings SET value='0' WHERE key='recording'", "UPDATE settings SET value='1' WHERE key='recording'"),
      ("INSERT INTO settings(key,value) VALUES('app.0','invented.editor')", "DELETE FROM settings WHERE key='app.0'"),
      ("INSERT INTO forgotten_ranges(start_ts,end_ts) VALUES(10000,10005)", "DELETE FROM forgotten_ranges"),
      ("UPDATE ax_probe_runs SET cancelled=1", "UPDATE ax_probe_runs SET cancelled=0"),
    ]
    for (change, undo) in changes {
      try sqlite3(change)
      XCTAssertFalse(try store.axProbeAllowed(request, at: 10001), change)
      try sqlite3(undo)
      XCTAssertTrue(try store.axProbeAllowed(request, at: 10001), undo)
    }
  }
  func testProbeGateAppliesForgetThroughTheSameConnectionAtOnce() throws {
    let (store, _, request) = try gateFixture()
    let preview = try store.previewDeletion(in: TimeRange(10001, 10002))
    _ = try store.deleteRecords(in: preview.range, confirmation: preview.confirmation)
    XCTAssertFalse(try store.axProbeAllowed(request, at: 10001))
  }
  func testProbeGateFollowsSavepointsAndAnotherConnectionsTransaction() throws {
    let (store, other, request) = try gateFixture()
    try store.locked {
      try store.connection.run("SAVEPOINT invented")
      try store.connection.run("UPDATE ax_probe_runs SET cancelled=1")
      XCTAssertFalse(try store.axProbeAllowed(request, at: 10001))
      try store.connection.run("ROLLBACK TO invented")
      XCTAssertTrue(try store.axProbeAllowed(request, at: 10001))
      try store.connection.run("UPDATE ax_probe_runs SET cancelled=1")
      try store.connection.run("RELEASE invented")
    }
    XCTAssertFalse(try store.axProbeAllowed(request, at: 10001))
    try store.connection.run("UPDATE ax_probe_runs SET cancelled=0")
    XCTAssertTrue(try store.axProbeAllowed(request, at: 10001))
    try other.connection.run("BEGIN IMMEDIATE")
    try other.connection.run("UPDATE settings SET value='0' WHERE key='recording'")
    // Not committed yet: the gate still reads the committed state.
    XCTAssertTrue(try store.axProbeAllowed(request, at: 10001))
    try other.connection.run("COMMIT")
    XCTAssertFalse(try store.axProbeAllowed(request, at: 10001))
  }
  func testProbeGateAppliesChangesAcrossCheckpointsAndWALReset() throws {
    let (store, other, request) = try gateFixture()
    try other.connection.run("UPDATE settings SET value='0' WHERE key='recording'")
    XCTAssertTrue(other.connection.truncateWAL())
    XCTAssertFalse(try store.axProbeAllowed(request, at: 10001))
    try other.connection.run("UPDATE settings SET value='1' WHERE key='recording'")
    XCTAssertTrue(other.connection.truncateWAL())
    XCTAssertTrue(try store.axProbeAllowed(request, at: 10001))
    // The WAL starts again from its first frame; the change is still seen.
    try other.connection.run("UPDATE ax_probe_runs SET cancelled=1")
    XCTAssertFalse(try store.axProbeAllowed(request, at: 10001))
  }
  func testProbeGateEvaluatesPauseExpiryOnEveryCheck() throws {
    let (store, _, request) = try gateFixture()
    try edit(store) { $0.pausedUntil = 20000 }
    XCTAssertFalse(try store.axProbeAllowed(request, at: 19999))
    XCTAssertTrue(try store.axProbeAllowed(request, at: 20000))
    XCTAssertFalse(try store.axProbeAllowed(request, at: 19999))
  }
  func testProbeGateEvaluatesReviewLeaseExpiryOnEveryCheck() throws {
    let (store, other, request) = try gateFixture()
    let continuous = AXProbeReviewLease.continuous()
    let lease = #"{"boot":"\#(AXProbeReviewLease.bootID())","sessionStart":\#(continuous - 1),"issued":\#(continuous - 1),"deadline":\#(continuous + 0.5),"issuedWall":10000,"deadlineWall":10009}"#
    try other.connection.run("INSERT OR REPLACE INTO settings(key,value) VALUES('general.axProbe.reviewActive','1'),('general.axProbe.reviewLease',?)", [.key(lease)])
    XCTAssertFalse(try store.axProbeAllowed(request, at: 10001))
    // No write in between: only the continuous clock moves past the deadline.
    Thread.sleep(forTimeInterval: 0.7)
    XCTAssertTrue(try store.axProbeAllowed(request, at: 10001))
  }
  func testOtherWritesThroughTheSameConnectionKeepStoredPolicyReads() throws {
    let (store, _, request) = try gateFixture()
    PolicyReadStats.counting = true
    defer { PolicyReadStats.counting = false }
    _ = PolicyReadStats.take()
    // Counters, probe content and an unrelated row: none is read by the gate.
    try store.countAXProbeEvent(runID: request.run.id, event: .eligible)
    try store.connection.run("INSERT INTO ax_probe_blobs(hash,bytes,created_ts) VALUES('invented',1,10001)")
    try store.locked { try store.connection.transaction { try store.connection.run("DELETE FROM ax_probe_blobs") } }
    XCTAssertTrue(try store.axProbeAllowed(request, at: 10001))
    _ = try store.settings()
    let reads = PolicyReadStats.take()
    XCTAssertEqual(reads["probe"]?.misses, 0)
    XCTAssertEqual(reads["settings"]?.misses, 0)
    XCTAssertTrue(store.connection.policyTables.isSuperset(of: ["settings", "ax_probe_runs", "forgotten_ranges"]))
  }
  func testProbeGateSeesPolicyWritesMadeByATrigger() throws {
    let (store, _, request) = try gateFixture()
    try store.connection.run("CREATE TEMP TRIGGER invented_cancel AFTER INSERT ON ax_probe_blobs BEGIN UPDATE ax_probe_runs SET cancelled=1; END")
    XCTAssertTrue(try store.axProbeAllowed(request, at: 10001))
    try store.connection.run("INSERT INTO ax_probe_blobs(hash,bytes,created_ts) VALUES('invented',1,10001)")
    XCTAssertFalse(try store.axProbeAllowed(request, at: 10001))
  }
  func testPolicyReadsInsideWriteTransactionsFollowOwnWritesAndLaterCommits() throws {
    let (store, other, request) = try gateFixture()
    try store.locked {
      try store.connection.transaction {
        XCTAssertTrue(try store.axProbeAllowed(request, at: 10001))
        try store.connection.run("UPDATE ax_probe_runs SET cancelled=1")
        XCTAssertFalse(try store.axProbeAllowed(request, at: 10001))
        try store.connection.run("UPDATE ax_probe_runs SET cancelled=0")
        XCTAssertTrue(try store.axProbeAllowed(request, at: 10001))
      }
    }
    try other.disableAXProbe(at: 10002)
    // A later write transaction reads the version again.
    try store.locked {
      try store.connection.transaction { XCTAssertFalse(try store.axProbeAllowed(request, at: 10002)) }
    }
  }
  func testPolicyReadsAreNotReusedAfterAnImplicitRollback() throws {
    let (store, _, request) = try gateFixture()
    try store.countAXProbeEvent(runID: request.run.id, event: .eligible)
    try store.locked {
      try store.connection.run("BEGIN IMMEDIATE")
      try store.connection.run("UPDATE settings SET value='0' WHERE key='recording'")
      XCTAssertFalse(try store.axProbeAllowed(request, at: 10001))
      // The conflict rolls the whole transaction back without a ROLLBACK statement.
      XCTAssertThrowsError(try store.connection.run("INSERT OR ROLLBACK INTO ax_probe_flow(run_id,event,total) SELECT run_id,event,total FROM ax_probe_flow"))
      XCTAssertEqual(sqlite3_get_autocommit(store.connection.handle), 1)
    }
    XCTAssertTrue(try store.settings().recordingEnabled)
    XCTAssertTrue(try store.axProbeAllowed(request, at: 10001))
  }
}
