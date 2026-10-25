import Core
import CryptoKit
import Darwin
import Foundation
import SQLite3

// Retry receipts contain identifiers, numeric diagnostics and constant statuses, never acquired text.
struct AXProbeFinish {
  var runID: String
  var attemptID: String
  var pid: Int
  var status: AXProbeStatus
  var watchdog: String
  var time: Int
  var failures = 0
}

extension SQLiteConnection {
  func createAXProbeSchema() throws {
    try run("DROP TRIGGER IF EXISTS ax_probe_review_no_enable")
    for sql in [
      """
      CREATE TABLE IF NOT EXISTS ax_probe_runs (
        id TEXT PRIMARY KEY, start_ts INTEGER NOT NULL, expiry_ts INTEGER NOT NULL,last_wall INTEGER NOT NULL,
        cancelled INTEGER NOT NULL DEFAULT 0, reason TEXT NOT NULL DEFAULT '',active_attempt TEXT NOT NULL DEFAULT '', manifest TEXT NOT NULL,cancel_ts INTEGER)
      """,
      """
      CREATE TABLE IF NOT EXISTS ax_probe_attempts (
        id INTEGER PRIMARY KEY,run_id TEXT NOT NULL,attempt_id TEXT NOT NULL,ts INTEGER NOT NULL,
        mapping_key TEXT NOT NULL,evidence_id INTEGER,payload TEXT NOT NULL,
        UNIQUE(run_id,attempt_id))
      """,
      "CREATE TABLE IF NOT EXISTS ax_probe_pid (id INTEGER PRIMARY KEY,run_id TEXT NOT NULL,pid INTEGER NOT NULL,failures INTEGER NOT NULL DEFAULT 0,cooldown_until INTEGER NOT NULL DEFAULT 0,UNIQUE(run_id,pid))",
      "CREATE TABLE IF NOT EXISTS ax_probe_flow (id INTEGER PRIMARY KEY,run_id TEXT NOT NULL,event TEXT NOT NULL,total INTEGER NOT NULL,UNIQUE(run_id,event))",
      "CREATE INDEX IF NOT EXISTS ax_probe_time ON ax_probe_attempts(ts)",
      """
      CREATE TABLE IF NOT EXISTS ax_probe_review (
        id INTEGER PRIMARY KEY,run_id TEXT NOT NULL,attempt_row INTEGER NOT NULL UNIQUE,
        ordinal INTEGER NOT NULL CHECK(ordinal>=0 AND ordinal<8),ax_left INTEGER NOT NULL CHECK(ax_left IN (0,1)),
        choice INTEGER CHECK(choice IS NULL OR (choice>=0 AND choice<=4)),
        UNIQUE(run_id,ordinal))
      """,
      """
      CREATE TABLE IF NOT EXISTS ax_probe_review_state (
        id INTEGER PRIMARY KEY,run_id TEXT NOT NULL UNIQUE,sealed INTEGER NOT NULL DEFAULT 0,
        active INTEGER NOT NULL DEFAULT 0,generation INTEGER NOT NULL DEFAULT 0,sample_count INTEGER NOT NULL DEFAULT 0)
      """,
      """
      CREATE TRIGGER IF NOT EXISTS ax_probe_evidence_delete AFTER DELETE ON evidence
      BEGIN DELETE FROM ax_probe_attempts WHERE evidence_id=OLD.id; END
      """,
      """
      CREATE TRIGGER IF NOT EXISTS ax_probe_attempt_delete AFTER DELETE ON ax_probe_attempts
      BEGIN DELETE FROM ax_probe_review WHERE attempt_row=OLD.id; END
      """,
      """
      CREATE TRIGGER IF NOT EXISTS ax_probe_review_no_enable BEFORE INSERT ON settings
      WHEN NEW.key='general.axProbe.enabled' AND NEW.value='1'
        AND EXISTS(SELECT 1 FROM settings WHERE key='general.axProbe.reviewLease'
          AND json_valid(value) AND CAST(strftime('%s','now') AS REAL)>=json_extract(value,'$.issuedWall')
          AND CAST(strftime('%s','now') AS REAL)<json_extract(value,'$.deadlineWall'))
      BEGIN SELECT RAISE(ABORT,'Close probe review first'); END
      """,
      """
      CREATE TRIGGER IF NOT EXISTS ax_probe_review_immutable BEFORE UPDATE ON ax_probe_review
      WHEN EXISTS(SELECT 1 FROM ax_probe_review_state WHERE run_id=OLD.run_id AND sealed=1)
      BEGIN SELECT RAISE(ABORT,'Review sealed'); END
      """,
    ] { try run(sql) }
    // Old streaks include deadlines. Reset them once, then preserve real failures on reopen.
    var pidColumns = Set<String>()
    try rows("PRAGMA table_info(ax_probe_pid)") { pidColumns.insert(Self.text($0, 1)) }
    if !pidColumns.contains("failure_policy") {
      try run("ALTER TABLE ax_probe_pid ADD COLUMN failure_policy INTEGER NOT NULL DEFAULT 1")
    }
    try run("UPDATE ax_probe_pid SET failures=0,cooldown_until=0,failure_policy=2 WHERE failure_policy<2")
    try createAXProbeContentSchema()
    var columns = Set<String>()
    try rows("PRAGMA table_info(ax_probe_runs)") { columns.insert(Self.text($0, 1)) }
    if !columns.contains("cancel_ts") { try run("ALTER TABLE ax_probe_runs ADD COLUMN cancel_ts INTEGER") }
    if !columns.contains("probe_version") { try run("ALTER TABLE ax_probe_runs ADD COLUMN probe_version INTEGER NOT NULL DEFAULT 1") }
  }
}

extension ActivityStorage: AXProbeStore {
  func terminalizeAXProbe(runID: String, attemptID: String, reason: AXProbeOCRRefusal? = nil) throws {
    try connection.run("""
      UPDATE ax_probe_attempts SET evidence_id=NULL,payload=json_set(payload,'$.ax.status','policyRefused','$.ocrStatus','policy_refused','$.ocr_refusal_reason',?)
      WHERE run_id=? AND attempt_id=? AND json_extract(payload,'$.ax.status') IN ('pending','watchdog')
      """, [reason.map { .key($0.rawValue) } ?? .null, .key(runID), .key(attemptID)])
    if sqlite3_changes(connection.handle) == 1 {
      try countAXProbeEvent(runID: runID, event: .privacyRefused, amount: 1)
      if let reason, let event = AXProbeEvent(rawValue: "ocr_" + reason.rawValue) {
        try countAXProbeEvent(runID: runID, event: event, amount: 1)
      }
    }
  }
  public func refuseAXProbeOpportunity(runID: String, attemptID: String, reason: AXProbeOCRRefusal? = nil) throws {
    try locked { try connection.transaction { try terminalizeAXProbe(runID: runID, attemptID: attemptID, reason: reason) } }
  }
  public func recordWatchdogOCR(_ pair: AXProbePair, privacyAccepted: Bool) throws {
    try locked {
      try connection.transaction {
        guard privacyAccepted else {
          try terminalizeAXProbe(runID: pair.runID, attemptID: pair.attemptID)
          return
        }
        let status = ["completed", "empty"].contains(pair.ocrStatus) ? "acquired_without_snapshot" : pair.ocrStatus
        let number: (Double?) -> SQLValue = { $0.map { .key(String($0)) } ?? .null }
        // Update an existing counter only. Disable/forget never permits late strings or row resurrection.
        try connection.run("""
          UPDATE ax_probe_attempts SET payload=json_set(payload,'$.ocrStatus',?,
            '$.imageRequest',CAST(? AS REAL),'$.imageReturn',CAST(? AS REAL),'$.ocrCompletion',CAST(? AS REAL))
          WHERE run_id=? AND attempt_id=? AND json_extract(payload,'$.ax.status')='watchdog'
          """, [.key(status), number(pair.imageRequest), number(pair.imageReturn), number(pair.ocrCompletion),
            .key(pair.runID), .key(pair.attemptID)])
      }
    }
  }
  public func countAXProbeEvent(runID: String, event: AXProbeEvent, amount: Int = 1) throws {
    guard amount >= 0 else { throw StorageError("Invalid probe counter") }
    try locked {
      try connection.run("""
        INSERT INTO ax_probe_flow(run_id,event,total) SELECT ?,?,?
        WHERE EXISTS(SELECT 1 FROM ax_probe_runs WHERE id=? AND reason!='forgotten')
        ON CONFLICT(run_id,event) DO UPDATE SET total=total+excluded.total
        """, [.key(runID), .key(event.rawValue), .integer(amount), .key(runID)])
    }
  }
  /// A run has no expiry. Its text remains isolated from ordinary evidence.
  public func enableAXProbe(at now: Int) throws -> AXProbeRun {
    try locked {
      try connection.transaction {
        guard try !self.settings().axProbeReviewActive(at: now) else {
          throw StorageError("Close probe review first")
        }
        var settings = try self.settings()
        guard settings.axProbeRun == nil else { throw StorageError("Disable the previous run first") }
        let run = AXProbeRun(start: now)
        try connection.run("INSERT INTO ax_probe_runs(id,start_ts,expiry_ts,last_wall,manifest,probe_version) VALUES(?,?,?,?,?,3)",
          [.key(run.id), .integer(now), .integer(Int.max), .integer(now), .maskedText("")])
        settings.general["axProbe.enabled"] = "1"
        settings.general["axProbe.run"] = String(decoding: try JSONEncoder().encode(run), as: UTF8.self)
        try writeSettings(settings, probeEdit: true)
        return run
      }
    }
  }
  public func disableAXProbe(reason: String = "off", at now: Int = Int(Date().timeIntervalSince1970)) throws {
    try locked {
      try connection.transaction {
        var settings = try self.settings()
        if let run = settings.axProbeRun {
          try cancelAXProbeRun(run.id, reason: reason, at: now)
        }
        settings.general["axProbe.enabled"] = "0"
        try writeSettings(settings, probeEdit: true)
      }
    }
  }
  private func cancelAXProbeRun(_ id: String, reason: String, at now: Int) throws {
    // Preserve the first stop cause and its time, including when a watchdog arrives late.
    try connection.run("UPDATE ax_probe_runs SET cancelled=1,reason=?,cancel_ts=? WHERE id=? AND cancelled=0",
      [.key(reason), .integer(now), .key(id)])
    try connection.run("""
      UPDATE ax_probe_attempts SET evidence_id=NULL,payload=json_set(payload,'$.ax.status','policyRefused','$.ocrStatus','policy_refused')
      WHERE run_id=? AND json_extract(payload,'$.ax.status')='pending'
      """, [.key(id)])
    let refused = Int(sqlite3_changes(connection.handle))
    if refused > 0 { try countAXProbeEvent(runID: id, event: .privacyRefused, amount: refused) }
    var settings = try self.settings()
    if settings.axProbeRun?.id == id {
      settings.general["axProbe.enabled"] = "0"
      try writeSettings(settings, probeEdit: true)
    }
  }
  public func retryAXProbeFinishes() throws {
    try locked {
      try flushAXProbeOverloads()
      try flushAXProbePersistenceFailures()
      for key in axProbeFinishes.keys.sorted() { try flushAXProbeFinish(key) }
    }
  }
  public func beginAXProbe(_ request: AXProbeRequest, at now: Int) throws -> AXProbeStatus? {
    try locked {
      // Only a recorded end callback can authorize retrying a lease clear. A busy retry admits no read.
      try retryAXProbeFinishes()
      let status: AXProbeStatus? = try connection.transaction {
        guard try axProbeAllowed(request, at: now) else { return .cancelled }
        var cooldown = 0
        try connection.namedRows("SELECT failures,cooldown_until FROM ax_probe_pid WHERE run_id=? AND pid=?",
          [.key(request.run.id), .integer(Int(request.window.processID))]) {
          cooldown = try $0.int("cooldown_until")
        }
        if now < cooldown { return .cooldown }
        var active = ""
        try connection.namedRows("SELECT active_attempt FROM ax_probe_runs WHERE id=?", [.key(request.run.id)]) {
          active = try $0.text("active_attempt")
        }
        guard active.isEmpty else {
          try cancelAXProbeRun(request.run.id, reason: "unfinished_worker", at: now)
          return .cancelled
        }
        // A restart with an unfinished lease fails closed; a stuck worker can never be silently replaced.
        try connection.run("UPDATE ax_probe_runs SET active_attempt=? WHERE id=?", [.key(request.attemptID), .key(request.run.id)])
        return nil
      }
      if status == nil { axProbeLeases.insert(request.run.id + "|" + request.attemptID) }
      return status
    }
  }
  public func finishAXProbe(_ request: AXProbeRequest, result: AXProbeResult, at now: Int = Int(Date().timeIntervalSince1970)) {
    locked {
      let key = request.run.id + "|" + request.attemptID
      // Permission, busy and refused-begin outcomes own no lease and cannot prove another read ended.
      guard axProbeLeases.contains(key) || result.status == .watchdog else { return }
      if axProbeFinishes[key] == nil || result.status == .watchdog {
        var diagnostic = result; diagnostic.text = ""; diagnostic.nodes = []
        // Acquired text is discarded before encoding watchdog diagnostics.
        let watchdog: String
        var encodingFailures = 0
        do {
          watchdog = result.status == .watchdog
            ? String(decoding: try JSONEncoder().encode(diagnostic), as: UTF8.self) : ""
        } catch {
          // Even malformed diagnostics must persist the watchdog cancellation barrier.
          var fallback = AXProbeResult(status: .watchdog)
          fallback.workerWall = 16; fallback.end = 16; fallback.truncated = true
          watchdog = String(decoding: (try? JSONEncoder().encode(fallback)) ?? Data(), as: UTF8.self)
          encodingFailures = 1
        }
        axProbeFinishes[key] = AXProbeFinish(runID: request.run.id, attemptID: request.attemptID,
          pid: Int(request.window.processID), status: result.status, watchdog: watchdog, time: now,
          failures: (axProbeFinishes[key]?.failures ?? 0) + encodingFailures)
      }
      do { try flushAXProbeFinish(key) }
      catch { /* Retained without text; begin retries before admitting another AX read. */ }
    }
  }
  private func flushAXProbeFinish(_ key: String) throws {
    guard let finish = axProbeFinishes[key] else { return }
    do {
      try connection.transaction {
        guard try connection.integer("SELECT count(*) FROM ax_probe_runs WHERE id=? AND reason!='forgotten'", [.key(finish.runID)]) == 1 else { return }
        if finish.status == .messagingFailure {
          try connection.run("""
            INSERT INTO ax_probe_pid(run_id,pid,failures,cooldown_until,failure_policy) VALUES(?,?,1,0,2)
            ON CONFLICT(run_id,pid) DO UPDATE SET
              failures=CASE WHEN failures>=2 THEN 0 ELSE failures+1 END,
              cooldown_until=CASE WHEN failures>=2 THEN ? ELSE cooldown_until END
            """, [.key(finish.runID), .integer(finish.pid), .integer(finish.time + 60)])
          try countAXProbeEvent(runID: finish.runID, event: .messagingFailures, amount: 1)
          if try connection.integer("SELECT cooldown_until FROM ax_probe_pid WHERE run_id=? AND pid=?", [.key(finish.runID), .integer(finish.pid)]) == finish.time + 60 {
            try countAXProbeEvent(runID: finish.runID, event: .cooldowns, amount: 1)
          }
        } else if finish.status == .completed || finish.status == .empty {
          try connection.run("UPDATE ax_probe_pid SET failures=0,cooldown_until=0 WHERE run_id=? AND pid=?",
            [.key(finish.runID), .integer(finish.pid)])
        }
        if finish.status == .watchdog {
          try connection.run("""
            UPDATE ax_probe_attempts SET payload=json_set(payload,'$.ax',json(?),'$.ocrStatus','not_acquired')
            WHERE run_id=? AND attempt_id=? AND json_extract(payload,'$.ax.status')='pending'
            """, [.maskedText(finish.watchdog), .key(finish.runID), .key(finish.attemptID)])
          try countAXProbeEvent(runID: finish.runID, event: .watchdog, amount: 1)
          try countAXProbeEvent(runID: finish.runID, event: .censoredMilliseconds, amount: 16000)
          try cancelAXProbeRun(finish.runID, reason: "watchdog", at: finish.time)
        } else {
          try connection.run("UPDATE ax_probe_runs SET active_attempt='' WHERE id=? AND active_attempt=?",
            [.key(finish.runID), .key(finish.attemptID)])
          if finish.failures > 0 && sqlite3_changes(connection.handle) == 1 {
            try countAXProbeEvent(runID: finish.runID, event: .recoveredWorkerLease, amount: 1)
          }
        }
        if finish.failures > 0 {
          try countAXProbeEvent(runID: finish.runID, event: .finishStorageFailures, amount: finish.failures)
        }
      }
      axProbeFinishes.removeValue(forKey: key)
      axProbeLeases.remove(key)
    } catch {
      axProbeFinishes[key]?.failures += 1
      throw error
    }
  }
  public func axProbeAllowed(_ request: AXProbeRequest, at now: Int) throws -> Bool {
    try locked {
      let settings = try self.settings()
      guard settings.axProbeRun == request.run, RecorderPolicy.recording(settings, at: now),
        !settings.excludedApps.contains(where: { $0.lowercased() == request.bundleID.lowercased() }),
        !settings.axProbeReviewActive(at: now),
        try connection.integer("SELECT count(*) FROM ax_probe_runs WHERE id=? AND cancelled=0", [.key(request.run.id)]) == 1,
        request.time < Int.max, try !forgotten(TimeRange(request.time, request.time + 1)) else { return false }
      return true
    }
  }
  @discardableResult public func appendAXProbe(_ pair: AXProbePair, evidenceID: Int?, at now: Int, permitted: () -> Bool = { true }) throws -> Bool {
    let counterOnly = [.pending, .browserExcluded, .policyRefused, .watchdog, .overload_dropped].contains(pair.ax.status)
    if !counterOnly {
      // This connection and lock belong only to probe writes. Neither masks nor large writes
      // can acquire the recorder/settings connection lock.
      let writer = try ActivityStorage(url: url, appDataDirectory: appDataDirectory,
        busyMilliseconds: 25, databaseScope: databaseScope)
      return try writer.writeAXProbeContent(pair, evidenceID: evidenceID, at: now, permitted: permitted)
    }
    var prepared = pair
    prepared.ocr = ""; prepared.ax.text = ""; prepared.ax.nodes = []
    prepared.bundleID = probeHash(pair.bundleID.lowercased())
    let payload = String(decoding: try JSONEncoder().encode(prepared), as: UTF8.self)
    guard permitted() else { try refuseAXProbeOpportunity(runID: pair.runID, attemptID: pair.attemptID); return false }
    return try locked { try connection.transaction {
      guard try probeWriteAllowed(pair, at: now) else { return false }
      try connection.run("""
        INSERT OR IGNORE INTO ax_probe_attempts(run_id,attempt_id,ts,mapping_key,evidence_id,payload)
        VALUES(?,?,?,?,?,?)
        """, [.key(pair.runID), .key(pair.attemptID), .integer(pair.time), .key(prepared.bundleID),
          evidenceID.map(SQLValue.integer) ?? .null, .maskedText(payload)])
      return sqlite3_changes(connection.handle) == 1
    } }
  }
  func requireAXProbeReviewClosed() throws {
    guard try !self.settings().axProbeReviewActive(at: Int(Date().timeIntervalSince1970)) else {
      throw StorageError("Close the probe review and clear its page before deletion or retention")
    }
  }
  private func probePreview(_ run: String) throws -> DeletionPreview {
    guard UUID(uuidString: run) != nil else { throw StorageError("Invalid probe run") }
    var digest = SHA256()
    digest.update(data: Data("probe-forget-v1|\(settingsIdentity)|\(run)".utf8))
    var counts: [String: Int] = [:]
    for table in ["ax_probe_runs", "ax_probe_attempts", "ax_probe_review", "ax_probe_review_state", "ax_probe_flow", "ax_probe_pid"] {
      let column = table == "ax_probe_runs" ? "id" : "run_id"
      var count = 0
      try connection.rows("SELECT * FROM \(table) WHERE \(column)=? ORDER BY 1", [.key(run)]) { row in
        count += 1
        for column in 0..<sqlite3_column_count(row) {
          digest.update(data: Data("|\(sqlite3_column_type(row, column)):\(sqlite3_column_bytes(row, column)):".utf8))
          if let bytes = sqlite3_column_blob(row, column) {
            digest.update(data: Data(bytes: bytes, count: Int(sqlite3_column_bytes(row, column))))
          }
        }
      }
      counts[table] = count
    }
    try digestAXProbeContent(attempts: "SELECT id FROM ax_probe_attempts WHERE run_id=?",
      values: [.key(run)], into: &digest)
    let settings = try self.settings()
    if let bytes = settings.general["axProbe.run"],
      let value = try? JSONDecoder().decode(AXProbeRun.self, from: Data(bytes.utf8)), value.id == run {
      digest.update(data: Data((bytes + "|" + (settings.general["axProbe.enabled"] ?? "")).utf8))
      counts["probe_settings"] = 1
    }
    return DeletionPreview(range: TimeRange(0, 1), counts: counts,
      confirmation: digest.finalize().map { String(format: "%02x", $0) }.joined())
  }
  public func previewAXProbeDeletion(run: String) throws -> DeletionPreview {
    try locked { try connection.transaction(write: false) { try probePreview(run) } }
  }
  public func deleteAXProbe(run: String, confirmation: String) throws -> DeletionResult {
    try locked {
      let preview = try connection.transaction {
        try requireAXProbeReviewClosed()
        let preview = try probePreview(run)
        guard preview.confirmation == confirmation else { throw StorageError("Records changed; request a new preview") }
        var settings = try self.settings()
        if let bytes = settings.general["axProbe.run"],
          let value = try? JSONDecoder().decode(AXProbeRun.self, from: Data(bytes.utf8)), value.id == run {
          settings.general["axProbe.enabled"] = "0"; settings.general.removeValue(forKey: "axProbe.run")
          try writeSettings(settings, probeEdit: true)
        }
        // Retain only a content-free cancellation barrier, never a broad recording-day barrier.
        try connection.run("UPDATE ax_probe_runs SET cancelled=1,reason='forgotten',cancel_ts=CAST(strftime('%s','now') AS INTEGER),manifest='',start_ts=0,expiry_ts=0,last_wall=0,active_attempt='' WHERE id=?", [.key(run)])
        for table in ["ax_probe_review", "ax_probe_review_state", "ax_probe_attempts", "ax_probe_flow", "ax_probe_pid"] {
          try connection.run("DELETE FROM \(table) WHERE run_id=?", [.key(run)])
          guard try connection.integer("SELECT count(*) FROM \(table) WHERE run_id=?", [.key(run)]) == 0 else {
            throw StorageError("Probe deletion incomplete")
          }
        }
        guard try connection.integer("SELECT count(*) FROM ax_probe_runs WHERE id=? AND cancelled=1 AND reason='forgotten' AND manifest=''", [.key(run)]) == 1 else {
          throw StorageError("Probe cancellation barrier missing")
        }
        return preview
      }
      return DeletionResult(preview: preview, walTruncated: connection.truncateWAL())
    }
  }
}

extension ActivityStorage {
  /// Owner-only recovery after a crashed server and clearing its browser page. A live writer refuses recovery.
  public func closeStaleAXProbeReview(run: String) throws {
    let descriptor = open(url.path + ".ax-review.lock", O_RDWR | O_NOFOLLOW)
    guard descriptor >= 0 else { throw StorageError("Review lock unavailable") }
    defer { close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
      flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw StorageError("Review writer still active") }
    try locked {
      try connection.transaction {
        guard try self.settings().axProbeRun == nil else { throw StorageError("Disable probe first") }
        try connection.run("UPDATE ax_probe_review_state SET active=0,generation=generation+1 WHERE run_id=?", [.key(run)])
        if try connection.integer("SELECT count(*) FROM ax_probe_review_state WHERE active=1") == 0 {
          try connection.run("INSERT OR REPLACE INTO settings(key,value) VALUES('general.axProbe.reviewActive','0')")
        }
        try connection.run("DELETE FROM settings WHERE key='general.axProbe.reviewLease'")
        try connection.run("INSERT OR REPLACE INTO settings(key,value) VALUES('general.axProbe.reviewGeneration',?)", [.key(UUID().uuidString)])
      }
    }
  }
}

extension ActivityStorage {
  public func axProbeStatus() throws -> String {
    try locked {
      var status = "ax_probe_run=none"
      var hasTime = false
      try connection.rows("PRAGMA table_info(ax_probe_runs)") { if SQLiteConnection.text($0, 1) == "cancel_ts" { hasTime = true } }
      let timeColumn = hasTime ? "cancel_ts" : "NULL AS cancel_ts"
      let ordering = hasTime ? "COALESCE(cancel_ts,start_ts)" : "start_ts"
      try connection.namedRows("SELECT id,cancelled,reason,\(timeColumn) FROM ax_probe_runs ORDER BY \(ordering) DESC,rowid DESC LIMIT 1") { row in
        let reason = try row.text("reason")
        let safe = ["off", "watchdog", "clock_backward", "unfinished_worker", "forgotten", "expired", ""].contains(reason) ? reason : "unknown"
        let time = try row.value("cancel_ts")
        let timestamp: String
        if case .integer(let value) = time { timestamp = String(value) } else { timestamp = "unknown" }
        status = "ax_probe_enabled=\(try row.int("cancelled") == 0 ? 1 : 0) ax_probe_run=\(try row.text("id")) ax_probe_cancelled=\(try row.int("cancelled")) ax_probe_reason=\(safe.isEmpty ? "none" : safe) ax_probe_cancelled_at=\(timestamp)"
      }
      let now = Int(Date().timeIntervalSince1970)
      let bytes = try probeStorageBytes(since: nil)
      let added = try probeStorageBytes(since: now - 86400)
      let drops = try connection.integer("SELECT COALESCE(SUM(total),0) FROM ax_probe_flow WHERE event='overload_dropped'")
      return status + " ax_probe_storage_bytes=\(bytes) ax_probe_added_24h_bytes=\(added) overload_dropped=\(drops)"
    }
  }
}
