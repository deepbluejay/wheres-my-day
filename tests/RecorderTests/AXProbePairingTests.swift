import Core
import Foundation
import Shell
import XCTest
@testable import Storage

final class InventedPairedScreen: AXProbeScreenSource {
  var pending: (() -> Void)?
  var probeGate: (() -> Bool)?
  var mutations: (() -> Void)?
  var result = SourceReading.value("Invented OCR before line memory")
  var invalidations = 0
  var axStatus = AXProbeStatus.completed
  var axNodes: [AXProbeNode]? = nil
  func invalidateProbe() { invalidations += 1 }
  func captureText(window: WindowIdentity, permitted: @escaping (CaptureCheck) -> Bool,
    completion: @escaping (SourceReading<String>) -> Void) { completion(result) }
  func captureText(window: WindowIdentity, probe: AXProbeRequest, permitted: @escaping (CaptureCheck) -> Bool,
    probePermitted: @escaping () -> Bool, probeBegin: @escaping () -> AXProbeStatus?,
    probeEnd: @escaping (AXProbeResult) -> Void, probeWatchdogOCR: @escaping (AXProbePair, Bool) -> Void, probeRefused: @escaping () -> Void, probeCompletion: @escaping (AXProbePair) -> Void,
    completion: @escaping (SourceReading<String>) -> Void) {
    probeGate = probePermitted
    _ = permitted(.beforeImage)
    guard probePermitted() else { completion(.absent(.policyRefused)); return }
    mutations?()
    pending = {
      var ax = AXProbeResult(status: self.axStatus)
      ax.nodes = self.axNodes
      ax.text = self.axStatus == .watchdog ? "" : "Invented AX visible text"
      ax.start = 100; ax.end = self.axStatus == .watchdog ? 100.5 : 100.2
      ax.identity = self.axStatus == .watchdog ? "unknown" : "geometry_validated"
      ax.workerWall = ax.end - ax.start
      if self.axStatus == .watchdog { probeEnd(ax) }
      completion(self.result)
      let pair = AXProbePair(request: probe, ax: ax,
        ocrStatus: self.result.value == nil ? "failed" : "completed", ocr: self.result.value ?? "",
        imageRequest: 100, imageReturn: 100.1, ocrCompletion: 101)
      if self.axStatus == .watchdog { probeWatchdogOCR(pair, permitted(.beforeDelivery)) }
      else { probeCompletion(pair) }
    }
  }
}
final class AXProbePairingTests: XCTestCase {
  var folder: URL!
  var store: ActivityStorage!
  var loop: RecorderLoop!
  var clock: FakeClock!
  var sources: FakeSources!
  var screen: InventedPairedScreen!
  override func setUpWithError() throws {
    folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    store = try ActivityStorage(url: folder.appendingPathComponent("invented.sqlite"), appDataDirectory: folder, databaseScope: .directory(folder))
    _ = try store.enableAXProbe(at: 10000)
    clock = FakeClock(); sources = FakeSources(); sources.clock = clock; screen = InventedPairedScreen()
    loop = RecorderLoop(clock: clock, input: sources, front: sources, secure: sources, awake: sources,
      screen: screen, storage: store, maintenanceStorage: store, ownBundleID: "invented.own")
  }
  override func tearDownWithError() throws {
    loop.stop(); drainProbe(); loop = nil; store = nil
    try FileManager.default.removeItem(at: folder)
  }
  private func drainProbe() {
    let drained = expectation(description: "probe writer drained")
    loop.finishMaintenance { drained.fulfill() }
    wait(for: [drained], timeout: 60)
  }
  private func attempts() throws -> Int { try store.connection.integer("SELECT count(*) FROM ax_probe_attempts WHERE json_extract(payload,'$.ax.status') NOT IN ('pending','policyRefused')") }
  func testProbeChecksAvoidCostlyDetailsAndLeaveRecorderResponsive() throws {
    loop.tick()
    let baseline = sources.detailReads
    sources.detailWork = { Thread.sleep(forTimeInterval: 0.01) }
    let completed = expectation(description: "2511 probe checks completed")
    let gate = try XCTUnwrap(screen.probeGate)
    let start = ProcessInfo.processInfo.systemUptime
    DispatchQueue.global().async {
      for _ in 0..<2511 { XCTAssertTrue(gate()) }
      completed.fulfill()
    }
    for _ in 0..<3 { clock.now += 1; loop.tick(); loop.flush() }
    wait(for: [completed], timeout: 10)
    let elapsed = ProcessInfo.processInfo.systemUptime - start
    XCTAssertEqual(sources.detailReads - baseline, 3, "only recorder ticks acquire window details")
    XCTAssertLessThan(elapsed, 5, "probe checks must not pay the invented 25.11-second details cost")
    XCTAssertGreaterThanOrEqual(try store.samples(in: TimeRange(10000, 10004)).count, 4)
    print("Invented probe policy checks: 2511; detail calls avoided: 2511; elapsed seconds: \(elapsed)")
  }
  func testPairingPreservesProductAndNullableEvidenceOnRepeatedLinesAndOCRFailure() throws {
    loop.tick(); screen.pending?(); loop.flush(); drainProbe()
    XCTAssertEqual(try attempts(), 1)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM ax_probe_attempts WHERE evidence_id IS NOT NULL"), 1)
    clock.now += 15; loop.tick(); screen.pending?(); loop.flush(); drainProbe()
    XCTAssertEqual(try attempts(), 2)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM ax_probe_attempts WHERE evidence_id IS NULL"), 1)
    screen.result = .absent(.failed)
    clock.now += 15; loop.tick(); screen.pending?(); loop.flush(); drainProbe()
    XCTAssertEqual(try attempts(), 3)
    XCTAssertEqual(try store.evidence(in: TimeRange(0, 100000)).count, 1)
  }
  func testLargePayloadPreparationAllowsRecorderTicksAndOCRDelivery() throws {
    loop.stop(); drainProbe()
    let preparing = expectation(description: "background payload preparation")
    let stored = expectation(description: "large payload persisted")
    let release = DispatchSemaphore(value: 0)
    let testStore = store!
    let pipeline = AXProbePipeline(write: { pair, evidence, now, gate in
      XCTAssertFalse(Thread.isMainThread)
      preparing.fulfill()
      XCTAssertEqual(release.wait(timeout: .now() + 10), .success)
      XCTAssertTrue(try testStore.appendAXProbe(pair, evidenceID: evidence, at: now, permitted: gate))
      stored.fulfill()
    }, dropped: { _ in XCTFail("large invented attempt fits queue") })
    loop = RecorderLoop(clock: clock, input: sources, front: sources, secure: sources, awake: sources,
      screen: screen, storage: store, maintenanceStorage: store, ownBundleID: "invented.own", probePipeline: pipeline)
    let large = String(repeating: "invented words ", count: 70000)
    screen.axNodes = [AXProbeNode(nodeID: 1, role: "AXTextArea", attributes: (0..<9).map { AXProbeText(attribute: "AXInvented\($0)", text: large) })]
    loop.tick(); screen.pending?(); loop.flush()
    wait(for: [preparing], timeout: 5)
    let start = ProcessInfo.processInfo.systemUptime
    for _ in 0..<3 { clock.now += 1; loop.tick(); loop.flush() }
    XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
    XCTAssertGreaterThanOrEqual(try store.samples(in: TimeRange(10000, 10004)).count, 4)
    XCTAssertEqual(try store.evidence(in: TimeRange(0, 100000)).count, 1)
    XCTAssertTrue(try store.settings().recordingEnabled)
    release.signal(); wait(for: [stored], timeout: 60); drainProbe()
    XCTAssertEqual(try attempts(), 1)
  }

  func testSecureInputDiscardsAXAndKeyChangePreservesAXAtDeliveryAndPersistence() throws {
    loop.tick(); sources.secure = .value(true)
    screen.pending?(); loop.flush(); drainProbe()
    XCTAssertEqual(try attempts(), 0)
    sources.secure = .value(false)
    clock.now += 15; loop.tick()
    sources.front.document = "file:///invented/different"
    screen.pending?(); loop.flush(); drainProbe()
    XCTAssertEqual(try attempts(), 1)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM ax_probe_attempts WHERE json_extract(payload,'$.ocr_refusal_reason')='key_changed'"), 1)
    XCTAssertEqual(try store.connection.integer("SELECT total FROM ax_probe_flow WHERE event='ocr_secure_input'"), 1)
    XCTAssertEqual(try store.connection.integer("SELECT total FROM ax_probe_flow WHERE event='ocr_key_changed'"), 1)
    clock.now += 15; loop.tick()
    sources.front.window = WindowIdentity(processID: 10, windowID: 21)
    screen.pending?(); loop.flush(); drainProbe()
    XCTAssertEqual(try attempts(), 2)
    XCTAssertEqual(try store.connection.integer("SELECT total FROM ax_probe_flow WHERE event='ocr_key_changed'"), 2)
  }
  func testPrivacyGateIsRecheckedOnBackgroundPersistence() throws {
    let preparing = expectation(description: "background probe ready"), refused = expectation(description: "privacy refused at write")
    let release = DispatchSemaphore(value: 0), testStore = store!
    loop.stop(); drainProbe()
    let pipeline = AXProbePipeline(write: { pair, evidence, now, gate in
      preparing.fulfill()
      XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
      XCTAssertFalse(try testStore.appendAXProbe(pair, evidenceID: evidence, at: now, permitted: gate))
      refused.fulfill()
    }, dropped: { _ in XCTFail() })
    loop = RecorderLoop(clock: clock, input: sources, front: sources, secure: sources, awake: sources,
      screen: screen, storage: store, maintenanceStorage: store, ownBundleID: "invented.own", probePipeline: pipeline)
    loop.tick(); screen.pending?(); loop.flush()
    wait(for: [preparing], timeout: 1)
    sources.secure = .value(true); release.signal()
    wait(for: [refused], timeout: 5); drainProbe()
    XCTAssertEqual(try attempts(), 0)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM ax_probe_blobs"), 0)
  }
  func testNoInputSupersededAndBusyOCRPreserveAXWithoutEvidence() throws {
    sources.input = .value(InputCounts())
    loop.tick(); screen.pending?(); loop.flush(); drainProbe()
    XCTAssertEqual(try attempts(), 1)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM ax_probe_attempts WHERE json_extract(payload,'$.ocr_refusal_reason')='no_person_input'"), 1)
    sources.input = .value(InputCounts(keys: 1))
    for reason in [SourceAbsence.superseded, .busy] {
      screen.result = .absent(reason)
      clock.now += 15; loop.tick(); screen.pending?(); loop.flush(); drainProbe()
      XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM ax_probe_attempts WHERE json_extract(payload,'$.ocr_refusal_reason')=?", [.key(reason.rawValue)]), 1)
    }
    XCTAssertEqual(try attempts(), 3)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM ax_probe_attempts WHERE evidence_id IS NOT NULL"), 0)
    XCTAssertEqual(try store.evidence(in: TimeRange(0, 100000)).count, 0)
  }
  func testEachPrivacyGateStillDiscardsAX() throws {
    for reason in ["recording_off", "pause", "excluded_app", "own_app", "secure_input", "capture_generation", "stop", "settings_unreadable"] {
      clock.now += 15; loop.tick()
      let deliver = screen.pending
      var settings = try store.settings()
      switch reason {
      case "recording_off": settings.recordingEnabled = false; try store.saveSettings(settings)
      case "pause": settings.pausedUntil = clock.now + 60; try store.saveSettings(settings)
      case "excluded_app": settings.excludedApps.append(sources.front.bundleID); try store.saveSettings(settings)
      case "own_app": sources.front.bundleID = "invented.own"
      case "secure_input": sources.secure = .value(true)
      case "capture_generation": loop.setSuspended(true)
      case "stop": loop.stop()
      default: try store.connection.run("ALTER TABLE settings RENAME TO invented_hidden_settings")
      }
      deliver?(); loop.flush(); drainProbe()
      XCTAssertEqual(try attempts(), 0, reason)
      if reason == "settings_unreadable" { try store.connection.run("ALTER TABLE invented_hidden_settings RENAME TO settings") }
      settings.recordingEnabled = true; settings.pausedUntil = nil; settings.excludedApps = []
      try store.saveSettings(settings)
      sources.front.bundleID = "invented.editor"; sources.secure = .value(false)
      loop.setSuspended(false)
      if reason == "stop" {
        loop = RecorderLoop(clock: clock, input: sources, front: sources, secure: sources, awake: sources,
          screen: screen, storage: store, maintenanceStorage: store, ownBundleID: "invented.own")
      }
    }
  }
  func testForgetDuringInflightSleepAndOffInvalidateProbe() throws {
    loop.tick()
    let preview = try store.previewDeletion(in: TimeRange(10000, 10001))
    _ = try store.deleteRecords(in: preview.range, confirmation: preview.confirmation)
    screen.pending?(); loop.flush(); drainProbe()
    XCTAssertEqual(try attempts(), 0)
    clock.now += 15; loop.tick(); loop.setSuspended(true); screen.pending?(); loop.flush(); drainProbe()
    XCTAssertEqual(try attempts(), 0); XCTAssertGreaterThan(screen.invalidations, 0)
    loop.setSuspended(false)
    clock.now += 15; loop.tick(); try store.disableAXProbe(); screen.pending?(); loop.flush(); drainProbe()
    XCTAssertEqual(try attempts(), 0)
  }
  func testReviewEpochBlocksOrdinaryOCRAcrossBriefOpenAndClose() throws {
    loop.tick()
    try store.connection.run("INSERT OR REPLACE INTO settings(key,value) VALUES('general.axProbe.reviewGeneration','invented-new-epoch')")
    // The page already closed before delivery, so its active flag alone could not reject this old request.
    screen.pending?(); loop.flush(); drainProbe()
    XCTAssertEqual(try store.evidence(in: TimeRange(0, 100000)).count, 0)
    XCTAssertEqual(try attempts(), 0)
    let ordinary = try store.settings()
    var reviewing = ordinary; reviewing.general["axProbe.reviewActive"] = "1"
    XCTAssertTrue(RecorderPolicy.captureAllowed(front: sources.front, input: InputCounts(keys: 1), secureInput: false,
      settings: reviewing, ownBundleID: "invented.own", at: clock.now))
  }

  func testWallClockStepDoesNotInventScheduledTickGaps() throws {
    loop.tick()
    clock.now += 15
    loop.tick()
    XCTAssertEqual(try store.connection.integer("SELECT COALESCE(SUM(total),0) FROM ax_probe_flow WHERE event='scheduledTickGaps'"), 0)
  }

  func testWatchdogKeepsOCRAvailabilityAndAtomicEvidenceLinkWithoutLateText() throws {
    screen.axStatus = .watchdog
    loop.tick(); screen.pending?(); loop.flush(); drainProbe()
    XCTAssertNil(try store.settings().axProbeRun)
    XCTAssertEqual(try store.evidence(in: TimeRange(0, 100000)).count, 1)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM ax_probe_attempts WHERE evidence_id IS NOT NULL"), 1)
    var pair: AXProbePair?
    try store.connection.namedRows("SELECT payload FROM ax_probe_attempts") {
      pair = try JSONDecoder().decode(AXProbePair.self, from: Data(try $0.text("payload").utf8))
    }
    XCTAssertEqual(pair?.ax.status, .watchdog)
    XCTAssertEqual(pair?.ocrStatus, "acquired_without_snapshot")
    XCTAssertEqual(pair?.imageReturn, 100.1)
    XCTAssertEqual(pair?.ocrCompletion, 101)
    XCTAssertEqual(pair?.ocr, ""); XCTAssertEqual(pair?.ax.text, "")
  }

}
