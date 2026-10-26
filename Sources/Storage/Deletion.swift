import Core
import CryptoKit
import Darwin
import Foundation
import SQLite3

extension ActivityStorage {
  private func validateDeletion(_ range: TimeRange, allowOver24Hours: Bool) throws {
    let (duration, overflow) = range.end.subtractingReportingOverflow(range.start)
    guard !overflow, duration > 0 else { throw StorageError("Start must be before end") }
    guard duration <= 86400 || allowOver24Hours else {
      throw StorageError("Ranges over 24 hours require explicit allowance")
    }
  }
  private var deletionSelections: [(String, String)] {
    let modernObservations = (try? connection.integer("SELECT count(*) FROM sqlite_master WHERE name='collection_legacy_times'")) == 1
    let selections = [
      ("samples", "ts>=? AND ts<?"),
      ("sample_observations", modernObservations ? "ts>=?1 AND ts<?2 OR observed_ts>=?1 AND observed_ts<?2 OR id IN (SELECT observation_row FROM collection_legacy_times WHERE ts>=?1 AND ts<?2)" : "ts>=? AND ts<?"),
      ("input_batches", "ts>=? AND ts<?"),
      ("collection_metadata", "ts>=? AND ts<?"),
      ("collection_legacy_times", "ts>=? AND ts<?"),
      ("ax_probe_review", "attempt_row IN (SELECT id FROM ax_probe_attempts WHERE ts>=? AND ts<?)"),
      ("ax_probe_attempts", "ts>=? AND ts<?"),
      ("evidence", "ts>=? AND ts<?"),
      ("agent_log_events", "ts>=? AND ts<?"),
      ("intervals", "end_ts>? AND start_ts<?"),
      ("model_calls", "pending=1 AND end_ts>? AND start_ts<?"),
    ]
    // A read-only preview can precede the first version-6 migration.
    return selections.filter { table, _ in
      !(table.hasPrefix("ax_probe_") || table.hasPrefix("agent_log_") || ["sample_observations", "input_batches", "collection_legacy_times", "collection_metadata"].contains(table)) || (try? connection.integer(
        "SELECT count(*) FROM sqlite_master WHERE type='table' AND name=?", [.key(table)])) != 0
    }
  }
  private func selectionValues(_ range: TimeRange) -> [SQLValue] {
    [.integer(range.start), .integer(range.end)]
  }
  private func snapshotDeletion(_ range: TimeRange, journal: ModelCallJournal) throws -> DeletionPreview {
    var info = stat()
    guard stat(url.path, &info) == 0 else { throw StorageError("Database file disappeared") }
    // SQLite's file descriptor is private; remember the file identity for the storage lifetime.
    guard let identity = openedIdentity, identity == [UInt64(info.st_dev), UInt64(info.st_ino)] else {
      throw StorageError("Database file was replaced; reopen and request a new preview")
    }
    var digest = SHA256()
    digest.update(
      data: Data(
        "delete-v1|\(try FileLocation.key(url))|\(info.st_dev)|\(info.st_ino)|\(range.start)|\(range.end)".utf8
      ))
    var counts: [String: Int] = [:]
    for (table, selection) in deletionSelections {
      digest.update(data: Data(table.utf8))
      var count = 0
      try connection.rows("SELECT * FROM \(table) WHERE \(selection) ORDER BY id", selectionValues(range)) { s in
        count += 1
        for column in 0..<sqlite3_column_count(s) {
          let type = sqlite3_column_type(s, column)
          let size = sqlite3_column_bytes(s, column)
          digest.update(data: Data("|\(type):\(size):".utf8))
          if let bytes = sqlite3_column_blob(s, column), size > 0 {
            digest.update(data: Data(bytes: bytes, count: Int(size)))
          }
        }
        digest.update(data: Data(";".utf8))
      }
      if table != "model_calls" || count > 0 { counts[table] = count }
    }
    if try connection.integer("SELECT count(*) FROM sqlite_master WHERE name='agent_log_events'") > 0 {
      for query in [
        "SELECT p.payload FROM agent_log_payloads p WHERE p.id IN (SELECT payload_id FROM agent_log_events WHERE ts>=? AND ts<?) ORDER BY p.id",
        "SELECT i.identity FROM agent_log_event_identities i JOIN agent_log_events e ON e.id=i.event_id WHERE e.ts>=? AND e.ts<? ORDER BY e.id,i.identity",
      ] {
        try connection.rows(query, selectionValues(range)) { row in
          let value = SQLiteConnection.text(row, 0)
          digest.update(data: Data("|\(value.utf8.count):".utf8))
          digest.update(data: Data(value.utf8))
        }
      }
    }
    for (table, tag) in [("agent_log_event_sessions", "session"), ("agent_log_inherited_sessions", "inherited-session")] {
      if try connection.integer("SELECT count(*) FROM sqlite_master WHERE name IN (?, 'agent_log_events')", [.key(table)]) == 2 {
        try connection.namedRows("""
          SELECT s.event_id,s.tool,s.session_id FROM \(table) s JOIN agent_log_events e ON e.id=s.event_id
          WHERE e.ts>=? AND e.ts<? ORDER BY s.event_id
          """, selectionValues(range)) { row in
          for value in [String(try row.int("event_id")), try row.text("tool"), try row.text("session_id")] {
            digest.update(data: Data("|\(tag):\(value.utf8.count):".utf8))
            digest.update(data: Data(value.utf8))
          }
        }
      }
    }
    try legacyLogAdapter.visitDeletionProofs(range) { tag, value in
      digest.update(data: Data("|\(tag):\(value.utf8.count):".utf8))
      digest.update(data: Data(value.utf8))
    }
    try resolveDeletionIdentities(range)
    // Hash the exact reachable relationship snapshot used to create permanent tombstones.
    if let relation = try logLineageRelation() {
      try connection.namedRows("""
        SELECT a.alias,a.canonical FROM \(relation) a
        JOIN log_identity_component c ON c.identity=a.alias ORDER BY a.alias,a.canonical
        """) { row in
        for value in [try row.text("alias"), try row.text("canonical")] {
          digest.update(data: Data("|lineage:\(value.utf8.count):".utf8))
          digest.update(data: Data(value.utf8))
        }
      }
    }
    if try connection.integer("SELECT count(*) FROM sqlite_master WHERE type='table' AND name='screen_payloads'") > 0 {
      try digestCollectionRows("SELECT * FROM screen_payloads WHERE evidence_id IN (SELECT id FROM evidence WHERE ts>=? AND ts<?) ORDER BY evidence_id", values: selectionValues(range), into: &digest)

    }
    if try connection.integer("SELECT count(*) FROM sqlite_master WHERE name='collection_blobs'") > 0 {
      try connection.namedRows("""
        SELECT hash,content FROM collection_blobs WHERE hash IN (
          SELECT text_hash FROM screen_payloads WHERE evidence_id IN (SELECT id FROM evidence WHERE ts>=?1 AND ts<?2)
          UNION SELECT payload_hash FROM screen_payloads WHERE evidence_id IN (SELECT id FROM evidence WHERE ts>=?1 AND ts<?2)) ORDER BY hash
        """, selectionValues(range)) {
        digest.update(data: Data("blob:\(try $0.text("hash")):\(try $0.text("content"))".utf8))
      }
    }
    counts["sample_metadata"] = try digestSampleMetadata(in: range, into: &digest)
    counts["screen_metadata"] = try digestScreenMetadata(in: range, into: &digest)
    counts["staged_collection"] = try digestStagedCollection(in: range, into: &digest)
    try digestAXProbeContent(attempts: "SELECT id FROM ax_probe_attempts WHERE ts>=? AND ts<?",
      values: selectionValues(range), into: &digest)
    if let (call, bytes) = try journal.read(), call.range.start < range.end && call.range.end > range.start {
      digest.update(data: Data("pending-accounting".utf8)); digest.update(data: bytes)
      if try connection.integer("SELECT count(*) FROM model_calls WHERE attempt_id=?", [.key(call.attemptID!)]) == 0 {
        counts["model_calls", default: 0] += 1
      }
    }
    var extent: TimeRange?
    try connection.namedRows(
      "SELECT MIN(start_ts) AS start_ts,MAX(end_ts) AS end_ts FROM intervals WHERE end_ts>? AND start_ts<?",
      [.integer(range.start), .integer(range.end)]
    ) {
      if case .integer = try $0.value("start_ts") {
        extent = TimeRange(try $0.int("start_ts"), try $0.int("end_ts"))
      }
    }
    return DeletionPreview(
      range: range, counts: counts, confirmation: digest.finalize().map { String(format: "%02x", $0) }.joined(),
      intervalExtent: extent)
  }
  private struct DeletionCallState: Equatable {
    let id: Int
    let billing: [Data]
    var facts: Data?
  }

  private func deletionCallState(ids: Set<Int>? = nil) throws -> [DeletionCallState] {
    if let ids, ids.isEmpty { return [] }
    let selection = ids.map { " WHERE id IN (" + $0.sorted().map(String.init).joined(separator: ",") + ")" } ?? ""
    var calls: [DeletionCallState] = []
    try connection.rows("""
      SELECT id,ts,start_ts,end_ts,model,input_tokens,cached_tokens,output_tokens,succeeded,table_facts,pending,attempt_id
      FROM model_calls\(selection) ORDER BY id
      """) { row in
      // Preserve the bytes and SQLite types of every billing field and outer boundary.
      let billing = (Array(Int32(0)..<9) + [10, 11]).map { column -> Data in
        var value = Data([UInt8(sqlite3_column_type(row, column))])
        if let bytes = sqlite3_column_blob(row, column) {
          value.append(Data(bytes: bytes, count: Int(sqlite3_column_bytes(row, column))))
        }
        return value
      }
      var facts: Data?
      if sqlite3_column_type(row, 9) != SQLITE_NULL {
        facts = sqlite3_column_blob(row, 9).map { Data(bytes: $0, count: Int(sqlite3_column_bytes(row, 9))) } ?? Data()
      }
      calls.append(DeletionCallState(id: SQLiteConnection.int(row, 0), billing: billing, facts: facts))
    }
    return calls
  }

  private func factsAfterDeletion(_ bytes: Data?, in range: TimeRange) throws -> Data? {
    guard let bytes else { return nil }
    // Unreadable facts cannot prove that the deleted activity layout is gone.
    guard var facts = try? JSONDecoder().decode(SummaryCallFacts.self, from: bytes) else { return nil }
    let original = facts
    facts.sentRanges = facts.sentRanges.flatMap { span -> [TimeRange] in
      guard span.start < range.end && span.end > range.start else { return [span] }
      var remaining: [TimeRange] = []
      if span.start < range.start { remaining.append(TimeRange(span.start, range.start)) }
      if span.end > range.end { remaining.append(TimeRange(range.end, span.end)) }
      return remaining
    }
    let overlaps: (Int) -> Bool = { minute in
      let (end, overflow) = minute.addingReportingOverflow(60)
      return minute < range.end && (overflow || end > range.start)
    }
    facts.activeMinutes.removeAll(where: overlaps)
    facts.restMinutes.removeAll(where: overlaps)
    return facts == original ? bytes : try JSONEncoder().encode(facts)
  }

  private func verifyDeletionEndState(
    in range: TimeRange, expectedCalls: [DeletionCallState]
  ) throws {
    try legacyLogAdapter.verifyRefusals()
    // Check after all writes, so later triggers cannot undo an earlier erasure or marker.
    for (table, selection) in deletionSelections {
      guard try connection.integer("SELECT EXISTS(SELECT 1 FROM \(table) WHERE \(selection))", selectionValues(range)) == 0
      else { throw StorageError("Deleted records remain") }
    }
    guard try deletionCallState() == expectedCalls else {
      throw StorageError("Deletion call facts or billing differ")
    }
    guard try connection.integer(
      "SELECT EXISTS(SELECT 1 FROM forgotten_ranges WHERE start_ts=? AND end_ts=?)", selectionValues(range)) == 1
    else { throw StorageError("Deletion range marker missing") }
    guard try connection.integer("""
      SELECT EXISTS(SELECT 1 FROM log_deletion_identities c
        WHERE NOT EXISTS(SELECT 1 FROM forgotten_sources f WHERE f.source_id=c.identity AND f.source=c.source))
      """) == 0 else { throw StorageError("Deletion source marker missing") }
  }

  public func previewDeletion(in range: TimeRange, allowOver24Hours: Bool = false) throws -> DeletionPreview {
    try validateDeletion(range, allowOver24Hours: allowOver24Hours)
    return try locked {
      let journal = try ModelCallJournal(database: url)
      return try journal.withAccountingLock { try connection.transaction(write: false) { try snapshotDeletion(range, journal: journal) } }
    }
  }
  @discardableResult public func deleteRecords(
    in range: TimeRange, confirmation: String, allowOver24Hours: Bool = false
  ) throws -> DeletionResult {
    try validateDeletion(range, allowOver24Hours: allowOver24Hours)
    return try locked {
      let journal = try ModelCallJournal(database: url)
      return try journal.withMaintenanceLock(connection) {
        let result = try connection.transaction(collectionMaintenance: true) {
          try requireAXProbeReviewClosed()
          let preview = try snapshotDeletion(range, journal: journal)
          guard preview.confirmation == confirmation else { throw StorageError("Records changed; request a new preview") }
          try resolveDeletionIdentities(range)
          try connection.run("""
            INSERT OR IGNORE INTO forgotten_sources(source,source_id)
            SELECT source,identity FROM log_deletion_identities
            """)
          try legacyLogAdapter.refuseEvidence(in: range)
          try connection.run("""
            INSERT OR IGNORE INTO agent_log_refusals
            SELECT tool,device,inode,byte_offset,'forgotten' FROM agent_log_events WHERE ts>=? AND ts<?
            """, selectionValues(range))
          let childIDs = try collectionPayloadIDs(in: range)
          var observationIDs: [CollectionErasureTarget] = []
          if let (_, selection) = deletionSelections.first(where: { $0.0 == "sample_observations" }) {
            try connection.namedRows("SELECT id,observation_id,ts FROM sample_observations WHERE (\(selection)) AND ts>=?1 AND ts<?2", selectionValues(range)) {
              observationIDs.append(CollectionErasureTarget(row: try $0.int("id"), identity: try $0.optionalText("observation_id"), time: try $0.int("ts")))
            }
          }
          let originalCalls = try deletionCallState()
          var removedCalls = Set<Int>()
          try connection.namedRows("SELECT id FROM model_calls WHERE pending=1 AND end_ts>? AND start_ts<?", selectionValues(range)) {
            removedCalls.insert(try $0.int("id"))
          }
          let retainedCalls = originalCalls.filter { !removedCalls.contains($0.id) }
          var expectedCalls = retainedCalls
          for index in expectedCalls.indices {
            expectedCalls[index].facts = try factsAfterDeletion(expectedCalls[index].facts, in: range)
          }
          // Capture billing/fact expectations before the early progress marker.
          // Only changed call identities are reread at each batch boundary.
          var expectedAtCheckpoint = Dictionary(uniqueKeysWithValues: originalCalls.map { ($0.id, $0) })
          var changedCalls = Set<Int>()
          connection.collectionPrivacyChangeObserver = { table, row in
            if table == "model_calls" { changedCalls.insert(Int(row)) }
          }
          let progressID = try connection.integer("SELECT COALESCE(MAX(rowid),0)+1 FROM forgotten_ranges")
          let markerValues: [SQLValue] = [.integer(progressID)] + selectionValues(range)
          try connection.run("INSERT INTO forgotten_ranges(rowid,start_ts,end_ts) VALUES(?,?,?)", markerValues)
          connection.collectionPrivacyProgressProof = { [unowned self] in
            try self.requireAXProbeReviewClosed()
            guard try self.connection.integer("SELECT EXISTS(SELECT 1 FROM forgotten_ranges WHERE rowid=? AND start_ts=? AND end_ts=?)", markerValues) == 1 else { throw StorageError("Deletion progress marker missing") }
            let expected = changedCalls.compactMap { expectedAtCheckpoint[$0] }.sorted { $0.id < $1.id }
            guard try self.deletionCallState(ids: changedCalls) == expected else { throw StorageError("Deletion batch changed call facts or billing") }
            changedCalls.removeAll(keepingCapacity: true)
          }
          try connection.enableCollectionMaintenanceBatches()
          try preserveCollectionMetadata(in: range)
          let scrubbedObservations = try scrubObservationMetadata(in: range)
          for (table, selection) in deletionSelections {
            try connection.collectionWrite("DELETE FROM \(table) WHERE \(selection)", selectionValues(range))
            if table == "model_calls" {
              changedCalls.formUnion(removedCalls)
              expectedAtCheckpoint = Dictionary(uniqueKeysWithValues: retainedCalls.map { ($0.id, $0) })
            }
          }
          let expectedSampleMetadata = try scrubSampleMetadata(ids: sampleMetadataTargets(in: range))
          let expectedMetadata = try scrubScreenMetadata(ids: screenMetadataTargets(in: range))
          for (original, expected) in zip(retainedCalls, expectedCalls) where original.facts != expected.facts {
            let value = expected.facts.map { SQLValue.maskedText(String(decoding: $0, as: UTF8.self)) } ?? .null
            try connection.run("UPDATE model_calls SET table_facts=? WHERE id=?", [value, .integer(expected.id)])
            expectedAtCheckpoint[expected.id] = expected; changedCalls.insert(expected.id)
          }
          // Refresh the progress marker after the last planned writes. Removing
          // and reinserting this operation's row is atomic within the final batch.
          try connection.run("DELETE FROM forgotten_ranges WHERE rowid=?", [.integer(progressID)])
          try connection.run("INSERT INTO forgotten_ranges(rowid,start_ts,end_ts) VALUES(?,?,?)", markerValues)
          try verifyScrubbedObservationMetadata(count: scrubbedObservations)
          try verifySampleMetadataErasure(expectedSampleMetadata)
          try verifyScreenMetadataErasure(expectedMetadata)
          try verifyCollectionErasure(ids: childIDs, observationIDs: observationIDs)
          try verifyDeletionEndState(in: range, expectedCalls: expectedCalls)
          return preview
        }
        if let (call, _) = try journal.read(), call.range.start < range.end && call.range.end > range.start {
          try journal.clear()
        }
        try eraseStagedCollection(in: range)
        // A reader snapshot can delay truncation; deletion itself has already committed.
        return DeletionResult(preview: result, walTruncated: connection.truncateWAL())
      }
    }
  }
}
