import Core
import CryptoKit
import Foundation
import Darwin
import SQLite3

extension SQLiteConnection {
  func createAgentLogSchema() throws {
    for sql in [
      """
      CREATE TABLE IF NOT EXISTS agent_log_payloads (
        id INTEGER PRIMARY KEY, digest TEXT NOT NULL UNIQUE, payload TEXT NOT NULL)
      """,
      """
      CREATE TABLE IF NOT EXISTS agent_log_events (
        id INTEGER PRIMARY KEY, tool TEXT NOT NULL, source TEXT NOT NULL,
        device INTEGER NOT NULL, inode INTEGER NOT NULL, byte_offset INTEGER NOT NULL,
        ts INTEGER NOT NULL, timestamp_known INTEGER NOT NULL, observed_ts INTEGER NOT NULL,
        session_id TEXT, project TEXT NOT NULL, record_type TEXT NOT NULL, role TEXT NOT NULL, flags TEXT NOT NULL,
        parse_status TEXT NOT NULL, byte_count INTEGER NOT NULL,
        payload_id INTEGER NOT NULL REFERENCES agent_log_payloads(id),
        UNIQUE(tool,device,inode,byte_offset,payload_id))
      """,
      "CREATE INDEX IF NOT EXISTS agent_log_events_time ON agent_log_events(ts)",
      "CREATE INDEX IF NOT EXISTS agent_log_events_payload ON agent_log_events(payload_id)",
      "CREATE INDEX IF NOT EXISTS agent_log_events_source ON agent_log_events(device,inode,source)",
      """
      CREATE TABLE IF NOT EXISTS agent_log_event_identities (
        event_id INTEGER NOT NULL REFERENCES agent_log_events(id) ON DELETE CASCADE,
        identity TEXT NOT NULL, PRIMARY KEY(event_id,identity))
      """,
      "CREATE INDEX IF NOT EXISTS agent_log_event_identity ON agent_log_event_identities(identity)",
      """
      CREATE TABLE IF NOT EXISTS agent_log_refusals (
        tool TEXT NOT NULL, device INTEGER NOT NULL, inode INTEGER NOT NULL, byte_offset INTEGER NOT NULL,
        reason TEXT NOT NULL, PRIMARY KEY(tool,device,inode,byte_offset))
      """,
      """
      CREATE TABLE IF NOT EXISTS agent_prompt_aliases (
        alias TEXT PRIMARY KEY, canonical TEXT NOT NULL)
      """,
      "CREATE INDEX IF NOT EXISTS agent_prompt_alias_canonical ON agent_prompt_aliases(canonical)",
      "CREATE TABLE IF NOT EXISTS agent_prompt_edges(alias TEXT NOT NULL, canonical TEXT NOT NULL, PRIMARY KEY(alias,canonical))",
      "CREATE INDEX IF NOT EXISTS agent_prompt_edge_canonical ON agent_prompt_edges(canonical,alias)",
      "CREATE VIEW IF NOT EXISTS agent_prompt_lineage AS SELECT alias,canonical FROM agent_prompt_aliases UNION SELECT alias,canonical FROM agent_prompt_edges",
      "CREATE TABLE IF NOT EXISTS agent_log_source_evidence(tool TEXT NOT NULL,device INTEGER NOT NULL,inode INTEGER NOT NULL,source TEXT NOT NULL,evidence_id INTEGER NOT NULL,PRIMARY KEY(tool,device,inode,source,evidence_id))",
      "CREATE INDEX IF NOT EXISTS agent_log_source_evidence_id ON agent_log_source_evidence(evidence_id)",
      "CREATE INDEX IF NOT EXISTS agent_log_source_evidence_source ON agent_log_source_evidence(device,inode,source)",
      "CREATE TRIGGER IF NOT EXISTS agent_log_source_evidence_cleanup AFTER DELETE ON evidence BEGIN DELETE FROM agent_log_source_evidence WHERE evidence_id=OLD.id; END",
      "CREATE TABLE IF NOT EXISTS agent_log_own_sources(device INTEGER NOT NULL,inode INTEGER NOT NULL,path TEXT NOT NULL,PRIMARY KEY(device,inode,path))",
      """
      CREATE TRIGGER IF NOT EXISTS agent_log_payload_cleanup AFTER DELETE ON agent_log_events BEGIN
        DELETE FROM agent_log_event_identities WHERE event_id=OLD.id;
        DELETE FROM agent_log_payloads WHERE id=OLD.payload_id
          AND NOT EXISTS(SELECT 1 FROM agent_log_events WHERE payload_id=OLD.payload_id);
      END
      """,
    ] { try run(sql) }
    try adoptAgentLogProvenance()
  }

  func adoptAgentLogProvenance() throws {
    for sql in [
      "CREATE TABLE IF NOT EXISTS agent_log_evidence_origins(evidence_id INTEGER PRIMARY KEY,tool TEXT NOT NULL,device INTEGER NOT NULL,inode INTEGER NOT NULL,source TEXT NOT NULL)",
      "CREATE INDEX IF NOT EXISTS agent_log_evidence_origins_source ON agent_log_evidence_origins(tool,device,inode,source,evidence_id)",
      "CREATE TRIGGER IF NOT EXISTS agent_log_evidence_origin_cleanup AFTER DELETE ON evidence BEGIN DELETE FROM agent_log_evidence_origins WHERE evidence_id=OLD.id; END",
      "CREATE TABLE IF NOT EXISTS agent_log_owned_evidence_origins(evidence_id INTEGER PRIMARY KEY REFERENCES evidence(id) ON DELETE CASCADE)",
      "CREATE TRIGGER IF NOT EXISTS agent_log_owned_evidence_origin_cleanup AFTER DELETE ON evidence BEGIN DELETE FROM agent_log_owned_evidence_origins WHERE evidence_id=OLD.id; END",
      "CREATE TABLE IF NOT EXISTS agent_log_tool_own_sources(tool TEXT NOT NULL,device INTEGER NOT NULL,inode INTEGER NOT NULL,path TEXT NOT NULL,PRIMARY KEY(tool,device,inode,path))",
      "CREATE TABLE IF NOT EXISTS agent_log_event_sessions(event_id INTEGER PRIMARY KEY REFERENCES agent_log_events(id) ON DELETE CASCADE,tool TEXT NOT NULL,session_id TEXT NOT NULL)",
      "CREATE INDEX IF NOT EXISTS agent_log_event_session ON agent_log_event_sessions(tool,session_id,event_id)",
      "CREATE TABLE IF NOT EXISTS agent_log_inherited_sessions(event_id INTEGER PRIMARY KEY REFERENCES agent_log_events(id) ON DELETE CASCADE,tool TEXT NOT NULL,session_id TEXT NOT NULL)",
      "CREATE INDEX IF NOT EXISTS agent_log_inherited_session ON agent_log_inherited_sessions(tool,session_id,event_id)",
      "CREATE TRIGGER IF NOT EXISTS agent_log_inherited_session_cleanup AFTER DELETE ON agent_log_events BEGIN DELETE FROM agent_log_inherited_sessions WHERE event_id=OLD.id; END",
      "CREATE TRIGGER IF NOT EXISTS agent_log_event_session_cleanup AFTER DELETE ON agent_log_events BEGIN DELETE FROM agent_log_event_sessions WHERE event_id=OLD.id; END",
      "CREATE TABLE IF NOT EXISTS agent_log_revoked_sessions(tool TEXT NOT NULL,session_id TEXT NOT NULL,PRIMARY KEY(tool,session_id))",
      "CREATE INDEX IF NOT EXISTS agent_log_events_tool_source ON agent_log_events(tool,device,inode,source)",
      "CREATE INDEX IF NOT EXISTS agent_log_events_session ON agent_log_events(tool,session_id,device,inode,source)",
      "CREATE INDEX IF NOT EXISTS log_positions_session ON log_positions(json_extract(state,'$.session')) WHERE json_valid(state)",
      "CREATE INDEX IF NOT EXISTS log_positions_ownership_session ON log_positions(json_extract(state,'$.ownershipSession')) WHERE json_valid(state)",
    ] { try run(sql) }
  }
}

extension ActivityStorage {
  func ownLogSourceKnown(_ position: LogPosition, tool: AgentLogTool) throws -> Bool {
    for key in legacyLogAdapter.ownSourceKeys(path: position.path) {
      if try connection.integer("SELECT count(*) FROM agent_log_tool_own_sources WHERE tool=? AND device=? AND inode=? AND path=?",
        [.key(tool.rawValue), .integer(position.device), .integer(position.inode), .key(key)]) > 0 { return true }
    }
    return false
  }
  func insertAdmittedLogEvents(_ events: [PreparedAgentLogEvent], position: LogPosition) throws -> AgentLogGrowth {
    var growth = AgentLogGrowth()
    for prepared in events {
      let event = prepared.event
      let time = event.timestamp ?? event.observedAt
      let key: [SQLValue] = [.key(event.tool.rawValue), .integer(position.device),
        .integer(position.inode), .integer(event.offset)]
      let payload = prepared.payload, digest = prepared.digest
      try connection.run("INSERT OR IGNORE INTO agent_log_payloads(digest,payload) VALUES(?,?)", [.key(digest), .maskedText(payload)])
      if sqlite3_changes(connection.handle) == 1 {
        growth.payloads += 1
        growth.payloadBytes += payload.utf8.count
      }
      let payloadID = try connection.integer("SELECT id FROM agent_log_payloads WHERE digest=?", [.key(digest)])
      let flags = prepared.flags
      try connection.run("""
        INSERT OR IGNORE INTO agent_log_events(tool,source,device,inode,byte_offset,ts,timestamp_known,
          observed_ts,session_id,project,record_type,role,flags,parse_status,byte_count,payload_id)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """, [.key(event.tool.rawValue), .maskedText(AgentLogIdentity.decodedPath(position.path)), .integer(position.device), .integer(position.inode),
          .integer(event.offset), .integer(time), .integer(event.timestamp == nil ? 0 : 1), .integer(event.observedAt), event.session.map(SQLValue.text) ?? .null, .maskedText(event.project),
          .maskedText(event.type), .maskedText(event.role), .maskedText(flags), .maskedText(event.parseStatus), .integer(event.byteCount), .integer(payloadID)])
      if sqlite3_changes(connection.handle) == 1 {
        growth.events += 1
        growth.sourceBytes += event.byteCount
      }
      let eventID = try connection.integer("SELECT id FROM agent_log_events WHERE tool=? AND device=? AND inode=? AND byte_offset=? AND payload_id=?", key + [.integer(payloadID)])
      // The event column is display-masked; ownership uses this exact inherited subject.
      if let session = event.session, session.isUsable {
        try connection.run("INSERT OR IGNORE INTO agent_log_inherited_sessions VALUES(?,?,?)",
          [.integer(eventID), .key(event.tool.rawValue), .key(session)])
      }
      if let session = event.explicitSession {
        try connection.run("INSERT OR IGNORE INTO agent_log_event_sessions VALUES(?,?,?)",
          [.integer(eventID), .key(event.tool.rawValue), .key(session)])
      }
      for id in event.identities {
        try connection.run("INSERT OR IGNORE INTO agent_log_event_identities VALUES(?,?)", [.integer(eventID), .key(id)])
      }
    }
    return growth
  }
  /// Ownership receipts are only ever added: the baseline, own sources, revoked sessions,
  /// and the hash-only registry folder.
  public func agentLogOwnershipRevision() throws -> String? {
    try agentLogOwnershipCounts().map { $0 + ":" + (try ownLogSources().revision()) }
  }
  public func agentLogOwnershipCounts() throws -> String? {
    try locked {
      try ["agent_log_own_baseline", "agent_log_tool_own_sources", "agent_log_revoked_sessions"].map { table in
        try connection.integer("SELECT count(*) FROM sqlite_master WHERE type='table' AND name=?", [.key(table)]) == 0
          ? -1 : connection.integer("SELECT count(*) FROM \(table)")
      }
    }.map(String.init).joined(separator: ":")
  }
  public func agentLogOwnershipReceipts() throws -> Set<String>? { Set(try ownLogSources().inventory()) }
  public func agentLogToolOwnSources() throws -> Set<AgentLogToolOwnSource>? {
    try locked {
      guard try connection.integer("SELECT count(*) FROM sqlite_master WHERE type='table' AND name='agent_log_tool_own_sources'") == 1 else { return nil }
      var sources = Set<AgentLogToolOwnSource>()
      try connection.rows("SELECT tool, device, inode, path FROM agent_log_tool_own_sources") {
        let path = SQLiteConnection.text($0, 3)
        sources.insert(AgentLogToolOwnSource(tool: SQLiteConnection.text($0, 0), device: SQLiteConnection.int($0, 1), inode: SQLiteConnection.int($0, 2),
          pathDigest: SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()))
      }
      return sources
    }
  }
  func ownLogSources() -> AgentLogOwnSources {
    AgentLogOwnSources(appDataDirectory: appDataDirectory, digest: {
      SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined()
    }, retainedReceipt: { key in
      try self.connection.integer("SELECT EXISTS(SELECT 1 FROM agent_log_own_baseline WHERE receipt=?)", [.key(key)]) != 0
    }, receiptExists: { url in
      var info = stat()
      while true {
        if stat(url.path, &info) == 0 { return true }
        let code = errno
        if code == EINTR { continue }
        if code == ENOENT { return false }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
      }
    })
  }
  // Deduplication retains every permitted physical provenance, using explicit IDs only.
  func logEvidenceID(_ row: EvidenceText, inserted: Bool) throws -> Int? {
    if inserted { return Int(sqlite3_last_insert_rowid(connection.handle)) }
    guard let id = row.sourceID else { return nil }
    if row.kind == .prompt, AgentLogEventParser.isNativePromptIdentity(id) {
      try resolveLogIdentities([AgentLogIdentityCodec.instruction(id)])
      return try logContentID()
    }
    var found: Int?
    try connection.namedRows("SELECT id FROM evidence WHERE kind=? AND source=? AND source_id=?",
      [.key(row.kind.rawValue), .key(row.source), .key(id)]) { found = try $0.int("id") }
    return found
  }
  static let ownLogSessionSourcesSQL = """
      SELECT DISTINCT e.device,e.inode,e.source FROM agent_log_inherited_sessions s
        JOIN agent_log_events e ON e.id=s.event_id WHERE s.tool=? AND s.session_id=?
      UNION
      SELECT e.device,e.inode,e.source FROM agent_log_event_sessions s
        JOIN agent_log_events e ON e.id=s.event_id WHERE s.tool=? AND s.session_id=?
      UNION
      SELECT p.device,p.inode,p.path AS source FROM log_positions p
      WHERE json_valid(p.state) AND json_extract(p.state,'$.session')=?
        AND (json_extract(p.state,'$.tool')=? OR (json_extract(p.state,'$.tool') IS NULL AND EXISTS(
          SELECT 1 FROM agent_log_events e WHERE e.tool=? AND e.device=p.device AND e.inode=p.inode AND e.source=p.path)
          AND NOT EXISTS(SELECT 1 FROM agent_log_events other WHERE other.tool=? AND other.device=p.device
            AND other.inode=p.inode AND other.source=p.path)))
      UNION
      SELECT p.device,p.inode,p.path AS source FROM log_positions p
      WHERE json_valid(p.state) AND json_extract(p.state,'$.ownershipSession')=?
        AND (json_extract(p.state,'$.tool')=? OR (json_extract(p.state,'$.tool') IS NULL AND EXISTS(
          SELECT 1 FROM agent_log_events e WHERE e.tool=? AND e.device=p.device AND e.inode=p.inode AND e.source=p.path)
          AND NOT EXISTS(SELECT 1 FROM agent_log_events other WHERE other.tool=? AND other.device=p.device
            AND other.inode=p.inode AND other.source=p.path)))
      """

  static func ownLogSessionSourceValues(_ session: AgentLogSessionSubject, tool: AgentLogTool) -> [SQLValue] {
    let other: AgentLogTool = tool == .claude ? .codex : .claude
    return [.key(tool.rawValue), .key(session), .key(tool.rawValue), .key(session),
      .key(session), .key(tool.rawValue), .key(tool.rawValue), .key(other.rawValue),
      .key(session), .key(tool.rawValue), .key(tool.rawValue), .key(other.rawValue)]
  }

  /// Explicit same-session copies are revoked in the discovering checkpoint's transaction.
  func purgeOwnLogSession(_ session: AgentLogSessionSubject, tool: AgentLogTool) throws {
    // Standalone revocation needs the same proof and atomicity as checkpoint admission.
    if sqlite3_get_autocommit(connection.handle) != 0 {
      try connection.transaction { try purgeOwnLogSession(session, tool: tool) }
      return
    }
    let identity = session
    guard identity.isUsable else { return }
    try connection.run("DELETE FROM git_working_folders WHERE tool=? AND session=?",
      [.key(tool.rawValue), .key(identity)])
    if sqlite3_changes(connection.handle) > 0 { try cleanGitOrphans() }
    // This receipt commits only after all revocations and the discovering checkpoint succeed.
    // Admission checks this database receipt as well as the filesystem ownership registry.
    guard try connection.integer("SELECT count(*) FROM agent_log_revoked_sessions WHERE tool=? AND session_id=?",
      [.key(tool.rawValue), .key(identity)]) == 0 else { return }
    var sources: [(position: LogPosition, key: AgentLogPhysicalSource)] = []
    try connection.namedRows(Self.ownLogSessionSourcesSQL, Self.ownLogSessionSourceValues(identity, tool: tool)) { row in
      sources.append((LogPosition(path: "", device: try row.int("device"),
        inode: try row.int("inode"), offset: 0, state: "{}", seenAt: 0), AgentLogIdentityCodec.physical(try row.text("source"))))
    }
    for source in sources {
      try connection.run("INSERT OR IGNORE INTO agent_log_tool_own_sources VALUES(?,?,?,?)",
        [.key(tool.rawValue), .integer(source.position.device), .integer(source.position.inode),
          .key(legacyLogAdapter.ownershipSourceKey(source.key))])
      try purgeOwnLogSource(source.position, tool: tool, sourceKey: source.key)
    }
    try connection.run("INSERT INTO agent_log_revoked_sessions VALUES(?,?)", [.key(tool.rawValue), .key(identity)])
  }
  /// A late own marker revokes this physical source in the same transaction as its checkpoint.
  static let legacyOccurrenceCleanupSQL = """
    DELETE FROM evidence INDEXED BY evidence_prompt_id WHERE kind='prompt' AND source_id>=? COLLATE BINARY AND source_id<? COLLATE BINARY
      AND NOT EXISTS(SELECT 1 FROM agent_log_source_evidence s WHERE s.evidence_id=evidence.id)
    """
  static func legacyOccurrenceCleanupValues(_ position: LogPosition, tool: AgentLogTool) -> [SQLValue] {
    let stem = "\(tool.rawValue):occurrence:\(position.device):\(position.inode)"
    // ':' and ';' are adjacent UTF-8 bytes. This range matches exactly the complete prefix.
    return [.key(stem + ":"), .key(stem + ";")]
  }
  func purgeOwnLogSource(_ position: LogPosition, tool: AgentLogTool, sourceKey: AgentLogPhysicalSource) throws {
    try purgeOwnGitSource(position, tool: tool, sourceKey: sourceKey)
    let values: [SQLValue] = [.key(tool.rawValue), .integer(position.device), .integer(position.inode),
      .key(sourceKey)]
    // Remember proven origin ownership without copying a historical raw path into a new row.
    try connection.run("""
      INSERT OR IGNORE INTO agent_log_owned_evidence_origins
      SELECT evidence_id FROM agent_log_evidence_origins WHERE tool=? AND device=? AND inode=? AND source=?
      """, values)
    // Keep the candidates before removing receipts, then delete only unshared canonical content.
    try connection.run("CREATE TEMP TABLE IF NOT EXISTS revoked_log_evidence(id INTEGER PRIMARY KEY)")
    try connection.run("DELETE FROM revoked_log_evidence")
    try connection.run("""
      INSERT OR IGNORE INTO revoked_log_evidence SELECT evidence_id FROM agent_log_source_evidence
      WHERE tool=? AND device=? AND inode=? AND source=?
      """, values)
    try connection.run("DELETE FROM agent_log_source_evidence WHERE tool=? AND device=? AND inode=? AND source=?", values)
    try connection.collectionWrite("""
      DELETE FROM evidence WHERE id IN (SELECT id FROM revoked_log_evidence)
        AND NOT EXISTS(SELECT 1 FROM agent_log_source_evidence s WHERE s.evidence_id=evidence.id)
        AND (EXISTS(SELECT 1 FROM agent_log_owned_evidence_origins o WHERE o.evidence_id=evidence.id)
          OR EXISTS(SELECT 1 FROM agent_log_evidence_origins o JOIN agent_log_tool_own_sources own
            ON own.tool=o.tool AND own.device=o.device AND own.inode=o.inode AND own.path=o.source
            WHERE o.evidence_id=evidence.id))
      """)
    // A legacy occurrence ID proves physical provenance; basename/lineage equality cannot.
    try connection.collectionWrite(Self.legacyOccurrenceCleanupSQL, Self.legacyOccurrenceCleanupValues(position, tool: tool))
    try connection.run("DELETE FROM agent_log_events WHERE tool=? AND device=? AND inode=? AND source=?", values)
  }
  public func agentLogGrowth() throws -> AgentLogGrowth {
    try locked {
      var growth = AgentLogGrowth()
      growth.events = try connection.integer("SELECT count(*) FROM agent_log_events")
      growth.payloads = try connection.integer("SELECT count(*) FROM agent_log_payloads")
      growth.refusalOccurrences = try connection.integer("SELECT count(*) FROM agent_log_refusals")
      growth.sourceBytes = try connection.integer("SELECT COALESCE(sum(byte_count),0) FROM agent_log_events")
      growth.payloadBytes = try connection.integer("SELECT COALESCE(sum(length(CAST(payload AS BLOB))),0) FROM agent_log_payloads")
      return growth
    }
  }
}

extension AgentLogEvent {
  func maskedForPersistence() -> AgentLogEvent {
    var safe = self
    let mask = AgentLogEventParser.safeString
    safe.workingFolder = nil
    safe.session = session
    safe.explicitSession = explicitSession
    safe.canonicalIdentity = canonicalIdentity
    safe.project = mask(project)
    safe.type = mask(type)
    safe.role = mask(role)
    safe.flags = flags.map(mask)
    safe.identities = identities
    safe.parseStatus = mask(parseStatus)
    safe.prompt?.agentLogIdentity = prompt?.agentLogIdentity
    safe.prompt?.agentLogAliases = prompt?.agentLogAliases ?? []
    return safe
  }
}

/// Content preparation carries no admission authority. Policy and ownership stay transactional.
struct PreparedAgentLogEvent {
  let event: AgentLogEvent
  let payload: String
  let digest: AgentLogPayloadDigest
  let flags: String
  init(_ input: AgentLogEvent) throws {
    var safe = autoreleasepool { input.maskedForPersistence() }
    // Encode flags before allocating the re-masked payload. The writer needs
    // only the encoded flags, so release their selected representation first.
    flags = try autoreleasepool {
      String(decoding: try JSONEncoder().encode(safe.flags.map { Redaction.apply($0).text }), as: UTF8.self)
    }
    safe.flags.removeAll()
    safe.payload = ""
    event = safe
    payload = autoreleasepool { AgentLogEventParser.maskedPayload(input.payload) }
    digest = AgentLogIdentityCodec.payload(SHA256.hash(data: Data(payload.utf8)).map { String(format: "%02x", $0) }.joined())
  }
}
