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
    var activated: (Int32?) -> Void = { _ in }
    /// The call's answer; the simulation replaces it with a model of a wrong call.
    lazy var call: () -> FrontProcess? = { self.process }
    /// Work running as the main thread: hops, activation handlers. Front-process reads made
    /// there are counted, at most `mainReadsPerCompare` between two comparisons.
    var onMain = false
    var mainFrontReads = 0, mainReadsPerCompare = 0
    var mainProcess: () -> Int32 = { 99 }
    var counted: [FrontApplicationCount: Int] = [:]
    var activating = false, activationDisagreements = 0
    /// NSWorkspace names `pid`, after its activation notification.
    func activate(_ pid: Int32) { workspace = pid; activating = true; asMain { activated(pid) }; activating = false }
    func asMain(_ work: () -> Void) { let was = onMain; onMain = true; work(); onMain = was }
    lazy var source = MacFrontWindowSource(boundary: FrontWindowBoundary(
      application: { self.mainReads += 1; return FrontObservation(bundleID: "invented.main", processID: self.mainProcess()) },
      listed: { _ in ("", nil) }, trusted: { true }, focused: { _ in nil }, attribute: { _, _ in nil },
      browser: { _ in nil }, uptime: { self.now }, wallTime: { 0 }, work: { $0() },
      frontProcess: {
        if self.onMain { self.mainFrontReads += 1 }
        return self.call().map { .success($0) } ?? .failure(self.failure)
      },
      runningApplication: { pid in
        self.lookups += 1; self.duringLookup()
        return self.applications[pid].map { FrontObservation(bundleID: $0, app: "Invented", isBrowserKnown: false, processID: pid) }
      }, workspaceProcess: {
        self.comparisons += 1
        self.mainReadsPerCompare = max(self.mainReadsPerCompare, self.mainFrontReads); self.mainFrontReads = 0
        return self.workspace
      }, main: { work in self.mainHops += 1; self.asMain(work) },
      activations: { handler in self.activated = handler; return { self.activated = { _ in } } },
      count: {
        self.usage.count($0.rawValue); self.counted[$0, default: 0] += 1
        if self.activating, $0 == .disagreements { self.activationDisagreements += 1 }
      }))
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
  /// While activations keep coming, one comparison per check interval at most, run by the
  /// activation itself; once settled, one at most per check interval, however many gate calls
  /// ask. Each reads the call once on the main thread; gate calls never hop there to compare.
  func testComparisonsAreBoundedAndNeverRunPerCall() {
    let fakes = Fakes()
    _ = fakes.source.frontApplication()
    // An activation every 0.25 s for 75 s: checks at the 2nd and then every 20th.
    for _ in 0..<300 {
      fakes.now += 0.25
      fakes.activate(10)
      for _ in 0..<10 { _ = fakes.source.frontApplication() }
    }
    let switching = 300 / 20
    XCTAssertEqual(fakes.comparisons, switching)
    XCTAssertEqual(fakes.mainHops, 0)
    fakes.now += FrontProcessGuard.settledSeconds
    for _ in 0..<1_000 { _ = fakes.source.frontApplication() }
    XCTAssertEqual(fakes.comparisons, switching + 1)
    XCTAssertEqual(fakes.mainHops, 1)
    fakes.now += FrontProcessGuard.checkSeconds - 0.5
    for _ in 0..<1_000 { _ = fakes.source.frontApplication() }
    XCTAssertEqual(fakes.comparisons, switching + 1)
    fakes.now += 0.5
    _ = fakes.source.frontApplication()
    XCTAssertEqual(fakes.comparisons, switching + 2)
    XCTAssertEqual(fakes.mainReadsPerCompare, 1)
    XCTAssertEqual(fakes.mainReads, 0)
  }
  /// gate-cpu S2: a call stuck on one process while the person switched less than
  /// `settledSeconds` apart was never compared. A check now also runs on activation.
  func testAStaleFrontProcessIsCaughtWhileSwitchingFast() {
    let fakes = Fakes()
    _ = fakes.source.frontApplication()
    // 2.5 s apart: never settled, and every `switchesPerCheck`-th activation is checked.
    for index in 0..<(FrontProcessGuard.switchesPerCheck * FrontProcessGuard.disagreementLimit) {
      fakes.now += 2.5
      XCTAssertEqual(fakes.source.frontApplication().bundleID, "invented.editor")
      // NSWorkspace follows each switch; the call keeps naming pid 10.
      fakes.activate(index % 2 == 0 ? 11 : 12)
    }
    // The last disagreement is held for `raceSeconds`; the next activation counts it.
    XCTAssertEqual(fakes.source.frontApplication().bundleID, "invented.editor")
    fakes.now += 2.5; fakes.activate(11)
    XCTAssertEqual(fakes.comparisons, FrontProcessGuard.disagreementLimit)
    XCTAssertEqual(fakes.source.frontApplication().bundleID, "invented.main")
  }
  /// A call stuck on an app the person keeps returning to agrees on every other check; the
  /// disagreements among the latest checks on activation turn it off all the same.
  func testChanceAgreementsOnActivationDoNotSpareAStuckCall() {
    let fakes = Fakes()
    _ = fakes.source.frontApplication()
    var checks = 0
    while fakes.counted[.disabled] == nil, checks < FrontProcessGuard.activationWindow {
      for _ in 0..<FrontProcessGuard.switchesPerCheck {
        fakes.now += 2.5
        fakes.activate(checks % 2 == 0 ? 11 : 10)  // the call keeps naming pid 10
      }
      checks += 1
    }
    XCTAssertEqual(fakes.comparisons, 2 * FrontProcessGuard.disagreementLimit - 1)
    XCTAssertEqual(fakes.counted[.disabled], 1)
    XCTAssertEqual(fakes.source.frontApplication().bundleID, "invented.main")
  }

  /// Checks on activation land on whichever app is activated once `checkSeconds` have passed,
  /// so they alternate between two apps switched every second. Every 8th switch they would
  /// always land on the app a stuck call names. Once the call is off, activations check no more.
  func testACallStuckOnOneOfTwoAlternatingAppsIsTurnedOffAndThenNoLongerChecked() {
    let fakes = Fakes()
    _ = fakes.source.frontApplication()
    var switches = 0
    while fakes.counted[.disabled] == nil, switches < 40 {
      switches += 1; fakes.now += 1
      fakes.activate(switches % 2 == 1 ? 11 : 10)  // the call keeps naming pid 10
    }
    XCTAssertEqual(fakes.counted[.disabled], 1)
    XCTAssertEqual(fakes.counted[.disagreements], FrontProcessGuard.disagreementLimit)
    XCTAssertEqual(fakes.activationDisagreements, FrontProcessGuard.disagreementLimit)
    XCTAssertLessThanOrEqual(switches, 30)
    let comparisons = fakes.comparisons
    for index in 0..<100 { fakes.now += 1; fakes.activate(index % 2 == 0 ? 11 : 10) }
    XCTAssertEqual(fakes.comparisons, comparisons)
    XCTAssertEqual(fakes.mainFrontReads, 0)
    XCTAssertEqual(fakes.source.frontApplication().bundleID, "invented.main")
  }
  /// cpu-shoulds M2: an app that hands focus on within NSWorkspace's delivery lag has the call
  /// name the next app while the first activation is handled. The delivery of that next
  /// activation within `raceSeconds` withdraws the disagreement; any other one does not.
  func testAHeldDisagreementCountsUnlessTheActivationItNamedArrives() {
    let fakes = Fakes()
    fakes.applications[12] = "invented.viewer"
    fakes.process = FrontProcess(pid: 12, serial: 2)  // the call is ahead: pid 12 is in front
    _ = fakes.source  // registers for activations
    fakes.now += 2.5; fakes.activate(13)
    fakes.now += 2.5; fakes.activate(11)
    XCTAssertEqual(fakes.comparisons, 1)
    XCTAssertNil(fakes.counted[.disagreements])
    fakes.now += 0.05; fakes.activate(12)
    fakes.now += 2.5; fakes.activate(10)
    XCTAssertNil(fakes.counted[.disagreements])
    // Next check: held again, but the activation delivered within `raceSeconds` is another
    // app's, so the next activation after that counts it.
    fakes.now += 2.5; fakes.activate(11)
    XCTAssertEqual(fakes.comparisons, 2)
    fakes.now += 0.05; fakes.activate(13)
    XCTAssertNil(fakes.counted[.disagreements])
    fakes.now += FrontProcessGuard.raceSeconds; fakes.activate(12)
    XCTAssertEqual(fakes.counted[.disagreements], 1)
    XCTAssertEqual(fakes.activationDisagreements, 1)
    // Held with no activation after it: the next settled check counts it, then its own.
    fakes.now += FrontProcessGuard.checkSeconds; fakes.activate(11)
    XCTAssertEqual(fakes.comparisons, 3)
    XCTAssertEqual(fakes.counted[.disagreements], 1)
    fakes.now += FrontProcessGuard.checkSeconds
    _ = fakes.source.frontApplication()
    XCTAssertEqual(fakes.comparisons, 4)
    XCTAssertEqual(fakes.counted[.disagreements], 3)
    XCTAssertEqual(fakes.counted[.disabled], 1)
  }
  /// cpu-shoulds M2: with the window of checks on activation alone, a few percent of such
  /// quick hand-offs turned an honest call off within an hour of fast switching.
  func testAnHonestCallStaysInUseWhenAppsHandFocusOnQuickly() {
    for usage in [Usage.every(0.3...1.0), .mixed] {
      let run = Self.simulate(usage, .honest, lags: 0.005...0.05, handOffs: 0.1)
      let label = "\(usage): \(run)"
      XCTAssertEqual(run.disables, 0, label)
      XCTAssertEqual(run.activationDisagreements, 0, label)
      XCTAssertLessThan(run.disagreements, run.compares / 100, label)
      XCTAssertGreaterThan(run.compares, 1_500, label)
    }
  }

  /// cpu-shoulds S1: NSWorkspace names a new front only once its activation is delivered on
  /// the main thread, while the call names it at once. A check after switches that ran in
  /// between counted a disagreement, and three in a row turned an honest call off. Checked on
  /// activation, an honest call agrees whenever NSWorkspace follows before the next switch;
  /// only a settled check may still race the first switch after a pause, once at a time.
  func testAnHonestCallWithALaggingWorkspaceStaysInUse() {
    let usages: [Usage] = [.every(0.3...1.0), .every(0.5...2.0), .every(1.0...3.0), .mixed]
    for usage in usages {
      for lag in [0.1, 0.3] {
        let run = Self.simulate(usage, .honest, lag: lag)
        let label = "\(usage), \(lag) s: \(run)"
        XCTAssertEqual(run.activationDisagreements, 0, label)
        XCTAssertEqual(run.disables, 0, label)
        if case .every = usage { XCTAssertEqual(run.disagreements, 0, label) }
        XCTAssertLessThan(run.disagreements, run.compares / 100, label)
        XCTAssertGreaterThan(run.compares, 1_500, label)
        XCTAssertEqual(run.mainReadsPerCompare, 1, label)
        XCTAssertGreaterThanOrEqual(run.shortestCheckGap, FrontProcessGuard.checkSeconds, label)
      }
    }
  }
  /// A call that stays on one process is turned off within a minute of switching, again after
  /// each restart: one the person also switches to, and one without an application identity.
  func testAStuckCallIsTurnedOffWithinAMinute() {
    for usage in [Usage.every(0.3...1.0), .mixed] {
      for (call, applications) in [(Call.stuck, 4), (.stuck, 2), (.stuckWithoutIdentity, 4)] {
        let run = Self.simulate(usage, call, lag: 0.1, applications: applications)
        XCTAssertLessThan(run.firstDisable ?? .infinity, 60, "\(usage), \(call), \(applications): \(run)")
        XCTAssertGreaterThan(run.disables, 100, "\(usage), \(call), \(applications): \(run)")
      }
    }
  }
  /// cpu-shoulds fix2 M1: a call that names the app the person just left still moves on with
  /// the next switch, so withdrawing a disagreement once the call moved spared it for good.
  func testACallLateByOneSecondIsTurnedOffInMixedUse() {
    let run = Self.simulate(.mixed, .late(1))
    XCTAssertLessThan(run.firstDisable ?? .infinity, 120, "\(run)")
  }
  func testACallOneSwitchBehindIsTurnedOffWhileSwitching() {
    let run = Self.simulate(.every(0.3...1.0), .oneSwitchBehind)
    XCTAssertLessThan(run.firstDisable ?? .infinity, 120, "\(run)")
  }
  /// Other calls that are wrong while switching: turned off within two minutes.
  func testCallsWrongWhileSwitchingAreTurnedOffWithinTwoMinutes() {
    let calls: [Call] = [.late(1), .late(3), .oneSwitchBehind, .alternating, .held(10), .stale(0.7)]
    for usage in [Usage.every(0.3...1.0), .mixed] {
      for call in calls {
        let run = Self.simulate(usage, call, lag: 0.1)
        XCTAssertLessThan(run.firstDisable ?? .infinity, 120, "\(usage), \(call): \(run)")
      }
    }
  }
  struct Seeded: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
      state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return state ^ (state >> 29)
    }
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
