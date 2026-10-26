import Core
extension AgentLogEventParser {
  static func pathIdentity(_ path: String) -> String { AgentLogIdentity.decodedPath(path).storedKey }
  static func safeIdentity(_ key: String) -> String { AgentLogIdentityCodec.component(key).storedKey }
  static func rawIdentity(_ text: String) -> String { AgentLogIdentity.decoded(text).component.storedKey }
}
