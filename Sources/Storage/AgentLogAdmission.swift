import Core
import Foundation
import SQLite3

/// A transaction-local plan. Content writers consume it without re-deciding privacy.
struct AgentLogAdmissionPlan {
  var events: [AgentLogEvent]
  var eventIndices: [Int]
  var projections: [Bool]
  var growth: AgentLogGrowth
}

enum AgentLogBatchAdmission {
  case stopped(AgentLogGrowth)
  case owned(AgentLogTool, AgentLogOwnershipDecision)
  case content(AgentLogAdmissionPlan)
}

private struct LogAdmissionSubject {
  let time: Int
  let timestampKnown: Bool
  let identities: [AgentLogInstructionIdentity]
  let canonical: AgentLogInstructionIdentity?
  let legacy: AgentLogLegacyRefusal
  let source: String
  let sourceID: String?
  let occurrence: [SQLValue]?
}

extension ActivityStorage {
  /// The authoritative collection decision, called only inside the final writer transaction.
  func planLogBatch(_ events: [AgentLogEvent], evidence: [EvidenceText], position: LogPosition,
    checkpoint: AgentLogState?, tool: AgentLogTool?, oldest: Int) throws -> AgentLogBatchAdmission {
    let current = try settings()
    guard AgentLogRecordingPermission.allows(enabled: current.recordingEnabled, pausedUntil: current.pausedUntil, at: position.seenAt) else {
      let refusal = try planLogAdmission(events, evidence: evidence, position: position, oldest: oldest, recordingStopped: true)
      return .stopped(refusal.growth)
    }
    try establishAgentLogBaseline()
    if let tool {
      let ownership = try evaluateLogOwnership(events, position: position, checkpoint: checkpoint, tool: tool)
      if ownership.excludesSource { return .owned(tool, ownership) }
    }
    return .content(try planLogAdmission(events, evidence: evidence, position: position, oldest: oldest))
  }
  /// Install the complete represented graph and historical correspondences before sealing refusals.
  /// Both passes finish before any payload, occurrence, projection or provenance is written.
  func planLogAdmission(_ events: [AgentLogEvent], evidence: [EvidenceText], position: LogPosition?,
    oldest: Int = Int.min, recordingStopped: Bool = false) throws -> AgentLogAdmissionPlan {
    let source = position.map { AgentLogIdentity.decodedPath($0.path).storedKey } ?? ""
    let eventSubjects = events.map { event in
      LogAdmissionSubject(time: event.timestamp ?? event.observedAt, timestampKnown: event.timestamp != nil,
        identities: event.identities, canonical: event.canonicalIdentity ?? event.prompt?.agentLogIdentity,
        legacy: event.legacyRefusal, source: source, sourceID: nil,
        occurrence: position.map { [.key(event.tool.rawValue), .integer($0.device), .integer($0.inode), .integer(event.offset)] })
    }
    let projectionSubjects = evidence.map { row in
      LogAdmissionSubject(time: row.ts, timestampKnown: true,
        identities: nativePromptID(row).map { [$0] + nativeAliases(row) } ?? [], canonical: nativePromptID(row),
        legacy: row.legacyRefusal, source: row.source, sourceID: row.sourceID, occurrence: nil)
    }
    let subjects = eventSubjects + projectionSubjects
    for subject in subjects {
      guard subject.time < Int.max else { throw StorageError("Timestamp outside supported range") }
      try registerLogIdentities(subject.identities, canonical: subject.canonical)
      if recordingStopped { try legacyLogAdapter.sealRefusalOnlyProofs(subject.legacy) }
      if !recordingStopped, let identity = subject.canonical ?? subject.identities.first {
        try legacyLogAdapter.bindContent(subject.legacy, identity: identity)
      }
    }
    // Unknown event times retain the existing conservative historical-barrier policy.
    let unknownBarrier = try position != nil && (
      connection.integer("SELECT EXISTS(SELECT 1 FROM log_recording_history WHERE enabled=0 OR paused_until IS NOT NULL)") != 0
      || connection.integer("SELECT EXISTS(SELECT 1 FROM forgotten_ranges)") != 0)
    for subject in subjects {
      try resolveLogIdentities(subject.identities)
      if try logSubjectRefused(subject, historical: position != nil, unknownBarrier: unknownBarrier, recordingStopped: recordingStopped) {
        try refuseLogComponent(source: recordingStopped ? "agent-log-recording-stopped" : subject.source)
      }
    }
    var growth = AgentLogGrowth()
    var allowed: [Bool] = []
    for subject in subjects {
      try resolveLogIdentities(subject.identities)
      let refused = try logSubjectRefused(subject, historical: position != nil, unknownBarrier: unknownBarrier, recordingStopped: recordingStopped)
      if refused, let occurrence = subject.occurrence {
        try connection.run("INSERT OR IGNORE INTO agent_log_refusals VALUES(?,?,?,?,?)", occurrence + [.key("privacy")])
        growth.refusalOccurrences += Int(sqlite3_changes(connection.handle))
      }
      allowed.append(!refused && subject.time >= oldest)
    }
    return AgentLogAdmissionPlan(events: zip(events, allowed).compactMap { $1 ? $0 : nil },
      eventIndices: allowed.prefix(events.count).enumerated().compactMap { $1 ? $0 : nil },
      projections: Array(allowed.dropFirst(events.count)), growth: growth)
  }
  private func logSubjectRefused(_ subject: LogAdmissionSubject, historical: Bool, unknownBarrier: Bool, recordingStopped: Bool) throws -> Bool {
    if recordingStopped { return true }
    if try forgotten(TimeRange(subject.time, subject.time + 1)) { return true }
    if historical {
      if try !logRecordingAllowed(at: subject.time) { return true }
      if !subject.timestampKnown && unknownBarrier { return true }
    }
    if try legacyLogAdapter.refused(subject.legacy) || logComponentRefused() { return true }
    if let sourceID = subject.sourceID,
      try connection.integer("SELECT EXISTS(SELECT 1 FROM forgotten_sources WHERE source=? AND source_id=?)",
        [.key(subject.source), .key(sourceID)]) != 0 { return true }
    if let occurrence = subject.occurrence,
      try connection.integer("SELECT EXISTS(SELECT 1 FROM agent_log_refusals WHERE tool=? AND device=? AND inode=? AND byte_offset=?)", occurrence) != 0 { return true }
    return false
  }
  /// Fresh receipt evaluation occurs inside the same transaction as revocation and the cursor.
  func evaluateLogOwnership(_ events: [AgentLogEvent], position: LogPosition, checkpoint: AgentLogState?,
    tool: AgentLogTool) throws -> AgentLogOwnershipDecision {
    let registry = ownLogSources()
    let positive = events.compactMap { event -> AgentLogSessionSubject? in
      guard event.facts?.ownMarker == true else { return nil }
      return event.explicitSession ?? event.session
    }
    return try AgentLogOwnership.evaluate(state: checkpoint ?? AgentLogState(),
      sessions: [checkpoint?.session, checkpoint?.ownershipSession].compactMap { $0 }
        + events.flatMap { [$0.session, $0.explicitSession].compactMap { $0 } }, positiveSessions: positive,
      pathOwned: registry.contains(path: position.path, tool: tool) || ownLogSourceKnown(position, tool: tool),
      containsSession: { session in
        try self.connection.integer("SELECT EXISTS(SELECT 1 FROM agent_log_revoked_sessions WHERE tool=? AND session_id=?)",
          [.key(tool.rawValue), .key(session)]) != 0 || registry.containsSession(session, tool: tool)
      })
  }
  /// Deduplication chooses content, never permission. All privacy checks precede this call.
  @discardableResult func insertAdmittedEvidence(_ input: EvidenceText, alreadyMasked: Bool, applicationIdentity: String? = nil) throws -> Bool {
    var row = input
    if let id = nativePromptID(row) {
      try resolveLogIdentities([id])
      if try logContentID() != nil { return false }
      var next = id
      try connection.run("UPDATE log_identity_component SET expanded=0")
      while true {
        let seen = try connection.integer("SELECT expanded FROM log_identity_component WHERE identity=?", [.key(next)])
        if seen != 0 { break }
        try connection.run("UPDATE log_identity_component SET expanded=1 WHERE identity=?", [.key(next)])
        row.agentLogIdentity = next
        var parent: AgentLogInstructionIdentity?
        try connection.namedRows("SELECT canonical FROM agent_prompt_lineage WHERE alias=? ORDER BY canonical LIMIT 1", [.key(next)]) {
          parent = AgentLogIdentityCodec.instruction(try $0.text("canonical"))
        }
        guard let parent else { break }
        next = parent
      }
    }
    let textValue: (String) -> SQLValue = alreadyMasked ? SQLValue.maskedText : SQLValue.text
    try connection.collectionWrite("""
      INSERT OR IGNORE INTO evidence(ts,kind,source,source_id,document_key,project,text,application_identity) VALUES(?,?,?,?,?,?,?,?)
      """, [.integer(row.ts), textValue(row.kind.rawValue), .key(row.source), row.sourceID.map(SQLValue.key) ?? .null,
        textValue(row.documentKey), textValue(row.project), textValue(row.text), applicationIdentity.map(SQLValue.key) ?? .null])
    return sqlite3_changes(connection.handle) == 1
  }
}
