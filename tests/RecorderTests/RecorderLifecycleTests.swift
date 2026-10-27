import Core
import Foundation
@testable import Shell
import XCTest
@testable import Storage

final class RecorderLifecycleTests: XCTestCase {
  var root: URL!
  var storage: ActivityStorage!
  var clock: FakeClock!
  var sources: FakeSources!
  var loop: RecorderLoop!
  override func setUpWithError() throws {
    root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ACTIVITYPROBE_TEST_ROOT"] ?? NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    storage = try ActivityStorage(url: root.appendingPathComponent("invented.sqlite"), appDataDirectory: root, databaseScope: .directory(root))
    try storage.saveSettings(StorageSettings(excludedApps: []))
    clock = FakeClock(); sources = FakeSources(); sources.clock = clock
    loop = RecorderLoop(clock: clock, input: sources, front: sources, secure: sources, awake: sources,
      screen: sources, storage: storage, maintenanceStorage: storage, ownBundleID: "invented.own")
  }
  override func tearDownWithError() throws {
    loop?.stop()
    if let loop {
      let drained = expectation(description: "Owned recorder work drained")
      loop.finishMaintenance { drained.fulfill() }; wait(for: [drained], timeout: 60)
    }
    loop = nil; storage = nil
    try FileManager.default.removeItem(at: root)
  }
  func testSettingsStopDrainsLifecycleAndReleasesLifetimeLock() throws {
    let paths = AppPaths(userHome: root.appendingPathComponent("person"), appData: root,
      database: root.appendingPathComponent("invented.sqlite"), appBinary: root.appendingPathComponent("ActivityProbe"), queryHelper: root.appendingPathComponent("helper"))
    var owner: RecorderStartupGuard? = try RecorderStartupGuard(paths: paths)
    var stopped = false, stops = 0
    let lifecycle = RecorderLifecycle(loop: loop, clock: clock, startInput: {}, stopInput: { stops += 1 }, requestSummary: { _ in })
    loop.recordingDisabled = { [weak lifecycle] in
      lifecycle?.stop { health in
        XCTAssertEqual(health.pendingSeconds, 0); XCTAssertEqual(health.pendingCaptures, 0)
        stopped = true; owner = nil
      }
    }
    lifecycle.start(); loop.tick()
    let control = RecorderControl(wait: {
      self.clock.now += 1; self.loop.tick()
      _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
    }, timeout: 10)
    XCTAssertEqual(try control.stop(paths: paths).status, 0)
    XCTAssertTrue(stopped); XCTAssertNil(owner); XCTAssertEqual(stops, 1)
    XCTAssertFalse(try storage.settings().recordingEnabled)
  }
  // Ideal: overlapping lock/sleep reasons suppress all observations, and wake alone adds no input.
  func testOverlappingLockAndSleepResumeWithoutInventedInput() throws {
    var starts = 0, stops = 0
    var requests: [Int] = []
    let lifecycle = RecorderLifecycle(loop: loop, clock: clock, startInput: { XCTAssertTrue(Thread.isMainThread); starts += 1 },
      stopInput: { XCTAssertTrue(Thread.isMainThread); stops += 1 }, requestSummary: { requests.append($0) })
    lifecycle.start(); lifecycle.start()
    loop.tick()
    let beforeLock = sources.detailReads
    XCTAssertGreaterThan(beforeLock, 0)
    clock.now += 1; lifecycle.receive(.lock)
    lifecycle.receive(.sleep); lifecycle.receive(.displaySleep)
    loop.tick()
    XCTAssertEqual(sources.detailReads, beforeLock)
    lifecycle.receive(.wake); lifecycle.receive(.unlock)
    loop.tick()
    XCTAssertEqual(sources.detailReads, beforeLock)
    sources.input = .value(InputCounts())
    clock.now += 1; lifecycle.receive(.displayWake)
    loop.tick(); loop.flush()
    XCTAssertEqual(starts, 2); XCTAssertEqual(stops, 1)
    XCTAssertEqual(requests, [10001])
    XCTAssertEqual(try storage.samples(in: TimeRange(0, 20000)).map(\.ts), [10000])
    let stopped = expectation(description: "drained")
    lifecycle.stop { health in
      XCTAssertEqual(health.pendingSeconds, 0); XCTAssertEqual(health.pendingCaptures, 0)
      stopped.fulfill()
    }
    wait(for: [stopped], timeout: 5)
    XCTAssertEqual(stops, 2)
    clock.now += 1; sources.input = .value(InputCounts(keys: 1)); loop.tick()
    XCTAssertEqual(try storage.samples(in: TimeRange(0, 20000)).count, 1)
  }
  func testDelayedImageCannotUseInputFromBeforeLockAndUnlock() throws {
    sources.deferCompletion = true
    loop.tick()
    loop.setSuspended(true)
    sources.input = .value(InputCounts())
    loop.setSuspended(false)
    sources.delayed?()
    loop.flush()
    XCTAssertTrue(try storage.evidence(in: TimeRange(0, 20000)).isEmpty)
    XCTAssertEqual(sources.imagePermissions, [false])
    XCTAssertEqual(loop.health.droppedCaptures, 1)
    loop.stop()
  }
  // Ideal: an already sleeping, unlocked display suppresses even a foreground awake assertion.
  func testDisplayAlreadyAsleepDoesNotRecordAtStartup() throws {
    sources.input = .value(InputCounts()); sources.awake = .value(true)
    var starts = 0
    let lifecycle = RecorderLifecycle(loop: loop, clock: clock, startInput: { starts += 1 }, stopInput: {},
      initialSnapshot: { RecorderSessionSnapshot(displaySleeping: true) }, requestSummary: { _ in })
    lifecycle.start(); loop.tick(); loop.flush()
    XCTAssertEqual(starts, 0)
    XCTAssertEqual(sources.detailReads, 0)
    XCTAssertTrue(try storage.samples(in: TimeRange(0, 20000)).isEmpty)
    sources.awake = .value(false)
    lifecycle.receive(.displayWake); clock.now += 1; loop.tick(); loop.flush()
    XCTAssertEqual(starts, 1)
    XCTAssertTrue(try storage.samples(in: TimeRange(0, 20000)).isEmpty)
    sources.input = .value(InputCounts(keys: 1)); clock.now += 1; loop.tick(); loop.flush()
    XCTAssertEqual(try storage.samples(in: TimeRange(0, 20000)).map(\.ts), [10002])
    loop.stop()
  }
  func testInitiallyLockedDoesNotStartInputOrObserveWindow() throws {
    var starts = 0
    let lifecycle = RecorderLifecycle(loop: loop, clock: clock, startInput: { starts += 1 }, stopInput: {},
      initialSnapshot: { RecorderSessionSnapshot(locked: true) }, requestSummary: { _ in })
    lifecycle.start(); loop.tick()
    XCTAssertEqual(starts, 0); XCTAssertEqual(sources.detailReads, 0)
    loop.stop()
  }
  // Ideal: every initial suspension reason survives partial wakes; resume alone adds no input.
  func testInitialSleepAndLockRequireEveryWakeAndFreshInput() throws {
    sources.input = .value(InputCounts())
    var starts = 0, snapshots = 0
    let lifecycle = RecorderLifecycle(loop: loop, clock: clock, startInput: {
      XCTAssertEqual(snapshots, 1); XCTAssertEqual(self.sources.detailReads, 0); starts += 1
    }, stopInput: {}, initialSnapshot: {
      snapshots += 1
      XCTAssertEqual(starts, 0); XCTAssertEqual(self.sources.drains, 0)
      return RecorderSessionSnapshot(locked: true, sleeping: true, displaySleeping: true)
    }, requestSummary: { _ in XCTFail("Starting suspended invents no boundary") })
    lifecycle.start(); lifecycle.start(); loop.tick()
    lifecycle.receive(.displayWake); clock.now += 1; loop.tick()
    lifecycle.receive(.unlock); clock.now += 1; loop.tick()
    XCTAssertEqual(starts, 0); XCTAssertEqual(sources.detailReads, 0)
    lifecycle.receive(.wake); clock.now += 1; loop.tick(); loop.flush()
    XCTAssertEqual(starts, 1); XCTAssertEqual(snapshots, 1)
    XCTAssertTrue(try storage.samples(in: TimeRange(0, 20000)).isEmpty)
    sources.input = .value(InputCounts(keys: 1)); clock.now += 1; loop.tick(); loop.flush()
    XCTAssertEqual(try storage.samples(in: TimeRange(0, 20000)).map(\.ts), [10004])
    loop.stop()
  }
  func testSessionSnapshotDecodingFailsClosedForUnknownPowerAndLock() {
    XCTAssertEqual(MacRecorderSessionObserver.snapshot(locked: false, systemPowerState: 4, displaySleeping: true),
      RecorderSessionSnapshot(displaySleeping: true))
    XCTAssertEqual(MacRecorderSessionObserver.snapshot(locked: true, systemPowerState: 2, displaySleeping: true),
      RecorderSessionSnapshot(locked: true, sleeping: true, displaySleeping: true))
    XCTAssertEqual(MacRecorderSessionObserver.snapshot(locked: nil, systemPowerState: nil, displaySleeping: false),
      RecorderSessionSnapshot(locked: true, sleeping: true))
  }
  // Ideal: older resume notifications cannot clear any reason in the current snapshot.
  func testEarlierUnlockCannotOverrideLockedSnapshot() throws {
    try assertSuspendedStartup(RecorderSessionSnapshot(locked: true), earlier: .unlock)
  }
  func testEarlierWakeCannotOverrideSleepingSnapshot() throws {
    try assertSuspendedStartup(RecorderSessionSnapshot(sleeping: true), earlier: .wake)
  }
  func testEarlierDisplayWakeCannotOverrideSleepingDisplaySnapshot() throws {
    try assertSuspendedStartup(RecorderSessionSnapshot(displaySleeping: true), earlier: .displayWake)
  }
  private func assertSuspendedStartup(_ snapshot: RecorderSessionSnapshot, earlier: RecorderSessionEvent) throws {
    sources.input = .value(InputCounts()); sources.awake = .value(true)
    var starts = 0
    let lifecycle = RecorderLifecycle(loop: loop, clock: clock, startInput: { starts += 1 }, stopInput: {},
      initialSnapshot: { snapshot }, requestSummary: { _ in XCTFail("Startup invents no boundary") })
    lifecycle.receive(earlier); lifecycle.start(); loop.tick(); loop.flush()
    XCTAssertEqual(starts, 0); XCTAssertEqual(sources.detailReads, 0)
    XCTAssertTrue(try storage.samples(in: TimeRange(0, 20000)).isEmpty)
    XCTAssertTrue(try storage.evidence(in: TimeRange(0, 20000)).isEmpty)
    loop.stop()
  }
  // Ideal: observation is installed before the snapshot; all earlier events are obsolete.
  func testObserverInstallationPrecedesSnapshotAndInputStartup() throws {
    var order: [String] = []
    var receive: ((RecorderSessionEvent) -> Void)?
    weak var observer: NSObject?
    let lifecycle = RecorderLifecycle(loop: loop, clock: clock, startInput: {
      XCTAssertTrue(Thread.isMainThread)
      XCTAssertEqual(self.sources.drains, 0)
      order.append("input")
    }, stopInput: {}, observeSession: { callback in
      XCTAssertTrue(Thread.isMainThread)
      XCTAssertEqual(self.sources.drains, 0)
      order.append("observer")
      receive = callback
      for event: RecorderSessionEvent in [.sleep, .lock, .displaySleep, .wake, .unlock, .displayWake,
        .sleep, .lock, .displaySleep] { callback(event) }
      let token = NSObject(); observer = token; return token
    }, initialSnapshot: {
      XCTAssertTrue(Thread.isMainThread)
      XCTAssertNotNil(observer)
      XCTAssertEqual(order, ["observer"])
      XCTAssertEqual(self.sources.drains, 0)
      order.append("snapshot")
      return RecorderSessionSnapshot()
    }, requestSummary: { _ in })
    lifecycle.start(); lifecycle.start()
    XCTAssertEqual(order, ["observer", "snapshot", "input"])
    XCTAssertNotNil(observer)
    loop.tick()
    let reads = sources.detailReads
    XCTAssertGreaterThan(reads, 0)
    receive?(.lock); clock.now += 1; loop.tick()
    XCTAssertEqual(sources.detailReads, reads)
    loop.stop()
  }
  // Ideal: each of the seven suspended snapshots stays paused until every reason clears,
  // in all six resume orders, and then records only after fresh input.
  func testEveryInitialSuspensionCombinationAndResumeOrder() throws {
    let orders: [[RecorderSessionEvent]] = [
      [.wake, .unlock, .displayWake], [.wake, .displayWake, .unlock],
      [.unlock, .wake, .displayWake], [.unlock, .displayWake, .wake],
      [.displayWake, .wake, .unlock], [.displayWake, .unlock, .wake]
    ]
    for mask in 1...7 {
      for (index, order) in orders.enumerated() {
        let store = try ActivityStorage(url: root.appendingPathComponent("matrix-\(mask)-\(index).sqlite"), appDataDirectory: root, databaseScope: .directory(root))
        try store.saveSettings(StorageSettings(excludedApps: []))
        let clock = FakeClock(), sources = FakeSources()
        sources.clock = clock; sources.input = .value(InputCounts()); sources.awake = .value(true)
        let loop = RecorderLoop(clock: clock, input: sources, front: sources, secure: sources, awake: sources,
          screen: sources, storage: store, maintenanceStorage: store, ownBundleID: "invented.own")
        var remaining = mask, starts = 0
        let lifecycle = RecorderLifecycle(loop: loop, clock: clock, startInput: { starts += 1 }, stopInput: {},
          initialSnapshot: { RecorderSessionSnapshot(locked: mask & 1 != 0, sleeping: mask & 2 != 0,
            displaySleeping: mask & 4 != 0) }, requestSummary: { _ in XCTFail("Resuming invents no boundary") })
        lifecycle.start(); loop.tick(); loop.flush()
        XCTAssertEqual(starts, 0); XCTAssertEqual(sources.detailReads, 0)
        XCTAssertTrue(try store.samples(in: TimeRange(0, 20000)).isEmpty)
        sources.awake = .value(false)
        for event in order {
          switch event {
          case .unlock: remaining &= ~1
          case .wake: remaining &= ~2
          case .displayWake: remaining &= ~4
          default: XCTFail("Unexpected resume event")
          }
          lifecycle.receive(event); clock.now += 1; loop.tick(); loop.flush()
          XCTAssertEqual(starts, remaining == 0 ? 1 : 0)
          if remaining != 0 { XCTAssertEqual(sources.detailReads, 0) }
          XCTAssertTrue(try store.samples(in: TimeRange(0, 20000)).isEmpty)
        }
        sources.input = .value(InputCounts(keys: 1)); clock.now += 1; loop.tick(); loop.flush()
        XCTAssertEqual(try store.samples(in: TimeRange(0, 20000)).map(\.ts), [10004])
        loop.stop()
      }
    }
  }
  // Ideal: stop accounts for failed writes and in-flight capture exactly once, including late delivery.
  func testStopCountsFailuresAndLateCaptureCannotReviveQueue() throws {
    let failing = FailingRecorderStorage(storage)
    failing.failSamples = true
    sources.ignorePermission = true; sources.deferDelivery = true
    loop = RecorderLoop(clock: clock, input: sources, front: sources, secure: sources, awake: sources,
      screen: sources, storage: failing, maintenanceStorage: storage, ownBundleID: "invented.own")
    loop.tick(); loop.stop()
    XCTAssertEqual(loop.health.droppedSeconds, 1)
    XCTAssertEqual(loop.health.droppedCaptures, 1)
    sources.delayedDelivery?(); loop.stop()
    XCTAssertEqual(loop.health.droppedCaptures, 1)
    XCTAssertEqual(loop.pendingCaptureCompletions, 0)
    XCTAssertEqual(loop.health.pendingSeconds, 0)
    XCTAssertEqual(loop.health.pendingCaptures, 0)
  }
  // Ideal: one-second ticks continue in common mode; shutdown waits asynchronously for owned work.
  func testCommonModeTimerAndMaintenanceDrain() throws {
    let began = expectation(description: "maintenance began")
    let release = DispatchSemaphore(value: 0)
    loop = RecorderLoop(clock: clock, input: sources, front: sources, secure: sources, awake: sources,
      screen: sources, storage: storage, maintenanceStorage: storage, ownBundleID: "invented.own",
      maintenanceTasks: [RecorderMaintenanceTask(name: "invented-slow") { _ in began.fulfill(); release.wait() }])
    loop.start(); loop.requestMaintenance()
    wait(for: [began], timeout: 5)
    let before = sources.drains
    let tracking = RunLoop.Mode("ActivityProbe.InventedTracking")
    CFRunLoopAddCommonMode(CFRunLoopGetMain(), CFRunLoopMode(rawValue: tracking.rawValue as CFString))
    let until = Date().addingTimeInterval(1.1)
    while Date() < until { _ = RunLoop.main.run(mode: tracking, before: until) }
    XCTAssertGreaterThan(sources.drains, before)
    loop.stop()
    var finished = false
    let drained = expectation(description: "maintenance drained")
    loop.finishMaintenance { finished = true; drained.fulfill() }
    XCTAssertFalse(finished)
    release.signal()
    wait(for: [drained], timeout: 5)
  }
  func testStopCancelsMaintenanceAndWaitsForItsOwnedQueueBarrier() throws {
    let began = expectation(description: "owned queue barrier began"), drained = expectation(description: "owned queue drained")
    let lock = NSLock()
    var release: (() -> Void)?, cancellations = 0, finished = false
    let task = RecorderMaintenanceTask(name: "invented-owned", cancel: { cancellations += 1 }, finish: { completion in
      lock.lock(); release = completion; lock.unlock(); began.fulfill()
    }) { _ in }
    loop = RecorderLoop(clock: clock, input: sources, front: sources, secure: sources, awake: sources,
      screen: sources, storage: storage, maintenanceStorage: storage, ownBundleID: "invented.own", maintenanceTasks: [task])
    loop.stop(); loop.stop()
    XCTAssertEqual(cancellations, 1)
    loop.finishMaintenance { finished = true; drained.fulfill() }
    wait(for: [began], timeout: 5); XCTAssertFalse(finished)
    lock.lock(); let completion = release; lock.unlock(); completion?()
    wait(for: [drained], timeout: 5); XCTAssertTrue(finished)
    // This fixture already completed its one-shot owned barrier.
    loop = nil
  }
}
