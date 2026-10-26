import Foundation

extension ActivityStorage {
  // Both DELETE and its postcondition use these production predicates. JSON is
  // confined to migration-flagged rows; modern per-second maintenance uses indexes.
  static let expiredCollectionObservations = """
    SELECT id FROM sample_observations WHERE ts<?1
    UNION SELECT id FROM sample_observations WHERE observed_ts<?1
    UNION SELECT observation_row FROM collection_legacy_times WHERE ts<?1
    UNION SELECT id FROM sample_observations INDEXED BY sample_observations_legacy
      WHERE legacy_timing=1 AND (json_extract(payload,'$.sample.observedAt')<?1
        OR EXISTS(SELECT 1 FROM json_each(payload,'$.sample.inputEvents') WHERE json_extract(value,'$.timestamp')<?1))
    """
}

extension SQLiteConnection {
  func createCollectionAccounting(existingTablesOnly: Bool = false) throws {
    try run("CREATE TABLE IF NOT EXISTS collection_ingestion(committed_ts INTEGER PRIMARY KEY,bytes INTEGER NOT NULL)")
    try run("CREATE TABLE IF NOT EXISTS collection_ingestion_pending(id INTEGER PRIMARY KEY CHECK(id=1),bytes INTEGER NOT NULL)")
    try collectionWrite("INSERT OR IGNORE INTO collection_ingestion_pending VALUES(1,0)")
    try createCollectionAccountingTriggers(existingTablesOnly: existingTablesOnly) { try self.run($0) }
  }
  func createCollectionAccountingTriggers(existingTablesOnly: Bool, transform: (String) throws -> Void) throws {
    for (table, size, filter) in [
      ("samples", "length(NEW.application_identity)", "NEW.application_identity IS NOT NULL"),
      ("evidence", "length(CAST(NEW.source AS BLOB))+length(CAST(NEW.document_key AS BLOB))+length(CAST(NEW.project AS BLOB))+length(CAST(NEW.text AS BLOB))+COALESCE(length(NEW.application_identity),0)+32", "NEW.kind='screen'"),
      ("screen_payloads", "length(CAST(NEW.payload AS BLOB))+COALESCE(length(NEW.text_hash),0)+COALESCE(length(NEW.payload_hash),0)+COALESCE(length(CAST(NEW.novel_text AS BLOB)),0)+COALESCE(length(NEW.occurrence_id),0)+COALESCE(length(NEW.metadata_time),0)+24", "1"),
      ("collection_blobs", "length(NEW.hash)+length(CAST(NEW.content AS BLOB))+8", "1"),
      ("sample_observations", "length(NEW.observation_id)+length(CAST(NEW.payload AS BLOB))+24", "1"),
      ("input_batches", "length(NEW.observation_id)+length(NEW.events)+COALESCE(length(NEW.application_identity),0)+24", "1"),
      ("collection_legacy_times", "16", "1"),
      ("collection_metadata", "length(NEW.identity)+length(CAST(NEW.source AS BLOB))+length(CAST(NEW.document_key AS BLOB))+length(CAST(NEW.payload AS BLOB))+COALESCE(length(NEW.application_identity),0)+16", "1"),
    ] {
      if existingTablesOnly {
        guard try integer("SELECT count(*) FROM sqlite_master WHERE type='table' AND name=?", [.key(table)]) > 0 else { continue }
      }
      try transform("""
        CREATE TRIGGER IF NOT EXISTS ingestion_\(table) AFTER INSERT ON \(table) WHEN \(filter)
        BEGIN UPDATE collection_ingestion_pending SET bytes=bytes+(\(size)) WHERE id=1; END
        """)
    }
  }
  // Sampled immediately before COMMIT; a rollback also rolls back the counter.
  func commitCollectionIngestion(at time: Int) throws {
    let bytes = try integer("SELECT bytes FROM collection_ingestion_pending WHERE id=1")
    guard bytes > 0 else { return }
    try collectionWrite("INSERT INTO collection_ingestion(committed_ts,bytes) VALUES(?,?) ON CONFLICT(committed_ts) DO UPDATE SET bytes=bytes+excluded.bytes", [.integer(time), .integer(bytes)])
    try collectionWrite("UPDATE collection_ingestion_pending SET bytes=0 WHERE id=1")
    // Numeric commit-time accounting survives erasure but needs only the trailing day.
    try collectionWrite("DELETE FROM collection_ingestion WHERE committed_ts<?", [.integer(time - 86400)])
  }
}
