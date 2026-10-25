import Core
import Foundation
import Shell
import XCTest

@testable import Storage

final class FailingRecorderStorage: RecorderStorage {
  let base: ActivityStorage
  var failSettings = false
  var failRebuild = false
  var failSamples = false
  var failScreens = false
  var screenWrites = 0
  var afterSamples: (() throws -> Void)?
  var retentionRuns = 0
  let retentionLock = NSLock()
  init(_ base: ActivityStorage) { self.base = base }
  func settings() throws -> StorageSettings {
    if failSettings { throw StorageError.busy("invented contention") }
    return try base.settings()
  }
  func saveSettings(_ settings: StorageSettings) throws { try base.saveSettings(settings) }
  func deletionsSoFar() throws -> Int { try base.deletionsSoFar() }
  func appendSamples(_ samples: [TimeSample]) throws -> AppendResult {
    if failSamples { throw StorageError.busy("invented contention") }
    let result = try base.appendSamples(samples)
    let callback = afterSamples
    afterSamples = nil
    try callback?()
    return result
  }
  func evidence(in range: TimeRange) throws -> [EvidenceText] { try base.evidence(in: range) }
  func recentScreenLineKeys(at now: Int) throws -> [String: Int] {
    if failRebuild { throw StorageError.busy("invented contention") }
    return try base.recentScreenLineKeys(at: now)
  }
  func appendScreenCapture(
    text: String, at time: Int, source: String, documentKey: String,
    project: String, knownKeys: Set<String>
  ) throws -> ScreenCaptureResult {
    screenWrites += 1
    if failScreens { throw StorageError.busy("invented contention") }
    return try base.appendScreenCapture(
      text: text, at: time, source: source,
      documentKey: documentKey, project: project, knownKeys: knownKeys)
  }
  func cleanRetention(at now: Int) throws -> Int {
    retentionLock.lock()
    retentionRuns += 1
    retentionLock.unlock()
    return try base.cleanRetention(at: now)
  }
}

final class RecorderFixTests: XCTestCase {
  var folder: URL!
  var clock: FakeClock!
  var sources: FakeSources!
  var base: ActivityStorage!
  var store: FailingRecorderStorage!
  var loop: RecorderLoop!
  let all = TimeRange(0, 1_000_000)
  override func setUpWithError() throws {
    folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    base = try ActivityStorage(url: folder.appendingPathComponent("invented.sqlite"), appDataDirectory: folder, busyMilliseconds: 0, databaseScope: .directory(folder))
    try base.saveSettings(StorageSettings(excludedApps: []))
    store = FailingRecorderStorage(base)
    clock = FakeClock()
    sources = FakeSources()
    sources.clock = clock
    loop = makeLoop()
  }
  override func tearDownWithError() throws {
    loop = nil
    store = nil
    base = nil
    try FileManager.default.removeItem(at: folder)
  }
  func makeLoop(tasks: [RecorderMaintenanceTask] = []) -> RecorderLoop {
    RecorderLoop(
      clock: clock, input: sources, front: sources, secure: sources, awake: sources,
      screen: sources, storage: store, maintenanceStorage: store,
      ownBundleID: "invented.own", maintenanceTasks: tasks)
  }
  func tick(_ now: Int) {
    clock.now = now
    loop.tick()
  }
  func delete(_ range: TimeRange) throws {
    let other = try ActivityStorage(url: folder.appendingPathComponent("invented.sqlite"), appDataDirectory: folder, busyMilliseconds: 0, databaseScope: .directory(folder))
    let preview = try other.previewDeletion(in: range)
    _ = try other.deleteRecords(in: range, confirmation: preview.confirmation)
  }
  func testSettingsFailureCountsSecondAndFlushesPendingRows() throws {
    tick(10000)
    tick(10001)
    store.failSettings = true
    tick(10002)
    XCTAssertEqual(loop.health.droppedSeconds, 1)
    XCTAssertEqual(try base.samples(in: all).map(\.ts), [10000, 10001])
    XCTAssertEqual(loop.health.pendingSeconds, 0)
    store.failSettings = false
    tick(10003)
    loop.flush()
    XCTAssertEqual(try base.samples(in: all).map(\.ts), [10000, 10001, 10003])
  }
  func testStopFlushesAndFailedStopCountsLoss() throws {
    for now in 10000...10003 { tick(now) }
    loop.stop()
    XCTAssertEqual(try base.samples(in: all).count, 4)
    XCTAssertEqual(loop.health.droppedSeconds, 0)
    loop = makeLoop()
    store.failSamples = true
    tick(10004)
    loop.stop()
    XCTAssertEqual(loop.health.droppedSeconds, 1)
    XCTAssertTrue(loop.health.storageBusy)
    XCTAssertEqual(loop.health.pendingSeconds, 0)
  }
  func testDeliveryWindowIsCheckedEvenWhenAdapterDoesNotAsk() throws {
    sources.ignorePermission = true
    sources.deferDelivery = true
    tick(10000)
    sources.front.window = WindowIdentity(processID: 10, windowID: 21)
    sources.delayedDelivery?()
    loop.flush()
    XCTAssertEqual(try base.evidence(in: all), [])
    XCTAssertEqual(loop.health.policyRefusedCaptures, 1)
    XCTAssertNil(loop.health.absentSources[.screen])
  }
  func testDeliveryDocumentSettingsAndSecurityAreCheckedByLoop() throws {
    sources.ignorePermission = true
    sources.deferDelivery = true
    tick(10000)
    sources.front.document = "file:///invented/second"
    sources.delayedDelivery?()
    loop.flush()
    XCTAssertEqual(try base.evidence(in: all), [])
    tick(10015)
    try base.saveSettings(StorageSettings(recordingEnabled: false))
    sources.delayedDelivery?()
    loop.flush()
    XCTAssertEqual(try base.evidence(in: all), [])
    try base.saveSettings(StorageSettings(excludedApps: []))
    tick(10030)
    sources.secure = .value(true)
    sources.delayedDelivery?()
    loop.flush()
    XCTAssertEqual(try base.evidence(in: all), [])
    XCTAssertEqual(loop.health.policyRefusedCaptures, 3)
  }
  func testImageCanStartOneSecondLaterButNotTwo() throws {
    sources.deferCompletion = true
    tick(10000)
    clock.now = 10001
    sources.delayed?()
    loop.flush()
    XCTAssertEqual(try base.evidence(in: all).count, 1)
    sources.screen = .value("Invented later text")
    tick(10015)
    clock.now = 10017
    sources.delayed?()
    loop.flush()
    XCTAssertEqual(try base.evidence(in: all).count, 1)
    XCTAssertEqual(loop.health.policyRefusedCaptures, 1)
  }
  func testClockStepBackFlushesImmediately() throws {
    tick(10000)
    tick(10001)
    tick(9990)
    XCTAssertEqual(try base.samples(in: all).map(\.ts), [9990, 10000, 10001])
    XCTAssertEqual(loop.health.pendingSeconds, 0)
    XCTAssertEqual(sources.requested.map { $0.0 }, [10000, 9990])
  }
  func testNoCaptureWriteBeforeKeyRebuildSucceeds() throws {
    store.failRebuild = true
    tick(10000)
    sources.input = .value(InputCounts())
    tick(10005)
    XCTAssertEqual(store.screenWrites, 0)
    XCTAssertEqual(loop.health.pendingCaptures, 1)
    XCTAssertEqual(try base.samples(in: all).count, 2)
    store.failRebuild = false
    loop.flush()
    XCTAssertEqual(store.screenWrites, 1)
    XCTAssertEqual(try base.evidence(in: all).count, 1)
  }
  func testCompletionInboxBoundIsIndependentOfCaptureQueue() throws {
    sources.ignorePermission = true
    sources.deferDelivery = true
    tick(10000)
    let deliver = try XCTUnwrap(sources.completions.first)
    for _ in 0..<(RecorderTiming.pendingCaptures + 3) { deliver(.value("Invented inbox text")) }
    XCTAssertEqual(loop.pendingCaptureCompletions, RecorderTiming.pendingCaptures)
    store.failScreens = true
    loop.flush()
    XCTAssertEqual(loop.health.droppedCaptures, 3)
    XCTAssertEqual(loop.health.pendingCaptures, RecorderTiming.pendingCaptures)
  }
  func testDeletedInFlightCaptureIsRefusedAndCountedByStorage() throws {
    sources.ignorePermission = true
    sources.deferDelivery = true
    tick(10000)
    try delete(TimeRange(10000, 10001))
    sources.input = .value(InputCounts())
    tick(10001)
    sources.delayedDelivery?()
    loop.flush()
    XCTAssertEqual(try base.evidence(in: all), [])
    XCTAssertEqual(loop.health.refusedCaptures, 1)
    XCTAssertEqual(loop.keyMemory.keys, [])
  }
  func testSecondConnectionDeletionDropsQueueAndRebuildsMemory() throws {
    tick(10000)
    loop.flush()
    XCTAssertFalse(loop.keyMemory.keys.isEmpty)
    store.failScreens = true
    sources.screen = .value("Invented queued line")
    tick(10015)
    loop.flush()
    XCTAssertEqual(loop.health.pendingCaptures, 1)
    try delete(TimeRange(10000, 10001))
    store.failScreens = false
    sources.input = .value(InputCounts())
    tick(10016)
    loop.flush()
    XCTAssertEqual(loop.health.droppedCaptures, 1)
    XCTAssertEqual(loop.keyMemory.keys, [])
    XCTAssertEqual(try base.evidence(in: all), [])
    sources.input = .value(InputCounts(keys: 1))
    sources.screen = .value("Invented screen line")
    tick(10030)
    loop.flush()
    XCTAssertEqual(try base.evidence(in: all).map(\.ts), [10030])
  }
  func testExcludedAppsNeverHaveTheirDetailsReadAndQueuedCaptureRechecksExclusions() throws {
    for app in ["INVENTED.OWN", "INVENTED.PRIVATE"] {
      try base.saveSettings(StorageSettings(excludedApps: ["invented.private"]))
      sources.front.bundleID = app
      tick(clock.now + 1)
    }
    XCTAssertEqual(sources.detailReads, 0)
    XCTAssertEqual(sources.requested.count, 0)
    sources.front.bundleID = "invented.editor"
    store.failScreens = true
    tick(10015)
    loop.flush()
    XCTAssertEqual(loop.health.pendingCaptures, 1)
    try base.saveSettings(StorageSettings(excludedApps: ["INVENTED.EDITOR"]))
    store.failScreens = false
    loop.flush()
    XCTAssertEqual(try base.evidence(in: all), [])
    XCTAssertEqual(loop.health.policyRefusedCaptures, 1)
  }
  func testScreenHealthSeparatesPolicyFailureAndPermission() throws {
    for (offset, reason) in [SourceAbsence.policyRefused, .failed, .permission].enumerated() {
      sources.screen = .absent(reason)
      tick(10000 + offset * 15)
      loop.flush()
    }
    XCTAssertEqual(loop.health.policyRefusedCaptures, 1)
    XCTAssertEqual(loop.health.captureFailures, 1)
    XCTAssertEqual(loop.health.absentSources[.screen], .permission)
  }
  func testTwoTicksMergePendingOrCarryStoredInputIntoNextSecond() throws {
    sources.input = .value(InputCounts(keys: 1))
    tick(10000)
    sources.input = .value(InputCounts(keys: 7, clicks: 2, scrolls: 3, moved: true, synthetic: 4))
    tick(10000)
    sources.input = .value(InputCounts(keys: 2))
    tick(10001)
    sources.input = .value(InputCounts(keys: 5))
    tick(10001)
    loop.flush()
    let rows = try base.samples(in: all)
    XCTAssertEqual(rows.map(\.keys), [1, 14])
    XCTAssertEqual(rows[1].clicks, 2)
    XCTAssertEqual(rows[1].scrolls, 3)
    XCTAssertTrue(rows[1].moved)
    XCTAssertEqual(rows[1].synthetic, 4)
    XCTAssertEqual(loop.health.refusedSeconds, 0)
    sources.input = .value(InputCounts())
    tick(10003)
    loop.flush()
    XCTAssertEqual(try base.samples(in: all).map(\.ts), [10000, 10001, 10003])
  }
  func testTwentyIdleMinutesWriteOnlyFirst300IdleSecondsThenResume() throws {
    tick(10000)
    sources.input = .value(InputCounts())
    for now in 10001...11200 { tick(now) }
    loop.flush()
    XCTAssertEqual(try base.samples(in: all).map(\.ts), Array(10000...10300))
    sources.input = .value(InputCounts(keys: 1))
    tick(11201)
    loop.flush()
    XCTAssertEqual(try base.samples(in: all).last?.ts, 11201)
    XCTAssertEqual(try base.samples(in: all).count, 302)
  }
  func testDisplayAssertionWritesEveryIdleSecondWithoutWindow() throws {
    sources.front.window = nil
    sources.awake = .value(true)
    sources.input = .value(InputCounts())
    for now in 10000...11200 { tick(now) }
    loop.flush()
    XCTAssertEqual(try base.samples(in: all).count, 1201)
    XCTAssertTrue(sources.awakePIDs.allSatisfy { $0 == 10 })
  }
  func testFiveMinuteTasksRunOffTickAndFailuresAreNamedAndCounted() throws {
    let finished = expectation(description: "named tasks ran")
    let task = RecorderMaintenanceTask(name: "invented failure") { _ in
      XCTAssertFalse(Thread.isMainThread)
      finished.fulfill()
      throw StorageError.busy("invented contention")
    }
    loop = makeLoop(tasks: [task])
    tick(10000)
    tick(10299)
    XCTAssertEqual(store.retentionRuns, 0)
    tick(10300)
    wait(for: [finished], timeout: 5)
    // Queue completion is asynchronous; flush health on subsequent main-run-loop turns.
    let counted = expectation(description: "failure counted")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
      self.loop.flush()
      XCTAssertEqual(self.loop.health.maintenanceFailures["invented failure"], 1)
      XCTAssertEqual(self.store.retentionRuns, 1)
      counted.fulfill()
    }
    wait(for: [counted], timeout: 5)
  }
  func testUnknownInputHistoryHasNoRowAndPausedInputStillSetsRestBoundary() throws {
    sources.input = .value(InputCounts())
    tick(10000)
    loop.flush()
    XCTAssertEqual(try base.samples(in: all), [])
    try base.saveSettings(StorageSettings(excludedApps: [], pausedUntil: 10002))
    sources.input = .value(InputCounts(keys: 1))
    tick(10001)
    sources.input = .value(InputCounts())
    tick(10002)
    tick(10301)
    tick(10302)
    loop.flush()
    let rows = try base.samples(in: all)
    XCTAssertEqual(rows.map(\.ts), [10002, 10301])
    XCTAssertTrue(rows.allSatisfy { !$0.hasInput })
    XCTAssertEqual(sources.requested.count, 0)
  }

  func testCaptureReadsExclusionsAgainAfterPendingSamplesAreWritten() throws {
    tick(10000)
    tick(10001)
    store.afterSamples = {
      try self.base.saveSettings(StorageSettings(excludedApps: ["invented.editor"]))
    }
    loop.flush()
    XCTAssertEqual(try base.evidence(in: all), [])
    XCTAssertEqual(loop.health.policyRefusedCaptures, 1)
  }

}
