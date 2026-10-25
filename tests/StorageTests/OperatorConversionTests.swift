import Core
import Foundation
@testable import Storage
import XCTest

final class OperatorConversionTests: XCTestCase {
  var folder: URL!
  override func setUpWithError() throws {
    folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ACTIVITYPROBE_TEST_ROOT"] ?? NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }
  override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }
  func source() throws -> URL {
    let url = folder.appendingPathComponent("old.sqlite"), db = try SQLiteConnection(url: url, scope: .directory(folder))
    for sql in [
      "CREATE TABLE forgotten(start_ts INTEGER,end_ts INTEGER)", "INSERT INTO forgotten VALUES(86520,86580)",
      "CREATE TABLE forgotten_session_rows(bundle_id TEXT,source_id TEXT)", "INSERT INTO forgotten_session_rows VALUES('invented','gone')",
      "CREATE TABLE wanted(recording INTEGER)", "INSERT INTO wanted VALUES(0)",
      "CREATE TABLE log_cursors(path TEXT,device INTEGER,inode INTEGER,offset INTEGER,state TEXT,seen_ts INTEGER)",
      "INSERT INTO log_cursors VALUES('invented-log',1,2,13,'',86400)", "INSERT INTO log_cursors VALUES('invented-log',1,2,20,'',86400)",
      "CREATE TABLE samples(ts INTEGER,bundle_id TEXT,app TEXT,title TEXT,doc_key TEXT,keys INTEGER,clicks INTEGER,scrolls INTEGER,moved INTEGER,synth INTEGER,watching INTEGER,hidden_reason TEXT)",
      "CREATE TABLE evidence(ts INTEGER,bundle_id TEXT,doc_key TEXT,kind TEXT,text TEXT,source_id TEXT,project TEXT)",
      "CREATE TABLE activities(id INTEGER PRIMARY KEY,start_ts INTEGER,end_ts INTEGER,title TEXT,summary TEXT,category TEXT,kind TEXT,away INTEGER,project TEXT,active_secs INTEGER)",
      "CREATE TABLE llm_runs(created_at INTEGER,from_ts INTEGER,to_ts INTEGER,model TEXT,input_tokens INTEGER,cached_tokens INTEGER,output_tokens INTEGER,ok INTEGER)",
      "INSERT INTO llm_runs VALUES(86400,86400,86520,'invented',123,23,4,1)",
      "INSERT INTO llm_runs VALUES(172800,172900,172800,'invented',10,2,3,0)",
      "INSERT INTO llm_runs VALUES(259200,NULL,NULL,'invented',1,0,2,1)",
      "PRAGMA user_version=10",
    ] { try db.run(sql) }
    try db.run("UPDATE log_cursors SET state=? WHERE rowid=1", [.maskedText(#"{"session":"invented-session","project":"invented-project","metadataRead":true,"queued":[]}"#)])
    for day in [86400,172800,259200] {
      for offset in [1,1,2] {
        try db.run("INSERT INTO samples VALUES(?,'invented','Invented','password=invented-secret','invented-doc',1,2,3,1,4,1,?)", [.integer(day + offset), .text(offset == 2 ? "excluded" : "")])
      }
    }
    try db.run("INSERT INTO samples VALUES(86521,'invented','','','',1,0,0,0,0,0,'')")
    for (time,kind,id,doc) in [(86401,"ocr","s1",""),(86402,"screen","s2",""),(86403,"prompt","p1",""),(86404,"prompt","p1",""),(86521,"prompt","claude:invented-deleted",""),(86405,"prompt","gone",""),(86406,"reply","r",""),(86407,"choice","c",""),(86408,"input","i",""),(86409,"invented-other-kind","o",""),(86410,"screen","hidden","(비공개)")] {
      try db.run("INSERT INTO evidence VALUES(?,'invented',?,?,'password=invented-secret',?,'invented-project')", [.integer(time),.text(doc),.text(kind),.key(id)])
    }
    for (id,start,end,category,kind,away) in [(1,86401,86521,"coding","normal",0),(2,86461,86640,"review","normal",0),(3,86640,86760,"personal","normal",0),(4,86760,86820,"coding","unknown",0),(5,86820,86880,"coding","normal",1),(6,87001,87002,"coding","normal",0),(7,172800,172920,"coding","private",0),(8,259200,259380,"leisure","normal",0)] {
      try db.run("INSERT INTO activities VALUES(?,?,?,'Invented activity','Invented description',?,?,?,'invented-project',17)", [.integer(id),.integer(start),.integer(end),.text(category),.text(kind),.integer(away)])
    }
    return url
  }
  func store() throws -> ActivityStorage { try ActivityStorage(url: folder.appendingPathComponent("new.sqlite"), appDataDirectory: folder, databaseScope: .directory(folder)) }
  func utc() -> Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!; return c }

  // Ideal: every source row is explained across interruptions; distinct seconds, evidence identities,
  // interval minutes/projects and billing survive exactly, while forgotten content never returns.
  func testRehearsalThreeDaysEveryTableAndTwoResumes() throws {
    let source = try source(), original = try Data(contentsOf: source)
    for _ in 0..<2 {
      let partial = try store().convertOldDatabase(at: source, batchSize: 1, maxBatches: 2, verifyFrozenContent: true)
      XCTAssertFalse(partial.finished)
    }
    let store = try store()
    XCTAssertTrue(try store.convertOldDatabase(at: source, batchSize: 2, verifyFrozenContent: true).finished)
    let privacy = folder.appendingPathComponent("privacy.json"), general = folder.appendingPathComponent("settings.json")
    try Data(#"{"apps":["invented.excluded"],"retentionDays":45,"pausedUntil":100}"#.utf8).write(to: privacy)
    try Data(#"{"outputLanguage":"ko","dayStartHour":0}"#.utf8).write(to: general)
    let note = folder.appendingPathComponent("pause-until"), kept = folder.appendingPathComponent("pause-kept")
    try Data("500\n".utf8).write(to: note); try Data("900\n".utf8).write(to: kept)
    XCTAssertTrue(try store.importOldSettings(privacyFile: privacy, generalFile: general, pauseUntilFile: note, pauseKeptFile: kept, recordingIntent: true))
    let manifest = try store.conversionManifest(source: source, calendar: utc())
    XCTAssertTrue(manifest.passed, manifest.lines.filter { !$0.passed }.map(\.text).joined(separator:"\n"))
    let all = TimeRange(0,400000)
    XCTAssertEqual(try store.samples(in: all).count, 9)
    let position = try XCTUnwrap(store.logPosition(path:"invented-log"))
    XCTAssertEqual(position.offset,13)
    let state = try AgentLogState.decode(position.state)
    XCTAssertEqual(state.session,"invented-session"); XCTAssertTrue(state.metadataRead)
    XCTAssertEqual(state.project,"invented-project")
    XCTAssertEqual(try store.evidence(in: all).count, 3)
    XCTAssertEqual(try store.intervals(in: all).map { $0.range.end - $0.range.start }, [120,120,120,180])
    XCTAssertTrue(try store.intervals(in: all).allSatisfy { $0.project == "invented-project" })
    XCTAssertEqual(try store.modelCalls(in: all).map(\.inputTokens), [123,10,1])
    XCTAssertEqual(manifest.lines.first { $0.metric == "baseline.old_active_seconds" }?.actual, 136)
    XCTAssertEqual(manifest.lines.first { $0.metric == "baseline.old_interval_wall_seconds" }?.actual, 840)
    let settingsManifest = try store.conversionSettingsManifest(privacyFile:privacy,generalFile:general,pauseUntilFile:note,pauseKeptFile:kept,recordingIntent:true)
    XCTAssertTrue(settingsManifest.allSatisfy(\.passed))
    XCTAssertEqual(try store.settings().pausedUntil, 500); XCTAssertTrue(try store.settings().recordingEnabled)
    XCTAssertFalse(try store.settings().subscriptionConnected)
    let history = try store.logRecordingHistory(), settings = try store.settings()
    XCTAssertFalse(try store.importOldSettings(privacyFile: privacy, generalFile: general, recordingIntent: false))
    XCTAssertEqual(try store.settings(), settings); XCTAssertEqual(try store.logRecordingHistory(), history)
    for _ in 0..<2 {
      let again = try store.convertOldDatabase(at: source, verifyFrozenContent: true)
      XCTAssertTrue(again.finished); XCTAssertTrue(again.tables.isEmpty)
      XCTAssertTrue(try store.conversionManifest(source: source, calendar: utc()).passed)
    }
    XCTAssertEqual(try Data(contentsOf: source), original)
    for day in [86400,172800,259200] {
      let timeline = try TimelineDay.read(containing: day + 1, now: 400000, calendar: utc(), storage: store)
      // Input tails include quiet observed minutes; deletion removes the third minute of day one.
      let ideal: [TimelineGridKind: Int] = day == 86400 ? [.work:2,.other:2,.uninterpreted:1]
        : day == 172800 ? [.other:2,.uninterpreted:4] : [.distraction:3,.uninterpreted:3]
      XCTAssertEqual(timeline.minutesByKind, ideal)
      XCTAssertEqual(timeline.entries.reduce(0) { $0 + $1.minutes }, ideal.values.reduce(0,+))
      XCTAssertEqual(timeline.totalMinutes, timeline.columns.flatMap(\.slots).compactMap(\.kind).count)
    }
    _ = try store.appendEvidence([EvidenceText(ts: 300000,kind:.prompt,source:"other",sourceID:"claude:invented-deleted",text:"invented")])
    XCTAssertEqual(try store.evidence(in: all).count, 3)
    try store.finishConversion()
  }
  func testManifestDetectsWrongValuesWithUnchangedCounts() throws {
    let source = try source(), store = try store()
    _ = try store.convertOldDatabase(at: source)
    XCTAssertTrue(try store.conversionManifest(source: source, calendar: utc()).passed)
    try store.connection.run("UPDATE samples SET keys=keys+1 WHERE id=1")
    XCTAssertFalse(try store.conversionManifest(source: source, calendar: utc()).passed)
  }
  func testManifestDetectsTamperedAccountingAndSettings() throws {
    let source = try source(), store = try store()
    _ = try store.convertOldDatabase(at:source)
    try store.connection.run("UPDATE conversion_progress SET last_row=last_row+1 WHERE layer='count.evidenceKind.prompt.carried'")
    let manifest = try store.conversionManifest(source:source,calendar:utc())
    XCTAssertFalse(manifest.passed)
    XCTAssertFalse(try XCTUnwrap(manifest.lines.first { $0.metric == "source.evidence.kind.prompt" }).passed)
    let missing = folder.appendingPathComponent("missing")
    _ = try store.importOldSettings(privacyFile:missing,generalFile:missing,recordingIntent:true)
    _ = try store.patchSettings(.edit(.pause(2000000000),ownBundleID:"invented.self",now:1))
    XCTAssertFalse(try store.conversionSettingsManifest(privacyFile:missing,generalFile:missing,pauseUntilFile:missing,pauseKeptFile:missing,recordingIntent:true).allSatisfy(\.passed))
  }
  func testOperatorFrozenFingerprintRejectsChangedSourceWithoutFurtherWrites() throws {
    let source = try source(), store = try store()
    _ = try store.convertOldDatabase(at: source, batchSize:1, maxBatches:1, verifyFrozenContent:true)
    let counts = try store.conversionCounts()
    do { let db = try SQLiteConnection(url:source, scope: .directory(folder)); try db.run("UPDATE wanted SET recording=1") }
    XCTAssertThrowsError(try store.convertOldDatabase(at: source, verifyFrozenContent:true))
    XCTAssertEqual(try store.conversionCounts(), counts)
  }
  func testMissingPrivacyDoesNotInventAPauseFromStaleKeptNote() throws {
    let store = try store(), missing = folder.appendingPathComponent("missing"), kept = folder.appendingPathComponent("pause-kept")
    try Data("2000000000".utf8).write(to:kept)
    _ = try store.importOldSettings(privacyFile:missing,generalFile:missing,pauseKeptFile:kept,recordingIntent:true)
    XCTAssertNil(try store.settings().pausedUntil)
    XCTAssertTrue(try store.conversionSettingsManifest(privacyFile:missing,generalFile:missing,pauseUntilFile:missing,pauseKeptFile:kept,recordingIntent:true).allSatisfy(\.passed))
  }
  func testUnreadableSettingsKeepEffectivePauseAndDefaultWithoutSourceWrites() throws {
    let store = try store(), privacy = folder.appendingPathComponent("privacy.json"), general = folder.appendingPathComponent("settings.json"), kept = folder.appendingPathComponent("pause-kept")
    let bytes = Data("{invalid invented".utf8); try bytes.write(to: privacy)
    try Data("900".utf8).write(to: kept)
    XCTAssertTrue(try store.importOldSettings(privacyFile:privacy, generalFile:general, pauseKeptFile:kept, recordingIntent:false))
    XCTAssertEqual(try store.settings().pausedUntil,900); XCTAssertFalse(try store.settings().recordingEnabled)
    XCTAssertEqual(try store.settings().screenRetentionDays,30)
    XCTAssertEqual(try Data(contentsOf:privacy),bytes)
  }
  func testHardLinkedWALSourceIsRefusedBeforeImport() throws {
    let source = try source(), writer = try SQLiteConnection(url: source, scope: .directory(folder))
    try writer.run("PRAGMA journal_mode=WAL")
    try writer.run("DELETE FROM samples")
    try writer.run("INSERT INTO samples(ts) VALUES(300000)")
    try writer.run("PRAGMA wal_checkpoint(TRUNCATE)")
    let committed = try writer.integer("SELECT count(*) FROM samples")
    XCTAssertEqual(committed, 1)
    try writer.run("INSERT INTO samples(ts) VALUES(300001)")
    XCTAssertEqual(try writer.integer("SELECT count(*) FROM samples"), committed + 1)
    let alias = folder.appendingPathComponent("alias.sqlite")
    try FileManager.default.linkItem(at: source, to: alias)
    let destination = try store()
    XCTAssertThrowsError(try ActivityStorage.validateOldConversionSource(alias, scope: .directory(folder)))
    XCTAssertThrowsError(try destination.convertOldDatabase(at: alias))
    XCTAssertTrue(try destination.samples(in: TimeRange(0,400000)).isEmpty)
    withExtendedLifetime(writer) {}
  }
  func testRetiredWrongTypePreservesKeptPauseAndAuditRejectsLostPause() throws {
    let store = try store(), privacy = folder.appendingPathComponent("privacy.json")
    let missing = folder.appendingPathComponent("missing"), kept = folder.appendingPathComponent("pause-kept")
    let bytes = Data(#"{"apps":[],"autoContextProjects":17}"#.utf8)
    try bytes.write(to: privacy); try Data("2000000000".utf8).write(to: kept)
    _ = try store.importOldSettings(privacyFile: privacy, generalFile: missing, pauseKeptFile: kept, recordingIntent: true)
    XCTAssertEqual(try store.settings().pausedUntil, 2000000000)
    XCTAssertEqual(try store.settings().excludedApps, StorageSettings.defaultExcludedApps)
    XCTAssertTrue(try store.conversionSettingsManifest(privacyFile: privacy, generalFile: missing, pauseUntilFile: missing, pauseKeptFile: kept, recordingIntent: true).allSatisfy(\.passed))
    try store.connection.run("DELETE FROM settings WHERE key='pause'")
    XCTAssertFalse(try store.conversionSettingsManifest(privacyFile: privacy, generalFile: missing, pauseUntilFile: missing, pauseKeptFile: kept, recordingIntent: true).allSatisfy(\.passed))
    XCTAssertEqual(try Data(contentsOf: privacy), bytes)
  }
  func testHistorySameCountMutationsFailAudit() throws {
    let store = try store(), missing = folder.appendingPathComponent("missing"), kept = folder.appendingPathComponent("pause-until")
    try Data("2000000000".utf8).write(to: kept)
    _ = try store.importOldSettings(privacyFile: missing, generalFile: missing, pauseUntilFile: kept, recordingIntent: true)
    func audit() throws -> Bool {
      try store.conversionSettingsManifest(privacyFile: missing, generalFile: missing, pauseUntilFile: kept, pauseKeptFile: missing, recordingIntent: true).allSatisfy(\.passed)
    }
    XCTAssertTrue(try audit())
    for sql in ["UPDATE log_recording_history SET enabled=0 WHERE id=2",
      "UPDATE log_recording_history SET paused_until=NULL WHERE id=2",
      "UPDATE log_recording_history SET since=since+1 WHERE id=2",
      "UPDATE log_recording_history SET id=id+10 WHERE id=1",
      "UPDATE log_recording_history SET paused_until='invented-invalid' WHERE id=1",
      "UPDATE log_recording_history SET enabled=0.5 WHERE id=2"] {
      try store.connection.run("SAVEPOINT witness")
      try store.connection.run(sql)
      XCTAssertFalse(try audit(), sql)
      try store.connection.run("ROLLBACK TO witness"); try store.connection.run("RELEASE witness")
    }
  }

  func testHistoryRejectsMalformedPauseAndDisabledValuesWithoutChangingCounts() throws {
    let store = try store(), missing = folder.appendingPathComponent("missing")
    _ = try store.importOldSettings(privacyFile: missing, generalFile: missing, recordingIntent: false)
    func audit() throws -> Bool {
      try store.conversionSettingsManifest(privacyFile: missing, generalFile: missing, pauseUntilFile: missing,
        pauseKeptFile: missing, recordingIntent: false).allSatisfy(\.passed)
    }
    XCTAssertTrue(try audit())
    for sql in ["UPDATE log_recording_history SET enabled=0.5 WHERE id=2",
      "UPDATE log_recording_history SET paused_until='invented-invalid' WHERE id=1",
      "UPDATE log_recording_history SET paused_until='invented-invalid' WHERE id=2"] {
      try store.connection.run("SAVEPOINT witness")
      try store.connection.run(sql)
      XCTAssertEqual(try store.logRecordingHistory().count, 2)
      XCTAssertFalse(try audit(), sql)
      try store.connection.run("ROLLBACK TO witness"); try store.connection.run("RELEASE witness")
    }
  }

  // Ideal: adoption is an exact persisted snapshot, including markers and absent safety/consent keys.
  func testCompleteSettingsAuditRejectsEveryMissingChangedAndUnexpectedKey() throws {
    let store = try store(), missing = folder.appendingPathComponent("missing")
    _ = try store.importOldSettings(privacyFile:missing,generalFile:missing,recordingIntent:true)
    func audit() throws -> [ConversionManifestLine] {
      try store.conversionSettingsManifest(privacyFile:missing,generalFile:missing,pauseUntilFile:missing,
        pauseKeptFile:missing,recordingIntent:true)
    }
    XCTAssertTrue(try audit().allSatisfy(\.passed))
    var keys: [String] = []
    try store.connection.namedRows("SELECT key FROM settings ORDER BY key") { keys.append(try $0.text("key")) }
    XCTAssertEqual(keys.count,19)
    for key in keys {
      for remove in [false,true] {
        try store.connection.run("SAVEPOINT witness")
        if remove { try store.connection.run("DELETE FROM settings WHERE key=?",[.key(key)]) }
        else { try store.connection.run("UPDATE settings SET value='invented-audit-value' WHERE key=?",[.key(key)]) }
        let lines = try audit()
        XCTAssertFalse(lines.allSatisfy(\.passed),key)
        XCTAssertTrue(lines.contains { $0.metric == "settings.mismatch.\"\(key)\"" && !$0.passed },key)
        XCTAssertFalse(lines.map(\.text).joined().contains("invented-audit-value"))
        try store.connection.run("ROLLBACK TO witness"); try store.connection.run("RELEASE witness")
      }
    }
    for key in ["general.chat.skipApprovals","general.chat.selection","general.chat.claude.connected",
      "general.chat.claude.generation","subscription.connected","subscription.generation","invented.unknown"] {
      try store.connection.run("SAVEPOINT witness")
      // An explicit default is still an unexpected row in the adopted snapshot.
      try store.connection.run("INSERT INTO settings VALUES(?,'0')",[.key(key)])
      XCTAssertFalse(try audit().allSatisfy(\.passed),key)
      try store.connection.run("ROLLBACK TO witness"); try store.connection.run("RELEASE witness")
    }
    for sql in ["UPDATE settings SET value=CAST(X'3100696E76656E746564' AS TEXT) WHERE key='initialized'",
      "UPDATE settings SET value=CAST(X'31FF' AS TEXT) WHERE key='initialized'",
      "UPDATE settings SET key=CAST(X'696E697469616C697A656400' AS TEXT) WHERE key='initialized'",
      "UPDATE settings SET value=X'31' WHERE key='initialized'"] {
      try store.connection.run("SAVEPOINT witness")
      try store.connection.run(sql)
      XCTAssertFalse(try audit().allSatisfy(\.passed))
      try store.connection.run("ROLLBACK TO witness"); try store.connection.run("RELEASE witness")
    }
  }

  func testReadablePrivacyEmptyListAndUnreadableDefaultsHaveIndependentAudit() throws {
    let privacy = folder.appendingPathComponent("privacy.json"), missing = folder.appendingPathComponent("missing")
    for (index,json) in [#"{"pausedUntil":2000000000}"#, #"{"apps":null,"pausedUntil":2000000000}"#, "{invalid", "absent"].enumerated() {
      if json == "absent" { try FileManager.default.removeItem(at:privacy) }
      else { try Data(json.utf8).write(to:privacy) }
      let store = try ActivityStorage(url:folder.appendingPathComponent("privacy-\(index).sqlite"),appDataDirectory:folder,databaseScope:.directory(folder))
      _ = try store.importOldSettings(privacyFile:privacy,generalFile:missing,recordingIntent:true)
      let readable = index < 2
      XCTAssertEqual(try store.settings().excludedApps,readable ? [] : StorageSettings.defaultExcludedApps)
      func audit() throws -> Bool {
        try store.conversionSettingsManifest(privacyFile:privacy,generalFile:missing,pauseUntilFile:missing,
          pauseKeptFile:missing,recordingIntent:true).allSatisfy(\.passed)
      }
      XCTAssertTrue(try audit())
      var wrong = try store.settings(); wrong.excludedApps = readable ? StorageSettings.defaultExcludedApps : []
      try store.saveSettings(wrong,at:Int.min)
      XCTAssertFalse(try audit())
    }
  }

  func testSettingsAuditComparesOriginalUTF8Bytes() throws {
    let store = try store(), missing = folder.appendingPathComponent("missing")
    let general = folder.appendingPathComponent("settings.json")
    try Data(#"{"outputLanguage":"\uFFFD"}"#.utf8).write(to:general)
    _ = try store.importOldSettings(privacyFile:missing,generalFile:general,recordingIntent:true)
    func audit() throws -> Bool {
      try store.conversionSettingsManifest(privacyFile:missing,generalFile:general,pauseUntilFile:missing,
        pauseKeptFile:missing,recordingIntent:true).allSatisfy(\.passed)
    }
    let decoded = try store.settings()
    XCTAssertTrue(try audit())
    try store.connection.run("UPDATE settings SET value=CAST(X'FF' AS TEXT) WHERE key='general.outputLanguage'")
    XCTAssertEqual(try store.settings(),decoded)
    XCTAssertFalse(try audit())
  }

}
