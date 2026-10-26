import Core
import Foundation
import Shell
import XCTest
@testable import Storage

private final class InventedPayloadSource: ScreenTextSource {
  var deliver: ((SourceReading<ScreenTextPayload>) -> Void)?
  func capturePayload(window: WindowIdentity, permitted: @escaping (CaptureCheck) -> Bool,
    completion: @escaping (SourceReading<ScreenTextPayload>) -> Void) { deliver = completion }
  func captureText(window: WindowIdentity, permitted: @escaping (CaptureCheck) -> Bool,
    completion: @escaping (SourceReading<String>) -> Void) { XCTFail("Structured source expected") }
}

final class RecorderOversizedCaptureTests: XCTestCase {
  var folder: URL!
  var store: ActivityStorage!
  var clock: FakeClock!
  var sources: FakeSources!
  private var screen: InventedPayloadSource!
  var loop: RecorderLoop!
  let all = TimeRange(0, 100_000)
  override func setUpWithError() throws {
    folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ACTIVITYPROBE_TEST_ROOT"] ?? NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    store = try open()
    clock = FakeClock(); clock.now = 100
    sources = FakeSources(); sources.clock = clock
    screen = InventedPayloadSource()
    loop = makeLoop()
  }
  override func tearDownWithError() throws {
    loop.stop()
    let done = expectation(description: "Owned maintenance finished")
    loop.finishMaintenance { done.fulfill() }; wait(for: [done], timeout: 60)
    loop = nil; store = nil
    try FileManager.default.removeItem(at: folder)
  }
  func open() throws -> ActivityStorage {
    let value = try ActivityStorage(url: folder.appendingPathComponent("invented.sqlite"), appDataDirectory: folder,
      busyMilliseconds: 0, databaseScope: .directory(folder))
    try value.saveSettings(StorageSettings(excludedApps: [])); return value
  }
  func makeLoop() -> RecorderLoop {
    RecorderLoop(clock: clock, input: sources, front: sources, secure: sources, awake: sources, screen: screen,
      storage: store, maintenanceStorage: store, ownBundleID: "invented.own")
  }
  func large(structured: Bool = true) -> ScreenTextPayload {
    let line = String(String(repeating: "Invented words ", count: 622).prefix(8704))
    if !structured { return ScreenTextPayload(text: String(repeating: "Invented plain words\n", count: 500_000)) }
    let candidates = (0..<10).map { OCRCandidate(text: line + " \($0) password=inventedSecret", confidence: 0.9) }
    let observations = (0..<120).map { _ in OCRObservation(bounds: OCRBounds(x: 0, y: 0, width: 1, height: 0.01), candidates: candidates) }
    return ScreenTextPayload(text: observations.map { $0.candidates[0].text }.joined(separator: "\n"), observations: observations)
  }
  func request(_ time: Int) {
    clock.now = time; sources.input = .value(InputCounts(keys: 1)); loop.tick()
    XCTAssertNotNil(screen.deliver)
  }
  func complete(_ payload: ScreenTextPayload) { screen.deliver?(.value(payload)); screen.deliver = nil }
  func occurrences() throws -> Int { try store.connection.integer("SELECT count(*) FROM screen_payloads") }
  func assertNoLoss(file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(loop.health.droppedCaptures, 0, file: file, line: line)
    XCTAssertTrue(loop.health.collectionLastAdmissionLosses.isEmpty, file: file, line: line)
  }

  func testRealLoopStoresOrdinaryControlAndStructuredCaptureAboveEightMiB() throws {
    request(100); complete(ScreenTextPayload(text: "Invented ordinary control")); loop.flush()
    XCTAssertEqual(try occurrences(), 1)
    let payload = large(); XCTAssertGreaterThan(payload.estimatedBytes, CollectionPipeline.queueBytes)
    request(115); complete(payload); loop.flush()
    print("RECORDER_OVERSIZED structured_estimated_bytes=\(payload.estimatedBytes) occurrences=\(try occurrences()) drops=\(loop.health.droppedCaptures)")
    XCTAssertEqual(try occurrences(), 2); assertNoLoss()
    let id = try store.connection.integer("SELECT max(evidence_id) FROM screen_payloads")
    let saved = try XCTUnwrap(store.screenPayload(evidenceID: id))
    XCTAssertEqual(saved.observations.count, 120)
    guard let first = saved.observations.first else { return }
    XCTAssertEqual(first.candidates.count, 10)
    XCTAssertFalse(saved.text.contains("inventedSecret"))
    XCTAssertTrue(saved.observations.allSatisfy { $0.candidates.allSatisfy { !$0.text.contains("inventedSecret") } })
  }
  func testRealLoopStoresPlainCaptureAboveEightMiB() throws {
    let payload = large(structured: false); XCTAssertGreaterThan(payload.estimatedBytes, CollectionPipeline.queueBytes)
    request(100); complete(payload); loop.flush()
    print("RECORDER_OVERSIZED plain_estimated_bytes=\(payload.estimatedBytes) occurrences=\(try occurrences()) drops=\(loop.health.droppedCaptures)")
    XCTAssertEqual(try occurrences(), 1); assertNoLoss()
  }
  func testOtherPendingWorkDoesNotDisplaceOversizedOrOrdinaryCompletions() throws {
    var blocked = true
    store.collectionWriterFactory = {
      if blocked { throw StorageError("Invented writer outage") }
      return self.store
    }
    loop = makeLoop()
    let payload = large()
    request(100); complete(payload); loop.flush()
    XCTAssertGreaterThan(loop.health.collectionRetainedBytes, CollectionPipeline.queueBytes)
    request(115); complete(payload); loop.flush()
    XCTAssertEqual(loop.health.pendingCaptures, 1, "Second large item stays owned while publication is blocked")
    request(130)
    let deliver = try XCTUnwrap(screen.deliver)
    complete(ScreenTextPayload(text: "Invented ordinary queued control"))
    // Repeated delivery also exercises the existing completion-count bound.
    deliver(.value(payload))
    XCTAssertEqual(loop.pendingCaptureCompletions, 2)
    loop.tick(); loop.flush()
    XCTAssertEqual(loop.pendingCaptureCompletions, 1)
    XCTAssertEqual(loop.health.pendingCaptures, 1)
    assertNoLoss()
    blocked = false
    for _ in 0..<4 { loop.flush() }
    XCTAssertEqual(try occurrences(), 4)
    XCTAssertEqual(loop.pendingCaptureCompletions, 0); XCTAssertEqual(loop.health.pendingCaptures, 0)
    assertNoLoss()
  }
  func testPrivacyOffBetweenCompletionAndDrainRefusesOversizedCapture() throws {
    request(100); complete(large())
    XCTAssertEqual(loop.pendingCaptureCompletions, 1)
    try store.saveSettings(StorageSettings(excludedApps: [], recordingEnabled: false), at: 101)
    loop.flush()
    XCTAssertEqual(try occurrences(), 0); XCTAssertEqual(try store.collectionFiles().count, 0)
    XCTAssertEqual(loop.health.refusedCaptures, 1); assertNoLoss()
  }
  func fillThreeLargeSlots() throws {
    let payload = large()
    for time in [100, 115, 130] {
      request(time); complete(payload); loop.flush()
    }
    XCTAssertGreaterThan(loop.health.collectionRetainedBytes, CollectionPipeline.queueBytes)
    XCTAssertEqual(loop.health.pendingCaptures, 1)
    XCTAssertEqual(loop.pendingCaptureCompletions, 1)
    assertNoLoss()
  }
  func testSingleStopPersistsAllThreeLargeSlotsBeforeReleaseAndColdReopen() throws {
    var blocked = true
    store.collectionWriterFactory = {
      if blocked { throw StorageError("Invented writer outage") }; return self.store
    }
    loop = makeLoop()
    try fillThreeLargeSlots()
    blocked = false
    loop.stop()
    XCTAssertEqual(loop.pendingCaptureCompletions, 0); XCTAssertEqual(loop.health.pendingCaptures, 0)
    assertNoLoss()
    let done = expectation(description: "Old recorder fully retired")
    loop.finishMaintenance { done.fulfill() }; wait(for: [done], timeout: 60)
    loop = nil; store.collectionWriterFactory = nil; store = nil
    store = try open()
    XCTAssertEqual(try occurrences(), 3, "Cold SQL must contain every retained occurrence without another flush")
    XCTAssertTrue(try store.collectionFiles().isEmpty)
    loop = makeLoop()
  }
  func testSingleStopAfterPrivacyOffRefusesAllThreeLargeSlotsExplicitly() throws {
    var blocked = true
    store.collectionWriterFactory = {
      if blocked { throw StorageError("Invented writer outage") }; return self.store
    }
    loop = makeLoop(); try fillThreeLargeSlots()
    try store.saveSettings(StorageSettings(excludedApps: [], recordingEnabled: false), at: 131)
    blocked = false; loop.stop()
    XCTAssertEqual(try occurrences(), 0); XCTAssertTrue(try store.collectionFiles().isEmpty)
    XCTAssertEqual(loop.health.refusedCaptures, 3); assertNoLoss()
    XCTAssertEqual(loop.pendingCaptureCompletions, 0); XCTAssertEqual(loop.health.pendingCaptures, 0)
  }
  func testCompletedDeferredCapturesSurviveSuspensionGenerationChangeAndReplacement() throws {
    var blocked = true
    store.collectionWriterFactory = {
      if blocked { throw StorageError("Invented writer outage") }; return self.store
    }
    loop = makeLoop(); try fillThreeLargeSlots()
    loop.setSuspended(true); loop.setSuspended(false)
    blocked = false; loop.stop(); assertNoLoss()
    XCTAssertEqual(try occurrences(), 3)
    let done = expectation(description: "Replaced recorder finished")
    loop.finishMaintenance { done.fulfill() }; wait(for: [done], timeout: 60)
    loop = makeLoop(); loop.flush()
    XCTAssertEqual(try occurrences(), 3)
  }
  func testPrivacyOffWhileOversizedHandoffIsDeferredRefusesBothCaptures() throws {
    var blocked = true
    store.collectionWriterFactory = {
      if blocked { throw StorageError("Invented writer outage") }; return self.store
    }
    loop = makeLoop()
    let payload = large()
    request(100); complete(payload); loop.flush()
    request(115); complete(payload); loop.flush()
    XCTAssertEqual(loop.health.pendingCaptures, 1)
    try store.saveSettings(StorageSettings(excludedApps: [], recordingEnabled: false), at: 116)
    blocked = false
    for _ in 0..<3 { loop.flush() }
    XCTAssertEqual(try occurrences(), 0); XCTAssertEqual(try store.collectionFiles().count, 0)
    XCTAssertEqual(loop.health.refusedCaptures, 2); assertNoLoss()
  }
  func testGenerationChangeBeforeOversizedDeliveryCannotEnterNewSession() throws {
    request(100); loop.setSuspended(true); loop.setSuspended(false)
    complete(large()); loop.flush()
    XCTAssertEqual(try occurrences(), 0); XCTAssertEqual(loop.pendingCaptureCompletions, 0)
    XCTAssertEqual(loop.health.droppedCaptures, 1)
  }
  func testRealLoopOversizedReadyCaptureRecoversAfterRestartWithMaskedBytes() throws {
    try store.connection.run("CREATE TRIGGER invented_outage BEFORE INSERT ON screen_payloads BEGIN SELECT RAISE(ABORT,'invented outage'); END")
    request(100); complete(large()); loop.flush()
    XCTAssertEqual(try occurrences(), 0); XCTAssertGreaterThan(loop.health.collectionPersistenceFailures, 0)
    let files = try store.collectionFiles(); XCTAssertEqual(files.count, 1)
    let file = try XCTUnwrap(files.first)
    let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
    XCTAssertEqual(permissions?.intValue, 0o600)
    XCTAssertFalse(try Data(contentsOf: file).contains(Data("inventedSecret".utf8)))
    assertNoLoss(); loop.stop()
    let done = expectation(description: "Old recorder finished")
    loop.finishMaintenance { done.fulfill() }; wait(for: [done], timeout: 60)
    loop = nil
    try store.connection.run("DROP TRIGGER invented_outage")
    store = nil; store = try open()
    sources.input = .value(InputCounts()); screen.deliver = nil; loop = makeLoop()
    loop.flush()
    XCTAssertEqual(try occurrences(), 1); XCTAssertTrue(try store.collectionFiles().isEmpty)
    assertNoLoss()
  }
}
