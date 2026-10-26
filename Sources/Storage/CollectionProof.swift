import CryptoKit
import Foundation
import SQLite3

final class CollectionRowContract {
  let sql: String
  let values: [SQLValue]
  var expected: [Data: Data]
  init(sql: String, values: [SQLValue], expected: [Data: Data]) {
    self.sql = sql; self.values = values; self.expected = expected
  }
}

extension SQLiteConnection {
  // Retain typed hashes, not another copy of acquired content. The first column
  // is the immutable primary key in every collection proof query.
  private func collectionRowSet(_ sql: String, _ values: [SQLValue]) throws -> [Data: Data] {
    var result: [Data: Data] = [:]
    try rows(sql, values) { statement in
      var digest = SHA256(), key = Data()
      for column in 0..<sqlite3_column_count(statement) {
        let type = sqlite3_column_type(statement, column)
        let size = Int(sqlite3_column_bytes(statement, column))
        var cell = Data("\(column):\(type):\(size):".utf8)
        if let pointer = sqlite3_column_blob(statement, column), size > 0 {
          cell.append(Data(bytes: pointer, count: size))
        }
        digest.update(data: cell)
        if column == 0 { key = cell }
      }
      guard result[key] == nil else { throw StorageError("Duplicate collection proof identity") }
      result[key] = Data(digest.finalize())
    }
    return result
  }
  func baselineCollectionRows(_ identity: String, _ sql: String, _ values: [SQLValue]) throws {
    if collectionMaintenanceProof != nil { return }
    guard collectionRowContracts[identity] == nil else { return }
    collectionRowContracts[identity] = CollectionRowContract(sql: sql, values: values,
      expected: try collectionRowSet(sql, values))
    collectionProofs[identity] = { [unowned self] in try self.verifyCollectionRows(identity) }
  }
  func verifyCollectionRows(_ identity: String) throws {
    if collectionMaintenanceProof != nil { try verifyPendingCollectionChanges(); return }
    guard let contract = collectionRowContracts[identity],
      try collectionRowSet(contract.sql, contract.values) == contract.expected else {
      throw StorageError("Collection differs from expected transaction state")
    }
  }
  // Only a query matching prepared values and SQL types may admit new rows.
  // Baseline rows must remain byte-for-byte unchanged, including their keys.
  func proveCollectionRows(_ identity: String, adding sql: String, _ values: [SQLValue], count: Int = 1, verifySet: Bool = true) throws {
    if collectionMaintenanceProof != nil {
      try verifyPendingCollectionChanges()
      guard try collectionRowSet(sql, values).count == count else { throw StorageError("Expected collection rows were not stored") }
      return
    }
    guard let contract = collectionRowContracts[identity] else { throw StorageError("Missing collection baseline") }
    let admitted = try collectionRowSet(sql, values)
    guard admitted.count == count else { throw StorageError("Expected collection rows were not stored") }
    for (key, digest) in admitted {
      if let previous = contract.expected[key], previous != digest { throw StorageError("Preexisting collection row changed") }
      contract.expected[key] = digest
    }
    if verifySet { try verifyCollectionRows(identity) }
  }
}

extension ActivityStorage {
  func baselineCollectionComponents(_ record: CollectionRecord) throws {
    let identity = record.observation?.id ?? record.occurrenceID!
    try connection.baselineCollectionRows("observation:" + identity,
      "SELECT * FROM sample_observations WHERE observation_id=? ORDER BY id", [.key(identity)])
    try connection.baselineCollectionRows("input:" + identity,
      "SELECT * FROM input_batches WHERE observation_id=? ORDER BY id", [.key(identity)])
    try connection.baselineCollectionRows("legacy-times:" + identity,
      "SELECT t.* FROM collection_legacy_times t JOIN sample_observations o ON o.id=t.observation_row WHERE o.observation_id=? ORDER BY t.id", [.key(identity)])
    try connection.baselineCollectionRows("metadata:" + identity,
      "SELECT * FROM collection_metadata WHERE identity=? ORDER BY id", [.key(identity)])
    try protectScreenOccurrence(identity)
    if let screen = record.screen {
      for content in [screen.text, try record.screenJSON ?? screenPayloadJSON(screen)] {
        let hash = probeHash(content)
        try connection.baselineCollectionRows("blob:" + hash,
          "SELECT * FROM collection_blobs WHERE hash=?", [.key(hash)])
      }
    }
  }
  func protectScreenOccurrence(_ identity: String) throws {
    try connection.baselineCollectionRows("screen:" + identity, """
      SELECT p.*,e.*,t.hash,t.content,t.created_ts,b.hash,b.content,b.created_ts FROM screen_payloads p
      LEFT JOIN evidence e ON e.id=p.evidence_id
      LEFT JOIN collection_blobs t ON t.hash=p.text_hash
      LEFT JOIN collection_blobs b ON b.hash=p.payload_hash
      WHERE p.occurrence_id=? ORDER BY p.evidence_id
      """, [.key(identity)])
  }
}
