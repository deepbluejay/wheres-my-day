import Core
import Foundation
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
}
