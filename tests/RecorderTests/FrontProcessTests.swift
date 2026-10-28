import Core
import Foundation
@testable import Inbound
@testable import Storage
import XCTest

/// The probe gate reads the front application on every AX call, off the main thread.
final class FrontProcessTests: XCTestCase {
  final class Fakes {
    var process: FrontProcess? = FrontProcess(pid: 10, serial: 1)
    var failure = FrontProcessFailure.error
    let usage = StageUsage()
    var applications: [Int32: String] = [10: "invented.editor", 11: "invented.secret"]
    var lookups = 0, mainReads = 0, comparisons = 0, mainHops = 0
    var duringLookup: () -> Void = {}
    var now = 100.0
    var workspace: Int32? = 10
    var activated: () -> Void = {}
    /// NSWorkspace names `pid`, after its activation notification.
    func activate(_ pid: Int32) { workspace = pid; activated() }
    lazy var source = MacFrontWindowSource(boundary: FrontWindowBoundary(
      application: { self.mainReads += 1; return FrontObservation(bundleID: "invented.main", processID: 99) },
      listed: { _ in ("", nil) }, trusted: { true }, focused: { _ in nil }, attribute: { _, _ in nil },
      browser: { _ in nil }, uptime: { self.now }, wallTime: { 0 }, work: { $0() },
      frontProcess: { self.process.map { .success($0) } ?? .failure(self.failure) },
      runningApplication: { pid in
        self.lookups += 1; self.duringLookup()
        return self.applications[pid].map { FrontObservation(bundleID: $0, app: "Invented", isBrowserKnown: false, processID: pid) }
      }, workspaceProcess: { self.comparisons += 1; return self.workspace }, main: { self.mainHops += 1; $0() },
      activations: { handler in self.activated = handler; return { self.activated = {} } },
      count: { self.usage.count($0.rawValue) }))
  }
  func testEachLaunchInFrontIsLookedUpOnceAndAChangeIsSeenAtOnce() {
    let fakes = Fakes()
    XCTAssertEqual(fakes.source.frontApplication().bundleID, "invented.editor")
    XCTAssertEqual(fakes.source.frontApplication().bundleID, "invented.editor")
    XCTAssertEqual(fakes.lookups, 1)
    // A switch to an excluded application mid-traversal: the very next read names it.
    fakes.process = FrontProcess(pid: 11, serial: 2)
    XCTAssertEqual(fakes.source.frontApplication().bundleID, "invented.secret")
    XCTAssertEqual(fakes.mainReads, 0)
  }
  func testAReusedPidIsANewLaunch() {
    let fakes = Fakes()
    XCTAssertEqual(fakes.source.frontApplication().bundleID, "invented.editor")
    fakes.process = FrontProcess(pid: 10, serial: 3)
    fakes.applications[10] = "invented.secret"
    XCTAssertEqual(fakes.source.frontApplication().bundleID, "invented.secret")
  }
  func testUnknownFrontFallsBackToTheMainThreadAnswer() {
    let fakes = Fakes()
    fakes.process = nil
    XCTAssertEqual(fakes.source.frontApplication().bundleID, "invented.main")
    // A process without an application identity, and a front that changes during the lookup.
    fakes.process = FrontProcess(pid: 12, serial: 4)
    XCTAssertEqual(fakes.source.frontApplication().bundleID, "invented.main")
    fakes.process = FrontProcess(pid: 10, serial: 5)
    fakes.duringLookup = { fakes.process = FrontProcess(pid: 11, serial: 6) }
    XCTAssertEqual(fakes.source.frontApplication().bundleID, "invented.main")
    XCTAssertEqual(fakes.mainReads, 3)
    fakes.duringLookup = {}
    XCTAssertEqual(fakes.source.frontApplication().bundleID, "invented.secret")
  }
  func testAReadOffTheMainThreadDoesNotWaitForIt() {
    let fakes = Fakes()
    let done = DispatchSemaphore(value: 0)
    var answer = ""
    DispatchQueue.global().async { answer = fakes.source.frontApplication().bundleID; done.signal() }
    // The main thread is busy here; a hop to it would not return within the wait.
    XCTAssertEqual(done.wait(timeout: .now() + 2), .success)
    XCTAssertEqual(answer, "invented.editor")
  }

  /// A call that keeps naming one process while NSWorkspace follows the switches is not
  /// used again once the settled checks disagree `disagreementLimit` times in a row.
  func testAStaleFrontProcessIsTurnedOffAfterTheDisagreementLimit() {
    let fakes = Fakes()
    _ = fakes.source.frontApplication()
    fakes.activate(11)
    for _ in 1...FrontProcessGuard.disagreementLimit {
      fakes.now += FrontProcessGuard.checkSeconds
      XCTAssertEqual(fakes.source.frontApplication().bundleID, "invented.editor")
    }
    XCTAssertEqual(fakes.mainReads, 0)
    // The last check ran during that call; the next one asks NSWorkspace's side.
    XCTAssertEqual(fakes.source.frontApplication().bundleID, "invented.main")
    XCTAssertEqual(fakes.comparisons, FrontProcessGuard.disagreementLimit)
    // Off for good: an agreeing front later does not bring it back.
    fakes.activate(10); fakes.now += 60
    XCTAssertEqual(fakes.source.frontApplication().bundleID, "invented.main")
  }
  /// A switch that lands between the call and NSWorkspace's update disagrees once; the next
  /// settled check agrees, so the call stays in use.
  func testTransientDisagreementsDuringSwitchesKeepTheFrontProcess() {
    let fakes = Fakes()
    _ = fakes.source.frontApplication()
    for _ in 1...4 {
      fakes.now += FrontProcessGuard.checkSeconds
      fakes.workspace = 9  // the switch's notification is not delivered yet
      _ = fakes.source.frontApplication()
      fakes.activate(10); fakes.now += FrontProcessGuard.checkSeconds
      _ = fakes.source.frontApplication()
    }
    XCTAssertEqual(fakes.comparisons, 8)
    XCTAssertEqual(fakes.source.frontApplication().bundleID, "invented.editor")
    XCTAssertEqual(fakes.mainReads, 0)
  }
  /// No comparison while activations keep coming, and one at most per check interval however
  /// many gate calls ask.
  func testComparisonsWaitForASettledFrontAndNeverRunPerCall() {
    let fakes = Fakes()
    for _ in 0..<60 {
      fakes.activate(10)
      for _ in 0..<100 { fakes.now += 0.02; _ = fakes.source.frontApplication() }
    }
    XCTAssertEqual(fakes.comparisons, 0)
    XCTAssertEqual(fakes.mainHops, 0)
    fakes.now += FrontProcessGuard.settledSeconds
    for _ in 0..<1_000 { _ = fakes.source.frontApplication() }
    XCTAssertEqual(fakes.comparisons, 1)
    fakes.now += FrontProcessGuard.checkSeconds - 0.5
    for _ in 0..<1_000 { _ = fakes.source.frontApplication() }
    XCTAssertEqual(fakes.comparisons, 1)
    fakes.now += 0.5
    _ = fakes.source.frontApplication()
    XCTAssertEqual(fakes.comparisons, 2)
  }

  /// `status` shows how the front was read, as numbers only, and zeros before any count.
  func testStatusShowsFrontReadCountsAsNumbersOnly() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = try ActivityStorage(url: root.appendingPathComponent("invented.sqlite"), appDataDirectory: root, databaseScope: .directory(root))
    // A file written before the counts existed.
    try storage.saveStageUsage(StageUsage.Snapshot(time: 5, stages: [:]))
    for count in FrontApplicationCount.allCases {
      XCTAssertTrue(storage.stageUsageStatus().contains("\(count.rawValue)=0"), count.rawValue)
    }
    let fakes = Fakes()
    fakes.process = nil; fakes.failure = .missingSymbol; _ = fakes.source.frontApplication()
    fakes.failure = .error; _ = fakes.source.frontApplication(); _ = fakes.source.frontApplication()
    fakes.process = FrontProcess(pid: 12, serial: 4); _ = fakes.source.frontApplication()
    fakes.process = FrontProcess(pid: 10, serial: 5)
    fakes.duringLookup = { fakes.process = FrontProcess(pid: 11, serial: 6) }
    _ = fakes.source.frontApplication()
    fakes.duringLookup = {}
    fakes.activate(12)
    for _ in 0...FrontProcessGuard.disagreementLimit {
      fakes.now += FrontProcessGuard.checkSeconds; _ = fakes.source.frontApplication()
    }
    try storage.saveStageUsage(fakes.usage.roll(at: 10))
    let status = storage.stageUsageStatus()
    let limit = FrontProcessGuard.disagreementLimit
    for expected in ["front_comparisons=\(limit)", "front_disagreements=\(limit)", "front_fallback_missing_symbol=1",
      "front_fallback_error=2", "front_fallback_no_identity=1", "front_fallback_changed_during_lookup=1",
      "front_fast_path_disabled=1"] {
      XCTAssertTrue(status.split(separator: " ").contains(Substring(expected)), "\(expected) in \(status)")
    }
    let front = status.split(separator: " ").filter { $0.hasPrefix("front_") }
    XCTAssertEqual(front.count, FrontApplicationCount.allCases.count)
    for field in front {
      let parts = field.split(separator: "=")
      XCTAssertEqual(parts.count, 2, status)
      XCTAssertTrue(parts[0].allSatisfy { $0 == "_" || ("a"..."z").contains($0) }, status)
      XCTAssertNotNil(UInt(parts[1]), status)
    }
  }
}
