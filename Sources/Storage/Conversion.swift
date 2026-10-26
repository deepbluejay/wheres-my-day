import Core
import CryptoKit
import Darwin
import Foundation
import SQLite3

public struct ConversionTableCounts: Equatable {
  public var carried = 0
  public var refused = 0
  public var notCarried = 0
}

/// Counts cover this call only. Sum calls across a stopped and resumed conversion to count all source rows.
public struct ConversionResult: Equatable {
  public var tables: [String: ConversionTableCounts] = [:]
  public var skippedEvidenceKinds: [String: Int] = [:]
  public var skippedHiddenEvidence = 0
  public var evidenceKinds: [String: ConversionTableCounts] = [:]
  public var forgottenEvidence = 0
  public var duplicateEvidence = 0
  public var samples = 0
  public var evidence = 0
  public var intervals = 0
  public var shortened = 0
  public var skippedAway = 0
  public var skippedUnknown = 0
  public var skippedEmpty = 0
  public var refusedSamples = 0
  public var refusedEvidence = 0
  public var refusedIntervals = 0
  public var finished = false
}

private enum CarryDisposition { case carried, refused, notCarried }

/// Each old table describes its projection, cursor and carrying rule together.
private struct OldMove {
  let name: String
  var defaults: [(String, String)] = []
  var orderedActivities = false
  var refuse: (inout ConversionResult) -> Void = { _ in }
  let carry: (DatabaseRow, inout ConversionResult) throws -> CarryDisposition

  func nextCursor(after rows: [DatabaseRow], cursor: Int) throws -> Int {
    orderedActivities ? cursor + rows.count : try rows.last!.int("old_row")
  }
}

private struct OldTable {
  let name: String
  let columns: Set<String>
  func column(_ name: String, fallback: String = "''") -> String {
    columns.contains(name) ? name : "\(fallback) AS \(name)"
  }
}

extension ActivityStorage {
  // Old categories outside the seven known names convert to work.
  static let fallbackOldCategory: ActivityKind = .work

  /// At the switch, import one frozen SQLite backup into an empty destination.
  /// Every completed batch commits with its cursor; reruns accept only the same source.
  public func convertOldDatabase(at sourceURL: URL, batchSize: Int = 256, verifyFrozenContent: Bool = false) throws -> ConversionResult {
    try convertOldDatabase(at: sourceURL, batchSize: batchSize, maxBatches: nil, verifyFrozenContent: verifyFrozenContent)
  }

  func convertOldDatabase(at sourceURL: URL, batchSize: Int, maxBatches: Int?, verifyFrozenContent: Bool = false) throws -> ConversionResult {
    guard batchSize > 0, maxBatches.map({ $0 >= 0 }) ?? true else {
      throw StorageError("Invalid conversion batch limit")
    }
    try FileLocation.validate(sourceURL)
    let resolved = OperationalDirectory.systemURL(sourceURL)
    guard try !FileLocation.same(resolved, url) else {
      throw StorageError("Conversion needs a separate destination")
    }
    let source = try SQLiteConnection(url: resolved, readOnly: true, immutable: true, scope: databaseScope)
    guard try source.integer("PRAGMA application_id") != SQLiteConnection.applicationID else {
      throw StorageError("Source is already a new database")
    }
    var info = stat()
    guard stat(resolved.path, &info) == 0 else { throw StorageError("Source file unavailable") }
    let identity = "\(try FileLocation.key(resolved))|\(info.st_dev)|\(info.st_ino)"
    let sourceKey = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    let fingerprint = try verifyFrozenContent ? Self.conversionFingerprint(resolved) : nil
    return try locked {
      try claimConversion(sourceKey, fingerprint: fingerprint)
      return try source.transaction(write: false) {
        var result = ConversionResult()
        var batches = 0
        for move in oldMoves {
          let name = move.name
          guard let table = try oldTable(name, source: source) else { continue }
          while true {
            let cursor = try connection.integer(
              "SELECT last_row FROM conversion_progress WHERE source=? AND layer=?",
              [.key(sourceKey), .key(name)])
            let rows = try oldBatch(table, move: move, source: source, cursor: cursor, size: batchSize)
            if rows.isEmpty { break }
            if let limit = maxBatches, batches >= limit { return result }
            try connection.transaction(collectionMaintenance: name == "samples" || name == "evidence") {
              let before = result
              for row in rows {
                let disposition: CarryDisposition
                do { disposition = try move.carry(row, &result) }
                catch StorageError.constraint { disposition = .refused }
                var counts = result.tables[name, default: ConversionTableCounts()]
                switch disposition {
                case .carried: counts.carried += 1
                case .refused: counts.refused += 1; move.refuse(&result)
                case .notCarried: counts.notCarried += 1
                }
                result.tables[name] = counts
                if name == "evidence" {
                  let kind = try row.text("kind")
                  let safe = ["ocr", "screen", "prompt", "input", "reply", "choice", "typed"].contains(kind) ? kind : "other"
                  var kinds = result.evidenceKinds[safe, default: ConversionTableCounts()]
                  switch disposition {
                  case .carried: kinds.carried += 1
                  case .refused: kinds.refused += 1
                  case .notCarried: kinds.notCarried += 1
                  }
                  result.evidenceKinds[safe] = kinds
                }
              }
              let next = try move.nextCursor(after: rows, cursor: cursor)
              try connection.run(
                """
                INSERT INTO conversion_progress(source,layer,last_row) VALUES(?,?,?)
                ON CONFLICT(source,layer) DO UPDATE SET last_row=excluded.last_row
                """, [.key(sourceKey), .key(name), .integer(next)])
              try persistConversionCounts(result, since: before, source: sourceKey)
            }
            batches += 1
          }
        }
        result.finished = true
        try connection.run("INSERT OR REPLACE INTO conversion_progress VALUES(?,'finished',1)", [.key(sourceKey)])
        return result
      }
    }
  }

  private func claimConversion(_ source: String, fingerprint: String?) throws {
    try connection.transaction {
      guard try connection.integer("SELECT count(*) FROM conversion_progress WHERE source!=?", [.key(source)]) == 0
      else { throw StorageError("Destination belongs to a different conversion source") }
      if try connection.integer("SELECT count(*) FROM conversion_progress") == 0 {
        for table in [
          "samples", "evidence", "intervals", "model_calls", "settings",
          "log_positions", "forgotten_ranges", "forgotten_sources",
        ] {
          guard try connection.integer("SELECT count(*) FROM \(table)") == 0 else {
            throw StorageError("Conversion requires an empty destination")
          }
        }
        try connection.run("INSERT INTO conversion_progress VALUES(?,'source',0)", [.key(source)])
      }
      if let fingerprint {
        let layer = "content." + fingerprint
        let existing = try connection.integer("SELECT count(*) FROM conversion_progress WHERE layer LIKE 'content.%'")
        guard try existing == 0 || (connection.integer("SELECT count(*) FROM conversion_progress WHERE layer=?", [.key(layer)])) == 1
        else { throw StorageError("Frozen source changed") }
        try connection.run("INSERT OR IGNORE INTO conversion_progress VALUES(?,?,1)", [.key(source), .key(layer)])
      }
    }
  }

  private func oldTable(_ name: String, source: SQLiteConnection) throws -> OldTable? {
    guard try source.integer("SELECT count(*) FROM sqlite_master WHERE type='table' AND name=?", [.key(name)]) > 0
    else { return nil }
    var columns = Set<String>()
    try source.namedRows("PRAGMA table_info(\(name))") { columns.insert(try $0.text("name")) }
    return OldTable(name: name, columns: columns)
  }

  private var oldMoves: [OldMove] {
    [
      OldMove(name: "forgotten") { row, _ in try self.carryForgotten(row); return .carried },
      OldMove(name: "forgotten_session_rows") { row, _ in
        try self.carryForgottenSource(row) ? .carried : .refused
      },
      OldMove(name: "wanted") { row, _ in try self.carryRecording(row); return .carried },
      OldMove(name: "log_cursors") { row, _ in try self.carryLogPosition(row) ? .carried : .refused },
      OldMove(name: "samples", defaults: [("watching", "0"), ("hidden_reason", "''")],
        refuse: { $0.refusedSamples += 1 }, carry: carrySample),
      OldMove(name: "evidence", defaults: [("source_id", "NULL"), ("project", "''")],
        refuse: { $0.refusedEvidence += 1 }, carry: carryEvidence),
      OldMove(name: "activities", defaults: [("category", "''"), ("kind", "''"), ("away", "0"), ("project", "''")],
        orderedActivities: true, refuse: { $0.refusedIntervals += 1 }, carry: carryActivity),
      OldMove(name: "llm_runs", defaults: [("from_ts", "NULL"), ("to_ts", "NULL")]) { row, _ in
        try self.carryModelCall(row); return .carried
      },
    ]
  }

  private func oldBatch(
    _ table: OldTable, move: OldMove, source: SQLiteConnection, cursor: Int, size: Int
  ) throws -> [DatabaseRow] {
    let extra = move.defaults.map { table.column($0.0, fallback: $0.1) }
    let projection = (["rowid AS old_row", "*"] + extra).joined(separator: ",")
    let selection = move.orderedActivities
      ? "ORDER BY start_ts,id LIMIT ? OFFSET ?" : "WHERE rowid>? ORDER BY rowid LIMIT ?"
    let values: [SQLValue] = move.orderedActivities
      ? [.integer(size), .integer(cursor)] : [.integer(cursor), .integer(size)]
    var rows: [DatabaseRow] = []
    try source.namedRows("SELECT \(projection) FROM \(table.name) \(selection)", values) { rows.append($0) }
    return rows
  }

  private func carryForgotten(_ row: DatabaseRow) throws {
    try connection.run(
      "INSERT INTO forgotten_ranges VALUES(?,?)",
      [.integer(try row.int("start_ts")), .integer(try row.int("end_ts"))])
  }

  private func carryForgottenSource(_ row: DatabaseRow) throws -> Bool {
    try connection.run(
      "INSERT OR IGNORE INTO forgotten_sources VALUES(?,?)",
      [.key(try row.text("bundle_id")), .key(try row.text("source_id"))])
    return sqlite3_changes(connection.handle) == 1
  }

  private func carryRecording(_ row: DatabaseRow) throws {
    try connection.run(
      "INSERT OR REPLACE INTO settings(key,value) VALUES('recording',?)",
      [.text(try row.int("recording") == 0 ? "0" : "1")])
  }

  private func carryLogPosition(_ row: DatabaseRow) throws -> Bool {
    if try logPosition(path: try row.text("path")) == nil {
      try saveLogPosition(
        LogPosition(
          path: try row.text("path"), device: try row.int("device"), inode: try row.int("inode"),
          offset: try row.int("offset"), state: try row.text("state"), seenAt: try row.int("seen_ts")))
      return true
    }
    return false
  }

  private func carrySample(_ row: DatabaseRow, result: inout ConversionResult) throws -> CarryDisposition {
    let stored = try insertSample(
      TimeSample(
        ts: try row.int("ts"), bundleID: try row.text("bundle_id"),
        app: try row.text("app"), window: try row.text("title"), documentKey: try row.text("doc_key"),
        keys: try row.int("keys"), clicks: try row.int("clicks"), scrolls: try row.int("scrolls"),
        moved: try row.int("moved") != 0,
        synthetic: try row.int("synth"), keepingAwake: try row.int("watching") != 0,
        excluded: try !row.text("hidden_reason").isEmpty || row.text("doc_key") == "(비공개)"), legacy: true)
    if stored { result.samples += 1 }
    return stored ? .carried : .refused
  }

  private func carryEvidence(_ row: DatabaseRow, result: inout ConversionResult) throws -> CarryDisposition {
    // Removed input/reply/choice paths and hidden content have no reader in the new product.
    let oldKind = try row.text("kind")
    let kind: EvidenceKind? = ["ocr", "screen"].contains(oldKind) ? .screen : (oldKind == "prompt" ? .prompt : nil)
    guard let kind else {
      result.skippedEvidenceKinds[oldKind, default: 0] += 1
      return .notCarried
    }
    guard try row.text("doc_key") != "(비공개)" else {
      result.skippedHiddenEvidence += 1
      return .notCarried
    }
    let id = try row.text("source_id")
    let stored = try insertEvidence(
      EvidenceText(
        ts: try row.int("ts"), kind: kind, source: try row.text("bundle_id"),
        sourceID: id.isEmpty ? nil : id, documentKey: try row.text("doc_key"), project: try row.text("project"),
        text: try row.text("text")))
    if stored { result.evidence += 1 }
    else if try forgotten(TimeRange(row.int("ts"), row.int("ts") + 1)) { result.forgottenEvidence += 1 }
    else { result.duplicateEvidence += 1 }
    return stored ? .carried : .refused
  }

  private func carryActivity(_ row: DatabaseRow, result: inout ConversionResult) throws -> CarryDisposition {
    if try row.int("away") == 1 {
      result.skippedAway += 1
      return .notCarried
    }
    if try row.text("kind") == "unknown" {
      result.skippedUnknown += 1
      return .notCarried
    }
    func floorMinute(_ time: Int) throws -> Int {
      let (value, overflow) = time.subtractingReportingOverflow((time % 60 + 60) % 60)
      guard !overflow else { throw StorageError("Unsupported activity boundary") }
      return value
    }
    let roundedStart = try floorMinute(row.int("start_ts"))
    let end = try floorMinute(row.int("end_ts"))
    let lastEnd = try connection.integer("SELECT COALESCE(MAX(end_ts),\(Int.min)) FROM intervals")
    let start = max(roundedStart, lastEnd)
    guard end > start else {
      result.skippedEmpty += 1
      return .notCarried
    }
    let state: IntervalState = try row.text("kind") == "private" ? .private : .named
    let kind: ActivityKind
    switch try row.text("category") {
    case "coding", "review", "research", "planning", "communication": kind = .work
    case "personal": kind = .personal
    case "leisure": kind = .distraction
    default: kind = Self.fallbackOldCategory
    }
    let stored = try insertInterval(
      NamedInterval(
        range: TimeRange(start, end), name: try row.text("title"),
        description: try row.text("summary"), kind: state == .named ? kind : nil,
        project: try row.text("project"), state: state))
    if stored {
      result.intervals += 1
      if start > roundedStart { result.shortened += 1 }
    }
    return stored ? .carried : .refused
  }

  private func carryModelCall(_ row: DatabaseRow) throws {
    let from: Int
    if case .integer(let value) = try row.value("from_ts") { from = value } else { from = try row.int("created_at") }
    guard from < Int.max else { throw StorageError("Unsupported call boundary") }
    let to: Int
    if case .integer(let value) = try row.value("to_ts") { to = value } else { to = from + 1 }
    try insertModelCall(
      ModelCall(
        ts: try row.int("created_at"), range: TimeRange(from, max(from + 1, to)),
        model: try row.text("model"), inputTokens: try row.int("input_tokens"),
        cachedTokens: try row.int("cached_tokens"),
        outputTokens: try row.int("output_tokens"), succeeded: try row.int("ok") != 0))
  }
}
