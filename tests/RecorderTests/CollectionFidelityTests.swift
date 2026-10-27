import Core
import Foundation
import ApplicationServices
import Vision
import Shell
import XCTest
@testable import Inbound
@testable import Storage

private final class StructuredInventedDriver: AXProbeScreenDriver {
  let payload: ScreenTextPayload
  init(_ payload: ScreenTextPayload) { self.payload = payload }
  func preflight() -> Bool { true }
  func capture(window: WindowIdentity, permitted: @escaping (CaptureCheck) -> Bool,
    requested: (() -> Void)?, returned: (() -> Void)?, completion: @escaping (SourceReading<String>) -> Void) {
    XCTFail("Structured native path must preserve observations")
  }
  func capturePayload(window: WindowIdentity, permitted: @escaping (CaptureCheck) -> Bool,
    requested: (() -> Void)?, returned: (() -> Void)?, completion: @escaping (SourceReading<ScreenTextPayload>) -> Void) {
    completion(permitted(.beforeImage) ? .value(payload) : .absent(.policyRefused))
  }
}
final class CollectionFidelityTests: XCTestCase {
  var folder: URL!
  var store: ActivityStorage!
  override func setUpWithError() throws {
    folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ACTIVITYPROBE_TEST_ROOT"] ?? NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    store = try ActivityStorage(url: folder.appendingPathComponent("invented.sqlite"), appDataDirectory: folder,
      databaseScope: .directory(folder))
    try store.saveSettings(StorageSettings(excludedApps: []))
  }
  override func tearDownWithError() throws { store = nil; try FileManager.default.removeItem(at: folder) }
  let all = TimeRange(0, 100_000)
  func testSummaryCallerReceivesNovelFirstCandidateViewOnly() throws {
    try store.saveFixtureSettings(StorageSettings(excludedApps: [], subscriptionConnected: true).withClaudeUse)
    try store.appendSamples([TimeSample(ts: 120, keys: 1), TimeSample(ts: 180, keys: 1)])
    try store.appendScreenCapture(text: "Invented repeated version 1", at: 120, source: "invented", knownKeys: [])
    try store.appendScreenCapture(payload: ScreenTextPayload(text: "Invented repeated version 2",
      observations: [OCRObservation(bounds: OCRBounds(x: 0, y: 0, width: 1, height: 1),
        candidates: [OCRCandidate(text: "Invented alternate withheld", confidence: 0.1)])],
      document: "file:///invented/original-withheld", browserAddress: "https://invented.invalid/withheld?q=1"),
      at: 180, source: "invented", documentKey: "", project: "", probe: nil)
    let caller = SummaryFakeCaller()
    try SummaryService(storage: store, caller: caller).summarize(from: 120, through: 600,
      dayStart: 0, locale: "en-US", requested: true)
    let prompt = try XCTUnwrap(caller.prompts.first)
    XCTAssertTrue(prompt.contains("Invented repeated version 1"))
    XCTAssertFalse(prompt.contains("Invented repeated version 2"))
    XCTAssertFalse(prompt.contains("withheld"))
    XCTAssertEqual(try store.evidence(in: all).count, 2)
  }
  func testStructuredNativeAndPairedAdaptersRetainPayloadWithoutCaptureOrAX() throws {
    let payload = ScreenTextPayload(text: "Invented literal_code", observations: [OCRObservation(
      bounds: OCRBounds(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
      candidates: [OCRCandidate(text: "Invented literal_code", confidence: 0.01)])])
    let source = MacScreenTextSource(driver: StructuredInventedDriver(payload),
      probeWorker: MacAXProbeWorker(preflight: { false }))
    let window = WindowIdentity(processID: 10, windowID: 20)
    let pairDone = expectation(description: "Invented AX completion")
    var ordinary: ScreenTextPayload?, paired: ScreenTextPayload?
    source.capturePayload(window: window, permitted: { _ in true }) { ordinary = $0.value }
    source.capturePayload(window: window, probe: AXProbeRequest(run: AXProbeRun(start: 100),
      time: 100, window: window, bundleID: "invented", isBrowser: false),
      permitted: { _ in true }, probePermitted: { true }, probeBegin: { XCTFail(); return nil },
      probeEnd: { XCTAssertEqual($0.status, .permission) }, probeWatchdogOCR: { _, _ in XCTFail() }, probeRefused: { XCTFail() },
      probeCompletion: { XCTAssertEqual($0.ocr, payload.text); pairDone.fulfill() }, completion: { paired = $0.value })
    wait(for: [pairDone], timeout: 2)
    XCTAssertEqual(ordinary, payload); XCTAssertEqual(paired, payload)
  }
  func testRecorderPersistsStructuredPayloadAndOriginalCaptureMetadata() throws {
    let payload = ScreenTextPayload(text: "Invented literal_code", observations: [OCRObservation(
      bounds: OCRBounds(x: 0.1, y: 0.2, width: 0.3, height: 0.4), candidates: [
        OCRCandidate(text: "Invented literal_code", confidence: 0.01),
        OCRCandidate(text: "Invented literal_c0de", confidence: 0.001)])],
      languages: ["en-US"], languageStatus: "supported_automatic", engine: "Vision")
    let clock = FakeClock(), sources = FakeSources()
    sources.clock = clock
    sources.front.browserAddress = "https://invented.invalid:8443/page?q=1#fragment"
    let native = MacScreenTextSource(driver: StructuredInventedDriver(payload))
    let loop = RecorderLoop(clock: clock, input: sources, front: sources, secure: sources, awake: sources,
      screen: native, storage: store, maintenanceStorage: store, ownBundleID: "invented.own")
    loop.tick(); loop.flush()
    let id = try store.connection.integer("SELECT id FROM evidence WHERE kind='screen' LIMIT 1")
    let stored = try XCTUnwrap(store.screenPayload(evidenceID: id))
    XCTAssertEqual(stored.observations, payload.observations)
    XCTAssertEqual(stored.languages, payload.languages)
    XCTAssertEqual(stored.document, sources.front.document)
    XCTAssertEqual(stored.browserAddress, sources.front.browserAddress)
    XCTAssertEqual(stored.window, sources.front.window)
    loop.stop()
  }
  func testEveryObservedAwakeStateSurvivesWithoutInventingAccountingSeconds() throws {
    let clock = FakeClock(), sources = FakeSources()
    sources.clock = clock; sources.input = .value(InputCounts())
    let loop = RecorderLoop(clock: clock, input: sources, front: sources, secure: sources, awake: sources,
      screen: sources, storage: store, maintenanceStorage: store, ownBundleID: "invented.own")
    loop.tick(); loop.flush()
    XCTAssertEqual(try store.samples(in: all), [])
    sources.awake = .value(true); loop.tick(); loop.flush()
    sources.awake = .value(false); loop.tick(); loop.flush()
    XCTAssertEqual(try store.samples(in: all).count, 1)
    XCTAssertEqual(try store.observations(in: all).map(\.sample.keepingAwake), [false, true, false])
    loop.stop()
  }
  func testLateURLUpdatesSurviveFocusChangeAndCompletedMissWithoutTitleChange() throws {
    let clock = FakeClock(), sources = FakeSources()
    sources.clock = clock
    let loop = RecorderLoop(clock: clock, input: sources, front: sources, secure: sources, awake: sources,
      screen: sources, storage: store, maintenanceStorage: store, ownBundleID: "invented.own")
    let time = Double(clock.now) - 0.5
    sources.completedDetails = [FrontObservation(bundleID: "invented.embedded", title: "Invented same title",
      isBrowserKnown: false, observedAt: time)]
    loop.tick(); loop.flush()
    sources.completedDetails = [FrontObservation(bundleID: "invented.embedded", title: "Invented same title",
      browserAddress: "https://invented.invalid/first?q=1", isBrowser: false, observedAt: time + 1)]
    clock.now += 1; loop.tick(); loop.flush()
    sources.completedDetails = [FrontObservation(bundleID: "invented.embedded", title: "Invented same title",
      browserAddress: "https://invented.invalid/second?q=2", isBrowser: false, observedAt: time + 2)]
    clock.now += 1; loop.tick(); loop.flush()
    let updates = try store.observations(in: all).filter { $0.sample.bundleID == "invented.embedded" }
    XCTAssertEqual(updates.map(\.sample.browserAddress), [nil, "https://invented.invalid/first?q=1", "https://invented.invalid/second?q=2"])
    XCTAssertEqual(updates.map(\.sample.observedAt), [time, time + 1, time + 2])
    XCTAssertEqual(updates.map(\.sample.documentKey), ["", "invented.invalid/first", "invented.invalid/second"])
    XCTAssertEqual(updates.map(\.sample.isBrowserKnown), [false, true, true])
    loop.stop()
  }
  func testExcludedObservationKeepsCountSkeletonAndBlanksRichContent() throws {
    var input = InputCounts()
    input.observe(InputObservation(kind: .key, timestamp: 100, sourcePID: 123))
    let row = RecorderPolicy.sample(at: 100, front: FrontObservation(bundleID: "invented.blocked",
      title: "Invented excluded title", document: "file:///invented/excluded",
      browserAddress: "https://invented.invalid/excluded"), input: input, keepingAwake: false,
      settings: StorageSettings(excludedApps: ["invented.blocked"]))
    try store.appendSamples([row])
    let sample = try XCTUnwrap(store.observations(in: all).first).sample
    XCTAssertEqual(sample.keys, 1); XCTAssertEqual(sample.synthetic, 1)
    XCTAssertEqual(sample.window, ""); XCTAssertNil(sample.document); XCTAssertNil(sample.browserAddress)
    XCTAssertEqual(sample.inputEvents, [])
    XCTAssertEqual(try store.samples(in: all).first?.keys, 0)
  }
  func testReleaseModifierAndDragMappingWithoutTap() {
    XCTAssertEqual(MacInputSource.kind(for: .keyUp), .keyUp)
    XCTAssertEqual(MacInputSource.kind(for: .leftMouseUp), .mouseUp)
    XCTAssertEqual(MacInputSource.kind(for: .rightMouseUp), .mouseUp)
    XCTAssertEqual(MacInputSource.kind(for: .otherMouseUp), .mouseUp)
    XCTAssertEqual(MacInputSource.kind(for: .flagsChanged), .modifiers)
    XCTAssertEqual(MacInputSource.kind(for: .rightMouseDragged), .drag)
    XCTAssertNil(MacInputSource.kind(for: .tapDisabledByTimeout))
  }
  func testSyntheticKindsUnknownProvenanceMovementsButtonsAndScrollRoundTrip() throws {
    var counts = InputCounts()
    for (offset, kind) in [InputEventKind.key, .click, .scroll, .move, .move, .mouseUp, .modifiers].enumerated() {
      counts.observe(InputObservation(kind: kind, timestamp: 100.0 + Double(offset) / 100,
        sourcePID: 123, button: kind == .click ? 2 : nil,
        scrollX: kind == .scroll ? -5 : nil, scrollY: kind == .scroll ? 11 : nil))
    }
    counts.observe(InputObservation(kind: .keyUp, timestamp: 100.9))
    XCTAssertEqual(counts.keys, 1); XCTAssertEqual(counts.clicks, 1); XCTAssertEqual(counts.scrolls, 1)
    XCTAssertEqual(counts.movements, 2); XCTAssertEqual(counts.synthetic, 7); XCTAssertFalse(counts.byPerson)
    let row = RecorderPolicy.sample(at: 100, front: FrontObservation(bundleID: "invented.app"), input: counts,
      keepingAwake: false, settings: StorageSettings(excludedApps: []))
    try store.appendSamples([row])
    let observed = try XCTUnwrap(store.observations(in: all).first).sample
    XCTAssertEqual(observed.inputEvents, counts.events)
    XCTAssertNil(observed.inputEvents.last?.programMade)
    XCTAssertEqual(observed.inputEvents[1].button, 2)
    XCTAssertEqual(observed.inputEvents[2].scrollX, -5)
    XCTAssertEqual(observed.inputEvents[2].scrollY, 11)
    let canonical = try XCTUnwrap(store.samples(in: all).first)
    XCTAssertEqual(canonical.keys, 0); XCTAssertEqual(canonical.synthetic, 7)
  }
  func testEveryContextInOneSecondAndOriginalURLsRemainDistinctAndMasked() throws {
    let secret = "inventedQueryCredential"
    let urls = ["https://invented.invalid:8443/page?q=one#first", "https://invented.invalid:8443/page?q=two#second"]
    let rows = urls.enumerated().map { index, address in
      RecorderPolicy.sample(at: 100,
        front: FrontObservation(bundleID: "invented.webview", title: "Invented \(index)",
          document: "file:///invented/file", browserAddress: address, isBrowser: false),
        input: InputCounts(keys: 1), keepingAwake: false, settings: StorageSettings(excludedApps: []))
    }
    XCTAssertEqual(try store.appendSamples(rows), AppendResult(stored: 1, refused: 1))
    XCTAssertEqual(try store.observations(in: all).map(\.sample.browserAddress), urls)
    XCTAssertEqual(try store.observations(in: all).map(\.sample.documentKey), ["invented.invalid/page", "invented.invalid/page"])
    XCTAssertEqual(try store.observations(in: all).map(\.sample.document), ["file:///invented/file", "file:///invented/file"])
    let row = TimeSample(ts: 101, document: "https://invented.invalid/?password=\(secret)",
      browserAddress: "https://invented.invalid/?password=\(secret)")
    try store.appendSamples([row])
    let observed = try XCTUnwrap(store.observations(in: TimeRange(101, 102)).first).sample
    XCTAssertFalse(observed.document?.contains(secret) ?? true)
    XCTAssertFalse(observed.browserAddress?.contains(secret) ?? true)
    XCTAssertEqual(try store.samples(in: all).count, 2)
  }
  func testFullCapturesKeepNumericPunctuationBlankLayoutCrossAppAndRepeatedOccurrences() throws {
    let texts = ["123\n\nVersion 1.2!\nSame\nSame\n", "124\n\nVersion 1.3?\nSame\nSame\n",
      "124\n\nVersion 1.3?\nSame\nSame\n", "password=inventedA\npassword=inventedB\n\n", "", "\n\n"]
    for (index, text) in texts.enumerated() {
      try store.appendScreenCapture(text: text, at: 100 + index, source: "invented.\(index % 2)", knownKeys: ["Same", "Version"])
    }
    XCTAssertEqual(try store.evidence(in: all).map(\.text), texts.map { Redaction.apply($0).text })
    XCTAssertEqual(try store.evidence(in: all).map(\.ts), [100, 101, 102, 103, 104, 105])
    XCTAssertEqual(try store.evidence(in: all)[3].text, "[secret]\n[secret]\n\n")
  }
  func testHistoricalEvidenceKeepsItsExistingOutwardViewWhileNewOccurrencesAreNovel() throws {
    let old = ["Invented count 1\nInvented count 2", "Invented count 3"]
    for (index, text) in old.enumerated() {
      try store.connection.run("INSERT INTO evidence(ts,kind,source,document_key,project,text) VALUES(?,'screen','invented','','',?)",
        [.integer(100 + index * 10), .text(text)])
    }
    try store.appendScreenCapture(text: "Invented count 4", at: 120, source: "invented", knownKeys: [])
    XCTAssertEqual(try store.novelEvidence(in: all).map(\.text), old)
    XCTAssertEqual(try store.evidence(in: all).count, 3)
    try store.appendScreenCapture(text: "Invented count 5", at: 3710, source: "invented", knownKeys: [])
    XCTAssertEqual(try store.novelEvidence(in: all).map(\.ts), [100, 110, 3710])
  }
  func testNovelViewDoesNotRefreshSuppressedKeysAndHandlesRangeStartAndExactHour() throws {
    for time in [100, 110, 3699, 3700, 3701] {
      try store.appendScreenCapture(text: "Invented count \(time)", at: time, source: "invented", knownKeys: [])
    }
    XCTAssertEqual(try store.evidence(in: all).count, 5)
    XCTAssertEqual(try store.novelEvidence(in: all).map(\.ts), [100, 3700])
    XCTAssertEqual(try store.novelEvidence(in: TimeRange(110, 3701)).map(\.ts), [3700])
  }
  func testSupportedLanguagePlanIgnoresLocaleAndLiteralNativeConfiguration() {
    let supported = ["en-US", "ko-KR", "ja-JP", "ar-SA"]
    let request = VNRecognizeTextRequest()
    let plan = MacScreenTextSource.configure(request, supported: supported)
    XCTAssertEqual(plan.languages, supported)
    XCTAssertEqual(request.recognitionLanguages, supported)
    XCTAssertFalse(request.usesLanguageCorrection)
    XCTAssertTrue(request.automaticallyDetectsLanguage)
    let fallback = MacScreenTextSource.configure(request, supported: nil)
    XCTAssertEqual(fallback.languages, []); XCTAssertEqual(fallback.status, "discovery_failed_automatic")
    XCTAssertTrue(request.automaticallyDetectsLanguage)
    XCTAssertEqual(OCRRecognitionPlan(supported: ["ja-JP"]).languages, ["ja-JP"])
  }
  func testLowConfidenceUnicodeBoundsAlternatesSurviveAndDeletionCascades() throws {
    let payload = ScreenTextPayload(text: "문자 code_1", observations: [OCRObservation(
      bounds: OCRBounds(x: 0.1, y: 0.2, width: 0.3, height: 0.4), candidates: [
        OCRCandidate(text: "문자 code_1", confidence: 0.01), OCRCandidate(text: "문자 code_l", confidence: 0.001)])],
      languages: ["ko-KR", "en-US"], languageStatus: "supported_automatic", engine: "Vision")
    let result = try store.appendScreenCapture(payload: payload, at: 100, source: "invented", documentKey: "", project: "", probe: nil)
    let id = try XCTUnwrap(result.evidenceID)
    XCTAssertEqual(try store.screenPayload(evidenceID: id), payload)
    let preview = try store.previewDeletion(in: TimeRange(100, 101))
    try store.deleteRecords(in: preview.range, confirmation: preview.confirmation)
    XCTAssertNil(try store.screenPayload(evidenceID: id))
    XCTAssertEqual(try store.appendScreenCapture(payload: payload, at: 100, source: "invented", documentKey: "", project: "", probe: nil).append.refused, 1)
  }
  func testMigrationAddsRelationsWithoutChangingHistoricalRows() throws {
    try store.appendSamples([TimeSample(ts: 50, app: "Invented historical")])
    try store.connection.transaction { try store.insertEvidence(EvidenceText(ts: 50, kind: .screen, source: "invented", text: "Invented old line")) }
    let beforeSamples = try store.samples(in: all), beforeEvidence = try store.evidence(in: all)
    try store.connection.run("DROP TABLE sample_observations")
    try store.connection.run("DROP TRIGGER screen_payload_delete")
    try store.connection.run("DROP TABLE screen_payloads")
    try store.connection.run("PRAGMA user_version=9")
    try store.connection.run("""
      CREATE TRIGGER invented_historical_samples_no_update BEFORE UPDATE ON samples
      BEGIN SELECT RAISE(ABORT,'Historical samples must not be rewritten'); END
      """)
    let adopted = try ActivityStorage(url: folder.appendingPathComponent("invented.sqlite"), appDataDirectory: folder,
      databaseScope: .directory(folder))
    XCTAssertEqual(try adopted.connection.integer("PRAGMA user_version"), SQLiteConnection.schemaVersion)
    XCTAssertEqual(try adopted.samples(in: all), beforeSamples)
    XCTAssertEqual(try adopted.evidence(in: all), beforeEvidence)
    XCTAssertEqual(try adopted.observations(in: all), [])
  }
  func testStructuredCandidateBlockSecretsNeverReachDatabaseOrWAL() throws {
    let secret = "INVENTED_BLOCK_BODY_ABCDEF"
    let lines = ["Invented safe before", "-----BEGIN PRIVATE KEY-----", secret, "-----END PRIVATE KEY-----", "Invented safe after"]
    let payload = ScreenTextPayload(text: lines.joined(separator: "\n"), observations: lines.map {
      OCRObservation(bounds: OCRBounds(x: 0, y: 0, width: 1, height: 0.1),
        candidates: [OCRCandidate(text: $0, confidence: 0.1), OCRCandidate(text: $0, confidence: 0.01)])
    })
    let result = try store.appendScreenCapture(payload: payload, at: 100, source: "invented", documentKey: "", project: "", probe: nil)
    let stored = try XCTUnwrap(store.screenPayload(evidenceID: XCTUnwrap(result.evidenceID)))
    XCTAssertFalse(stored.text.contains(secret))
    XCTAssertFalse(stored.observations.flatMap(\.candidates).contains { $0.text.contains(secret) })
    XCTAssertEqual(stored.blockHypotheses?.count, 2)
    XCTAssertTrue(stored.blockHypotheses?.allSatisfy {
      $0.contains("Invented safe before") && $0.contains("Invented safe after") && !$0.contains(secret)
    } ?? false)
    for suffix in ["", "-wal"] {
      let bytes = (try? Data(contentsOf: folder.appendingPathComponent("invented.sqlite" + suffix))) ?? Data()
      XCTAssertNil(bytes.range(of: Data(secret.utf8)))
    }
  }
  func testWholeAndStructuredCaptureWritersPreserveHistoricalOffAndPause() throws {
    try store.saveSettings(StorageSettings(excludedApps: [], recordingEnabled: false), at: 100)
    try store.saveSettings(StorageSettings(excludedApps: [], pausedUntil: 104), at: 102)
    try store.saveSettings(StorageSettings(excludedApps: []), at: 105)
    for time in [101, 103] {
      XCTAssertEqual(try store.appendScreenCapture(text: "Invented blocked capture", at: time,
        source: "invented", knownKeys: []).append, AppendResult(refused: 1))
      XCTAssertEqual(try store.appendScreenCapture(payload: ScreenTextPayload(text: "Invented blocked capture"),
        at: time, source: "invented", documentKey: "", project: "", probe: nil).append, AppendResult(refused: 1))
    }
    XCTAssertEqual(try store.evidence(in: all), [])
  }
  func testInputEventTimestampsCannotReintroduceForgottenOrPausedMetadataInLaterSample() throws {
    try store.saveSettings(StorageSettings(excludedApps: [], recordingEnabled: false), at: 100)
    try store.saveSettings(StorageSettings(excludedApps: []), at: 101)
    let preview = try store.previewDeletion(in: TimeRange(102, 103))
    try store.deleteRecords(in: preview.range, confirmation: preview.confirmation)
    let events = [100.5, 101.5, 102.5, 103.5].map {
      InputObservation(kind: .key, timestamp: $0, sourcePID: 0)
    }
    try store.appendSamples([TimeSample(ts: 104, keys: 4, inputEvents: events)])
    XCTAssertEqual(try store.observations(in: all).first?.sample.inputEvents.map(\.timestamp), [101.5, 103.5])
    XCTAssertEqual(try store.samples(in: all).first?.keys, 2)
  }
  func testObservationDeletionRetentionAndHistoricalPause() throws {
    let observation = ActivityObservation(sample: TimeSample(ts: 100, document: "file:///invented/private"))
    try store.appendObservations([observation])
    let preview = try store.previewDeletion(in: TimeRange(100, 101))
    try store.deleteRecords(in: preview.range, confirmation: preview.confirmation)
    XCTAssertEqual(try store.appendObservations([observation]).refused, 1)
    XCTAssertEqual(try store.observations(in: all), [])
    try store.appendSamples([TimeSample(ts: 101, document: "file:///invented/old")])
    _ = try store.cleanRetention(at: 101 + 31 * 86400)
    XCTAssertEqual(try store.observations(in: all), [])
    XCTAssertEqual(try store.samples(in: all).count, 1)
    try store.saveSettings(StorageSettings(excludedApps: [], pausedUntil: 1000), at: 200)
    XCTAssertEqual(try store.appendObservations([ActivityObservation(sample: TimeSample(ts: 201))]).refused, 1)
    try store.saveSettings(StorageSettings(excludedApps: []), at: 1001)
    XCTAssertEqual(try store.appendObservations([ActivityObservation(sample: TimeSample(ts: 201))]).refused, 1)
  }
}
