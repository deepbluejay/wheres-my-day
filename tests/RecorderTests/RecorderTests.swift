import Core
import Foundation
import Shell
import XCTest

@testable import Storage

final class FakeClock: RecorderClock {
  private let lock = NSLock()
  private var time = 10000
  var now: Int {
    get { lock.lock(); defer { lock.unlock() }; return time }
    set { lock.lock(); time = newValue; lock.unlock() }
  }
}
final class FakeSources: InputCountSource, FrontWindowSource, SecureInputSource,
  DisplayAwakeSource, ScreenTextSource
{
  var input = SourceReading.value(InputCounts(keys: 1))
  var front = FrontObservation(
    bundleID: "invented.editor", app: "Invented editor", title: "Invented title",
    document: "file:///invented/project/item", window: WindowIdentity(processID: 10, windowID: 20))
  var secure = SourceReading.value(false)
  var awake = SourceReading.value(false)
  var screen = SourceReading.value("Invented screen line")
  var requested: [(Int, WindowIdentity)] = []
  var imagePermissions: [Bool] = []
  var clock: FakeClock!
  var deferCompletion = false
  var delayed: (() -> Void)?
  var deferDelivery = false
  var delayedDelivery: (() -> Void)?
  var drains = 0
  var ignorePermission = false
  var completions: [(SourceReading<String>) -> Void] = []
  func takeInput() -> SourceReading<InputCounts> {
    drains += 1
    return input
  }
  var detailReads = 0
  var detailWork: (() -> Void)?
  var awakePIDs: [Int32] = []
  func frontApplication() -> FrontObservation {
    FrontObservation(bundleID: front.bundleID, app: front.app, processID: front.processID)
  }
  func details(for application: FrontObservation) -> FrontObservation {
    detailReads += 1
    detailWork?()
    return front
  }
  func secureInput() -> SourceReading<Bool> { secure }
  func keepingDisplayAwake(processID: Int32) -> SourceReading<Bool> {
    awakePIDs.append(processID)
    return awake
  }
  func captureText(
    window: WindowIdentity, permitted: @escaping (CaptureCheck) -> Bool,
    completion: @escaping (SourceReading<String>) -> Void
  ) {
    requested.append((clock.now, window))
    completions.append(completion)
    if ignorePermission {
      delayedDelivery = { completion(self.screen) }
      if !deferDelivery { delayedDelivery?() }
      return
    }
    let begin = {
      let allowed = permitted(.beforeImage)
      self.imagePermissions.append(allowed)
      guard allowed else {
        completion(.absent(.policyRefused))
        return
      }
      let deliver = { completion(permitted(.beforeDelivery) ? self.screen : .absent(.policyRefused)) }
      if self.deferDelivery { self.delayedDelivery = deliver } else { deliver() }
    }
    if deferCompletion { delayed = begin } else { begin() }
  }
}

final class RecorderTests: XCTestCase {
  private var clock: FakeClock!
  private var sources: FakeSources!
  private var folder: URL!
  private var database: URL { folder.appendingPathComponent("invented.sqlite") }
  private var storage: ActivityStorage!
  private var recorder: RecorderLoop!
  private let all = TimeRange(0, 1_000_000)
  override func setUpWithError() throws {
    folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    clock = FakeClock()
    sources = FakeSources()
    sources.clock = clock
    storage = try ActivityStorage(url: database, appDataDirectory: database.deletingLastPathComponent(), busyMilliseconds: 0, databaseScope: .directory(folder))
    try storage.saveSettings(StorageSettings(excludedApps: ["invented.private"]))
    recorder = makeRecorder()
  }
  override func tearDownWithError() throws {
    recorder = nil
    storage = nil
    try FileManager.default.removeItem(at: folder)
  }
  private func makeRecorder() -> RecorderLoop {
    RecorderLoop(
      clock: clock, input: sources, front: sources, secure: sources, awake: sources,
      screen: sources, storage: storage, maintenanceStorage: storage,
      ownBundleID: "invented.own")
  }
  private func second(_ ts: Int) {
    clock.now = ts
    recorder.tick()
  }
  private func finish(_ ts: Int) {
    sources.input = .value(InputCounts())
    second(ts)
    recorder.flush()
  }
  func testInventedHourAllCaptureGatesAndChangingApps() throws {
    var expectedCaptureTimes: [Int] = []
    var lastByWindow: [UInt32: Int] = [:]
    for offset in 0..<3600 {
      let ts = 10000 + offset
      let phase = offset % 100
      sources.front.bundleID = phase < 10 ? "invented.private" : phase < 20 ? "invented.own" : "invented.editor"
      sources.front.app = "Invented app " + String(phase / 10)
      sources.front.window = WindowIdentity(processID: 10, windowID: phase < 60 ? 20 : 21)
      sources.secure = .value(phase >= 20 && phase < 30)
      sources.input = .value(
        phase % 4 == 0 ? InputCounts(keys: 1) : phase % 4 == 1 ? InputCounts(synthetic: 1) : InputCounts())
      sources.awake = .value(phase >= 90)
      if phase >= 30, phase % 4 == 0 {
        let id: UInt32 = phase < 60 ? 20 : 21
        if lastByWindow[id].map({ ts - $0 >= 15 }) ?? true {
          expectedCaptureTimes.append(ts)
          lastByWindow[id] = ts
        }
      }
      second(ts)
    }
    recorder.flush()
    let rows = try storage.samples(in: TimeRange(10000, 13600))
    XCTAssertEqual(rows.count, 3600)
    XCTAssertEqual(rows.map(\.ts), Array(10000..<13600))
    for row in rows {
      let phase = (row.ts - 10000) % 100
      XCTAssertEqual(row.hasInput, phase % 4 == 0)
      XCTAssertEqual(row.synthetic, phase % 4 == 1 ? 1 : 0)
      XCTAssertEqual(row.keepingAwake, phase >= 90)
      if phase < 20 {
        XCTAssertFalse(row.app.isEmpty)
        XCTAssertTrue(row.excluded)
        XCTAssertEqual(row.window, "")
        XCTAssertEqual(row.documentKey, "")
      }
    }
    XCTAssertEqual(sources.requested.map { $0.0 }, expectedCaptureTimes)
    XCTAssertEqual(try storage.evidence(in: all).count, 1)
    XCTAssertEqual(recorder.health.refusedSeconds, 0)
  }
  func testRepeatedCapturesExactExpiryAndRestartRebuild() throws {
    sources.screen = .value("Invented first 1\nInvented first 2\nInvented second")
    second(10000)
    finish(10001)
    XCTAssertEqual(try storage.evidence(in: all).first?.text, "Invented first 1\nInvented second")
    XCTAssertEqual(recorder.keyMemory.storedAt, ["Inventedfirst": 10000, "Inventedsecond": 10000])
    sources.input = .value(InputCounts(keys: 1))
    sources.screen = .value("Invented first 9\nInvented third")
    second(10015)
    finish(10016)
    XCTAssertEqual(try storage.evidence(in: all).map(\.text), ["Invented first 1\nInvented second", "Invented third"])
    let beforeRestart = recorder.keyMemory
    recorder = makeRecorder()
    second(10017)
    XCTAssertEqual(recorder.keyMemory, beforeRestart)
    second(13599)
    XCTAssertTrue(recorder.keyMemory.keys.contains("Inventedfirst"))
    second(13600)
    XCTAssertFalse(recorder.keyMemory.keys.contains("Inventedfirst"))
    XCTAssertEqual(recorder.keyMemory.storedAt, ["Inventedthird": 10015])
    sources.input = .value(InputCounts(keys: 1))
    sources.screen = .value("Invented first 7")
    second(13600)
    finish(13601)
    XCTAssertEqual(try storage.evidence(in: all).last?.text, "Invented first 7")
  }
  func testDeletionRebuildRemovesDeletedKeysAndDiscardsInFlightCapture() throws {
    second(10000)
    finish(10001)
    sources.input = .value(InputCounts(keys: 1))
    sources.screen = .value("Invented retained line")
    second(10020)
    finish(10021)
    let preview = try storage.previewDeletion(in: TimeRange(10000, 10010))
    try storage.deleteRecords(in: preview.range, confirmation: preview.confirmation)
    second(10022)
    XCTAssertEqual(recorder.keyMemory.storedAt, ["Inventedretainedline": 10020])
    sources.deferCompletion = true
    sources.input = .value(InputCounts(keys: 1))
    sources.screen = .value("Invented delayed line")
    second(10040)
    let next = try storage.previewDeletion(in: TimeRange(10040, 10041))
    try storage.deleteRecords(in: next.range, confirmation: next.confirmation)
    sources.delayed?()
    finish(10041)
    XCTAssertFalse(recorder.keyMemory.keys.contains("Inventeddelayedline"))
    XCTAssertEqual(try storage.evidence(in: all).map(\.text), ["Invented retained line"])
  }
  func testWholeSecretBlockNeverReachesDatabaseOrWAL() throws {
    sources.screen = .value(
      """
      Invented page
      -----BEGIN PRIVATE KEY-----
      INVENTED_SECRET_BODY_ALPHA_ABCXYZ
      INVENTED_SECRET_BODY_BETA_ABCXYZ
      -----END PRIVATE KEY-----
      Invented end
      """)
    second(10000)
    finish(10001)
    let rows = try storage.evidence(in: all)
    XCTAssertEqual(rows.count, 1)
    XCTAssertTrue(rows[0].text.contains("[secret]"))
    for path in [database.path, database.path + "-wal"] {
      let bytes = (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()
      for body in ["INVENTED_SECRET_BODY_ALPHA_ABCXYZ", "INVENTED_SECRET_BODY_BETA_ABCXYZ"] {
        XCTAssertNil(bytes.range(of: Data(body.utf8)))
      }
    }
  }
  func testPauseDisabledAndResumeDrainInput() throws {
    try storage.saveSettings(StorageSettings(excludedApps: [], pausedUntil: 10010))
    for ts in 10000..<10010 { second(ts) }
    XCTAssertEqual(try storage.samples(in: all), [])
    XCTAssertEqual(sources.requested.count, 0)
    XCTAssertEqual(sources.drains, 10)
    second(10010)
    recorder.flush()
    XCTAssertEqual(try storage.samples(in: all).map(\.ts), [10010])
    try storage.saveSettings(StorageSettings(recordingEnabled: false))
    for ts in 10011..<10020 { second(ts) }
    recorder.flush()
    XCTAssertEqual(try storage.samples(in: all).map(\.ts), [10010])
    try storage.saveSettings(StorageSettings(excludedApps: []))
    second(10020)
    recorder.flush()
    XCTAssertEqual(try storage.samples(in: all).map(\.ts), [10010, 10020])
  }
  func testBusyDatabaseRetriesEverySecondInOrderAndCountsRefusal() throws {
    let blocker = try SQLiteConnection(url: database, scope: .directory(folder), busyMilliseconds: 0)
    try blocker.run("BEGIN IMMEDIATE")
    for ts in 10000..<10009 { second(ts) }
    XCTAssertTrue(recorder.health.storageBusy)
    XCTAssertEqual(recorder.health.pendingSeconds, 9)
    XCTAssertEqual(try storage.samples(in: all), [])
    try blocker.run("COMMIT")
    second(10009)
    recorder.flush()
    XCTAssertEqual(try storage.samples(in: all).map(\.ts), Array(10000...10009))
    var insertionOrder: [Int] = []
    try storage.connection.namedRows("SELECT ts FROM samples ORDER BY id") { insertionOrder.append(try $0.int("ts")) }
    XCTAssertEqual(insertionOrder, Array(10000...10009))
    second(10005)
    second(10010)
    recorder.flush()
    XCTAssertEqual(try storage.samples(in: all).map(\.ts), Array(10000...10010))
    XCTAssertEqual(recorder.health.refusedSeconds, 1)
    XCTAssertEqual(recorder.health.storedSeconds, 11)
    XCTAssertFalse(recorder.health.storageFailed)
    XCTAssertEqual(recorder.health.pendingSeconds, 0)
  }
  func testShortBusyWriteRetriesOnFirstAvailableSecond() throws {
    sources.input = .value(InputCounts())
    sources.awake = .value(true)
    let blocker = try SQLiteConnection(url: database, scope: .directory(folder), busyMilliseconds: 0)
    try blocker.run("BEGIN IMMEDIATE")
    for ts in 10000...10002 { second(ts) }
    try blocker.run("COMMIT")
    second(10003)
    XCTAssertEqual(try storage.samples(in: all).map(\.ts), Array(10000...10003))
    XCTAssertEqual(recorder.health.pendingSeconds, 0)
  }
  func testMissingSourcesDoNotStopSamplesAndRecover() throws {
    sources.input = .absent(.permission)
    sources.secure = .absent(.unavailable)
    sources.awake = .value(true)
    sources.front.title = ""
    sources.front.document = nil
    sources.front.accessibility = .permission
    second(10000)
    recorder.flush()
    let row = try XCTUnwrap(storage.samples(in: all).first)
    XCTAssertEqual(row.app, "Invented editor")
    XCTAssertEqual(row.window, "")
    XCTAssertEqual(row.documentKey, "")
    XCTAssertFalse(row.hasInput)
    XCTAssertEqual(sources.requested.count, 0)
    XCTAssertEqual(recorder.health.absentSources[.input], .permission)
    XCTAssertEqual(recorder.health.absentSources[.accessibility], .permission)
    XCTAssertEqual(recorder.health.absentSources[.secureInput], .unavailable)
    sources.input = .value(InputCounts(keys: 1))
    sources.secure = .value(false)
    sources.screen = .absent(.permission)
    second(10015)
    finish(10016)
    XCTAssertEqual(recorder.health.absentSources[.screen], .permission)
    XCTAssertEqual(try storage.samples(in: all).count, 3)
    sources.screen = .value("Invented restored screen")
    sources.front.accessibility = nil
    second(10029)
    sources.input = .value(InputCounts(keys: 1))
    second(10030)
    finish(10031)
    XCTAssertNil(recorder.health.absentSources[.input])
    XCTAssertNil(recorder.health.absentSources[.screen])
    XCTAssertNil(recorder.health.absentSources[.accessibility])
    XCTAssertEqual(try storage.evidence(in: all).count, 1)
  }
  func testRecognitionCompletionDoesNotHoldLaterSamples() throws {
    sources.deferDelivery = true
    second(10000)
    sources.input = .value(InputCounts())
    for ts in 10001...10010 { second(ts) }
    recorder.flush()
    XCTAssertEqual(try storage.samples(in: all).map(\.ts), Array(10000...10010))
    XCTAssertEqual(try storage.evidence(in: all), [])
    sources.delayedDelivery?()
    finish(10011)
    XCTAssertEqual(try storage.evidence(in: all).map(\.ts), [10000])
  }
  func testDelayedImageRequestCannotBeginBeyondGrace() throws {
    sources.deferCompletion = true
    second(10000)
    clock.now = 10002
    sources.delayed?()
    finish(10002)
    XCTAssertEqual(try storage.evidence(in: all), [])
    XCTAssertEqual(try storage.samples(in: all).map(\.ts), [10000, 10002])
  }
  func testDelayedCaptureRechecksPauseAndSecurity() throws {
    sources.deferCompletion = true
    second(10000)
    sources.secure = .value(true)
    sources.delayed?()
    finish(10001)
    XCTAssertEqual(try storage.evidence(in: all), [])
    sources.secure = .value(false)
    sources.input = .value(InputCounts(keys: 1))
    second(10015)
    try storage.saveSettings(StorageSettings(recordingEnabled: false))
    sources.delayed?()
    finish(10016)
    XCTAssertEqual(try storage.evidence(in: all), [])
  }
  func testCaptureInboxAndRetryQueueOverflowIsCounted() throws {
    let blocker = try SQLiteConnection(url: database, scope: .directory(folder), busyMilliseconds: 0)
    try blocker.run("BEGIN IMMEDIATE")
    for offset in 0..<243 {
      sources.front.window = WindowIdentity(processID: 10, windowID: UInt32(100 + offset))
      second(10000 + offset)
    }
    finish(10243)
    XCTAssertEqual(recorder.health.pendingCaptures, 240)
    XCTAssertEqual(recorder.health.droppedCaptures, 3)
    try blocker.run("COMMIT")
    recorder.flush()
    XCTAssertEqual(try storage.evidence(in: all).count, 1)
    XCTAssertEqual(recorder.health.pendingCaptures, 0)
  }
  func testBoundedBusyBacklogCountsNewestOverflow() throws {
    sources.input = .value(InputCounts())
    sources.front.window = nil
    sources.awake = .value(true)
    let blocker = try SQLiteConnection(url: database, scope: .directory(folder), busyMilliseconds: 0)
    try blocker.run("BEGIN IMMEDIATE")
    for offset in 0..<(RecorderTiming.pendingSeconds + 3) { second(10000 + offset) }
    XCTAssertEqual(recorder.health.pendingSeconds, 3600)
    XCTAssertEqual(recorder.health.droppedSeconds, 3)
    try blocker.run("COMMIT")
    recorder.flush()
    XCTAssertEqual(try storage.samples(in: all).map(\.ts), Array(10000..<13600))
    XCTAssertEqual(recorder.health.pendingSeconds, 0)
  }
}
