import Foundation

/// Classified from once-decoded metadata. Display strings never become ownership proof.
public struct AgentLogRecordFacts {
  public var session: AgentLogSessionTransition
  public var isHeader: Bool
  public var sessionExact: Bool
  public var legacySession: AgentLogLegacyProof?
  public var project: String?
  public var projectTimestamp: Int? = nil
  public var projectOwned: Bool
  public var headerOrigin: AgentLogIgnore?
  public var ownMarker: Bool
  public var unusableValues: Int
  public var retainedByteEstimate: Int {
    192 + (session.subject?.utf8.count ?? 0) + (legacySession?.utf8.count ?? 0) + (project?.utf8.count ?? 0)
  }
}

/// The only metadata state transition, shared by ordinary parsing, replay and lookahead.
/// A lookahead caller supplies its own state and copies back positive proof only.
public enum AgentLogTransitionReducer {
  public static func apply(_ facts: AgentLogRecordFacts?, tool: AgentLogTool, state: inout AgentLogState) {
    guard let facts else { return }
    state.unusableMetadataValues += facts.unusableValues
    let replacesSession: Bool
    if tool == .claude {
      replacesSession = facts.session != .missing
    } else {
      replacesSession = facts.isHeader || facts.session == .unusable
    }
    if replacesSession {
      state.session = facts.session.subject
      state.sessionExact = state.session.map { _ in facts.sessionExact }
      if tool == .claude || facts.isHeader { state.legacySession = facts.legacySession }
    }
    if tool == .codex && facts.isHeader {
      state.ignoredSession = facts.headerOrigin
      state.metadataRead = true
    }
    if let project = facts.project, !project.isEmpty {
      if state.ownWorkingFolder == nil { state.ownWorkingFolder = facts.projectOwned }
      state.ownWorkingFolder = state.ownWorkingFolder == true || facts.projectOwned
      if state.project.isEmpty {
        state.project = project
        state.cwdSession = facts.session.subject ?? state.session
        state.cwdObservedAt = facts.projectTimestamp
      }
    }
    if facts.ownMarker {
      if let session = facts.session.subject ?? state.session { state.ownedSession = session }
      state.ownWorkingFolder = true
      state.ignoredSession = .ownWindow
    }
  }
}

public struct AgentLogOwnershipDecision {
  public let excludesSource: Bool
  public let sessions: Set<AgentLogSessionSubject>
  public func update(_ state: inout AgentLogState) {
    if let session = sessions.sorted().first { state.ownedSession = session }
    if excludesSource { state.ownWorkingFolder = true; state.ignoredSession = .ownWindow }
  }
}

/// Positive proof is tool scoped; neither shared content nor cooccurrence establishes ownership.
/// Callers supply their cursor-local candidate subjects; the final writer supplies both cursors.
/// Reader shortcuts and the final writer use this evaluation with fresh receipt lookups.
public enum AgentLogOwnership {
  public static func evaluate(state: AgentLogState, sessions: [AgentLogSessionSubject] = [],
    positiveSessions: [AgentLogSessionSubject] = [], pathOwned: Bool,
    containsSession: (AgentLogSessionSubject) throws -> Bool) rethrows -> AgentLogOwnershipDecision {
    var positive = Set(([state.ownedSession].compactMap { $0 } + positiveSessions).filter(\.isUsable))
    let candidates = Set(sessions.filter(\.isUsable))
    for session in candidates where try containsSession(session) { positive.insert(session) }
    return AgentLogOwnershipDecision(excludesSource: pathOwned || state.ownWorkingFolder == true
      || state.ignoredSession == .ownWindow || !positive.isEmpty, sessions: positive)
  }
}
