import Core

// Test-only spelling adapters. Production carries typed values to serialization boundaries.
extension AgentLogEventParser {
  static func pathIdentity(_ path: String) -> String { AgentLogIdentity.decodedPath(path).storedKey }
  static func legacyPathIdentity(_ path: String) -> String { AgentLogIdentity.legacyPath(path).storedKey }
  static func safeIdentity(_ key: String) -> String { AgentLogIdentityCodec.component(key).storedKey }
  static func rawIdentity(_ text: String) -> String { AgentLogIdentity.decoded(text).component.storedKey }
  static func claudeIdentity(_ uuid: String) -> String { AgentLogIdentity.claude(uuid).storedKey }
  static func codexIdentity(thread: String, turn: String, item: String) -> String {
    AgentLogIdentity.codex(thread: AgentLogIdentityCodec.component(thread), turn: turn, item: item).storedKey
  }
}

extension AgentLogOwnSources {
  func registerSession(_ decoded: String, tool: AgentLogTool) throws {
    try registerSession(AgentLogIdentity.decoded(decoded), tool: tool)
  }
  func containsSession(_ decoded: String?, tool: AgentLogTool) throws -> Bool {
    guard let decoded else { return false }
    return try containsSession(AgentLogIdentity.decoded(decoded), tool: tool)
  }
}

@testable import Storage

extension ActivityStorage {
  func purgeOwnLogSession(_ decoded: String, tool: AgentLogTool) throws {
    guard let session = AgentLogIdentity.decoded(decoded).session.subject else { return }
    try purgeOwnLogSession(session, tool: tool)
  }
}
