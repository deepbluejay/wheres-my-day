import Core
import CryptoKit
import Foundation
import SQLite3

func probeHash(_ text: String) -> String {
  SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

extension SQLiteConnection {
  func createAXProbeContentSchema() throws {
    for sql in [
      "CREATE TABLE IF NOT EXISTS ax_probe_blobs(hash TEXT PRIMARY KEY,bytes INTEGER NOT NULL,created_ts INTEGER NOT NULL,complete INTEGER NOT NULL DEFAULT 0)",
      "CREATE TABLE IF NOT EXISTS ax_probe_chunks(hash TEXT NOT NULL,ordinal INTEGER NOT NULL,text TEXT NOT NULL,PRIMARY KEY(hash,ordinal)) WITHOUT ROWID",
      "CREATE TABLE IF NOT EXISTS ax_probe_refs(attempt_row INTEGER NOT NULL,hash TEXT NOT NULL,PRIMARY KEY(attempt_row,hash)) WITHOUT ROWID",
      "CREATE INDEX IF NOT EXISTS ax_probe_ref_hash ON ax_probe_refs(hash)",
      "CREATE TABLE IF NOT EXISTS ax_probe_parts(attempt_row INTEGER NOT NULL,ordinal INTEGER NOT NULL,hash TEXT NOT NULL,PRIMARY KEY(attempt_row,ordinal)) WITHOUT ROWID",
      """
      CREATE TRIGGER IF NOT EXISTS ax_probe_content_delete AFTER DELETE ON ax_probe_attempts BEGIN
        DELETE FROM ax_probe_parts WHERE attempt_row=OLD.id;
        DELETE FROM ax_probe_refs WHERE attempt_row=OLD.id;
      END
      """,
      """
      CREATE TRIGGER IF NOT EXISTS ax_probe_unref AFTER DELETE ON ax_probe_refs BEGIN
        DELETE FROM ax_probe_blobs WHERE hash=OLD.hash AND NOT EXISTS(SELECT 1 FROM ax_probe_refs WHERE hash=OLD.hash);
      END
      """,
      """
      CREATE TRIGGER IF NOT EXISTS ax_probe_blob_delete AFTER DELETE ON ax_probe_blobs BEGIN
        DELETE FROM ax_probe_chunks WHERE hash=OLD.hash;
      END
      """,
      """
      CREATE TRIGGER IF NOT EXISTS ax_probe_content_refused AFTER UPDATE OF payload ON ax_probe_attempts
      WHEN json_extract(NEW.payload,'$.ax.status')='policyRefused' BEGIN
        DELETE FROM ax_probe_parts WHERE attempt_row=NEW.id;
        DELETE FROM ax_probe_refs WHERE attempt_row=NEW.id;
      END
      """,
    ] { try run(sql) }
  }
}

extension ActivityStorage {
  func probeWriteAllowed(_ pair: AXProbePair, at now: Int) throws -> Bool {
    let settings = try self.settings()
    guard let run = settings.axProbeRun, run.id == pair.runID else { return false }
    let request = AXProbeRequest(run: run, attemptID: pair.attemptID, time: pair.time,
      window: WindowIdentity(processID: 0, windowID: 0), bundleID: pair.bundleID, isBrowser: false)
    return try axProbeAllowed(request, at: now) && pair.time >= now - settings.screenRetentionDays * 86400
  }

  /// Small transactions bound writer contention. Every chunk is attached to an extant attempt,
  /// so forget/retention cascades erase partial writes too, including interrupted processes.
  func writeAXProbeContent(_ pair: AXProbePair, evidenceID: Int?, at now: Int, permitted: () -> Bool) throws -> Bool {
    guard AXProbeResources.bytes(pair) <= AXProbeResources.attemptBytes else {
      try countAXProbeOverload(AXProbeReceipt(pair)); return false
    }
    var header = pair
    header.ax.nodes = []; header.ax.text = ""; header.ocr = ""
    // Timing belongs to the attempt header so unchanged node metadata keeps deduplicating.
    var latencies: [Int] = [], latencyCount = 0, random: UInt64 = 1
    for node in pair.ax.nodes ?? [] {
      guard let seconds = node.readSeconds, seconds.isFinite, seconds >= 0, seconds <= 16 else { continue }
      let microseconds = Int((seconds * 1e6).rounded())
      latencyCount += 1
      if latencies.count < 4096 { latencies.append(microseconds) }
      else {
        random = random &* 6364136223846793005 &+ 1442695040888963407
        let index = Int(random % UInt64(latencyCount))
        if index < 4096 { latencies[index] = microseconds }
      }
    }
    header.ax.nodeReadMicroseconds = latencies.isEmpty ? nil : latencies
    header.ax.nodeReadCount = latencyCount == 0 ? nil : latencyCount
    header.bundleID = probeHash(pair.bundleID.lowercased())
    header.ax.identity = Redaction.apply(pair.ax.identity).text
    // Free-form diagnostics supplied by a provider must never become JSON keys or statuses.
    header.ax.counts = pair.ax.counts.filter { key, _ in
      ["secure_fields", "messaging_failures", "cooldowns", "invalid_element", "unresolved_children", "repeated_reference", "visible_range_incomplete", "overload_dropped",
       "resource_truncated_original_utf16", "resource_length_sum_overflow", "manual_accessibility_set", "manual_accessibility_not_settable", "manual_accessibility_failed"].contains(key)
        || ["elementLimit", "depthLimit", "deadline", "messagingFailure", "resource_truncated"].contains(String(key.dropFirst("truncation_".count))) && key.hasPrefix("truncation_")
    }
    header.ax.manualAccessibility = ["set", "not_settable", "failed"].contains(pair.ax.manualAccessibility ?? "") ? pair.ax.manualAccessibility : nil
    header.ax.truncations = pair.ax.truncations?.filter { ["elementLimit", "depthLimit", "deadline", "watchdog", "messagingFailure", "resource_truncated"].contains($0.key) }
    header.ocrStatus = ["pending", "completed", "empty", "failed", "busy", "superseded", "policy_refused", "settings_unreadable", "not_acquired", "acquired_without_snapshot"].contains(pair.ocrStatus) ? pair.ocrStatus : "unknown"
    var row = 0
    var pending = header; pending.ax.status = .pending
    let initial = String(decoding: try JSONEncoder().encode(pending), as: UTF8.self)
    guard permitted() else { try refuseAXProbeOpportunity(runID: pair.runID, attemptID: pair.attemptID); return false }
    try connection.transaction {
      guard try probeWriteAllowed(pair, at: now) else { return }
      if let evidenceID {
        guard try connection.integer("SELECT count(*) FROM evidence WHERE id=? AND kind='screen' AND ts=?", [.integer(evidenceID), .integer(pair.time)]) == 1 else { return }
      }
      try connection.run("INSERT OR IGNORE INTO ax_probe_attempts(run_id,attempt_id,ts,mapping_key,evidence_id,payload) VALUES(?,?,?,?,?,?)",
        [.key(pair.runID), .key(pair.attemptID), .integer(pair.time), .key(header.bundleID), evidenceID.map(SQLValue.integer) ?? .null, .maskedText(initial)])
      row = try connection.integer("SELECT id FROM ax_probe_attempts WHERE run_id=? AND attempt_id=? AND ts=? AND json_extract(payload,'$.ax.status')='pending'",
        [.key(pair.runID), .key(pair.attemptID), .integer(pair.time)])
    }
    guard row > 0 else { return false }
    let identity: [SQLValue] = [.integer(row), .key(pair.runID), .key(pair.attemptID), .integer(pair.time)]
    let original = "id=? AND run_id=? AND attempt_id=? AND ts=?"
    var finished = false
    defer {
      if !finished {
        try? connection.transaction {
          // SQLite can reuse a forgotten row ID for a kept attempt.
          guard try connection.integer("SELECT count(*) FROM ax_probe_attempts WHERE \(original)", identity) == 1 else { return }
          try terminalizeAXProbe(runID: pair.runID, attemptID: pair.attemptID)
          try connection.run("DELETE FROM ax_probe_parts WHERE attempt_row=?", [.integer(row)])
          try connection.run("DELETE FROM ax_probe_refs WHERE attempt_row=?", [.integer(row)])
        }
      }
    }
    func batch(_ body: () throws -> Void) throws {
      // No recorder lock is held during preparation or these bounded writes.
      guard permitted() else { throw StorageError("Probe generation or capture policy changed") }
      try connection.transaction {
        guard try probeWriteAllowed(pair, at: now),
          try connection.integer("SELECT count(*) FROM ax_probe_attempts WHERE \(original) AND json_extract(payload,'$.ax.status')='pending'", identity) == 1
          else { throw StorageError("Probe run, policy or forget barrier changed") }
        try body()
        guard permitted(), try probeWriteAllowed(pair, at: now) else { throw StorageError("Probe commit barrier changed") }
      }
    }
    var referenced = Set<String>()
    func blob(_ text: String) throws -> String {
      let hash = probeHash(text)
      guard referenced.insert(hash).inserted else { return hash }
      var complete = false
      try batch {
        try connection.run("INSERT OR IGNORE INTO ax_probe_blobs(hash,bytes,created_ts) VALUES(?,?,?)", [.key(hash), .integer(text.utf8.count), .integer(pair.time)])
        try connection.run("INSERT OR IGNORE INTO ax_probe_refs(attempt_row,hash) VALUES(?,?)", [.integer(row), .key(hash)])
        complete = try connection.integer("SELECT complete FROM ax_probe_blobs WHERE hash=?", [.key(hash)]) == 1
      }
      if !complete {
        var start = text.unicodeScalars.startIndex, ordinal = 0
        while start < text.unicodeScalars.endIndex {
          var end = start, bytes = 0
          while end < text.unicodeScalars.endIndex {
            let scalar = text.unicodeScalars[end]
            let size = scalar.utf8.count
            if bytes + size > AXProbeResources.chunkBytes { break }
            bytes += size; text.unicodeScalars.formIndex(after: &end)
          }
          let chunk = String(text.unicodeScalars[start..<end])
          try batch { try connection.run("INSERT OR IGNORE INTO ax_probe_chunks(hash,ordinal,text) VALUES(?,?,?)", [.key(hash), .integer(ordinal), .maskedText(chunk)]) }
          start = end; ordinal += 1
        }
        try batch { try connection.run("UPDATE ax_probe_blobs SET complete=1 WHERE hash=?", [.key(hash)]) }
      }
      return hash
    }
    // This transient cache shares raw String storage and retains only small masked receipts.
    // Repeated parent aggregates are masked once, without retaining another full masked aggregate.
    var cache: [String: (String, Int, Int, [String: Int])] = [:]
    func masked(_ raw: String) throws -> (String, Int, Int, [String: Int]) {
      if let found = cache[raw] { return found }
      guard raw.utf16.count <= AXProbeResources.stringUTF16 else {
        header.ax.truncated = true; header.ax.truncations = header.ax.truncations ?? [:]
        header.ax.truncations?["resource_truncated", default: 0] += 1
        header.ax.counts["resource_truncated_original_utf16", default: 0] += raw.utf16.count
        return (try blob(""), 0, 0, [:])
      }
      let value = AXProbeText(attribute: "", text: raw).redacted()
      let result = (try blob(value.text), value.length, value.text.utf8.count, value.maskHits)
      cache[raw] = result; return result
    }
    let ocr = try masked(pair.ocr)
    header.ocrScalars = ocr.1; header.ocrBytes = ocr.2
    var root: [String: Any] = ["storageVersion": 3, "ocrRef": ocr.0]
    var part: [[String: Any]] = [], ordinal = 0
    func savePart() throws {
      guard !part.isEmpty else { return }
      let encoded = String(decoding: try JSONSerialization.data(withJSONObject: part, options: [.sortedKeys]), as: UTF8.self)
      let hash = try blob(encoded)
      try batch { try connection.run("INSERT OR REPLACE INTO ax_probe_parts(attempt_row,ordinal,hash) VALUES(?,?,?)", [.integer(row), .integer(ordinal), .key(hash)]) }
      ordinal += 1; part.removeAll(keepingCapacity: true)
    }
    if let nodes = pair.ax.nodes {
      header.axBytes = 0; header.axScalars = 0
      for node in nodes {
        var n = node; n.attributes = []; n.readSeconds = nil
        n.secure = node.secure || node.role == "AXSecureTextField" || node.subrole == "AXSecureTextField"
        n.role = nil; n.subrole = nil; n.bundleID = nil
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(n)) as! [String: Any]
        if let role = node.role { object["roleRef"] = try masked(role).0 }
        if let subrole = node.subrole { object["subroleRef"] = try masked(subrole).0 }
        if let bundleID = node.bundleID { object["bundleIDRef"] = try masked(bundleID).0 }
        var attributes: [[String: Any]] = []
        for attribute in node.attributes {
          if n.secure && ["AXValue", "AXSelectedText", "AXStringForVisibleRange"].contains(attribute.attribute) { continue }
          let value = try masked(attribute.text)
          var a: [String: Any] = ["attributeRef": try masked(attribute.attribute).0, "textRef": value.0, "length": value.1, "maskHits": value.3]
          if let length = attribute.originalLength { a["originalLength"] = length; a["resourceTruncated"] = true }
          if attribute.text.utf16.count > AXProbeResources.stringUTF16 { a["originalLength"] = attribute.text.utf16.count; a["resourceTruncated"] = true }
          attributes.append(a); header.axScalars += value.1; header.axBytes += value.2
        }
        object["attributes"] = attributes; part.append(object)
        if part.count == 16 { try savePart() }
      }
      try savePart()
    } else {
      let text = try masked(pair.ax.text); root["axTextRef"] = text.0
      header.axScalars = text.1; header.axBytes = text.2
    }
    var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(header)) as! [String: Any]
    for (key, value) in root { object[key] = value }
    let payload = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    try batch {
      try connection.run("UPDATE ax_probe_attempts SET payload=?,evidence_id=? WHERE \(original)", [.maskedText(payload), evidenceID.map(SQLValue.integer) ?? .null] + identity)
    }
    finished = true; return true
  }

  public func recordAXProbePersistenceFailure(_ receipt: AXProbeReceipt) throws {
    try locked {
      let key = "\(receipt.runID)|\(receipt.attemptID)|\(receipt.time)"
      axProbePersistenceFailures[key] = receipt
      try flushAXProbePersistenceFailures()
    }
  }
  func flushAXProbePersistenceFailures() throws {
    guard !axProbePersistenceFailures.isEmpty else { return }
    try connection.transaction {
      for receipt in axProbePersistenceFailures.values {
        try countAXProbeEvent(runID: receipt.runID, event: .finishStorageFailures, amount: 1)
        let identity: [SQLValue] = [.key(receipt.runID), .key(receipt.attemptID), .integer(receipt.time)]
        try connection.run("""
          UPDATE ax_probe_attempts SET evidence_id=NULL,payload=json_set(payload,'$.ax.status','storage_failed')
          WHERE run_id=? AND attempt_id=? AND ts=? AND json_extract(payload,'$.ax.status')='pending'
          """, identity)

      }
    }
    axProbePersistenceFailures.removeAll()
  }

  public func countAXProbeOverload(_ receipt: AXProbeReceipt) throws {
    try locked {
      axProbeOverloadTotals[receipt.runID, default: 0] += 1
      // All drops remain counted even if per-attempt retry receipts reach this small bound.
      if axProbeOverloadAttempts.count < RecorderTiming.pendingCaptures { axProbeOverloadAttempts[receipt.attemptID] = receipt.runID }
      try flushAXProbeOverloads()
    }
  }
  func flushAXProbeOverloads() throws {
    guard !axProbeOverloadTotals.isEmpty else { return }
    try connection.transaction {
      for (run, total) in axProbeOverloadTotals {
        try countAXProbeEvent(runID: run, event: .overload_dropped, amount: total)
      }
      for (attempt, run) in axProbeOverloadAttempts {
        try connection.run("UPDATE ax_probe_attempts SET payload=json_set(payload,'$.ax.status','overload_dropped') WHERE run_id=? AND attempt_id=? AND json_extract(payload,'$.ax.status')='pending'",
          [.key(run), .key(attempt)])
      }
    }
    axProbeOverloadTotals.removeAll(); axProbeOverloadAttempts.removeAll()
  }

  func probeStorageBytes(since: Int?) throws -> Int {
    let condition = since == nil ? "" : " WHERE ts>=?"
    let values = since.map { [SQLValue.integer($0)] } ?? []
    let attempts = try connection.integer("SELECT COALESCE(SUM(length(CAST(payload AS BLOB))+length(mapping_key)+length(run_id)+length(attempt_id)+32),0) FROM ax_probe_attempts" + condition, values)
    guard try connection.integer("SELECT count(*) FROM sqlite_master WHERE name='ax_probe_blobs'") == 1 else { return attempts }
    let refs = try connection.integer("SELECT count(*) FROM ax_probe_refs WHERE attempt_row IN (SELECT id FROM ax_probe_attempts" + condition + ")", values)
    let parts = try connection.integer("SELECT count(*) FROM ax_probe_parts WHERE attempt_row IN (SELECT id FROM ax_probe_attempts" + condition + ")", values)
    let blobs = try connection.integer("SELECT COALESCE(SUM(bytes+80),0) FROM ax_probe_blobs" + (since == nil ? "" : " WHERE created_ts>=?"), values)
    return attempts + (refs + parts) * 80 + blobs
  }
}

extension ActivityStorage {
  func digestAXProbeContent(attempts: String, values: [SQLValue], into digest: inout SHA256) throws {
    guard try connection.integer("SELECT count(*) FROM sqlite_master WHERE name='ax_probe_blobs'") == 1 else { return }
    let selected = "attempt_row IN (\(attempts))"
    let reachable = "SELECT hash FROM ax_probe_refs WHERE \(selected) UNION SELECT hash FROM ax_probe_parts WHERE \(selected)"
    for (table, selection, ordering, bindings) in [
      ("ax_probe_refs", selected, "attempt_row,hash", values),
      ("ax_probe_parts", selected, "attempt_row,ordinal", values),
      ("ax_probe_blobs", "hash IN (\(reachable))", "hash", values + values),
      ("ax_probe_chunks", "hash IN (\(reachable))", "hash,ordinal", values + values),
    ] {
      digest.update(data: Data(table.utf8))
      try connection.rows("SELECT * FROM \(table) WHERE \(selection) ORDER BY \(ordering)", bindings) { row in
        for column in 0..<sqlite3_column_count(row) {
          let size = sqlite3_column_bytes(row, column)
          digest.update(data: Data("|\(sqlite3_column_type(row, column)):\(size):".utf8))
          if let bytes = sqlite3_column_blob(row, column), size > 0 {
            digest.update(data: Data(bytes: bytes, count: Int(size)))
          }
        }
        digest.update(data: Data(";".utf8))
      }
    }
  }
}
