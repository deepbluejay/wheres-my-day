import Core
import Foundation

/// Indexed, additive main-45312a9 compatibility. Original rows are immutable.
/// Main's lost boundaries remain conservative proof classes, never ownership edges.
struct AgentLogLegacyAdapter {
  let connection: SQLiteConnection
  func refused(_ proof: AgentLogLegacyRefusal) throws -> Bool {
    for digest in proof.digests {
      if try connection.integer("SELECT EXISTS(SELECT 1 FROM agent_log_legacy_refusals WHERE digest=?)", [.key(digest)]) != 0 { return true }
    }
    guard let thread = proof.codexThread, let suffix = proof.codexSuffixDigest else { return false }
    if try connection.integer("""
      SELECT EXISTS(SELECT 1 FROM agent_log_legacy_refusal_compatibility WHERE thread=? AND suffix=?)
      """, [.key(thread), .key(suffix)]) != 0 { return true }
    return try proof.ambiguousCodexThread && connection.integer("""
      SELECT EXISTS(SELECT 1 FROM agent_log_legacy_refusal_compatibility WHERE thread='*' AND suffix='*')
      """) != 0
  }
  /// Seal only actual adopted native correspondences. Implicit queue/body proofs cannot create a refusal class.
  /// This writes hash-only privacy receipts without installing a modern content correspondence.
  func sealRefusalOnlyProofs(_ proof: AgentLogLegacyRefusal) throws {
    for digest in proof.nativeDigests { try sealHistoricalDigest(digest) }
    if let thread = proof.codexThread, let suffix = proof.codexSuffixDigest {
      try connection.namedRows("""
        SELECT DISTINCT digest FROM agent_log_legacy_compatibility WHERE thread=? AND suffix=?
        """, [.key(thread), .key(suffix)]) {
        try sealHistoricalDigest(AgentLogIdentityCodec.legacy(try $0.text("digest")))
      }
    }
  }
  private func sealHistoricalDigest(_ digest: AgentLogLegacyProof) throws {
    try connection.run("""
      INSERT OR IGNORE INTO agent_log_legacy_refusals(digest,source_id)
      SELECT digest,'legacy:key:sha256:'||digest FROM agent_log_legacy_evidence_keys WHERE digest=?
      """, [.key(digest)])
    try connection.run("""
      INSERT OR IGNORE INTO agent_log_legacy_refusal_compatibility
      SELECT thread,suffix,digest FROM agent_log_legacy_compatibility c WHERE digest=?
        AND EXISTS(SELECT 1 FROM agent_log_legacy_refusals r WHERE r.digest=c.digest)
      """, [.key(digest)])
  }
  // A content receipt can associate many historical rows with many canonical keys.
  // It is never a session/ownership edge. Implicit queue and body hashes are excluded.
  func bindContent(_ proof: AgentLogLegacyRefusal, identity: AgentLogInstructionIdentity) throws {
    for digest in proof.nativeDigests {
      try connection.run("""
        INSERT OR IGNORE INTO agent_log_content_keys(identity,evidence_id)
        SELECT ?,evidence_id FROM agent_log_legacy_evidence_keys WHERE digest=?
        """, [.key(identity), .key(digest)])
    }
    if let thread = proof.codexThread, let suffix = proof.codexSuffixDigest {
      try connection.run("""
        INSERT OR IGNORE INTO agent_log_content_keys(identity,evidence_id)
        SELECT ?,k.evidence_id FROM agent_log_legacy_compatibility c
        JOIN agent_log_legacy_evidence_keys k ON k.digest=c.digest WHERE c.thread=? AND c.suffix=?
        """, [.key(identity), .key(thread), .key(suffix)])
    }
  }
  func refuseEvidence(in range: TimeRange) throws {
    try connection.run("CREATE TEMP TABLE IF NOT EXISTS legacy_log_deletion_keys(digest TEXT PRIMARY KEY,source_id TEXT NOT NULL) WITHOUT ROWID")
    try connection.run("DELETE FROM legacy_log_deletion_keys")
    try connection.run("""
      INSERT OR IGNORE INTO legacy_log_deletion_keys
      SELECT k.digest,k.source_id FROM agent_log_legacy_evidence_keys k JOIN evidence e ON e.id=k.evidence_id
      WHERE e.ts>=? AND e.ts<?
      """, [.integer(range.start), .integer(range.end)])
    try connection.run("INSERT OR IGNORE INTO agent_log_legacy_refusals SELECT digest,source_id FROM legacy_log_deletion_keys")
    try connection.run("""
      INSERT OR IGNORE INTO agent_log_legacy_refusal_compatibility
      SELECT c.thread,c.suffix,c.digest FROM legacy_log_deletion_keys k
      JOIN agent_log_legacy_compatibility c ON c.digest=k.digest
      """)
    try connection.run("CREATE TEMP TABLE IF NOT EXISTS legacy_log_deletion_compatibility(thread TEXT,suffix TEXT,digest TEXT,PRIMARY KEY(thread,suffix,digest)) WITHOUT ROWID")
    try connection.run("DELETE FROM legacy_log_deletion_compatibility")
    try connection.run("""
      INSERT INTO legacy_log_deletion_compatibility
      SELECT c.thread,c.suffix,c.digest FROM legacy_log_deletion_keys k
      JOIN agent_log_legacy_compatibility c ON c.digest=k.digest
      """)
  }
  func verifyRefusals() throws {
    guard try connection.integer("""
      SELECT EXISTS(SELECT 1 FROM legacy_log_deletion_keys k
        WHERE NOT EXISTS(SELECT 1 FROM agent_log_legacy_refusals r WHERE r.digest=k.digest AND r.source_id=k.source_id))
      """) == 0 else { throw StorageError("Legacy deletion source marker missing") }
    guard try connection.integer("""
      SELECT EXISTS(SELECT 1 FROM legacy_log_deletion_compatibility k WHERE NOT EXISTS(
        SELECT 1 FROM agent_log_legacy_refusal_compatibility c WHERE c.thread=k.thread AND c.suffix=k.suffix AND c.digest=k.digest))
      """) == 0 else { throw StorageError("Legacy deletion compatibility marker missing") }
  }

  func createSchema() throws {
    try connection.run("CREATE TABLE IF NOT EXISTS agent_log_legacy_refusals(digest TEXT PRIMARY KEY,source_id TEXT NOT NULL) WITHOUT ROWID")
    try connection.run("CREATE TABLE IF NOT EXISTS agent_log_legacy_evidence_keys(evidence_id INTEGER PRIMARY KEY,source TEXT NOT NULL,source_id TEXT NOT NULL,digest TEXT NOT NULL)")
    try connection.run("CREATE INDEX IF NOT EXISTS agent_log_legacy_evidence_digest ON agent_log_legacy_evidence_keys(digest,evidence_id)")
    try connection.run("CREATE TABLE IF NOT EXISTS agent_log_content_keys(identity TEXT NOT NULL,evidence_id INTEGER NOT NULL,PRIMARY KEY(identity,evidence_id)) WITHOUT ROWID")
    try connection.run("CREATE INDEX IF NOT EXISTS agent_log_content_evidence ON agent_log_content_keys(evidence_id,identity)")
    try connection.run("CREATE TABLE IF NOT EXISTS agent_log_legacy_compatibility(thread TEXT NOT NULL,suffix TEXT NOT NULL,digest TEXT NOT NULL,PRIMARY KEY(thread,suffix,digest)) WITHOUT ROWID")
    try connection.run("CREATE INDEX IF NOT EXISTS agent_log_legacy_compatibility_digest ON agent_log_legacy_compatibility(digest)")
    try connection.run("CREATE TABLE IF NOT EXISTS agent_log_legacy_refusal_compatibility(thread TEXT NOT NULL,suffix TEXT NOT NULL,digest TEXT NOT NULL,PRIMARY KEY(thread,suffix,digest)) WITHOUT ROWID")
    try connection.run("""
      CREATE TRIGGER IF NOT EXISTS agent_log_content_cleanup AFTER DELETE ON evidence BEGIN
        DELETE FROM agent_log_content_keys WHERE evidence_id=OLD.id;
        DELETE FROM agent_log_legacy_compatibility WHERE digest IN
          (SELECT digest FROM agent_log_legacy_evidence_keys WHERE evidence_id=OLD.id)
          AND NOT EXISTS(SELECT 1 FROM agent_log_legacy_refusals r WHERE r.digest=agent_log_legacy_compatibility.digest)
          AND NOT EXISTS(SELECT 1 FROM agent_log_legacy_evidence_keys k
            WHERE k.digest=agent_log_legacy_compatibility.digest AND k.evidence_id<>OLD.id);
        DELETE FROM agent_log_legacy_evidence_keys WHERE evidence_id=OLD.id;
      END
      """)
  }
  func indexLegacyLogKey(_ old: String) throws {
    let digest = AgentLogLegacyRefusal.digest(old)
    try AgentLogLegacyRefusal.compatibilityKeys(old) { thread, suffix in
      try connection.run("INSERT OR IGNORE INTO agent_log_legacy_compatibility VALUES(?,?,?)", [.key(thread), .key(suffix), .key(digest)])
    }
  }
  func indexLegacyLogRefusal(_ old: String) throws {
    try indexLegacyLogKey(old)
    try connection.run("""
      INSERT OR IGNORE INTO agent_log_legacy_refusal_compatibility
      SELECT thread,suffix,digest FROM agent_log_legacy_compatibility WHERE digest=?
      """, [.key(AgentLogLegacyRefusal.digest(old))])
  }
  func adoptNativeIdentities() throws {
    // Historical rows are immutable. Only bounded one-way compatibility receipts are added.
    try connection.namedRows("SELECT id,source,source_id FROM evidence WHERE kind='prompt' AND source_id IS NOT NULL") { row in
      let old = try row.text("source_id"), id = try row.int("id")
      let digest = AgentLogLegacyRefusal.digest(old)
      try connection.run("INSERT OR IGNORE INTO agent_log_legacy_evidence_keys VALUES(?,?,?,?)", [.integer(id),
        .key(AgentLogIdentityCodec.legacySourceLabel(try row.text("source"))), .key(AgentLogLegacyRefusal.marker(digest)), .key(digest)])
      try indexLegacyLogKey(old)
      let canonical: AgentLogInstructionIdentity?
      if old.hasPrefix("claude:") {
        canonical = AgentLogIdentity.claude(String(old.dropFirst(7)))
      } else if old.hasPrefix("codex:") {
        let parts = old.dropFirst(6).split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        // Delimiter-bearing tuples are bound by incoming exact receipts, never by a guessed split.
        canonical = parts.count == 3 ? AgentLogIdentity.codex(
          thread: AgentLogIdentity.decoded(parts[0]).component, turn: parts[1], item: parts[2]) : nil
      } else { canonical = nil }
      if let canonical {
        try connection.run("INSERT OR IGNORE INTO agent_log_content_keys VALUES(?,?)", [.key(canonical), .integer(id)])
      }
    }
    try connection.namedRows("SELECT DISTINCT source_id FROM forgotten_sources") {
      let old = try $0.text("source_id"), digest = AgentLogLegacyRefusal.digest(old)
      try connection.run("INSERT OR IGNORE INTO agent_log_legacy_refusals VALUES(?,?)", [.key(digest), .key(AgentLogLegacyRefusal.marker(digest))])
      try indexLegacyLogRefusal(old)
    }
  }
  private func has(_ name: String) throws -> Bool {
    try connection.integer("SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE name=?)", [.key(name)]) != 0
  }
  func sourceKeys(path: String) -> [AgentLogPhysicalSource] {
    var seen = Set<AgentLogPhysicalSource>()
    return [AgentLogIdentity.decodedPath(path), AgentLogIdentityCodec.physical(path), AgentLogIdentityCodec.legacyPhysicalSpelling(path)]
      .filter { seen.insert($0).inserted }
  }
  func ownershipSourceKey(_ source: AgentLogPhysicalSource) -> AgentLogPhysicalSource {
    source.hasPrefix("activityprobe:path:sha256:") ? source : AgentLogIdentity.legacyPath(source.storedKey)
  }
  func ownSourceKeys(path: String) -> [AgentLogPhysicalSource] {
    sourceKeys(path: path) + [AgentLogIdentityCodec.legacyPhysicalSpelling(path).storedKey,
      Redaction.applyKnownSecrets(path).text].map(AgentLogIdentity.legacyPath)
  }
  func contentID() throws -> Int? {
    var found: Int?
    try connection.namedRows("""
      SELECT e.id AS id FROM log_identity_component c CROSS JOIN evidence e INDEXED BY evidence_prompt_id ON e.source_id=c.identity
      WHERE e.kind='prompt' AND NOT EXISTS(SELECT 1 FROM agent_log_legacy_evidence_keys k WHERE k.evidence_id=e.id)
      UNION SELECT m.evidence_id AS id FROM log_identity_component c CROSS JOIN agent_log_content_keys m ON m.identity=c.identity
      ORDER BY id LIMIT 1
      """) { found = try $0.int("id") }
    return found
  }
  func expandCorrespondences(_ identity: AgentLogInstructionIdentity) throws {
    guard try has("agent_log_content_keys") else { return }
    try connection.run("""
      INSERT OR IGNORE INTO log_identity_component(identity)
      SELECT m.identity FROM agent_log_content_keys n JOIN agent_log_content_keys m ON m.evidence_id=n.evidence_id
      WHERE n.identity=?
      """, [.key(identity)])
  }
  func deletionIdentity(_ id: String) throws -> String {
    let adopted = try has("agent_log_legacy_evidence_keys") && connection.integer(
      "SELECT EXISTS(SELECT 1 FROM agent_log_legacy_evidence_keys WHERE digest=?)", [.key(AgentLogLegacyRefusal.digest(id))]) != 0
    return adopted ? AgentLogLegacyRefusal.marker(AgentLogLegacyRefusal.digest(id)).storedKey : AgentLogIdentityCodec.instruction(id).storedKey
  }
  func seedDeletionContent(_ range: TimeRange) throws {
    guard try has("agent_log_content_keys") else { return }
    try connection.run("""
      INSERT OR IGNORE INTO log_deletion_identities
      SELECT 'agent-log-content',m.identity FROM agent_log_content_keys m JOIN evidence e ON e.id=m.evidence_id
      WHERE e.ts>=? AND e.ts<?
      """, [.integer(range.start), .integer(range.end)])
  }
  func seedDeletionProofs(_ range: TimeRange) throws {
    guard try has("agent_log_legacy_evidence_keys") else { return }
    try connection.run("""
      INSERT OR IGNORE INTO log_deletion_identities
      SELECT k.source,k.source_id FROM agent_log_legacy_evidence_keys k JOIN evidence e ON e.id=k.evidence_id
      WHERE e.ts>=? AND e.ts<?
      """, [.integer(range.start), .integer(range.end)])
  }
  func visitDeletionProofs(_ range: TimeRange, visit: (String, String) -> Void) throws {
    let values: [SQLValue] = [.integer(range.start), .integer(range.end)]
    if try has("agent_log_legacy_evidence_keys") {
      try connection.namedRows("""
        SELECT k.evidence_id,k.source,k.source_id,k.digest FROM agent_log_legacy_evidence_keys k
        JOIN evidence e ON e.id=k.evidence_id WHERE e.ts>=? AND e.ts<? ORDER BY k.evidence_id
        """, values) { row in
        for value in [String(try row.int("evidence_id")), try row.text("source"), try row.text("source_id"), try row.text("digest")] {
          visit("legacy-native", value)
        }
      }
    }
    if try has("agent_log_content_keys") {
      for query in [
        "SELECT m.identity AS first,CAST(m.evidence_id AS TEXT) AS second,'' AS third FROM agent_log_content_keys m JOIN evidence e ON e.id=m.evidence_id WHERE e.ts>=? AND e.ts<? ORDER BY m.identity,m.evidence_id",
        "SELECT c.thread AS first,c.suffix AS second,c.digest AS third FROM agent_log_legacy_compatibility c JOIN agent_log_legacy_evidence_keys k ON k.digest=c.digest JOIN evidence e ON e.id=k.evidence_id WHERE e.ts>=? AND e.ts<? ORDER BY c.thread,c.suffix,c.digest,k.evidence_id",
      ] {
        try connection.namedRows(query, values) { row in
          for name in ["first", "second", "third"] { visit("content-receipt", try row.text(name)) }
        }
      }
    }
  }
  func status() throws -> String {
    guard try has("agent_log_legacy_compatibility") else {
      return "legacy_ambiguous_keys=0 legacy_wildcard_refusals=0"
    }
    let ambiguous = try connection.integer("SELECT count(*) FROM (SELECT digest FROM agent_log_legacy_compatibility GROUP BY digest HAVING count(*)>1)")
    let wildcard = try connection.integer("SELECT count(DISTINCT digest) FROM agent_log_legacy_refusal_compatibility WHERE thread='*' AND suffix='*'")
    return "legacy_ambiguous_keys=\(ambiguous) legacy_wildcard_refusals=\(wildcard)"
  }
}
extension SQLiteConnection {
  var legacyLogAdapter: AgentLogLegacyAdapter { AgentLogLegacyAdapter(connection: self) }
}
extension ActivityStorage {
  var legacyLogAdapter: AgentLogLegacyAdapter { connection.legacyLogAdapter }
  public func agentLogLegacyStatus() throws -> String { try locked { try legacyLogAdapter.status() } }
}
