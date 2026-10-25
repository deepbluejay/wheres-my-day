import Core
import CryptoKit
import Foundation
import Darwin

extension ConversionResult {
  var numericCounts: [String: Int] {
    var values: [String: Int] = ["samples": samples, "evidence": evidence, "intervals": intervals,
      "shortened": shortened, "skippedAway": skippedAway, "skippedUnknown": skippedUnknown,
      "skippedEmpty": skippedEmpty, "refusedSamples": refusedSamples, "refusedEvidence": refusedEvidence,
      "refusedIntervals": refusedIntervals, "skippedHiddenEvidence": skippedHiddenEvidence,
      "evidence.forgotten": forgottenEvidence, "evidence.deduplicated": duplicateEvidence]
    for (table, counts) in tables {
      values["table.\(table).carried"] = counts.carried
      values["table.\(table).refused"] = counts.refused
      values["table.\(table).notCarried"] = counts.notCarried
    }
    for (kind, counts) in evidenceKinds {
      values["evidenceKind.\(kind).carried"] = counts.carried
      values["evidenceKind.\(kind).refused"] = counts.refused
      values["evidenceKind.\(kind).notCarried"] = counts.notCarried
    }
    // Unknown source kind names never enter metadata or output.
    for (kind, count) in skippedEvidenceKinds {
      let safe = ["input", "reply", "choice", "typed"].contains(kind) ? kind : "other"
      values["skippedKind." + safe, default: 0] += count
    }
    return values
  }
}

extension ActivityStorage {
  static func conversionFingerprint(_ url: URL) throws -> String {
    let directory = try OperationalDirectory(url.deletingLastPathComponent())
    let file = FileHandle(fileDescriptor: try directory.open(url.lastPathComponent, flags: O_RDONLY)!, closeOnDealloc: true)
    defer { try? file.close() }
    var digest = SHA256()
    while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty { digest.update(data: data) }
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
  }
  func persistConversionCounts(_ result: ConversionResult, since before: ConversionResult, source: String) throws {
    let previous = before.numericCounts
    for (key, value) in result.numericCounts {
      let difference = value - previous[key, default: 0]
      guard difference != 0 else { continue }
      try connection.run("""
        INSERT INTO conversion_progress(source,layer,last_row) VALUES(?,?,?)
        ON CONFLICT(source,layer) DO UPDATE SET last_row=last_row+excluded.last_row
        """, [.key(source), .key("count." + key), .integer(difference)])
    }
  }
  public func conversionCounts() throws -> [String: Int] {
    try locked {
      var counts: [String: Int] = [:]
      try connection.namedRows("SELECT layer,last_row FROM conversion_progress WHERE layer LIKE 'count.%'") {
        counts[String(try $0.text("layer").dropFirst(6))] = try $0.int("last_row")
      }
      return counts
    }
  }
  /// Closes this store after producing a movable, self-contained conversion file.
  public func finishConversion() throws {
    try locked {
      guard connection.truncateWAL() else { throw StorageError("Destination checkpoint incomplete") }
      // A closed conversion travels as one file. The first writer enables WAL again.
      var mode = ""
      try connection.namedRows("PRAGMA journal_mode=DELETE") { mode = try $0.text("journal_mode") }
      guard mode == "delete" else { throw StorageError("Destination journal finalization incomplete") }
      try connection.close()
      let directory = try OperationalDirectory(url.deletingLastPathComponent()), leaf = url.lastPathComponent
      for suffix in ["-wal", "-journal"] {
        guard try !directory.exists(leaf + suffix) else { throw StorageError("Destination journal remains") }
      }
      // System SQLite can leave inert shared memory after closing a rollback-mode file.
      // DELETE mode has already excluded every WAL reader; no committed frames live here.
      try directory.validate(leaf + "-shm")
      if try directory.exists(leaf + "-shm"), unlinkat(directory.descriptor, leaf + "-shm", 0) != 0 {
        throw StorageError("Destination shared memory remains")
      }
    }
  }
  /// Inspect before creating or modifying the destination. An unrelated SQLite file is never accepted.
  public static func validateOldConversionSource(_ url: URL, scope: DatabaseOpenScope) throws {
    let db = try SQLiteConnection(url: url, readOnly: true, immutable: true, scope: scope)
    guard try db.integer("PRAGMA application_id") == 0,
      (0...11).contains(try db.integer("PRAGMA user_version")),
      try db.integer("SELECT count(*) FROM sqlite_master WHERE type='table' AND name IN ('samples','evidence','activities')") == 3
    else { throw StorageError("Unsupported source schema") }
    var good = true
    try db.namedRows("PRAGMA integrity_check") { if try $0.text("integrity_check") != "ok" { good = false } }
    guard good else { throw StorageError("Source integrity failed") }
  }
}
