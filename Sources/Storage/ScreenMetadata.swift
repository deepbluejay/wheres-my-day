import Core
import CryptoKit
import Foundation
import SQLite3

extension ActivityStorage {
  func digestCollectionRows(_ sql: String, values: [SQLValue], into digest: inout SHA256) throws {
    try connection.rows(sql, values) { row in
      for column in 0..<sqlite3_column_count(row) {
        let size = sqlite3_column_bytes(row, column)
        digest.update(data: Data("|\(sqlite3_column_type(row, column)):\(size):".utf8))
        if let bytes = sqlite3_column_blob(row, column), size > 0 { digest.update(data: Data(bytes: bytes, count: Int(size))) }
      }
      digest.update(data: Data(";".utf8))
    }
  }
  func collectionMetadataAllowed(at time: Double) throws -> Bool {
    try locked {
      let second = try collectionSecond(time)
      return try collectionRefusal(at: second) == nil
    }
  }
  func screenMetadataTargets(in range: TimeRange) throws -> [Int] {
    var ids: [Int] = []
    try connection.namedRows("SELECT evidence_id FROM screen_payloads WHERE metadata_ts>=? AND metadata_ts<? ORDER BY evidence_id",
      [.integer(range.start), .integer(range.end)]) { ids.append(try $0.int("evidence_id")) }
    return ids
  }
  func digestScreenMetadata(in range: TimeRange, into digest: inout SHA256) throws -> Int {
    guard try connection.integer("SELECT count(*) FROM pragma_table_info('screen_payloads') WHERE name='metadata_ts'") == 1 else { return 0 }
    let count = try connection.integer("SELECT count(*) FROM screen_payloads WHERE metadata_ts>=? AND metadata_ts<?", [.integer(range.start), .integer(range.end)])
    digest.update(data: Data("screen-metadata".utf8))
    try digestCollectionRows("""
      SELECT p.*,e.document_key,b.content FROM screen_payloads p JOIN evidence e ON e.id=p.evidence_id
      LEFT JOIN collection_blobs b ON b.hash=p.payload_hash
      WHERE p.metadata_ts>=? AND p.metadata_ts<? ORDER BY p.evidence_id
      """, values: [.integer(range.start), .integer(range.end)], into: &digest)
    return count
  }
  /// Erase only the independently timed metadata, keeping the later OCR occurrence intact.
  func scrubScreenMetadata(ids: [Int]) throws -> [(Int, String)] {
    try connection.requireCollectionMaintenance()
    var expected: [(Int, String)] = []
    for id in ids {
      if let hash = try connection.withCollectionMaintenanceUnit({ () throws -> String? in
        guard var payload = try screenPayload(evidenceID: id) else { return nil }
        payload.document = nil; payload.browserAddress = nil
        let time = try connection.integer("SELECT ts FROM evidence WHERE id=?", [.integer(id)])
        let json = try screenPayloadJSON(payload)
        let hash = try storeCollectionBlob(json, at: time)
        try connection.collectionWrite("UPDATE screen_payloads SET payload='',payload_hash=?,metadata_ts=NULL,metadata_time=NULL WHERE evidence_id=?", [.key(hash), .integer(id)])
        try connection.collectionWrite("UPDATE evidence SET document_key='' WHERE id=?", [.integer(id)])
        return hash
      }) { expected.append((id, hash)) }
    }
    return expected
  }
  func verifyScreenMetadataErasure(_ expected: [(Int, String)]) throws {
    for (id, hash) in expected {
      guard try connection.integer("""
        SELECT count(*) FROM screen_payloads p JOIN evidence e ON e.id=p.evidence_id
        WHERE p.evidence_id=? AND p.payload_hash=? AND p.payload='' AND p.metadata_ts IS NULL
          AND p.metadata_time IS NULL AND e.document_key=''
        """, [.integer(id), .key(hash)]) == 1 else { throw StorageError("Deleted screen metadata remains") }
      guard let payload = try screenPayload(evidenceID: id), payload.document == nil, payload.browserAddress == nil else {
        throw StorageError("Deleted screen metadata content remains")
      }
    }
  }
}

extension ActivityStorage {
  func sampleMetadataTargets(in range: TimeRange) throws -> [Int] {
    var ids: [Int] = []
    try connection.namedRows("SELECT id FROM samples WHERE observed_ts>=? AND observed_ts<? ORDER BY id",
      [.integer(range.start), .integer(range.end)]) { ids.append(try $0.int("id")) }
    return ids
  }
  func digestSampleMetadata(in range: TimeRange, into digest: inout SHA256) throws -> Int {
    guard try connection.integer("SELECT count(*) FROM pragma_table_info('samples') WHERE name='observed_ts'") == 1 else { return 0 }
    var count = 0
    try connection.namedRows("SELECT id,observed_ts,window,document_key FROM samples WHERE observed_ts>=? AND observed_ts<? ORDER BY id",
      [.integer(range.start), .integer(range.end)]) {
      count += 1
      digest.update(data: Data("sample-metadata:\(try $0.int("id")):\(try $0.int("observed_ts"))".utf8))
      for column in ["window", "document_key"] {
        let value = try $0.text(column)
        digest.update(data: Data("|\(column):\(value.utf8.count):".utf8)); digest.update(data: Data(value.utf8))
      }
    }
    return count
  }
  func scrubSampleMetadata(ids: [Int]) throws -> [Int] {
    try connection.requireCollectionMaintenance()
    var expected: [Int] = []
    for id in ids {
      guard try connection.integer("SELECT count(*) FROM samples WHERE id=?", [.integer(id)]) > 0 else { continue }
      try connection.collectionWrite("UPDATE samples SET window='',document_key='',observed_ts=NULL WHERE id=?", [.integer(id)])
      expected.append(id)
    }
    return expected
  }
  func verifySampleMetadataErasure(_ ids: [Int]) throws {
    for id in ids {
      guard try connection.integer("SELECT count(*) FROM samples WHERE id=? AND observed_ts IS NULL AND window='' AND document_key=''", [.integer(id)]) == 1 else {
        throw StorageError("Deleted accounting metadata remains")
      }
    }
  }
}
