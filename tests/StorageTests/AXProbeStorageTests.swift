import Core
import Foundation
import XCTest
@testable import Storage

extension StorageTests {
  private func probeFixture() throws -> (ActivityStorage, AXProbeRun, AXProbePair) {
    let store = try ActivityStorage(url: url, appDataDirectory: folder, databaseScope: .directory(folder))
    let run = try store.enableAXProbe(at: 10000)
    let request = AXProbeRequest(run: run, attemptID: UUID().uuidString, time: 10001,
      window: WindowIdentity(processID: 10, windowID: 20), bundleID: "invented.editor", isBrowser: false)
    var ax = AXProbeResult(status: .completed)
    ax.text = "Invented AX password=inventedCredential"; ax.start = 100; ax.end = 100.2; ax.identity = "geometry_validated"
    let pair = AXProbePair(request: request, ax: ax, ocrStatus: "completed", ocr: "Invented OCR text",
      imageRequest: 100, imageReturn: 100.1, ocrCompletion: 101)
    return (store, run, pair)
  }
  func testObservedBrowserFlagPersistsWithoutCategoriesInContentAndCounterRows() throws {
    let (store, _, original) = try probeFixture()
    for status: AXProbeStatus in [.completed, .pending, .watchdog, .policyRefused, .overload_dropped] {
      for browser: Bool? in [true, false, nil] {
        var pair = original
        pair.attemptID = UUID().uuidString; pair.ax.status = status; pair.isBrowser = browser
        XCTAssertTrue(try store.appendAXProbe(pair, evidenceID: nil, at: pair.time))
        try store.connection.rows("SELECT payload FROM ax_probe_attempts WHERE attempt_id=?", [.key(pair.attemptID)]) { row in
          let data = Data(SQLiteConnection.text(row, 0).utf8)
          let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
          XCTAssertNil(json["category"])
          XCTAssertEqual(json["isBrowser"] as? Bool, browser)
          XCTAssertEqual(try JSONDecoder().decode(AXProbePair.self, from: data).isBrowser, browser)
        }
      }
    }
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM ax_probe_attempts"), 15)
  }
  func testPerAppUpgradePreservesLegacyPayloadBytesSchemaAndActiveRun() throws {
    let (store, run, original) = try probeFixture()
    XCTAssertTrue(try store.appendAXProbe(original, evidenceID: nil, at: original.time))
    try store.connection.run("UPDATE ax_probe_attempts SET payload=json_set(json_remove(payload,'$.isBrowser'),'$.category','invented_legacy_category')")
    var legacy = ""
    try store.connection.rows("SELECT payload FROM ax_probe_attempts") { legacy = SQLiteConnection.text($0, 0) }
    XCTAssertNil(try JSONDecoder().decode(AXProbePair.self, from: Data(legacy.utf8)).isBrowser)
    let reopened = try ActivityStorage(url: url, appDataDirectory: folder, databaseScope: .directory(folder))
    XCTAssertEqual(try reopened.connection.integer("PRAGMA user_version"), SQLiteConnection.schemaVersion)
    XCTAssertEqual(try reopened.settings().axProbeRun, run)
    var next = original; next.attemptID = UUID().uuidString; next.time += 15; next.isBrowser = true
    XCTAssertTrue(try reopened.appendAXProbe(next, evidenceID: nil, at: next.time))
    try reopened.connection.rows("SELECT payload FROM ax_probe_attempts WHERE attempt_id=?", [.key(original.attemptID)]) {
      XCTAssertEqual(SQLiteConnection.text($0, 0), legacy)
    }
    XCTAssertEqual(try reopened.connection.integer("SELECT count(*) FROM ax_probe_attempts"), 2)
    XCTAssertEqual(try reopened.connection.integer("SELECT json_extract(payload,'$.isBrowser') FROM ax_probe_attempts WHERE attempt_id=?", [.key(next.attemptID)]), 1)
  }
  func testVersionSevenMigrationPreservesLegacyRunAndAttemptBytes() throws {
    let (store, run, pair) = try probeFixture()
    XCTAssertTrue(try store.appendAXProbe(pair, evidenceID: nil, at: pair.time))
    var before = ""
    try store.connection.rows("SELECT payload FROM ax_probe_attempts") { before = SQLiteConnection.text($0, 0) }
    try store.connection.run("UPDATE ax_probe_runs SET expiry_ts=96400,manifest='invented legacy manifest'")
    try store.connection.run("ALTER TABLE ax_probe_runs DROP COLUMN probe_version")
    try store.connection.run("PRAGMA user_version=7")
    let upgraded = try ActivityStorage(url: url, appDataDirectory: folder, databaseScope: .directory(folder))
    XCTAssertEqual(try upgraded.connection.integer("PRAGMA user_version"), SQLiteConnection.schemaVersion)
    XCTAssertEqual(try upgraded.connection.integer("SELECT probe_version FROM ax_probe_runs WHERE id=?", [.key(run.id)]), 1)
    XCTAssertEqual(try upgraded.connection.integer("SELECT expiry_ts FROM ax_probe_runs"), 96400)
    try upgraded.connection.rows("SELECT payload FROM ax_probe_attempts") { XCTAssertEqual(SQLiteConnection.text($0, 0), before) }
    try upgraded.connection.rows("SELECT manifest FROM ax_probe_runs") { XCTAssertEqual(SQLiteConnection.text($0, 0), "invented legacy manifest") }
  }
  func testPerNodeMaskingPersistenceAndBothForgetScopes() throws {
    for runScope in [true, false] {
      let (store, run, original) = try probeFixture()
      var pair = original
      pair.ax.nodes = [AXProbeNode(nodeID: 7, role: "AXTextField", depth: 3, pid: 99,
        bundleID: "invented.foreign", insideWindow: false, onScreen: false, hiddenBranch: true,
        nonSelectedTab: true, secure: false,
        attributes: [AXProbeText(attribute: "AXValue", text: "password=inventedNodeCredential")])]
      pair.ax.nodes?[0].readSeconds = 0.004
      pair.ocr_refusal_reason = .key_changed
      pair.ax.manualAccessibility = "set"; pair.ax.truncations = ["depthLimit": 1]
      XCTAssertTrue(try store.appendAXProbe(pair, evidenceID: nil, at: pair.time))
      try store.connection.rows("SELECT payload FROM ax_probe_attempts") { row in
        let payload = SQLiteConnection.text(row, 0)
        XCTAssertFalse(payload.contains("inventedNodeCredential"))
        let saved = try JSONDecoder().decode(AXProbePair.self, from: Data(payload.utf8))
        var nodePayload = ""
        try store.connection.rows("SELECT c.text FROM ax_probe_parts p JOIN ax_probe_chunks c ON c.hash=p.hash ORDER BY p.ordinal,c.ordinal") { nodePayload += SQLiteConnection.text($0, 0) }
        let nodes = try JSONSerialization.jsonObject(with: Data(nodePayload.utf8)) as! [[String: Any]]
        XCTAssertEqual(nodes.first?["pid"] as? Int, 99)
        XCTAssertNil(nodes.first?["readSeconds"])
        XCTAssertEqual(saved.ax.nodeReadMicroseconds, [4000])
        XCTAssertEqual(saved.ax.nodeReadCount, 1)
        XCTAssertEqual(saved.ocr_refusal_reason, .key_changed)
        let attributes = nodes.first?["attributes"] as! [[String: Any]]
        XCTAssertEqual((attributes.first?["maskHits"] as? [String: Int])?["secret"], 1)
        let hash = attributes.first?["textRef"] as! String
        try store.connection.rows("SELECT text FROM ax_probe_chunks WHERE hash=?", [.key(hash)]) { XCTAssertEqual(SQLiteConnection.text($0, 0), "[secret]") }
        XCTAssertEqual(saved.ax.manualAccessibility, "set")
      }
      if runScope {
        let preview = try store.previewAXProbeDeletion(run: run.id)
        _ = try store.deleteAXProbe(run: run.id, confirmation: preview.confirmation)
      } else {
        let preview = try store.previewDeletion(in: TimeRange(10000, 10002))
        _ = try store.deleteRecords(in: preview.range, confirmation: preview.confirmation)
        let previewRun = try store.previewAXProbeDeletion(run: run.id)
        _ = try store.deleteAXProbe(run: run.id, confirmation: previewRun.confirmation)
      }
      XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM ax_probe_attempts"), 0)
    }
  }
  func testMissingBundleIDDoesNotAddAProbeOnlyCaptureGate() throws {
    let (store, run, original) = try probeFixture()
    var pair = original; pair.bundleID = ""
    let request = AXProbeRequest(run: run, time: pair.time, window: WindowIdentity(processID: 10, windowID: 20),
      bundleID: "", isBrowser: false)
    XCTAssertTrue(try store.axProbeAllowed(request, at: pair.time))
    XCTAssertNil(try store.beginAXProbe(request, at: pair.time))
    store.finishAXProbe(request, result: AXProbeResult(status: .empty), at: pair.time)
    XCTAssertTrue(try store.appendAXProbe(pair, evidenceID: nil, at: pair.time))
  }
  func testProbeVersionFiveMigrationPreservesOrdinaryRowsAndQueryExports() throws {
    var old: ActivityStorage? = try ActivityStorage(url: url, appDataDirectory: folder, databaseScope: .directory(folder))
    try old!.appendSamples([TimeSample(ts: 10020, app: "Invented history", keys: 1)])
    _ = try old!.appendScreenCapture(text: "Invented ordinary OCR", at: 10020, source: "invented.editor", knownKeys: [])
    try old!.appendIntervals([NamedInterval(range: TimeRange(10020, 10080), name: "Invented history", kind: .work)])
    try old!.appendModelCall(ModelCall(ts: 10080, range: TimeRange(10020, 10080), model: "invented", succeeded: true))
    try old!.saveSettings(StorageSettings(excludedApps: [], general: ["dayStartHour": "4"]))
    let samples = try old!.samples(in: all), evidence = try old!.evidence(in: all)
    let intervals = try old!.intervals(in: all), calls = try old!.modelCalls(in: all), settings = try old!.settings()
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let before = try JSONEncoder().encode(ActivityQueries(storage: old!, calendar: calendar, now: { 11000 }).daySummary(containing: 10020))
    let tables = ["ax_probe_runs", "ax_probe_attempts", "ax_probe_pid", "ax_probe_flow", "ax_probe_review", "ax_probe_review_state"]
    let triggers = ["ax_probe_evidence_delete", "ax_probe_attempt_delete", "ax_probe_review_no_enable", "ax_probe_review_immutable"]
    for trigger in triggers { try old!.connection.run("DROP TRIGGER \(trigger)") }
    for table in tables { try old!.connection.run("DROP TABLE \(table)") }
    try old!.connection.run("PRAGMA user_version=5")
    old = nil
    for _ in 0..<2 {
      let store = try ActivityStorage(url: url, appDataDirectory: folder, databaseScope: .directory(folder))
      XCTAssertEqual(try store.connection.integer("PRAGMA user_version"), SQLiteConnection.schemaVersion)
      for table in tables { XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM \(table)"), 0) }
      XCTAssertEqual(try store.samples(in: all), samples); XCTAssertEqual(try store.evidence(in: all), evidence)
      XCTAssertEqual(try store.intervals(in: all), intervals); XCTAssertEqual(try store.modelCalls(in: all), calls)
      XCTAssertEqual(try store.settings(), settings)
      let after = try JSONEncoder().encode(ActivityQueries(storage: store, calendar: calendar, now: { 11000 }).daySummary(containing: 10020))
      XCTAssertEqual(try JSONSerialization.jsonObject(with: before) as? NSDictionary, try JSONSerialization.jsonObject(with: after) as? NSDictionary)
    }
    let store = try ActivityStorage(url: url, appDataDirectory: folder, databaseScope: .directory(folder))
    let run = try store.enableAXProbe(at: 10000)
    let evidenceID = try store.connection.integer("SELECT id FROM evidence LIMIT 1")
    let request = AXProbeRequest(run: run, time: 10020, window: WindowIdentity(processID: 10, windowID: 20), bundleID: "invented.editor", isBrowser: false)
    var pair = AXProbePair(request: request, ax: AXProbeResult(), ocrStatus: "empty", ocr: "", imageRequest: nil, imageReturn: nil, ocrCompletion: 0)
    XCTAssertTrue(try store.appendAXProbe(pair, evidenceID: nil, at: 10020))
    pair.attemptID = UUID().uuidString
    XCTAssertTrue(try store.appendAXProbe(pair, evidenceID: evidenceID, at: 10020))
    let linked = try store.connection.integer("SELECT id FROM ax_probe_attempts WHERE evidence_id IS NOT NULL")
    try store.connection.run("INSERT INTO ax_probe_review(run_id,attempt_row,ordinal,ax_left) VALUES(?,?,0,1)", [.key(run.id), .integer(linked)])
    try store.connection.run("DELETE FROM evidence WHERE id=?", [.integer(evidenceID)])
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM ax_probe_attempts WHERE evidence_id IS NULL"), 1)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM ax_probe_review"), 0)
  }

  func testProbeVersionSixLegacyReviewTriggerUpgradesOnlyOnce() throws {
    let original = try ActivityStorage(url: url, appDataDirectory: folder, databaseScope: .directory(folder))
    try original.connection.run("DROP TRIGGER ax_probe_review_no_enable")
    try original.connection.run("""
      CREATE TRIGGER ax_probe_review_no_enable BEFORE INSERT ON settings
      WHEN NEW.key='general.axProbe.enabled' AND NEW.value='1'
        AND EXISTS(SELECT 1 FROM ax_probe_review_state WHERE active=1)
      BEGIN SELECT RAISE(ABORT,'Close probe review first'); END
      """)
    let upgraded = try ActivityStorage(url: url, appDataDirectory: folder, databaseScope: .directory(folder))
    XCTAssertEqual(try upgraded.connection.integer("SELECT count(*) FROM sqlite_master WHERE name='ax_probe_review_no_enable' AND instr(sql,'general.axProbe.reviewLease')>0"), 1)
    try upgraded.connection.transaction {
      let reopened = try ActivityStorage(url: url, appDataDirectory: folder, busyMilliseconds: 50, databaseScope: .directory(folder))
      XCTAssertEqual(try reopened.connection.integer("PRAGMA user_version"), SQLiteConnection.schemaVersion)
    }
  }

  func testProbeIPCLimitAndCancellationNeverAddPIDCooldownOrFailure() throws {
    let (store, run, pair) = try probeFixture()
    let request = AXProbeRequest(run: run, time: pair.time, window: WindowIdentity(processID: 10, windowID: 20), bundleID: "invented.editor", isBrowser: false)
    for status in [AXProbeStatus.ipcLimit, .cancelled, .ipcLimit, .cancelled] {
      XCTAssertNil(try store.beginAXProbe(request, at: pair.time))
      store.finishAXProbe(request, result: AXProbeResult(status: status), at: pair.time)
    }
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM ax_probe_pid"), 0)
  }

  func testProbeStableLinkageEmptyFailureAndNoNewLines() throws {
    let (store, _, original) = try probeFixture()
    let evidence = try store.appendScreenCapture(text: original.ocr, at: original.time,
      source: "invented.editor", knownKeys: [])
    XCTAssertNotNil(evidence.evidenceID)
    XCTAssertTrue(try store.appendAXProbe(original, evidenceID: evidence.evidenceID, at: original.time))
    XCTAssertFalse(try store.appendAXProbe(original, evidenceID: evidence.evidenceID, at: original.time))
    let repeated = try store.appendScreenCapture(text: original.ocr, at: original.time + 1,
      source: "invented.editor", knownKeys: evidence.addedKeys)
    XCTAssertNotNil(repeated.evidenceID)
    for status in ["empty", "failed"] {
      var pair = original; pair.attemptID = UUID().uuidString; pair.ocr = ""; pair.ocrStatus = status
      XCTAssertTrue(try store.appendAXProbe(pair, evidenceID: nil, at: original.time))
    }
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM ax_probe_attempts"), 3)
    var payload = ""
    try store.connection.namedRows("SELECT payload FROM ax_probe_attempts LIMIT 1") { payload = try $0.text("payload") }
    XCTAssertFalse(payload.contains("inventedCredential"))
    XCTAssertFalse(payload.contains("invented.editor"))
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM ax_probe_chunks WHERE instr(text,'[secret]')>0"), 1)
    XCTAssertEqual(try store.evidence(in: all).count, 2)
  }
  func testProbeNormalForgetCoversUnlinkedRowsAndRejectsInflightResurrection() throws {
    let (store, _, pair) = try probeFixture()
    XCTAssertTrue(try store.appendAXProbe(pair, evidenceID: nil, at: pair.time))
    var preview = try store.previewDeletion(in: TimeRange(10000, 10002))
    XCTAssertEqual(preview.counts["ax_probe_attempts"], 1)
    var later = pair; later.attemptID = UUID().uuidString
    XCTAssertTrue(try store.appendAXProbe(later, evidenceID: nil, at: pair.time))
    XCTAssertThrowsError(try store.deleteRecords(in: preview.range, confirmation: preview.confirmation))
    preview = try store.previewDeletion(in: preview.range)
    _ = try store.deleteRecords(in: preview.range, confirmation: preview.confirmation)
    XCTAssertFalse(try store.appendAXProbe(later, evidenceID: nil, at: pair.time))
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM ax_probe_attempts"), 0)
  }
  func testProbeOnlyPreviewContentHashAndTombstonePreserveOrdinaryHistory() throws {
    let (store, run, pair) = try probeFixture()
    try store.appendSamples([TimeSample(ts: pair.time, keys: 1)])
    let evidence = try store.appendScreenCapture(text: pair.ocr, at: pair.time, source: "invented.editor", knownKeys: [])
    XCTAssertTrue(try store.appendAXProbe(pair, evidenceID: evidence.evidenceID, at: pair.time))
    let stale = try store.previewAXProbeDeletion(run: run.id)
    try store.connection.run("UPDATE ax_probe_attempts SET payload=payload||' '")
    XCTAssertThrowsError(try store.deleteAXProbe(run: run.id, confirmation: stale.confirmation))
    let preview = try store.previewAXProbeDeletion(run: run.id)
    _ = try store.deleteAXProbe(run: run.id, confirmation: preview.confirmation)
    XCTAssertEqual(try store.samples(in: all).count, 1)
    XCTAssertEqual(try store.evidence(in: all).count, 1)
    XCTAssertTrue(try store.forgottenRanges(in: all).isEmpty)
    XCTAssertFalse(try store.appendAXProbe(pair, evidenceID: evidence.evidenceID, at: pair.time))
    XCTAssertEqual(try store.appendSamples([TimeSample(ts: pair.time + 1, keys: 1)]).stored, 1)
  }
  func testProbeLinkedUnlinkedRetentionAndActiveReviewBarrier() throws {
    let (store, run, pair) = try probeFixture()
    var settings = try store.settings(); settings.screenRetentionDays = 1; try store.saveSettings(settings)
    let evidence = try store.appendScreenCapture(text: pair.ocr, at: pair.time, source: "invented.editor", knownKeys: [])
    XCTAssertTrue(try store.appendAXProbe(pair, evidenceID: evidence.evidenceID, at: pair.time))
    var unlinked = pair; unlinked.attemptID = UUID().uuidString
    XCTAssertTrue(try store.appendAXProbe(unlinked, evidenceID: nil, at: pair.time))
    try store.connection.run("INSERT INTO ax_probe_review_state(run_id,active) VALUES(?,1)", [.key(run.id)])
    let wall = Date().timeIntervalSince1970, continuous = AXProbeReviewLease.continuous()
    let lease: [String: Any] = ["boot": AXProbeReviewLease.bootID(), "sessionStart": continuous, "issued": continuous,
      "deadline": continuous + 10, "issuedWall": wall, "deadlineWall": wall + 10]
    try store.connection.run("INSERT INTO settings(key,value) VALUES('general.axProbe.reviewActive','1')")
    try store.connection.run("INSERT INTO settings(key,value) VALUES('general.axProbe.reviewLease',?)",
      [.key(String(decoding: try JSONSerialization.data(withJSONObject: lease), as: UTF8.self))])
    let restarted = try ActivityStorage(url: url, appDataDirectory: folder, databaseScope: .directory(folder))
    XCTAssertFalse(RecorderPolicy.recording(try restarted.settings(), at: Int(wall)))
    let preview = try store.previewDeletion(in: TimeRange(10000, 10002))
    XCTAssertThrowsError(try store.deleteRecords(in: preview.range, confirmation: preview.confirmation))
    XCTAssertThrowsError(try store.cleanRetention(at: pair.time + 86401))
    var expired = lease
    expired["sessionStart"] = continuous - 11; expired["issued"] = continuous - 11; expired["deadline"] = continuous - 1
    try store.connection.run("UPDATE settings SET value=? WHERE key='general.axProbe.reviewLease'",
      [.key(String(decoding: try JSONSerialization.data(withJSONObject: expired), as: UTF8.self))])
    let afterExpiry = try ActivityStorage(url: url, appDataDirectory: folder, databaseScope: .directory(folder))
    XCTAssertTrue(RecorderPolicy.recording(try afterExpiry.settings(), at: Int(wall)))
    try store.connection.run("UPDATE ax_probe_review_state SET active=0")
    try store.connection.run("DELETE FROM settings WHERE key='general.axProbe.reviewLease'")
    _ = try store.cleanRetention(at: pair.time + 86401)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM ax_probe_attempts"), 0)
    XCTAssertFalse(try store.appendAXProbe(unlinked, evidenceID: nil, at: pair.time + 86401))
  }
  func testProbeOffExclusionPauseRecordingOffAndIndefiniteRestart() throws {
    let (store, _, pair) = try probeFixture()
    var settings = try store.settings()
    settings.excludedApps.append("invented.editor"); try store.saveSettings(settings)
    XCTAssertFalse(try store.appendAXProbe(pair, evidenceID: nil, at: pair.time))
    settings.excludedApps.removeAll { $0 == "invented.editor" }; settings.pausedUntil = 11000
    try store.saveSettings(settings)
    XCTAssertFalse(try store.appendAXProbe(pair, evidenceID: nil, at: pair.time))
    settings.pausedUntil = nil; try store.saveSettings(settings)
    XCTAssertTrue(try store.appendAXProbe(pair, evidenceID: nil, at: pair.time))
    let restarted = try ActivityStorage(url: url, appDataDirectory: folder, databaseScope: .directory(folder))
    var other = pair; other.attemptID = UUID().uuidString
    var paused = try restarted.settings(); paused.recordingEnabled = false; try restarted.saveSettings(paused)
    XCTAssertFalse(try restarted.appendAXProbe(other, evidenceID: nil, at: 10000))
    paused.recordingEnabled = true; try restarted.saveSettings(paused)
    other.time = 96400
    XCTAssertTrue(try restarted.appendAXProbe(other, evidenceID: nil, at: 96400))
    try store.disableAXProbe()
    XCTAssertFalse(try store.appendAXProbe(other, evidenceID: nil, at: pair.time))
  }
  func testProbeFinishedWorkerAfterBusyFinishDoesNotCancelRun() throws {
    let (store, run, original) = try probeFixture()
    try store.connection.run("PRAGMA busy_timeout=0")
    let writer = try ActivityStorage(url: url, appDataDirectory: folder, databaseScope: .directory(folder))
    // Two prior deadline rows, then a finished attempt whose lease-clear write is busy.
    for index in 0..<2 {
      let request = AXProbeRequest(run: run, time: original.time + index,
        window: WindowIdentity(processID: Int32(10 + index), windowID: 20), bundleID: "invented.editor", isBrowser: false)
      XCTAssertNil(try store.beginAXProbe(request, at: request.time))
      store.finishAXProbe(request, result: AXProbeResult(status: .deadline), at: request.time)
      var pair = original; pair.attemptID = request.attemptID; pair.time = request.time; pair.ax = AXProbeResult(status: .deadline)
      XCTAssertTrue(try store.appendAXProbe(pair, evidenceID: nil, at: request.time))
    }
    let request = AXProbeRequest(run: run, time: original.time + 2,
      window: WindowIdentity(processID: 12, windowID: 20), bundleID: "invented.editor", isBrowser: false)
    var pending = original; pending.attemptID = request.attemptID; pending.time = request.time; pending.ax = AXProbeResult(status: .pending)
    XCTAssertTrue(try store.appendAXProbe(pending, evidenceID: nil, at: request.time))
    XCTAssertNil(try store.beginAXProbe(request, at: request.time))
    try writer.connection.transaction {
      // The callback returns while the database writer still holds its lock.
      store.finishAXProbe(request, result: AXProbeResult(status: .cancelled), at: request.time)
    }
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM ax_probe_runs WHERE active_attempt!=''"), 1)
    var next = pending; next.attemptID = UUID().uuidString; next.time += 1
    XCTAssertTrue(try store.appendAXProbe(next, evidenceID: nil, at: next.time))
    let nextRequest = AXProbeRequest(run: run, attemptID: next.attemptID, time: next.time,
      window: WindowIdentity(processID: 13, windowID: 20), bundleID: "invented.editor", isBrowser: false)
    XCTAssertNil(try store.beginAXProbe(nextRequest, at: next.time))
    XCTAssertEqual(try store.connection.integer("SELECT total FROM ax_probe_flow WHERE event='finishStorageFailures'"), 1)
    XCTAssertEqual(try store.connection.integer("SELECT total FROM ax_probe_flow WHERE event='recoveredWorkerLease'"), 1)
    XCTAssertEqual(try store.connection.integer("SELECT cancelled FROM ax_probe_runs"), 0)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM ax_probe_attempts WHERE json_extract(payload,'$.ax.status')='deadline'"), 2)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM ax_probe_attempts WHERE json_extract(payload,'$.ax.status')='policyRefused'"), 0)
  }

  func testProbeThrowingFinishRetriesAtomicallyAndCountsEveryFailure() throws {
    let (store, run, pair) = try probeFixture()
    let request = AXProbeRequest(run: run, time: pair.time,
      window: WindowIdentity(processID: 10, windowID: 20), bundleID: "invented.editor", isBrowser: false)
    XCTAssertNil(try store.beginAXProbe(request, at: request.time))
    try store.connection.run("""
      CREATE TRIGGER invented_finish_failure BEFORE UPDATE OF active_attempt ON ax_probe_runs
      WHEN NEW.active_attempt='' BEGIN SELECT RAISE(ABORT,'invented failure'); END
      """)
    var result = AXProbeResult(status: .deadline); result.text = "Invented text never retained for retry"
    store.finishAXProbe(request, result: result, at: request.time)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM ax_probe_pid"), 0)
    XCTAssertEqual(store.axProbeFinishes.count, 1)
    XCTAssertEqual(store.axProbeFinishes.values.first?.watchdog, "")
    let next = AXProbeRequest(run: run, time: pair.time + 61,
      window: WindowIdentity(processID: 11, windowID: 20), bundleID: "invented.editor", isBrowser: false)
    XCTAssertThrowsError(try store.beginAXProbe(next, at: next.time))
    // A refused begin's callback must not create a second recovery receipt.
    store.finishAXProbe(next, result: AXProbeResult(status: .cancelled), at: next.time)
    XCTAssertEqual(store.axProbeFinishes.count, 1)
    XCTAssertEqual(try store.connection.integer("SELECT cancelled FROM ax_probe_runs"), 0)
    try store.connection.run("DROP TRIGGER invented_finish_failure")
    XCTAssertNil(try store.beginAXProbe(next, at: next.time))
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM ax_probe_pid"), 0)
    XCTAssertEqual(try store.connection.integer("SELECT total FROM ax_probe_flow WHERE event='finishStorageFailures'"), 2)
    XCTAssertEqual(try store.connection.integer("SELECT total FROM ax_probe_flow WHERE event='recoveredWorkerLease'"), 1)
    XCTAssertTrue(store.axProbeFinishes.isEmpty)
    store.finishAXProbe(next, result: AXProbeResult(status: .empty), at: next.time)
  }

  func testProbeStillRunningWorkerWithoutEndReceiptCancelsSameInstance() throws {
    let (store, run, pair) = try probeFixture()
    let request = AXProbeRequest(run: run, time: pair.time,
      window: WindowIdentity(processID: 10, windowID: 20), bundleID: "invented.editor", isBrowser: false)
    XCTAssertNil(try store.beginAXProbe(request, at: request.time))
    let unrelated = AXProbeRequest(run: run, time: pair.time + 1,
      window: WindowIdentity(processID: 11, windowID: 20), bundleID: "invented.editor", isBrowser: false)
    store.finishAXProbe(unrelated, result: AXProbeResult(status: .cancelled), at: unrelated.time)
    XCTAssertEqual(try store.beginAXProbe(unrelated, at: unrelated.time), .cancelled)
    XCTAssertEqual(try store.connection.integer("SELECT cancel_ts FROM ax_probe_runs WHERE reason='unfinished_worker'"), unrelated.time)
    store.finishAXProbe(request, result: AXProbeResult(status: .watchdog), at: unrelated.time + 1)
    XCTAssertEqual(try store.connection.integer("SELECT cancel_ts FROM ax_probe_runs WHERE reason='unfinished_worker'"), unrelated.time)
  }

  func testProbeRestartCannotUseOtherInstancesFailedFinishReceipt() throws {
    let (store, run, pair) = try probeFixture()
    let request = AXProbeRequest(run: run, time: pair.time,
      window: WindowIdentity(processID: 10, windowID: 20), bundleID: "invented.editor", isBrowser: false)
    XCTAssertNil(try store.beginAXProbe(request, at: request.time))
    try store.connection.run("""
      CREATE TRIGGER invented_finish_failure BEFORE UPDATE OF active_attempt ON ax_probe_runs
      WHEN NEW.active_attempt='' BEGIN SELECT RAISE(ABORT,'invented failure'); END
      """)
    store.finishAXProbe(request, result: AXProbeResult(status: .empty), at: request.time)
    try store.connection.run("DROP TRIGGER invented_finish_failure")
    let restarted = try ActivityStorage(url: url, appDataDirectory: folder, databaseScope: .directory(folder))
    XCTAssertEqual(try restarted.beginAXProbe(request, at: request.time + 1), .cancelled)
    XCTAssertTrue(try restarted.axProbeStatus().contains("ax_probe_reason=unfinished_worker ax_probe_cancelled_at=10002"))
  }

  func testProbeBusyWatchdogFinishRetriesCancellationWithoutClearingLease() throws {
    let (store, run, pair) = try probeFixture()
    try store.connection.run("PRAGMA busy_timeout=0")
    let writer = try ActivityStorage(url: url, appDataDirectory: folder, databaseScope: .directory(folder))
    let request = AXProbeRequest(run: run, time: pair.time,
      window: WindowIdentity(processID: 10, windowID: 20), bundleID: "invented.editor", isBrowser: false)
    XCTAssertNil(try store.beginAXProbe(request, at: request.time))
    try writer.connection.transaction {
      store.finishAXProbe(request, result: AXProbeResult(status: .watchdog), at: request.time)
    }
    XCTAssertEqual(try store.beginAXProbe(request, at: request.time + 1), .cancelled)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM ax_probe_runs WHERE active_attempt!='' AND reason='watchdog' AND cancel_ts=10001"), 1)
    XCTAssertEqual(try store.connection.integer("SELECT total FROM ax_probe_flow WHERE event='watchdog'"), 1)
    XCTAssertEqual(try store.connection.integer("SELECT total FROM ax_probe_flow WHERE event='finishStorageFailures'"), 1)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM ax_probe_flow WHERE event='recoveredWorkerLease'"), 0)
  }

  func testProbeMalformedWatchdogDiagnosticsStillPersistCancellation() throws {
    let (store, run, pair) = try probeFixture()
    let request = AXProbeRequest(run: run, time: pair.time,
      window: WindowIdentity(processID: 10, windowID: 20), bundleID: "invented.editor", isBrowser: false)
    XCTAssertNil(try store.beginAXProbe(request, at: request.time))
    var watchdog = AXProbeResult(status: .watchdog); watchdog.start = .nan
    store.finishAXProbe(request, result: watchdog, at: request.time)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM ax_probe_runs WHERE reason='watchdog' AND cancel_ts=10001"), 1)
    XCTAssertEqual(try store.connection.integer("SELECT total FROM ax_probe_flow WHERE event='finishStorageFailures'"), 1)
  }

  func testProbeVersionSixCancellationMigrationPreservesUnknownStopTime() throws {
    let (store, _, _) = try probeFixture()
    try store.disableAXProbe(at: 10005)
    try store.connection.run("ALTER TABLE ax_probe_runs DROP COLUMN cancel_ts")
    try store.connection.run("PRAGMA user_version=6")
    let upgraded = try ActivityStorage(url: url, appDataDirectory: folder, databaseScope: .directory(folder))
    XCTAssertEqual(try upgraded.connection.integer("PRAGMA user_version"), SQLiteConnection.schemaVersion)
    XCTAssertTrue(try upgraded.axProbeStatus().contains("ax_probe_reason=off ax_probe_cancelled_at=unknown"))
    try upgraded.connection.transaction {
      _ = try ActivityStorage(url: url, appDataDirectory: folder, busyMilliseconds: 0, databaseScope: .directory(folder))
    }
  }

  func testProbeUnfinishedWorkerLeaseAndWatchdogPersistAcrossRestart() throws {
    let (store, run, pair) = try probeFixture()
    let request = AXProbeRequest(run: run, attemptID: pair.attemptID, time: pair.time,
      window: WindowIdentity(processID: 10, windowID: 20), bundleID: "invented.editor", isBrowser: false)
    XCTAssertNil(try store.beginAXProbe(request, at: pair.time))
    let restarted = try ActivityStorage(url: url, appDataDirectory: folder, databaseScope: .directory(folder))
    XCTAssertEqual(try restarted.beginAXProbe(request, at: pair.time), .cancelled)
    XCTAssertFalse(try restarted.appendAXProbe(pair, evidenceID: nil, at: pair.time))
    store.finishAXProbe(request, result: AXProbeResult(status: .watchdog))
    XCTAssertEqual(try store.connection.integer("SELECT total FROM ax_probe_flow WHERE event='watchdog'"), 1)
    XCTAssertFalse(try store.axProbeAllowed(request, at: pair.time))
  }
  func testProbeStaleSettingsSnapshotCannotReenableOrRewriteRun() throws {
    let (store, run, _) = try probeFixture()
    var snapshot = try store.settings()
    try store.disableAXProbe()
    snapshot.general["axProbe.enabled"] = "1"
    try store.saveSettings(snapshot)
    XCTAssertNil(try store.settings().axProbeRun)
    XCTAssertEqual(try store.connection.integer("SELECT cancelled FROM ax_probe_runs WHERE id=?", [.key(run.id)]), 1)
  }

  func testProbeEvidenceCascadeAndSealedJudgmentDeletion() throws {
    let (store, run, pair) = try probeFixture()
    let evidence = try store.appendScreenCapture(text: pair.ocr, at: pair.time, source: "invented.editor", knownKeys: [])
    XCTAssertTrue(try store.appendAXProbe(pair, evidenceID: evidence.evidenceID, at: pair.time))
    let attempt = try store.connection.integer("SELECT id FROM ax_probe_attempts")
    try store.connection.run("INSERT INTO ax_probe_review_state(run_id,sealed,sample_count) VALUES(?,1,1)", [.key(run.id)])
    try store.connection.run("INSERT INTO ax_probe_review(run_id,attempt_row,ordinal,ax_left,choice) VALUES(?,?,0,1,0)", [.key(run.id), .integer(attempt)])
    XCTAssertThrowsError(try store.connection.run("UPDATE ax_probe_review SET choice=1"))
    try store.connection.run("DELETE FROM evidence WHERE id=?", [.integer(evidence.evidenceID!)])
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM ax_probe_attempts"), 0)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM ax_probe_review"), 0)
    XCTAssertEqual(try store.connection.integer("SELECT sample_count FROM ax_probe_review_state"), 1)
  }

  func testLegacyDeadlinePIDStateResetsOnceAndNewPolicyStreaksSurviveRestart() throws {
    let (initial, run, pair) = try probeFixture()
    XCTAssertTrue(try initial.appendAXProbe(pair, evidenceID: nil, at: pair.time))
    var payload = ""
    try initial.connection.rows("SELECT payload FROM ax_probe_attempts") { payload = SQLiteConnection.text($0, 0) }
    try initial.connection.run("ALTER TABLE ax_probe_pid DROP COLUMN failure_policy")
    for failures in 1...3 {
      for future in [false, true] {
        let pid = failures * 10 + (future ? 1 : 0)
        try initial.connection.run("INSERT INTO ax_probe_pid(run_id,pid,failures,cooldown_until) VALUES(?,?,?,?)",
          [.key(run.id), .integer(pid), .integer(failures), .integer(future ? 11000 : 9999)])
      }
    }
    var reopened = try ActivityStorage(url: url, appDataDirectory: folder, databaseScope: .directory(folder))
    XCTAssertEqual(try reopened.connection.integer("SELECT sum(failures+cooldown_until) FROM ax_probe_pid"), 0)
    for failures in 1...3 {
      for future in [false, true] {
        let pid = failures * 10 + (future ? 1 : 0)
        for index in 0..<3 {
          let now = 10001 + index
          let request = AXProbeRequest(run: run, time: now, window: WindowIdentity(processID: Int32(pid), windowID: 20), bundleID: "invented.editor", isBrowser: false)
          XCTAssertNil(try reopened.beginAXProbe(request, at: now))
          reopened.finishAXProbe(request, result: AXProbeResult(status: .messagingFailure), at: now)
          reopened = try ActivityStorage(url: url, appDataDirectory: folder, databaseScope: .directory(folder))
          XCTAssertEqual(try reopened.connection.integer("SELECT failures FROM ax_probe_pid WHERE pid=?", [.integer(pid)]), index == 2 ? 0 : index + 1)
          if index == 2 {
            XCTAssertEqual(try reopened.beginAXProbe(request, at: now + 59), .cooldown)
            XCTAssertNil(try reopened.beginAXProbe(request, at: now + 60))
            reopened.finishAXProbe(request, result: AXProbeResult(status: .completed), at: now + 60)
          } else {
            XCTAssertEqual(try reopened.connection.integer("SELECT cooldown_until FROM ax_probe_pid WHERE pid=?", [.integer(pid)]), 0)
          }
        }
      }
    }
    XCTAssertEqual(try reopened.connection.integer("SELECT total FROM ax_probe_flow WHERE event='messagingFailures'"), 18)
    XCTAssertEqual(try reopened.connection.integer("SELECT total FROM ax_probe_flow WHERE event='cooldowns'"), 6)
    try reopened.connection.rows("SELECT payload FROM ax_probe_attempts") { XCTAssertEqual(SQLiteConnection.text($0, 0), payload) }
  }
  func testSecureFieldValuesNeverReachAnyStorageBlob() throws {
    let (store, _, original) = try probeFixture()
    var pair = original
    let secret = "InventedSecureFixture987654"
    pair.ax.nodes = (0..<3).map { index in
      AXProbeNode(nodeID: index, role: index == 0 ? "AXSecureTextField" : "AXTextField",
        subrole: index == 1 ? "AXSecureTextField" : nil, secure: index == 2,
        attributes: ["AXValue", "AXSelectedText", "AXStringForVisibleRange"].map { AXProbeText(attribute: $0, text: secret) }
          + [AXProbeText(attribute: "AXTitle", text: "Invented secure label")])
    }
    pair.ax.counts["secure_fields"] = 3
    XCTAssertTrue(try store.appendAXProbe(pair, evidenceID: nil, at: pair.time))
    for table in ["ax_probe_attempts", "ax_probe_chunks"] {
      let column = table == "ax_probe_attempts" ? "payload" : "text"
      try store.connection.rows("SELECT \(column) FROM \(table)") { XCTAssertFalse(SQLiteConnection.text($0, 0).contains(secret)) }
    }
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM ax_probe_chunks WHERE text='Invented secure label'"), 1)
    XCTAssertEqual(try store.connection.integer("SELECT json_extract(payload,'$.ax.counts.secure_fields') FROM ax_probe_attempts"), 3)
    try store.connection.rows("SELECT c.text FROM ax_probe_parts p JOIN ax_probe_chunks c ON c.hash=p.hash") {
      let nodes = try JSONSerialization.jsonObject(with: Data(SQLiteConnection.text($0, 0).utf8)) as! [[String: Any]]
      XCTAssertEqual(nodes.count, 3)
      XCTAssertTrue(nodes.allSatisfy { $0["secure"] as? Bool == true })
      XCTAssertTrue(nodes.allSatisfy { ($0["attributes"] as? [Any])?.count == 1 })
    }
  }
  func testDeadlinesNeverCreatePIDCooldownOrPermanentDisable() throws {
    let (store, run, pair) = try probeFixture()
    for index in 0..<8 {
      let request = AXProbeRequest(run: run, time: pair.time + index,
        window: WindowIdentity(processID: 10, windowID: 20), bundleID: "invented.editor", isBrowser: false)
      XCTAssertNil(try store.beginAXProbe(request, at: request.time))
      store.finishAXProbe(request, result: AXProbeResult(status: .deadline), at: request.time)
    }
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM ax_probe_pid"), 0)
    XCTAssertEqual(try store.connection.integer("SELECT COALESCE(SUM(total),0) FROM ax_probe_flow WHERE event IN ('messagingFailures','cooldowns')"), 0)
  }
  func testProbePIDCooldownAndThreeFailuresSurviveRestartAndForgetBlocksLateWatchdog() throws {
    let (store, run, pair) = try probeFixture()
    let request = AXProbeRequest(run: run, attemptID: pair.attemptID, time: pair.time,
      window: WindowIdentity(processID: 10, windowID: 20), bundleID: "invented.editor", isBrowser: false)
    for index in 0..<3 {
      let now = pair.time + index
      XCTAssertNil(try store.beginAXProbe(request, at: now))
      store.finishAXProbe(request, result: AXProbeResult(status: .messagingFailure), at: now)
      let reopened = try ActivityStorage(url: url, appDataDirectory: folder, databaseScope: .directory(folder))
      if index == 2 {
        XCTAssertEqual(try reopened.beginAXProbe(request, at: now + 59), .cooldown)
        XCTAssertNil(try reopened.beginAXProbe(request, at: now + 60))
        reopened.finishAXProbe(request, result: AXProbeResult(status: .completed), at: now + 60)
      } else {
        XCTAssertNil(try reopened.beginAXProbe(request, at: now))
        reopened.finishAXProbe(request, result: AXProbeResult(status: .deadline), at: now)
      }
    }
    XCTAssertEqual(try store.connection.integer("SELECT total FROM ax_probe_flow WHERE event='messagingFailures'"), 3)
    XCTAssertEqual(try store.connection.integer("SELECT total FROM ax_probe_flow WHERE event='cooldowns'"), 1)
    let preview = try store.previewAXProbeDeletion(run: run.id)
    _ = try store.deleteAXProbe(run: run.id, confirmation: preview.confirmation)
    store.finishAXProbe(request, result: AXProbeResult(status: .watchdog), at: pair.time + 200)
    XCTAssertFalse(try store.axProbeAllowed(request, at: pair.time + 200))
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM ax_probe_pid"), 0)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM ax_probe_flow"), 0)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM ax_probe_runs WHERE reason='forgotten' AND last_wall=0"), 1)
  }

  func testProbeWatchdogMetadataCannotWriteTextOrResurrectForgottenRows() throws {
    let (store, run, pair) = try probeFixture()
    var pending = pair; pending.ax = AXProbeResult(status: .pending); pending.ocr = ""; pending.ocrStatus = "pending"
    XCTAssertTrue(try store.appendAXProbe(pending, evidenceID: nil, at: pair.time))
    let request = AXProbeRequest(run: run, attemptID: pair.attemptID, time: pair.time,
      window: WindowIdentity(processID: 10, windowID: 20), bundleID: "invented.editor", isBrowser: false)
    var watchdog = AXProbeResult(status: .watchdog); watchdog.start = 100; watchdog.end = 100.5
    watchdog.workerWall = 0.5; watchdog.ipc = 7; watchdog.elements = 2; watchdog.text = "Invented forbidden late AX"
    store.finishAXProbe(request, result: watchdog, at: pair.time)
    try store.recordWatchdogOCR(pair, privacyAccepted: true)
    let evidence = try store.appendScreenCapture(text: pair.ocr, at: pair.time, source: "invented.editor", knownKeys: [],
      probe: AXProbeLink(runID: run.id, attemptID: pair.attemptID))
    var saved: AXProbePair?
    try store.connection.namedRows("SELECT payload,evidence_id FROM ax_probe_attempts") {
      saved = try JSONDecoder().decode(AXProbePair.self, from: Data(try $0.text("payload").utf8))
      XCTAssertEqual(try $0.int("evidence_id"), evidence.evidenceID)
    }
    XCTAssertEqual(saved?.ocrStatus, "acquired_without_snapshot")
    XCTAssertEqual(saved?.ax.ipc, 7); XCTAssertEqual(saved?.ax.elements, 2)
    XCTAssertEqual(saved?.ax.text, ""); XCTAssertEqual(saved?.ocr, "")
    try store.recordWatchdogOCR(pair, privacyAccepted: false)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM ax_probe_attempts WHERE evidence_id IS NOT NULL"), 0)
    let preview = try store.previewAXProbeDeletion(run: run.id)
    _ = try store.deleteAXProbe(run: run.id, confirmation: preview.confirmation)
    try store.recordWatchdogOCR(pair, privacyAccepted: true)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM ax_probe_attempts"), 0)
  }

}
