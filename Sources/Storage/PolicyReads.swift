import Core
import Foundation

/// Policy inputs: settings, and per probe attempt its run state and forgotten second.
/// They are reused only while no connection can have changed a table they read.
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
  /// data_version changes on another connection's commit (another process, the settings
  /// window, privacy forget). The policy write epoch changes on this connection's writes to
  /// a table a policy read has read, schema changes and rollbacks; see SQLiteConnection.
  /// Other writes through this connection (probe content, collection, counters) keep it.
  private func policyRevision() throws -> [Int] {
    [try connection.dataVersion(), connection.policyWriteEpoch]
  }
  func policyRead<T>(_ cached: (PolicyReads) -> T?, _ store: (inout PolicyReads, T) -> Void, _ read: () throws -> T) throws -> T {
    try locked {
      guard connection.handle != nil else { return try read() }
      let revision = try policyRevision()
      if let reads = policyReads, reads.revision == revision, let value = cached(reads) { PolicyReadStats.note(T.self, hit: true); return value }
      PolicyReadStats.note(T.self, hit: false)
      connection.readingPolicy += 1
      let value: T
      do { defer { connection.readingPolicy -= 1 }; value = try read() }
      // The revision was taken before the read, so a change during it is a later miss.
      // Inside a transaction the value is the snapshot plus this connection's own writes:
      // data_version is the snapshot's, and a rollback advances the policy write epoch.
      if policyReads?.revision != revision || (policyReads?.probeInputs.count ?? 0) >= 64 {
        policyReads = PolicyReads(revision: revision)
      }
      store(&policyReads!, value)
      return value
    }
  }
}

/// Hits and misses of policy reads in this process, by kind. Counted only while the CPU
/// harness or a test turns it on.
enum PolicyReadStats {
  static var counting = false
  private static let lock = NSLock()
  private static var counts: [String: (hits: Int, misses: Int)] = [:]
  static func note<T>(_ kind: T.Type, hit: Bool) {
    guard counting else { return }
    let name = kind == StorageSettings.self ? "settings" : "probe"
    lock.lock(); defer { lock.unlock() }
    var count = counts[name] ?? (0, 0)
    if hit { count.hits += 1 } else { count.misses += 1 }
    counts[name] = count
  }
  static func take() -> [String: (hits: Int, misses: Int)] {
    lock.lock(); defer { lock.unlock() }
    let result = counts; counts = [:]; return result
  }
}
