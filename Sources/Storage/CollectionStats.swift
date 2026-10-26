import Core
import Foundation

extension ActivityStorage {
  /// Logical retained bytes, including all new relations and occurrence metadata.
  /// Occurrence windows measure bytes still retained by source/event time, not growth.
  /// Ingestion measures logical bytes newly committed by commit time, including recovery;
  /// it excludes page/WAL overhead, deduplicated existing blobs and subsequent deletion.
  public func collectionStatus(at now: Int = Int(Date().timeIntervalSince1970)) throws -> String {
    try locked {
      guard try connection.integer("SELECT count(*) FROM sqlite_master WHERE name='collection_blobs'") == 1 else { return "collection_schema=legacy" }
      func identityBytes(_ table: String) throws -> String {
        try connection.integer("SELECT count(*) FROM pragma_table_info('\(table)') WHERE name='application_identity'") == 1
          ? "COALESCE(length(application_identity),0)" : "0"
      }
      let sampleBytes = try identityBytes("samples")
      let screenIdentityBytes = try identityBytes("evidence")
      let inputIdentityBytes = try identityBytes("input_batches")
      let metadataIdentityBytes = try identityBytes("collection_metadata")
      let relations = [
        ("sample_application_identities", "samples", "\(sampleBytes)>0", "ts", sampleBytes),
        ("screen_occurrences", "evidence", "kind='screen'", "ts", "length(CAST(source AS BLOB))+length(CAST(document_key AS BLOB))+length(CAST(project AS BLOB))+length(CAST(text AS BLOB))+\(screenIdentityBytes)+32"),
        ("screen_payloads", "screen_payloads", "1", "(SELECT ts FROM evidence WHERE id=evidence_id)", "length(CAST(payload AS BLOB))+COALESCE(length(text_hash),0)+COALESCE(length(payload_hash),0)+COALESCE(length(CAST(novel_text AS BLOB)),0)+COALESCE(length(occurrence_id),0)+COALESCE(length(metadata_time),0)+24"),
        ("collection_blobs", "collection_blobs", "1", "created_ts", "length(hash)+length(CAST(content AS BLOB))+8"),
        ("sample_observations", "sample_observations", "1", "ts", "length(observation_id)+length(CAST(payload AS BLOB))+24"),
        ("collection_metadata", "collection_metadata", "1", "ts", "length(identity)+length(CAST(source AS BLOB))+length(CAST(document_key AS BLOB))+length(CAST(payload AS BLOB))+\(metadataIdentityBytes)+16"),
        ("collection_legacy_times", "collection_legacy_times", "1", "ts", "16"),
        ("input_batches", "input_batches", "1", "ts", "length(observation_id)+length(events)+\(inputIdentityBytes)+24"),
      ]
      var output: [String] = [], total = 0, recent = 0
      do {
        let health = try CollectionOperationalHealth.read(database: url)
        output.append("collection_busy_retries=\(health.busyRetries) collection_acquisition_failures=\(health.acquisition) collection_staging_failures=\(health.staging) collection_persistence_failures=\(health.persistence) collection_initialization_failures=\(health.initialization)")
      } catch { output.append("collection_health_unreadable=1") }
      var refusals = try CollectionPolicyHealth.read(storage: self)
      if try connection.integer("SELECT count(*) FROM sqlite_master WHERE name='collection_policy_refusals'") == 1 {
        try connection.namedRows("SELECT reason,count FROM collection_policy_refusals") { row in
          refusals[try row.text("reason"), default: 0] += try row.int("count")
        }
      }
      for reason in refusals.keys.sorted() { output.append("collection_refused_\(reason)=\(refusals[reason]!)") }
      for (name, table, filter, time, size) in relations {
        guard try connection.integer("SELECT count(*) FROM sqlite_master WHERE name=?", [.key(table)]) == 1 else { continue }
        let bytes = try connection.integer("SELECT COALESCE(SUM(\(size)),0) FROM \(table) WHERE \(filter)")
        let added = try connection.integer("SELECT COALESCE(SUM(\(size)),0) FROM \(table) WHERE \(filter) AND \(time)>=? AND \(time)<=?", [.integer(now - 86400), .integer(now)])
        let rows = try connection.integer("SELECT count(*) FROM \(table) WHERE \(filter)")
        total += bytes; recent += added
        output.append("\(name)_rows=\(rows) \(name)_bytes=\(bytes) \(name)_retained_occurrence_24h_bytes=\(added)")
        if let pages = try? connection.integer("SELECT COALESCE(SUM(pgsize),0) FROM dbstat WHERE name=? OR name IN (SELECT name FROM sqlite_master WHERE type='index' AND tbl_name=?)", [.key(table), .key(table)]) {
          output.append("\(table)_page_bytes=\(pages)")
        }
      }
      var staged = 0, stagedRows = 0, quarantined = 0, quarantineBytes = 0
      try forEachCollectionFile { file in
        guard file.pathExtension == "json" else { return }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        staged += (attributes[.size] as? NSNumber)?.intValue ?? 0; stagedRows += 1
      }
      try forEachCollectionFile(in: collectionQuarantine) { file in
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        quarantineBytes += (attributes[.size] as? NSNumber)?.intValue ?? 0; quarantined += 1
      }
      var interrupted = 0, quarantineTotal = 0, unrecoverableTotal = 0
      if FileManager.default.fileExists(atPath: collectionDirectory.path) {
        let directory = try OperationalDirectory(collectionDirectory)
        interrupted = try directory.readStrict(".interrupted-temporaries").flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
        quarantineTotal = try directory.readStrict(".quarantined-total").flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
        unrecoverableTotal = try directory.readStrict(".unrecoverable-total").flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
      }
      let hasIngestion = try connection.integer("SELECT count(*) FROM sqlite_master WHERE name='collection_ingestion'") == 1
      let ingested = hasIngestion ? try connection.integer("SELECT COALESCE(SUM(bytes),0) FROM collection_ingestion WHERE committed_ts>=? AND committed_ts<=?", [.integer(now - 86400), .integer(now)]) : 0
      output.append("collection_ingested_commit_24h_bytes=\(ingested) collection_quarantined_rows=\(quarantined) collection_quarantined_bytes=\(quarantineBytes) collection_quarantined_total=\(quarantineTotal) collection_interrupted_temporaries=\(interrupted)")
      output.append("collection_unrecoverable_total=\(unrecoverableTotal)")
      let rebuildFailures = try connection.integer("SELECT COALESCE(SUM(novelty_rebuild_failed),0) FROM screen_payloads")
      output.append("novelty_rebuild_failures=\(rebuildFailures)")
      output.append("collection_total_bytes=\(total) collection_retained_occurrence_24h_bytes=\(recent) collection_staged_rows=\(stagedRows) collection_staged_bytes=\(staged)")
      return output.joined(separator: " ")
    }
  }
}
