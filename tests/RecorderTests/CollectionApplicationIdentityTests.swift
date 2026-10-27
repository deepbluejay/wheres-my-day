import Core
import CryptoKit
import Foundation
import Shell
import XCTest
@testable import Storage

final class CollectionApplicationIdentityTests: XCTestCase {
  var folder: URL!, store: ActivityStorage!
  let all = TimeRange(0, 1000)
  let identities = ["invented.Editor", "invented.AKIA1234567890ABCDEF", "invented.ghp_1234567890abcdefghijklmnop"]
  override func setUpWithError() throws {
    folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try reopen()
    try store.saveSettings(StorageSettings(excludedApps: []), at: 0)
  }
  override func tearDownWithError() throws { store = nil; try FileManager.default.removeItem(at: folder) }
  func reopen() throws {
    store = nil
    store = try ActivityStorage(url: folder.appendingPathComponent("invented.sqlite"), appDataDirectory: folder,
      busyMilliseconds: 0, databaseScope: .directory(folder))
  }
  func observe(_ source: String, at time: Int) -> ActivityObservation {
    ActivityObservation(sample: TimeSample(ts: time, bundleID: source, window: "Invented window",
      documentKey: "invented-document", inputEvents: [InputObservation(kind: .move, timestamp: Double(time)+0.1)],
      observedAt: Double(time)+0.2))
  }
  func offer(_ pipeline: CollectionPipeline, source: String, at time: Int) {
    XCTAssertTrue(pipeline.offer(observe(source, at: time)))
    XCTAssertTrue(pipeline.offer(payload: ScreenTextPayload(text: "Invented OCR", document: "invented-document"),
      at: time, source: source, documentKey: "invented-document", runID: nil, attemptID: nil))
  }
  func assertRefused(_ time: Int, file: StaticString = #filePath, line: UInt = #line) throws {
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM screen_payloads p JOIN evidence e ON e.id=p.evidence_id WHERE e.ts=?", [.integer(time)]), 0, file: file, line: line)
    let rows = try store.observations(in: TimeRange(time,time+1))
    XCTAssertEqual(rows.count, 1, file: file, line: line)
    XCTAssertTrue(rows.allSatisfy { $0.sample.excluded && $0.sample.window.isEmpty && $0.sample.documentKey.isEmpty
      && $0.sample.observedAt == nil && $0.sample.inputEvents.isEmpty }, file: file, line: line)
    XCTAssertTrue(try store.inputEvents(in: TimeRange(time,time+1)).isEmpty, file: file, line: line)
    XCTAssertTrue(try store.collectionFiles().isEmpty, file: file, line: line)
  }
  func testDigestMatchesSHA256AndCaseNormalizationAcrossBlockLengths() {
    for source in identities + ["", "ABC", String(repeating: "Invented.Long.App.", count: 100), "invented.한글.É"] {
      let expected = SHA256.hash(data: Data(source.lowercased().utf8)).map { String(format: "%02x", $0) }.joined()
      XCTAssertEqual(ApplicationPrivacyIdentity.digest(source), expected)
      XCTAssertEqual(ApplicationPrivacyIdentity.digest(source), ApplicationPrivacyIdentity.digest(source.lowercased()))
    }
  }
  func testSettingsRoundTripsKeepOpaqueIdentityForMaskedLabelsAndRemoveIt() throws {
    for source in identities {
      try store.saveSettings(StorageSettings(excludedApps: [source]), at: 10)
      try reopen()
      var settings = try store.settings()
      XCTAssertTrue(settings.excludesApplication(source))
      XCTAssertTrue(settings.excludesApplication(source.lowercased()))
      XCTAssertTrue(settings.excludesApplication(source.uppercased()))
      XCTAssertTrue(RecorderPolicy.excluded(FrontObservation(bundleID: source), settings: settings))
      settings.general["outputLanguage"] = "en"
      try store.saveSettings(settings, at: 11); try reopen()
      settings = try store.settings()
      XCTAssertTrue(settings.excludesApplication(source))
      let id = try XCTUnwrap(settings.excludedApps.first)
      settings = try SettingsViewModel(settings: settings, health: TimelineHealth(), ownBundleID: "invented.own", now: 12).applying(.removeApp(id))
      try store.saveSettings(settings, at: 12)
      XCTAssertFalse(try store.settings().excludesApplication(source))
    }
  }
  func testMemoryWriterRetryRefusesScreenObservationAndInputForEveryIdentity() throws {
    for (index, source) in identities.enumerated() {
      let time = 100 + index
      try store.saveSettings(StorageSettings(excludedApps: []), at: 0)
      var unavailable = true
      let pipeline = CollectionPipeline { if unavailable { throw StorageError("Invented writer outage") }; return self.store }
      offer(pipeline, source: source, at: time); pipeline.drain()
      XCTAssertGreaterThan(pipeline.takeDiagnostics().retainedBytes, 0)
      try store.saveSettings(StorageSettings(excludedApps: [source.lowercased()]), at: time+1)
      unavailable = false; pipeline.drain()
      try assertRefused(time)
      XCTAssertEqual(pipeline.takeDiagnostics().retainedBytes, 0)
    }
  }
  func testLegacyMaskedSettingsStillExcludeRawApplicationAtAcquisition() throws {
    let source = identities[2]
    let label = Redaction.applyKnownSecrets(source.lowercased()).text
    XCTAssertNotEqual(label, source.lowercased())
    try store.connection.run("INSERT INTO settings(key,value) VALUES('app.0',?)", [.maskedText(label)])
    try reopen()
    var settings = try store.settings()
    XCTAssertTrue(settings.excludedAppPrivacyIdentities.isEmpty)
    XCTAssertTrue(RecorderPolicy.excluded(FrontObservation(bundleID: source), settings: settings))
    settings.general["outputLanguage"] = "en"
    try store.saveSettings(settings, at: 10)
    XCTAssertTrue(try store.settings().excludesApplication(source))
  }
  func testReadyRestartRefusesScreenObservationAndInputForEveryIdentity() throws {
    for (index, source) in identities.enumerated() {
      let time = 200 + index
      try store.saveSettings(StorageSettings(excludedApps: []), at: 0)
      try store.connection.run("CREATE TRIGGER invented_observation_outage BEFORE INSERT ON sample_observations BEGIN SELECT RAISE(ABORT,'invented outage'); END")
      var pipeline: CollectionPipeline? = CollectionPipeline(writer: store)
      offer(pipeline!, source: source, at: time); pipeline!.drain()
      XCTAssertEqual(try store.collectionFiles().count, 2)
      for file in try store.collectionFiles() {
        let record = try XCTUnwrap(store.readReadyCollection(file))
        XCTAssertEqual(record.applicationPrivacyIdentity ?? record.observation?.applicationPrivacyIdentity, ApplicationPrivacyIdentity.digest(source))
        if source.contains("AKIA") { XCTAssertFalse(try Data(contentsOf: file).contains(Data(source.utf8))) }
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
      }
      pipeline = nil
      try store.saveSettings(StorageSettings(excludedApps: [source]), at: time+1)
      try store.connection.run("DROP TRIGGER invented_observation_outage")
      try reopen()
      pipeline = store.makeCollectionPipeline(); pipeline!.drain()
      try assertRefused(time)
      XCTAssertEqual(pipeline!.takeDiagnostics().persistenceFailures, 0)
      pipeline = nil
    }
  }
  func testDirectSQLAndCanonicalSamplePathsUseTheSamePrivacyIdentity() throws {
    for (index, source) in identities.enumerated() {
      let time = 300 + index
      try store.saveSettings(StorageSettings(excludedApps: [source.lowercased()]), at: 0)
      let screen = try store.appendScreenCapture(payload: ScreenTextPayload(text: "Invented OCR"), at: time,
        source: source, documentKey: "invented-document", project: "", probe: nil)
      XCTAssertEqual(screen.append.refused, 1)
      _ = try store.appendSamples([observe(source, at: time).sample])
      try assertRefused(time)
      XCTAssertTrue(try store.samples(in: TimeRange(time,time+1)).allSatisfy { $0.excluded && $0.window.isEmpty })
    }
  }
  func testAllowedIdentitiesKeepMaskedPresentationAndIndependentMatchingKeys() throws {
    let pipeline = store.makeCollectionPipeline()
    for (index, source) in identities.enumerated() { offer(pipeline, source: source, at: 400+index) }
    pipeline.drain()
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM screen_payloads"), 3)
    XCTAssertEqual(try store.observations(in: all).count, 3)
    XCTAssertEqual(try store.inputEvents(in: all).count, 3)
    XCTAssertEqual(try store.evidence(in: all).map(\.source), identities.map { Redaction.applyKnownSecrets($0).text })
    XCTAssertEqual(try store.observations(in: all).map(\.applicationPrivacyIdentity), identities.map { ApplicationPrivacyIdentity.digest($0) })
  }
  func testLegacyMaskedReadyWithoutIdentityIsExplicitlyPrivacyRefused() throws {
    var value = observe(identities[1], at: 500).redacted(); value.applicationPrivacyIdentity = nil
    let record = CollectionRecord(observation: value, time: 500,
      observationEvents: CompactInput.encode([InputObservation(kind: .move, timestamp: 500.1)]))
    try store.stageCollection(record)
    let pipeline = store.makeCollectionPipeline(); pipeline.drain()
    try assertRefused(500)
    XCTAssertTrue(try store.collectionStatus().contains("application_identity_unavailable="))
  }
  func testRealLoopRetainedSecretIdentityHonorsNewExclusion() throws {
    for (index, source) in identities.enumerated() {
      try store.saveSettings(StorageSettings(excludedApps: []), at: 0)
      var unavailable = true
      store.collectionWriterFactory = { if unavailable { throw StorageError("Invented writer outage") }; return self.store }
      let clock = FakeClock(); clock.now = 600+index
      let sources = FakeSources(); sources.clock = clock; sources.front.bundleID = source
      let loop = RecorderLoop(clock: clock, input: sources, front: sources, secure: sources, awake: sources,
        screen: sources, storage: store, maintenanceStorage: store, ownBundleID: "invented.own")
      loop.tick(); loop.flush()
      XCTAssertGreaterThan(loop.health.collectionRetainedBytes, 0)
      try store.saveSettings(StorageSettings(excludedApps: [source.lowercased()]), at: clock.now+1)
      unavailable = false; loop.stop()
      try assertRefused(clock.now)
      XCTAssertEqual(loop.health.droppedCaptures, 0)
      let done = expectation(description: "Owned recorder maintenance")
      loop.finishMaintenance { done.fulfill() }; wait(for: [done], timeout: 60)
      store.collectionWriterFactory = nil
    }
  }
  func query() -> ActivityQueries {
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return ActivityQueries(storage: store, calendar: calendar, ownBundleID: "invented.own", now: { 1000 })
  }
  func testQueryUsesStableIdentityToDistinguishNewRowsWithTheSameMaskedLabel() throws {
    let groups = [[identities[1], "invented.AKIAFEDCBA0987654321", identities[0]],
      [identities[2], "invented.ghp_abcdefghijklmnop1234567890", "invented.viewer"]]
    for (group, sources) in groups.enumerated() {
      XCTAssertEqual(Redaction.applyKnownSecrets(sources[0]).text, Redaction.applyKnownSecrets(sources[1]).text)
      for (index, source) in sources.enumerated() {
        let time = 60 + group*180 + index*60
        _ = try store.appendSamples([TimeSample(ts: time, bundleID: source, keys: 1)])
        _ = try store.appendIntervals([NamedInterval(range: TimeRange(time,time+60), name: "Invented row \(group) \(index)", kind: .work)])
      }
    }
    let before = try store.samples(in: all)
    try store.saveSettings(StorageSettings(excludedApps: groups.map { $0[0].lowercased() }), at: 500)
    let rows = try query().recentWork(in: TimeRange(60,420)).rows
    for group in groups.indices {
      XCTAssertNil(rows.first { $0.range.start == 60 + group*180 }?.name)
      XCTAssertEqual(rows.first { $0.range.start == 120 + group*180 }?.name, "Invented row \(group) 1")
      XCTAssertEqual(rows.first { $0.range.start == 180 + group*180 }?.name, "Invented row \(group) 2")
    }
    XCTAssertEqual(try store.samples(in: all), before)
  }
  func testHistoricalQueryHidesEveryOldMaskingOrderWithoutRewritingRows() throws {
    var time = 60
    for source in identities {
      let labels = [source.lowercased(), Redaction.applyKnownSecrets(source).text.lowercased(),
        Redaction.applyKnownSecrets(source.lowercased()).text]
      for label in labels {
        // Seed the actual old persisted spelling, including shapes a current
        // key binder would mask again. No rich observation identity exists.
        try store.connection.run("""
          INSERT INTO samples(ts,bundle_id,app,window,document_key,keys,clicks,scrolls,moved,synthetic,keeping_awake,excluded)
          VALUES(?,?,'Invented app','','',1,0,0,0,0,0,0)
          """, [.integer(time), .maskedText(label)])
        _ = try store.appendIntervals([NamedInterval(range: TimeRange(time,time+60), name: "Invented historical row", kind: .work)])
        time += 60
      }
    }
    let before = try store.samples(in: all)
    try store.saveSettings(StorageSettings(excludedApps: identities.map { $0.lowercased() }), at: 700)
    let rows = try query().recentWork(in: TimeRange(60,time)).rows
    XCTAssertFalse(rows.isEmpty); XCTAssertTrue(rows.allSatisfy { $0.name == nil && $0.description == nil && $0.project == nil })
    XCTAssertEqual(try query().timeTotals(in: TimeRange(60,time)).totalMinutes, 9)
    XCTAssertEqual(try store.samples(in: all), before)
    XCTAssertTrue(try store.observations(in: all).isEmpty)
  }
  func assertHidden(_ time: Int = 60, file: StaticString = #filePath, line: UInt = #line) throws {
    let rows = try query().recentWork(in: TimeRange(time,time+60)).rows
    XCTAssertFalse(rows.isEmpty, file: file, line: line)
    XCTAssertTrue(rows.allSatisfy { $0.name == nil && $0.description == nil && $0.project == nil }, file: file, line: line)
  }
  func seedInterval(_ time: Int = 60) throws {
    _ = try store.appendIntervals([NamedInterval(range: TimeRange(time,time+60), name: "Invented name",
      description: "Invented description", kind: .work, project: "Invented project")])
  }
  func testPublicAccountingIdentitySurvivesMissingLateRejectedAndCollidingObservations() throws {
    for (index, source) in identities.enumerated() {
      let time = 60 + index*120
      let other = index == 1 ? "invented.AKIAFEDCBA0987654321" : (index == 2 ? "invented.ghp_abcdefghijklmnop1234567890" : "invented.viewer")
      _ = try store.appendAccountingSamples([TimeSample(ts: time, bundleID: source, keys: 1)])
      try seedInterval(time)
      try store.saveSettings(StorageSettings(excludedApps: [source]), at: 900)
      try assertHidden(time)
      // B is independent, despite sharing a second and sometimes the entire masked label.
      _ = try store.appendObservations([observe(other, at: time)])
      try assertHidden(time)
      // A's own late observation is explicitly privacy-refused for metadata.
      _ = try store.appendObservations([observe(source, at: time)])
      XCTAssertTrue(try XCTUnwrap(store.observations(in: TimeRange(time,time+1)).last).sample.excluded)
      try assertHidden(time)
      // A rejected SQL write must not affect the canonical record's identity.
      try store.connection.run("CREATE TRIGGER invented_rejection BEFORE INSERT ON sample_observations BEGIN SELECT RAISE(ABORT,'invented rejection'); END")
      XCTAssertThrowsError(try store.appendObservations([observe(source, at: time)]))
      try store.connection.run("DROP TRIGGER invented_rejection")
      try assertHidden(time)
      let sample = try XCTUnwrap(store.samples(in: TimeRange(time,time+1)).first)
      XCTAssertEqual(sample.applicationPrivacyIdentity, ApplicationPrivacyIdentity.digest(source))
      // A genuinely permitted canonical B remains visible without any own observation.
      _ = try store.appendAccountingSamples([TimeSample(ts: time+60, bundleID: other, keys: 1)])
      try seedInterval(time+60)
      XCTAssertEqual(try query().recentWork(in: TimeRange(time+60,time+120)).rows.first?.name, "Invented name")
    }
  }
  func testHistoricalAccountingCannotBorrowACollidingObservationIdentity() throws {
    let source = identities[1], other = "invented.AKIAFEDCBA0987654321"
    try store.connection.run("INSERT INTO samples(ts,bundle_id,app,window,document_key,keys,clicks,scrolls,moved,synthetic,keeping_awake,excluded) VALUES(60,?,'','','',1,0,0,0,0,0,0)", [.key(source)])
    try seedInterval()
    let before = try store.samples(in: all)
    try store.saveSettings(StorageSettings(excludedApps: [source]), at: 100)
    try assertHidden()
    _ = try store.appendObservations([observe(other, at: 60)])
    try assertHidden()
    XCTAssertEqual(try store.samples(in: all), before)
    XCTAssertNil(before.first?.applicationPrivacyIdentity)
  }
  func testRealRecorderOverloadThenLateCollidingMetadataCannotUnhideAccounting() throws {
    var unavailable = true
    store.collectionWriterFactory = { if unavailable { throw StorageError("Invented writer outage") }; return self.store }
    let clock = FakeClock(); clock.now = 60
    let sources = FakeSources(); sources.clock = clock
    sources.front.window = nil
    sources.front.title = String(repeating: "Invented metadata ", count: 600_000)
    let loop = RecorderLoop(clock: clock, input: sources, front: sources, secure: sources, awake: sources,
      screen: sources, storage: store, maintenanceStorage: store, ownBundleID: "invented.own")
    loop.tick(); loop.flush()
    XCTAssertGreaterThan(loop.health.collectionRetainedBytes, CollectionPipeline.queueBytes + CollectionPipeline.overflowBytes)
    clock.now = 61; sources.front.bundleID = identities[1]; sources.front.title = "Invented A metadata"
    loop.tick(); loop.flush()
    XCTAssertEqual(loop.health.droppedObservations, 1)
    XCTAssertTrue(try store.observations(in: TimeRange(61,62)).isEmpty)
    try seedInterval()
    try store.saveSettings(StorageSettings(excludedApps: [identities[1]]), at: 62)
    unavailable = false; loop.flush()
    try assertHidden()
    var late = FrontObservation(bundleID: "invented.AKIAFEDCBA0987654321", title: "Invented B metadata", observedAt: 61.9)
    late.window = nil
    sources.completedDetails = [late]; sources.front = FrontObservation(bundleID: "invented.viewer")
    clock.now = 62; loop.tick(); loop.flush()
    XCTAssertEqual(try store.observations(in: TimeRange(61,62)).count, 1)
    try assertHidden()
    loop.stop()
    let done = expectation(description: "Owned recorder maintenance")
    loop.finishMaintenance { done.fulfill() }; wait(for: [done], timeout: 60)
    store.collectionWriterFactory = nil
    try reopen(); try assertHidden()
  }
  func testEveryIndependentCollectionRowRetainsItsOwnIdentity() throws {
    let source = identities[1], digest = ApplicationPrivacyIdentity.digest(source)
    _ = try store.appendSamples([observe(source, at: 60).sample])
    _ = try store.appendScreenCapture(payload: ScreenTextPayload(text: "Invented OCR", document: "Invented document"),
      at: 60, source: source, documentKey: "Invented document", project: "", probe: nil)
    for table in ["samples", "evidence", "input_batches"] {
      XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM \(table) WHERE application_identity=?", [.key(digest)]), 1)
    }
    // Its parent second is forgotten while metadata's own second remains permitted.
    var observation = observe(source, at: 70); observation.sample.observedAt = 80.2
    _ = try store.appendObservations([observation])
    let preview = try store.previewDeletion(in: TimeRange(70,71))
    _ = try store.deleteRecords(in: TimeRange(70,71), confirmation: preview.confirmation)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM collection_metadata WHERE application_identity=?", [.key(digest)]), 1)
  }
  func testScreenOccurrenceReplayCannotBorrowTheIncomingIdentity() throws {
    let source = identities[1], other = "invented.AKIAFEDCBA0987654321"
    let payload = ScreenTextPayload(text: "Invented OCR")
    _ = try store.storeScreenCapture(text: payload.text, at: 60, source: source, documentKey: "", project: "", knownKeys: [], probe: nil,
      payload: payload, occurrenceID: "invented-occurrence")
    try store.saveSettings(StorageSettings(excludedApps: [source]), at: 100)
    XCTAssertThrowsError(try store.storeScreenCapture(text: payload.text, at: 60, source: other, documentKey: "", project: "", knownKeys: [], probe: nil,
      payload: payload, occurrenceID: "invented-occurrence"))
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM evidence WHERE application_identity=?", [.key(ApplicationPrivacyIdentity.digest(source))]), 1)
  }
  func testInputIdentityIsProvedEvenWithoutAnObservationParent() throws {
    let source = identities[1], other = "invented.AKIAFEDCBA0987654321"
    var first = observe(source, at: 60); first.id = "invented-input-owner"
    let record = CollectionRecord(observation: first.redacted(), time: 60,
      observationEvents: CompactInput.encode(first.sample.inputEvents), eventsOnly: true)
    try store.connection.transaction {
      _ = try store.withCollectionAdmission(record) { try store.insertAdmittedObservation($0) }
    }
    XCTAssertTrue(try store.observations(in: all).isEmpty)
    var second = observe(other, at: 60); second.id = first.id
    let collision = CollectionRecord(observation: second.redacted(), time: 60,
      observationEvents: CompactInput.encode(second.sample.inputEvents), eventsOnly: true)
    XCTAssertThrowsError(try store.connection.transaction {
      _ = try store.withCollectionAdmission(collision) { try store.insertAdmittedObservation($0) }
    })
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM input_batches WHERE application_identity=?", [.key(ApplicationPrivacyIdentity.digest(source))]), 1)
  }
  func testUndeployedSchemaThirteenIsRefusedWithoutTouchingHistoricalBytes() throws {
    _ = try store.appendSamples([observe(identities[1], at: 60).sample])
    _ = try store.appendScreenCapture(payload: ScreenTextPayload(text: "Invented OCR"), at: 60,
      source: identities[1], documentKey: "", project: "", probe: nil)
    try seedInterval()
    try store.saveSettings(StorageSettings(excludedApps: [identities[1]]), at: 100)
    let tables = ["samples", "evidence", "input_batches", "collection_metadata", "sample_observations", "screen_payloads"]
    var before: [String: String] = [:]
    func snapshot(_ table: String, _ connection: SQLiteConnection) throws -> String {
      var columns: [String] = []
      try connection.namedRows("PRAGMA table_info(\(table))") { row in
        let name = try row.text("name")
        if name != "application_identity" { columns.append("quote(\(name))") }
      }
      var result = ""
      try connection.rows("SELECT \(columns.joined(separator: ",")) FROM \(table) ORDER BY rowid") { row in
        for index in columns.indices { result += SQLiteConnection.text(row, Int32(index)) + "|" }
        result += "\n"
      }
      return result
    }
    // Recreate the schema-13 boundary without any identity-dependent triggers.
    for table in ["samples", "evidence", "input_batches", "collection_metadata"] {
      try store.connection.run("DROP TRIGGER IF EXISTS ingestion_\(table)")
    }
    for table in tables {
      if ["samples", "evidence", "input_batches", "collection_metadata"].contains(table) {
        try store.connection.run("ALTER TABLE \(table) DROP COLUMN application_identity")
      }
      before[table] = try snapshot(table, store.connection)
      for action in ["INSERT", "UPDATE", "DELETE"] {
        try store.connection.run("CREATE TRIGGER invented_freeze_\(table)_\(action) BEFORE \(action) ON \(table) BEGIN SELECT RAISE(ABORT,'historical bytes immutable'); END")
      }
    }
    try store.connection.run("PRAGMA user_version=13")
    do {
      let reader = try ActivityStorage(url: store.url, appDataDirectory: folder, readOnly: true, databaseScope: .directory(folder))
      XCTAssertNil(try reader.samples(in: all).first?.applicationPrivacyIdentity)
      let answer = try ActivityQueries(storage: reader, ownBundleID: "invented.own", now: { 1000 }).recentWork(in: TimeRange(60,120))
      XCTAssertTrue(answer.rows.allSatisfy { $0.name == nil && $0.description == nil && $0.project == nil })
      XCTAssertFalse(answer.rows.isEmpty)
      XCTAssertFalse(try reader.collectionStatus().isEmpty)
      XCTAssertEqual(try reader.connection.integer("PRAGMA user_version"), 13)
    }
    for _ in 0..<2 {
      XCTAssertThrowsError(try ActivityStorage(url: store.url, appDataDirectory: folder, databaseScope: .directory(folder)))
      XCTAssertEqual(try store.connection.integer("PRAGMA user_version"), 13)
      for table in tables { XCTAssertEqual(try snapshot(table, store.connection), before[table]) }
      for table in ["samples", "evidence", "input_batches", "collection_metadata"] {
        XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM pragma_table_info('\(table)') WHERE name='application_identity'"), 0)
      }
    }
  }
  func testPresentationOnlyApplicationCannotBePromotedToANewIdentity() throws {
    let label = Redaction.applyKnownSecrets(identities[1]).text
    XCTAssertNil(ApplicationPrivacyIdentity.originalDigest(label))
    XCTAssertNil(ApplicationPrivacyIdentity.originalDigest(label.uppercased()))
    let observation = observe(label, at: 60)
    XCTAssertNil(observation.applicationPrivacyIdentity)
    _ = try store.appendAccountingSamples([observation.sample])
    try seedInterval()
    try store.saveSettings(StorageSettings(excludedApps: [identities[1]]), at: 100)
    _ = try store.appendObservations([observation])
    try assertHidden()
    XCTAssertNil(try store.samples(in: all).first?.applicationPrivacyIdentity)
    XCTAssertTrue(try XCTUnwrap(store.observations(in: all).first).sample.excluded)
  }
  func testCanonicalIdentityBytesParticipateInCommitAndRetainedAccounting() throws {
    _ = try store.appendAccountingSamples([TimeSample(ts: 60, bundleID: identities[1], keys: 1)])
    XCTAssertEqual(try store.connection.integer("SELECT sum(bytes) FROM collection_ingestion"), 64)
    let status = try store.collectionStatus()
    XCTAssertTrue(status.contains("sample_application_identities_rows=1 sample_application_identities_bytes=64"))
    XCTAssertTrue(status.contains("collection_total_bytes=64"))
    XCTAssertTrue(status.contains("collection_ingested_commit_24h_bytes=64"))
  }
  func testPrivacyVerdictsUseStableRawIDsAndConservativeHistoricalLabels() throws {
    let other = "invented.AKIAFEDCBA0987654321"
    try store.saveSettings(StorageSettings(excludedApps: identities), at: 0)
    let paths = AppPaths(userHome: folder.appendingPathComponent("person"), appData: folder, database: store.url,
      appBinary: folder.appendingPathComponent("invented-app"), queryHelper: folder.appendingPathComponent("invented-helper"))
    let labels = identities.flatMap { source in
      [source.lowercased(), Redaction.applyKnownSecrets(source).text.lowercased(), Redaction.applyKnownSecrets(source.lowercased()).text]
    }
    let input = (labels + [other, "invented.other"]).joined(separator: "\n") + "\n"
    let result = RetainedCommands.run(["privacy", "verdicts"], paths: paths, input: Data(input.utf8),
      applications: (identities + [other, "invented.other"]).map { CommandApplicationIdentity(bundleID: $0, names: []) })
    XCTAssertEqual(result.status, 0)
    XCTAssertEqual(result.output.components(separatedBy: "\n"), [String](repeating: "hidden app", count: 9) + ["open", "open"])
  }
}
