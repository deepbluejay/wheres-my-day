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
    let selections = [
      ("samples", "ts>=? AND ts<?"),
      ("ax_probe_review", "attempt_row IN (SELECT id FROM ax_probe_attempts WHERE ts>=? AND ts<?)"),
      ("ax_probe_attempts", "ts>=? AND ts<?"),
      ("evidence", "ts>=? AND ts<?"),
      ("intervals", "end_ts>? AND start_ts<?"),
      ("model_calls", "pending=1 AND end_ts>? AND start_ts<?"),
    ]
    // A read-only preview can precede the first version-6 migration.
    return selections.filter { table, _ in
      !table.hasPrefix("ax_probe_") || (try? connection.integer(
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

  private func deletionCallState() throws -> [DeletionCallState] {
    var calls: [DeletionCallState] = []
    try connection.rows("""
      SELECT id,ts,start_ts,end_ts,model,input_tokens,cached_tokens,output_tokens,succeeded,table_facts,pending,attempt_id
      FROM model_calls ORDER BY id
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
    in range: TimeRange, identities: [(String, String)], expectedCalls: [DeletionCallState]
  ) throws {
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
    for (source, id) in identities {
      guard try connection.integer(
        "SELECT EXISTS(SELECT 1 FROM forgotten_sources WHERE source=? AND source_id=?)", [.key(source), .key(id)]) == 1
      else { throw StorageError("Deletion source marker missing") }
    }
  }

  public func previewDeletion(in range: TimeRange, allowOver24Hours: Bool = false) throws -> DeletionPreview {
    try validateDeletion(range, allowOver24Hours: allowOver24Hours)
    return try locked {
      let journal = try ModelCallJournal(database: url)
      return try journal.withLock { try connection.transaction(write: false) { try snapshotDeletion(range, journal: journal) } }
    }
  }
  @discardableResult public func deleteRecords(
    in range: TimeRange, confirmation: String, allowOver24Hours: Bool = false
  ) throws -> DeletionResult {
    try validateDeletion(range, allowOver24Hours: allowOver24Hours)
    return try locked {
      let journal = try ModelCallJournal(database: url)
      return try journal.withLock {
        let result = try connection.transaction {
          try requireAXProbeReviewClosed()
          let preview = try snapshotDeletion(range, journal: journal)
          guard preview.confirmation == confirmation else { throw StorageError("Records changed; request a new preview") }
          var identities: [(String, String)] = []
          try connection.namedRows(
            "SELECT source,source_id FROM evidence WHERE ts>=? AND ts<? AND source_id IS NOT NULL",
            [.integer(range.start), .integer(range.end)]
          ) {
            identities.append((try $0.text("source"), try $0.text("source_id")))
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
          for (source, id) in identities {
            try connection.run("INSERT OR IGNORE INTO forgotten_sources VALUES(?,?)", [.key(source), .key(id)])
          }
          for (table, selection) in deletionSelections {
            try connection.run("DELETE FROM \(table) WHERE \(selection)", selectionValues(range))
          }
          for (original, expected) in zip(retainedCalls, expectedCalls) where original.facts != expected.facts {
            let value = expected.facts.map { SQLValue.maskedText(String(decoding: $0, as: UTF8.self)) } ?? .null
            try connection.run("UPDATE model_calls SET table_facts=? WHERE id=?", [value, .integer(expected.id)])
          }
          try connection.run("INSERT INTO forgotten_ranges VALUES(?,?)", selectionValues(range))
          try verifyDeletionEndState(in: range, identities: identities, expectedCalls: expectedCalls)
          return preview
        }
        if let (call, _) = try journal.read(), call.range.start < range.end && call.range.end > range.start {
          try journal.clear()
        }
        // A reader snapshot can delay truncation; deletion itself has already committed.
        return DeletionResult(preview: result, walTruncated: connection.truncateWAL())
      }
    }
  }
}
