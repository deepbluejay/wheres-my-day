import CryptoKit
import Foundation
import SQLite3

/// A read snapshot fixes the baseline before any write. Only planned identities
/// are materialized, and every live changed identity must also change in the
/// independently executed expectation. Unplanned deletes cannot hide as absence.
final class CollectionMaintenanceProof {
  static let tables: Set<String> = ["samples", "evidence", "sample_observations", "input_batches",
    "collection_legacy_times", "collection_metadata", "screen_payloads", "collection_blobs",
    "collection_retention", "collection_policy_refusals", "collection_ingestion", "collection_ingestion_pending"]
  let expected: SQLiteConnection
  private let baseline: SQLiteConnection?
  private weak var source: SQLiteConnection?
  private var loaded: [String: Set<Int64>] = [:]
  private var identities: [String: Set<Int64>] = [:]
  private var changed: [String: Set<Int64>] = [:]
  private var planned: [String: Set<Int64>] = [:]
  private var seeding = false
  let full: Bool
  private var referenceHashes = Set<String>()
  // Empty expectations keyed by the source's collection schema. Each scoped proof
  // receives a page copy instead of parsing the same tables and triggers again.
  private static let templateLock = NSLock()
  private static var templates: [String: SQLiteConnection] = [:]

  init(_ source: SQLiteConnection, full: Bool = false) throws {
    self.full = full
    self.source = source
    expected = try SQLiteConnection(temporaryCollectionProof: ())
    baseline = full ? nil : try source.collectionEntrySnapshot()
    try expected.run("PRAGMA cache_size=-512")
    try expected.run("PRAGMA secure_delete=ON")
    sqlite3_create_function_v2(expected.handle, "proof_seeding", 0, SQLITE_UTF8,
      Unmanaged.passUnretained(self).toOpaque(), { context, _, _ in
        guard let context, let pointer = sqlite3_user_data(context) else { return }
        let proof = Unmanaged<CollectionMaintenanceProof>.fromOpaque(pointer).takeUnretainedValue()
        sqlite3_result_int(context, proof.seeding ? 1 : 0)
      }, nil, nil, nil)
    let schema = try Self.schema(source)
    if full {
      try expected.run("BEGIN")
      try Self.build(expected, schema) { try copy(source, table: $0, predicate: "1") }
    } else {
      try Self.restoreTemplate(schema, into: expected)
      try expected.run("BEGIN")
      // The shipped accounting triggers are installed, without running an initialization INSERT.
      if schema.contains(where: { $0.table == "collection_ingestion_pending" }) {
        try seed(source, table: "collection_ingestion_pending", predicate: "id=1")
      }
    }
    expected.collectionChangeObserver = { [weak self] table, row in
      guard let self, !self.seeding, Self.tables.contains(table) else { return }
      self.planned[table, default: []].insert(row)
      self.identities[table, default: []].insert(row)
    }
  }
  deinit {
    if let baseline { source?.returnCollectionEntrySnapshot(baseline) }
  }
  /// Table and index definitions in creation order, read inside the writer's transaction.
  private static func schema(_ source: SQLiteConnection) throws -> [(table: String, sql: String, indexes: [String])] {
    let names = tables.sorted().map { "'" + $0 + "'" }.joined(separator: ",")
    var definitions: [String: String] = [:], indexes: [String: [String]] = [:]
    try source.rows("SELECT type,tbl_name,sql FROM sqlite_master WHERE type IN ('table','index') AND tbl_name IN (\(names))") { row in
      let table = SQLiteConnection.text(row, 1)
      if SQLiteConnection.text(row, 0) == "table" { definitions[table] = SQLiteConnection.text(row, 2) }
      else if let sql = SQLiteConnection.optionalText(row, 2) { indexes[table, default: []].append(sql) }
    }
    return tables.sorted().compactMap { table in definitions[table].map { (table, $0, indexes[table] ?? []) } }
  }
  private static func build(_ database: SQLiteConnection, _ schema: [(table: String, sql: String, indexes: [String])],
    filled: (String) throws -> Void = { _ in }) throws {
    try database.run("CREATE TABLE proof_external_refs(hash TEXT PRIMARY KEY)")
    for entry in schema {
      try database.run(entry.sql)
      for index in entry.indexes { try database.run(index) }
      try filled(entry.table)
    }
    for sql in SQLiteConnection.collectionCascadeTriggers {
      let owner = sql.components(separatedBy: " ON ").last?.components(separatedBy: " ").first ?? ""
      if try database.integer("SELECT count(*) FROM sqlite_master WHERE name=? AND type='table'", [.key(owner)]) == 1 {
        try installTrigger(sql, on: database)
      }
    }
    if try database.integer("SELECT count(*) FROM sqlite_master WHERE name='collection_ingestion_pending'") == 1 {
      try database.createCollectionAccountingTriggers(existingTablesOnly: true) { try installTrigger($0, on: database) }
    }
  }
  /// Copies the template pages built by the same code a full proof runs. The key is the
  /// complete schema text, so any table, index or definition change builds a new template.
  private static func restoreTemplate(_ schema: [(table: String, sql: String, indexes: [String])], into database: SQLiteConnection) throws {
    let key = schema.map { ([$0.table, $0.sql] + $0.indexes).joined(separator: "\u{0}") }.joined(separator: "\u{1}")
    templateLock.lock()
    defer { templateLock.unlock() }
    let template: SQLiteConnection
    if let found = templates[key] { template = found }
    else {
      template = try SQLiteConnection(temporaryCollectionProof: ())
      try build(template, schema)
      if templates.count >= 8 { templates.removeAll() }
      templates[key] = template
    }
    guard let backup = sqlite3_backup_init(database.handle, "main", template.handle, "main") else { throw database.failure() }
    let result = sqlite3_backup_step(backup, -1)
    guard sqlite3_backup_finish(backup) == SQLITE_OK, result == SQLITE_DONE else { throw StorageError("Collection proof template unavailable") }
  }
  private func installTrigger(_ definition: String) throws { try Self.installTrigger(definition, on: expected) }
  private static func installTrigger(_ definition: String, on database: SQLiteConnection) throws {
    var sql = definition
    if sql.contains("CREATE TRIGGER IF NOT EXISTS collection_unref ") {
      sql = sql.replacingOccurrences(of: "; END", with: " AND NOT EXISTS(SELECT 1 FROM proof_external_refs r WHERE r.hash=collection_blobs.hash); END")
    }
    guard let begin = sql.range(of: #"\bBEGIN\b"#, options: .regularExpression) else { throw StorageError("Invalid shipped collection trigger") }
    var header = String(sql[..<begin.lowerBound])
    let body = String(sql[begin.lowerBound...])
    if let condition = header.range(of: #"\bWHEN\b"#, options: .regularExpression) {
      header = String(header[..<condition.lowerBound]) + "WHEN proof_seeding()=0 AND (" + header[condition.upperBound...] + ") "
    } else { header += " WHEN proof_seeding()=0 " }
    sql = header + body
    try database.run(sql)
  }
  private func copy(_ database: SQLiteConnection, table: String, predicate: String, values: [SQLValue] = []) throws {
    let wasSeeding = seeding; seeding = true
    defer { seeding = wasSeeding }
    try database.rows("SELECT rowid,* FROM \(table) WHERE \(predicate)", values) { row in
      let id = sqlite3_column_int64(row, 0)
      guard loaded[table, default: []].insert(id).inserted else { return }
      identities[table, default: []].insert(id)
      try expected.insertCollectionProofRow(row, table: table)
    }
  }
  private func seed(_ source: SQLiteConnection, table: String, predicate: String, values: [SQLValue] = []) throws {
    guard !full, let baseline else { return }
    try copy(baseline, table: table, predicate: predicate, values: values)
    if table == "evidence" {
      try seed(source, table: "screen_payloads", predicate: "evidence_id IN (SELECT id FROM evidence WHERE \(predicate))", values: values)
    } else if table == "sample_observations" {
      try seed(source, table: "collection_legacy_times", predicate: "observation_row IN (SELECT id FROM sample_observations WHERE \(predicate))", values: values)
    } else if table == "screen_payloads" {
      // Scope content/owner dependencies, never all other occurrences sharing content.
      var owners: [Int] = [], hashes: [String] = []
      try baseline.namedRows("SELECT evidence_id,text_hash,payload_hash FROM screen_payloads WHERE \(predicate)", values) {
        owners.append(try $0.int("evidence_id"))
        for column in ["text_hash", "payload_hash"] { if let hash = try $0.optionalText(column) { hashes.append(hash) } }
      }
      for id in owners { try copy(baseline, table: "evidence", predicate: "id=?", values: [.integer(id)]) }
      for hash in hashes {
        try copy(baseline, table: "collection_blobs", predicate: "hash=?", values: [.key(hash)])
        referenceHashes.insert(hash)
      }
    }
  }
  func noteChange(_ table: String, _ row: Int64) {
    if Self.tables.contains(table) { changed[table, default: []].insert(row) }
  }
  func verifyChanges(_ source: SQLiteConnection) throws {
    for (table, rows) in changed {
      guard rows.isSubset(of: planned[table, default: []]) else { throw StorageError("Unplanned collection write: \(table)") }
    }
    for (table, rows) in planned {
      for row in rows { try verifyRow(source, table: table, row: row) }
    }
    changed.removeAll(keepingCapacity: true); planned.removeAll(keepingCapacity: true)
  }
  private func verifyRow(_ source: SQLiteConnection, table: String, row: Int64) throws {
    let selection = " WHERE rowid=\(row)"
    guard try digest(source, table: table, selection: selection) == digest(expected, table: table, selection: selection) else {
      throw StorageError("Collection differs from prepared row state: \(table)")
    }
  }
  private func refreshReferences(_ source: SQLiteConnection) throws {
    guard !full, !referenceHashes.isEmpty else { return }
    let ids = identities["screen_payloads", default: []].map(String.init).joined(separator: ",")
    for hash in referenceHashes {
      let outside = try source.integer("SELECT EXISTS(SELECT 1 FROM screen_payloads WHERE (text_hash=?1 OR payload_hash=?1) AND evidence_id NOT IN (\(ids.isEmpty ? "NULL" : ids)))", [.key(hash)])
      if outside == 1 { try expected.run("INSERT OR IGNORE INTO proof_external_refs VALUES(?)", [.key(hash)]) }
      else { try expected.run("DELETE FROM proof_external_refs WHERE hash=?", [.key(hash)]) }
    }
  }
  // Number parameters before removing a WHERE clause so SET/VALUES retain their bindings.
  func numbered(_ sql: String) -> String {
    var result = "", quoted = false, parameter = 0, offset = 0
    let characters = Array(sql)
    while offset < characters.count {
      let character = characters[offset]
      if character == "'" { quoted.toggle() }
      if character == "?" && !quoted {
        var end = offset + 1
        while end < characters.count && characters[end].isNumber { end += 1 }
        if end > offset + 1 {
          let explicit = String(characters[(offset + 1)..<end])
          parameter = max(parameter, Int(explicit) ?? 0); result += "?" + explicit
        } else { parameter += 1; result += "?\(parameter)" }
        offset = end
      } else { result.append(character); offset += 1 }
    }
    return result
  }
  func apply(_ original: String, _ values: [SQLValue], source: SQLiteConnection) throws {
    let pattern = #"(?i)^\s*(INSERT(?: OR (?:IGNORE|REPLACE))? INTO|UPDATE|DELETE FROM)\s+([a-z_]+)\b"#
    let expression = try NSRegularExpression(pattern: pattern)
    let range = NSRange(original.startIndex..., in: original)
    guard let match = expression.firstMatch(in: original, range: range),
      let target = Range(match.range(at: 2), in: original), Self.tables.contains(String(original[target]).lowercased()) else { return }
    let table = String(original[target]).lowercased()
    var sql = original
    if !full {
      sql = numbered(original)
      let args = values.isEmpty ? "" : "WITH proof_args AS (SELECT " + (1...values.count).map { "?\($0)" }.joined(separator: ",") + ") "
      if original.uppercased().hasPrefix("UPDATE ") || original.uppercased().hasPrefix("DELETE ") {
        let whereRange = sql.range(of: " WHERE ", options: [.caseInsensitive])
        let predicate = whereRange.map { String(sql[$0.upperBound...]) } ?? "1"
        var ids: [Int64] = []
        let header = String(sql[..<(whereRange?.lowerBound ?? sql.endIndex)])
        let indexHint = header.range(of: #"(?i)\s+INDEXED BY\s+[a-z_]+"#, options: .regularExpression)
          .map { String(header[$0]) } ?? ""
        try source.rows(args + "SELECT rowid FROM \(table)\(indexHint) WHERE \(predicate)", values) { ids.append(sqlite3_column_int64($0, 0)) }
        if !ids.isEmpty { try seed(source, table: table, predicate: "rowid IN (" + ids.map(String.init).joined(separator: ",") + ")") }
        let keepBindings = values.isEmpty ? "" : " AND (SELECT count(*) FROM (SELECT " + (1...values.count).map { "?\($0)" }.joined(separator: ",") + "))=1"
        sql = String(sql[..<(whereRange?.lowerBound ?? sql.endIndex)]) + " WHERE rowid IN (" + (ids.isEmpty ? "NULL" : ids.map(String.init).joined(separator: ",")) + ")" + keepBindings
        // The live predicate may justify a partial index. The expectation uses
        // selected rowids instead, so it must let SQLite choose its own index.
        sql = sql.replacingOccurrences(of: #"(?i)\s+INDEXED BY\s+[a-z_]+"#, with: "", options: .regularExpression)
      } else {
        let insert = try NSRegularExpression(pattern: #"(?is)^\s*INSERT(?: OR (?:IGNORE|REPLACE))? INTO\s+[a-z_]+\s*(?:\(([^)]*)\))?\s*VALUES\s*\(([^)]*)\)"#)
        guard let found = insert.firstMatch(in: sql, range: NSRange(sql.startIndex..., in: sql)), let valueRange = Range(found.range(at: 2), in: sql) else { throw StorageError("Collection INSERT requires a scoped VALUES plan") }
        var columns: [String] = []
        if let columnRange = Range(found.range(at: 1), in: sql) { columns = sql[columnRange].split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } }
        else { try source.namedRows("PRAGMA table_info(\(table))") { columns.append(try $0.text("name")) } }
        let expressions = sql[valueRange].split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard columns.count == expressions.count else { throw StorageError("Invalid collection VALUES plan") }
        let fields = Dictionary(uniqueKeysWithValues: zip(columns, expressions))
        var keys: [(columns: [String], collations: [String], predicate: String)] = []
        var primary: [String] = []
        var prepared = fields
        try source.namedRows("PRAGMA table_info(\(table))") {
          let name = try $0.text("name")
          if try $0.int("pk") > 0 { primary.append(name) }
          if prepared[name] == nil { prepared[name] = try $0.optionalText("dflt_value") ?? "NULL" }
        }
        if !primary.isEmpty { keys.append((primary, [], "1")) }
        var indexes: [String] = []
        try source.namedRows("PRAGMA index_list(\(table))") { if try $0.int("unique") != 0 { indexes.append(try $0.text("name")) } }
        for index in indexes {
          var key: [String] = [], collations: [String] = [], predicate = "1"
          try source.namedRows("PRAGMA index_xinfo(\(index))") {
            if try $0.int("key") != 0 {
              guard let name = try $0.optionalText("name") else { throw StorageError("Collection expression index needs a scoped conflict plan") }
              key.append(name); collations.append(try $0.text("coll"))
            }
          }
          try source.namedRows("SELECT sql FROM sqlite_master WHERE type='index' AND name=?", [.key(index)]) {
            if let definition = try $0.optionalText("sql"), let whereRange = definition.range(of: #"\bWHERE\b"#, options: [.caseInsensitive, .regularExpression]) {
              predicate = String(definition[whereRange.upperBound...])
            }
          }
          keys.append((key, collations, predicate))
        }
        let preparedRow = "WITH proof_insert AS (SELECT " + prepared.keys.sorted().map { prepared[$0]! + " AS \"" + $0 + "\"" }.joined(separator: ",") + ") "
        for key in keys where key.columns.allSatisfy({ prepared[$0] != nil }) {
          // NULLs are distinct in SQLite unique keys. Check the incoming partial
          // predicate first, then use that same predicate to select indexed conflicts.
          let applicable = key.columns.map { "\($0) IS NOT NULL" }.joined(separator: " AND ")
          guard try source.integer(preparedRow + "SELECT EXISTS(SELECT 1 FROM proof_insert WHERE (\(key.predicate)) AND \(applicable))", values) == 1 else { continue }
          let predicate = key.columns.enumerated().map { offset, name in
            let collation = key.collations.isEmpty ? "" : " COLLATE \"" + key.collations[offset].replacingOccurrences(of: "\"", with: "\"\"") + "\""
            return "\(name)\(collation) = (SELECT \(name) FROM proof_insert)"
          }.joined(separator: " AND ")
          var ids: [Int64] = []
          try source.rows(preparedRow + "SELECT rowid FROM \(table) WHERE (\(key.predicate)) AND \(predicate)", values) { ids.append(sqlite3_column_int64($0, 0)) }
          for id in ids { try seed(source, table: table, predicate: "rowid=\(id)") }
        }
        if table == "screen_payloads", let owner = fields["evidence_id"] {
          var id = 0
          try source.rows(args + "SELECT \(owner)", values) { id = SQLiteConnection.int($0, 0) }
          try seed(source, table: "evidence", predicate: "id=?", values: [.integer(id)])
        }
        // SQLite rowid allocation is derived before the live INSERT. It is not
        // learned from a possibly mutated row or sqlite3_last_insert_rowid.
        let alias = ["samples": "id", "evidence": "id", "sample_observations": "id", "input_batches": "id", "collection_legacy_times": "id", "collection_metadata": "id", "screen_payloads": "evidence_id", "collection_retention": "id", "collection_ingestion": "committed_ts", "collection_ingestion_pending": "id"][table]
        if alias == nil || fields[alias!] == nil {
          let next = try source.integer("SELECT COALESCE(MAX(rowid),0)+1 FROM \(table)")
          let ending = sql[Range(found.range, in: sql)!.upperBound...]
          let command = String(sql[..<sql.range(of: table)!.lowerBound])
          sql = command + table + "(rowid," + columns.joined(separator: ",") + ") VALUES(\(next)," + expressions.joined(separator: ",") + ")" + ending
        }
      }
      try refreshReferences(source)
    }
    try expected.run(sql, values)
  }
  func applySchema(_ sql: String) throws {
    let words = Set(sql.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "_" }.map(String.init))
    guard !words.isDisjoint(with: Self.tables) else { return }
    if sql.uppercased().contains("CREATE TRIGGER") {
      if sql.contains("CREATE TRIGGER IF NOT EXISTS ingestion_") { try installTrigger(sql) }
      return
    }
    try expected.run(sql)
    for trigger in SQLiteConnection.collectionCascadeTriggers {
      let owner = trigger.components(separatedBy: " ON ").last?.components(separatedBy: " ").first ?? ""
      if try expected.integer("SELECT count(*) FROM sqlite_master WHERE name=? AND type='table'", [.key(owner)]) == 1 { try installTrigger(trigger) }
    }
  }
  private func digest(_ database: SQLiteConnection, table: String, selection: String = "") throws -> Data {
    var digest = SHA256()
    try database.rows("SELECT * FROM \(table)\(selection) ORDER BY 1") { row in
      for column in 0..<sqlite3_column_count(row) {
        let count = Int(sqlite3_column_bytes(row, column))
        digest.update(data: Data("\(column):\(sqlite3_column_type(row, column)):\(count):".utf8))
        if let bytes = sqlite3_column_blob(row, column), count > 0 { digest.update(data: Data(bytes: bytes, count: count)) }
      }
      digest.update(data: Data(";".utf8))
    }
    return Data(digest.finalize())
  }
  func cleanupErasedReferences(_ source: SQLiteConnection) throws {
    // Only references in this plan can become orphaned. The indexed probes do
    // not scan retained occurrences or copy other occurrences of a dedup blob.
    for hash in referenceHashes {
      try source.collectionWrite("DELETE FROM collection_blobs WHERE hash=?1 AND NOT EXISTS(SELECT 1 FROM screen_payloads WHERE text_hash=?1 OR payload_hash=?1)", [.key(hash)])
    }
    for id in identities["screen_payloads", default: []] {
      guard try source.integer("SELECT count(*) FROM screen_payloads WHERE evidence_id=? AND (NOT EXISTS(SELECT 1 FROM evidence WHERE id=evidence_id) OR (text_hash IS NOT NULL AND (NOT EXISTS(SELECT 1 FROM collection_blobs WHERE hash=text_hash) OR NOT EXISTS(SELECT 1 FROM collection_blobs WHERE hash=payload_hash))))", [.integer(Int(id))]) == 0 else { throw StorageError("Collection content ownership failed") }
    }
  }
  func verify(_ source: SQLiteConnection) throws {
    try verifyChanges(source)
    if full {
      for table in Self.tables.sorted() where try expected.integer("SELECT count(*) FROM sqlite_master WHERE type='table' AND name=?", [.key(table)]) == 1 {
        guard try digest(source, table: table) == digest(expected, table: table) else { throw StorageError("Collection migration differs: \(table)") }
      }
    } else {
      for (table, rows) in identities { for row in rows { try verifyRow(source, table: table, row: row) } }
    }
  }
}

extension SQLiteConnection {
  func requireCollectionMaintenance() throws {
    guard collectionMaintenanceAuthorized else { throw StorageError("Collection maintenance requires a transaction-entry proof") }
  }
  /// All collection DML is registered here. Maintenance executes the prepared
  /// statement on its transaction-entry relation before the live statement.
  func collectionWrite(_ sql: String, _ values: [SQLValue] = []) throws {
    guard collectionMaintenanceProof != nil else { throw StorageError("Collection write requires a transaction-entry contract") }
    let plan = try NSRegularExpression(pattern: #"(?i)^(UPDATE|DELETE FROM)\s+([a-z_]+)\b"#)
    if collectionBatchingAuthorized, !collectionCheckpointing, collectionMaintenanceProof != nil,
      let match = plan.firstMatch(in: sql, range: NSRange(sql.startIndex..., in: sql)),
      let target = Range(match.range(at: 2), in: sql), CollectionMaintenanceProof.tables.contains(String(sql[target])) {
      let statement = collectionMaintenanceProof!.numbered(sql), table = String(sql[target])
      let whereRange = statement.range(of: " WHERE ", options: .caseInsensitive)
      let predicate = whereRange.map { String(statement[$0.upperBound...]) } ?? "1"
      let args = values.isEmpty ? "" : "WITH proof_args AS (SELECT " + (1...values.count).map { "?\($0)" }.joined(separator: ",") + ") "
      var cursor: Int64? = nil, total = 0
      while true {
        try checkpointCollectionBatchIfNeeded()
        var ids: [Int64] = []
        let deletion = statement.hasPrefix("DELETE ")
        let after = deletion ? "" : cursor.map { " AND rowid>\($0)" } ?? ""
        let order = deletion ? "" : " ORDER BY rowid"
        try rows(args + "SELECT rowid FROM \(table) WHERE (\(predicate))" + after + order + " LIMIT 64", values) { ids.append(sqlite3_column_int64($0, 0)) }
        guard let last = ids.last else { break }
        let keep = values.isEmpty ? "" : " AND (SELECT count(*) FROM (SELECT " + (1...values.count).map { "?\($0)" }.joined(separator: ",") + "))=1"
        let chunk = String(statement[..<(whereRange?.lowerBound ?? statement.endIndex)]) + " WHERE rowid IN (" + ids.map(String.init).joined(separator: ",") + ")" + keep
        try executeCollectionWrite(chunk, values)
        total += Int(sqlite3_changes(handle)); cursor = last
      }
      collectionLastChanges = total
    } else {
      try checkpointCollectionBatchIfNeeded()
      try executeCollectionWrite(sql, values)
      collectionLastChanges = Int(sqlite3_changes(handle))
    }
  }
  private func executeCollectionWrite(_ sql: String, _ values: [SQLValue]) throws {
    try verifyPendingCollectionChanges()
    try collectionMaintenanceProof?.apply(sql, values, source: self)
    collectionWriteAuthorized = true
    defer { collectionWriteAuthorized = false }
    try run(sql, values)
    collectionBatchChanges += Int(sqlite3_total_changes(handle)) - collectionBatchTotalBefore
    collectionBatchTotalBefore = Int(sqlite3_total_changes(handle))
    try verifyPendingCollectionChanges()
  }
  func withCollectionMaintenanceUnit<T>(_ body: () throws -> T) throws -> T {
    try requireCollectionMaintenance()
    try checkpointCollectionBatchIfNeeded()
    let previous = collectionCheckpointing
    collectionCheckpointing = true
    defer { collectionCheckpointing = previous }
    // Admission and its prepared writes share one writer transaction. Settings
    // can change while a checkpoint releases the lock, so checkpoint first.
    return try body()
  }
  func enableCollectionMaintenanceBatches() throws {
    try requireCollectionMaintenance()
    guard collectionMaintenanceProof?.full == false else { throw StorageError("Migration cannot checkpoint") }
    collectionBatchingAuthorized = true
    collectionBatchTotalBefore = Int(sqlite3_total_changes(handle))
  }
  private func checkpointCollectionBatchIfNeeded() throws {
    guard collectionBatchingAuthorized, !collectionCheckpointing, collectionBatchChanges >= 64 else { return }
    // A source cursor can retain a read snapshot after COMMIT and make the next
    // BEGIN IMMEDIATE fail as soon as a collector commits in the unlocked gap.
    guard sqlite3_next_stmt(handle, nil) == nil else { throw StorageError("Open statement at collection checkpoint") }
    collectionCheckpointing = true
    defer { collectionCheckpointing = false }
    try collectionMaintenanceProof?.cleanupErasedReferences(self)
    if collectionAccountingEnabled { try commitCollectionIngestion(at: collectionCommitClock()) }
    for key in collectionProofs.keys.sorted() { try collectionProofs[key]!() }
    try verifyCollectionMaintenance()
    try collectionPrivacyProgressProof?()
    try run("COMMIT")
    collectionMaintenanceProof = nil
    collectionProofs.removeAll(); collectionRowContracts.removeAll(); collectionRefusalExpected = nil
    guard sqlite3_get_autocommit(handle) == 1, sqlite3_txn_state(handle, "main") == SQLITE_TXN_NONE,
      sqlite3_next_stmt(handle, nil) == nil else { throw StorageError("Collection checkpoint retained a snapshot") }
    // The privacy marker is durable before either SQL or publication may proceed.
    if let yield = collectionMaintenanceYield { try yield() }
    else { Thread.sleep(forTimeInterval: 0.001) }
    try run("BEGIN IMMEDIATE")
    collectionMaintenanceProof = try CollectionMaintenanceProof(self)
    collectionBatchChanges = 0
    collectionBatchTotalBefore = Int(sqlite3_total_changes(handle))
  }
  func verifyPendingCollectionChanges() throws {
    guard let proof = collectionMaintenanceProof, !verifyingCollectionMaintenance else { return }
    verifyingCollectionMaintenance = true
    defer { verifyingCollectionMaintenance = false }
    try proof.verifyChanges(self)
  }
  func verifyCollectionMaintenance() throws {
    guard let proof = collectionMaintenanceProof, !verifyingCollectionMaintenance else { return }
    verifyingCollectionMaintenance = true
    defer { verifyingCollectionMaintenance = false }
    try proof.verify(self)
  }
}
