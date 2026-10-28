import Core
import Foundation
import SQLite3

/// Committed policy inputs: settings, and per probe attempt its run state and forgotten
/// second. They are reused only while no connection has changed the database.
/// Time-dependent checks (pause expiry, review lease) are still evaluated on every call.
struct PolicyReads {
  let revision: [Int]
  var settings: StorageSettings?
  var probeInputs: [String: ProbeInputs] = [:]
}
struct ProbeInputs {
  var settings: StorageSettings
  var sameRun: Bool
  var excluded: Bool
  var open: Bool
  var forgotten: Bool
}

extension ActivityStorage {
  /// Another connection's commit changes data_version. A write through this connection
  /// changes its write epoch or change count, including writes a rollback later discards.
  private func policyRevision() throws -> [Int] {
    [try connection.integer("SELECT data_version FROM pragma_data_version"),
     Int(sqlite3_total_changes64(connection.handle)), connection.writeEpoch]
  }
  func policyRead<T>(_ cached: (PolicyReads) -> T?, _ store: (inout PolicyReads, T) -> Void, _ read: () throws -> T) throws -> T {
    try locked {
      guard connection.handle != nil else { return try read() }
      let revision = try policyRevision()
      if let reads = policyReads, reads.revision == revision, let value = cached(reads) { return value }
      let value = try read()
      // Only reads outside a transaction are stored: a transaction can hold an older
      // snapshot or its own uncommitted writes. A stored value read later inside one is
      // still exact while the revision matches.
      guard sqlite3_get_autocommit(connection.handle) != 0 else { return value }
      if policyReads?.revision != revision || (policyReads?.probeInputs.count ?? 0) >= 64 {
        policyReads = PolicyReads(revision: revision)
      }
      store(&policyReads!, value)
      return value
    }
  }
}
