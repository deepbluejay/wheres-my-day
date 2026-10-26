import Core
import Foundation

extension ActivityStorage {
  func logContentID() throws -> Int? {
    try legacyLogAdapter.contentID()
  }

  // Read-only deletion preview must also work before the next writable migration.
  func logLineageRelation() throws -> String? {
    if try connection.integer("SELECT count(*) FROM sqlite_master WHERE name='agent_prompt_lineage'") > 0 {
      return "agent_prompt_lineage"
    }
    return nil
  }
  // The graph and frontier live in SQLite rather than an unbounded Swift Set.
  // This scratch relation is rebuilt for each resolution and is never a content store.
  func resolveLogIdentities(_ seeds: [AgentLogInstructionIdentity]) throws {
    try connection.run("CREATE TEMP TABLE IF NOT EXISTS log_identity_component(identity TEXT PRIMARY KEY, expanded INTEGER NOT NULL DEFAULT 0)")
    try connection.run("CREATE INDEX IF NOT EXISTS temp.log_identity_frontier ON log_identity_component(expanded,identity)")
    try connection.run("DELETE FROM log_identity_component")
    for seed in seeds {
      try connection.run("INSERT OR IGNORE INTO log_identity_component(identity) VALUES(?)", [.key(seed)])
    }
    try expandLogIdentities()
  }
  func expandLogIdentities() throws {
    guard let relation = try logLineageRelation() else { return }
    while true {
      var next: AgentLogInstructionIdentity?
      try connection.namedRows("SELECT identity FROM log_identity_component WHERE expanded=0 LIMIT 1") { next = AgentLogIdentityCodec.instruction(try $0.text("identity")) }
      guard let next else { break }
      try connection.run("UPDATE log_identity_component SET expanded=1 WHERE identity=?", [.key(next)])
      try legacyLogAdapter.expandCorrespondences(next)
      try connection.run("""
        INSERT OR IGNORE INTO log_identity_component(identity)
        SELECT canonical FROM \(relation) WHERE alias=?
        UNION SELECT alias FROM \(relation) WHERE canonical=?
        """, [.key(next), .key(next)])
    }
  }
  func resolveDeletionIdentities(_ range: TimeRange) throws {
    try resolveLogIdentities([])
    try connection.run("CREATE TEMP TABLE IF NOT EXISTS log_deletion_identities(source TEXT NOT NULL, identity TEXT NOT NULL, PRIMARY KEY(source,identity))")
    try connection.run("CREATE INDEX IF NOT EXISTS temp.log_deletion_identity ON log_deletion_identities(identity)")
    try connection.run("DELETE FROM log_deletion_identities")
    try connection.namedRows("SELECT source,source_id FROM evidence WHERE ts>=? AND ts<? AND source_id IS NOT NULL",
      [.integer(range.start), .integer(range.end)]) { row in
      let source = AgentLogIdentityCodec.legacySourceLabel(try row.text("source"))
      let id = try row.text("source_id")
      let safe = try legacyLogAdapter.deletionIdentity(id)
      try connection.run("INSERT OR IGNORE INTO log_deletion_identities VALUES(?,?)", [.key(source), .key(safe)])
    }
    try legacyLogAdapter.seedDeletionContent(range)
    if try connection.integer("SELECT count(*) FROM sqlite_master WHERE name='agent_log_events'") > 0 {
      try connection.run("""
        INSERT OR IGNORE INTO log_deletion_identities
        SELECT e.source,i.identity FROM agent_log_event_identities i JOIN agent_log_events e ON e.id=i.event_id WHERE e.ts>=? AND e.ts<?
        """, [.integer(range.start), .integer(range.end)])
    }
    try connection.run("INSERT OR IGNORE INTO log_identity_component(identity) SELECT identity FROM log_deletion_identities")
    if try connection.integer("SELECT count(*) FROM sqlite_master WHERE name='agent_prompt_aliases'") > 0 {
      try expandLogIdentities()
    }
    try connection.run("""
      INSERT OR IGNORE INTO log_deletion_identities
      SELECT 'agent-log-lineage',c.identity FROM log_identity_component c
      WHERE NOT EXISTS(SELECT 1 FROM log_deletion_identities d WHERE d.identity=c.identity)
      """)
    try legacyLogAdapter.seedDeletionProofs(range)
  }
  func logComponentRefused() throws -> Bool {
    try connection.integer("""
      SELECT EXISTS(SELECT 1 FROM log_identity_component c
        WHERE EXISTS(SELECT 1 FROM forgotten_sources f WHERE f.source_id=c.identity))
      """) != 0
  }
  func refuseLogComponent(source: String) throws {
    try connection.namedRows("SELECT identity FROM log_identity_component") {
      try connection.run("INSERT OR IGNORE INTO forgotten_sources VALUES(?,?)", [
        .key(AgentLogIdentityCodec.legacySourceLabel(source)), .key(AgentLogIdentityCodec.instruction(try $0.text("identity")))])
    }
  }
  func registerLogIdentities(_ identities: [AgentLogInstructionIdentity], canonical: AgentLogInstructionIdentity? = nil) throws {
    guard let first = canonical ?? identities.first else { return }
    for identity in identities where identity != first {
      try connection.run("INSERT OR IGNORE INTO agent_prompt_edges VALUES(?,?)", [.key(identity), .key(first)])
    }
  }
}