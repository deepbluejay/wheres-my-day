import Foundation

/// A local occurrence, separate from the deliberately narrow prompt projection used by models.
public struct AgentLogEvent {
  public var tool: AgentLogTool
  public var offset: Int
  public var timestamp: Int?
  public var observedAt: Int
  public var session: AgentLogSessionSubject?
  public var project: String
  public var type: String
  public var role: String
  public var flags: [String]
  public var identities: [AgentLogInstructionIdentity]
  public var payload: String
  public var parseStatus: String
  public var byteCount: Int
  public var prompt: EvidenceText?
  public var canonicalIdentity: AgentLogInstructionIdentity? = nil
  public var legacyRefusal = AgentLogLegacyRefusal()
  // Explicit attribution on this record, independent of either metadata cursor.
  public var explicitSession: AgentLogSessionSubject? = nil
  public var facts: AgentLogRecordFacts? = nil
  /// Includes conservative per-value/Foundation overhead and the separately retained projection.
  public var retainedByteEstimate: Int {
    1024 + payload.utf8.count + (session?.utf8.count ?? 0) + project.utf8.count
      + type.utf8.count + role.utf8.count + parseStatus.utf8.count
      + flags.reduce(0) { $0 + 64 + $1.utf8.count }
      + identities.reduce(0) { $0 + 64 + $1.utf8.count }
      + (canonicalIdentity?.utf8.count ?? 0) + (explicitSession?.utf8.count ?? 0)
      + legacyRefusal.retainedByteEstimate + (facts?.retainedByteEstimate ?? 0)
      + (prompt.map {
        256 + $0.text.utf8.count + $0.project.utf8.count + $0.source.utf8.count
          + $0.documentKey.utf8.count + ($0.sourceID?.utf8.count ?? 0)
          + $0.sourceAliases.reduce(0) { $0 + 64 + $1.utf8.count }
          + $0.legacyRefusal.retainedByteEstimate
      } ?? 0)
  }

}

public enum AgentLogEventParser {
  public static func parse(
    _ bytes: Data, byteCount: Int, offset: Int, observedAt: Int, tool: AgentLogTool,
    file: String, state: inout AgentLogState, logsRelativePath: String?, metadata: AgentLogMetadata? = nil, fingerprint: (String) -> String
  ) -> AgentLogEvent? {
    let truncated = byteCount > bytes.count
    let scanned: AgentLogMetadata
    if let metadata { scanned = metadata }
    else {
      var scanner = AgentLogMetadata()
      for byte in bytes { scanner.consume(byte) }
      scanned = scanner
    }
    let record = !truncated && scanned.complete ? AgentLogRecord.decode(bytes) : nil
    let line = record?.line ?? [:]
    let payload = line["payload"] as? [String: Any] ?? [:]
    let attachment = line["attachment"] as? [String: Any] ?? [:]
    let message = line["message"] as? [String: Any] ?? [:]
    let item = payload["item"] as? [String: Any] ?? [:]
    let type = line["type"] as? String ?? "unknown"
    let stamp = timestamp(line["timestamp"] ?? attachment["timestamp"])
    let facts = scanned.facts(tool: tool)
    let explicitSession = facts?.session.subject
    AgentLogTransitionReducer.apply(facts, tool: tool, state: &state)
    let projection: AgentLogLine = record != nil
      ? AgentLogParser.project(line, tool: tool, file: file, state: &state,
        logsRelativePath: logsRelativePath, fingerprint: fingerprint) : .malformed
    if state.ownWorkingFolder == true || state.ignoredSession == .ownWindow { return nil }
    var flags = Set(record?.flags ?? [])
    if metadata?.exceededNestingLimit == true { flags.insert("metadataTooDeep") }
    if let count = metadata?.unusableValueCount, count > 0 { flags.insert("unusableMetadataValues:\(count)") }
    if let mark = state.ignoredSession { flags.insert("sessionOrigin:" + mark.rawValue) }
    for fields in [line, payload, attachment, item, message] {
      for key in ["isMeta", "isCompactSummary", "isVisibleInTranscriptOnly", "isSidechain"]
      where fields[key] as? Bool == true { flags.insert(key) }
    }
    if logsRelativePath?.split(separator: "/").contains("subagents") == true { flags.insert("subagentPath") }
    if (payload["turn_id"] as? String ?? "").hasPrefix("external-import-turn-") { flags.insert("imported") }
    var prompt: EvidenceText?
    switch projection {
    case .prompt(let value): prompt = value
    case .excluded(let reason): flags.insert("promptProjection:" + reason.rawValue)
    case .ignored: break
    case .malformed: flags.insert("promptProjection:malformed")
    }
    let itemType = item["type"] as? String ?? ""
    let payloadType = payload["type"] as? String ?? ""
    if !itemType.isEmpty { flags.insert("itemType:" + itemType) }
    if !payloadType.isEmpty { flags.insert("payloadType:" + payloadType) }
    let inferredRole: String
    if ["UserMessage", "user_message"].contains(itemType) || payloadType == "user_message" { inferredRole = "user" }
    else if ["AssistantMessage", "AgentMessage", "Reasoning"].contains(itemType) || ["agent_message", "agent_reasoning"].contains(payloadType) { inferredRole = "assistant" }
    else if ["ToolCall", "ToolResult", "CommandExecution"].contains(itemType)
      || ["function_call", "function_call_output", "custom_tool_call", "custom_tool_call_output"].contains(payloadType) { inferredRole = "tool" }
    else if ["user", "assistant", "system", "tool"].contains(type) { inferredRole = type }
    else { inferredRole = "unknown" }
    let role = message["role"] as? String ?? item["role"] as? String
      ?? payload["role"] as? String ?? line["role"] as? String ?? inferredRole
    var ids: [AgentLogInstructionIdentity] = []
    var legacyRefusal = prompt?.legacyRefusal ?? AgentLogLegacyRefusal()
    if tool == .claude {
      ids = [line["uuid"], line["commandUuid"], line["source_uuid"], attachment["source_uuid"]]
        .compactMap { ($0 as? String).map(AgentLogIdentity.claude) }
      for value in [line["uuid"], line["commandUuid"], line["source_uuid"], attachment["source_uuid"]] {
        if let value = value as? String { legacyRefusal.claude(value) }
      }
    } else if let id = item["id"] as? String {
      let thread = (payload["thread_id"] as? String).map { AgentLogIdentity.decoded($0).component } ?? state.session?.nativeComponent
        ?? AgentLogIdentity.decoded(URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent).component
      let turn = payload["turn_id"] as? String ?? stamp.map(String.init) ?? ""
      ids = [AgentLogIdentity.codex(thread: thread, turn: turn, item: id)]
      if prompt == nil {
        legacyRefusal.codex(thread: thread, explicitThread: payload["thread_id"] as? String, state: state,
          fallbackSource: URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent, turn: turn, item: id)
      }
    }
    let status = truncated ? "truncated" : record == nil && String(data: bytes, encoding: .utf8) == nil ? "invalidUTF8"
      : record == nil ? "invalidJSON" : line.isEmpty || line["type"] == nil ? "unknownSchema"
      : stamp == nil ? "timestampUnknown" : "parsed"
    let safePayload = (record?.payload ?? maskedPayload(String(decoding: bytes, as: UTF8.self)))
      + (truncated ? "\n[truncated]" : "")
    var event = AgentLogEvent(tool: tool, offset: offset, timestamp: stamp, observedAt: observedAt,
      session: state.session, project: safeString(state.project), type: safeString(type), role: safeString(role),
      flags: flags.sorted().map(safeString), identities: Array(Set(ids)).sorted(),
      payload: safePayload, parseStatus: status, byteCount: byteCount, prompt: prompt)
    event.explicitSession = explicitSession
    event.facts = facts
    event.legacyRefusal = legacyRefusal
    event.canonicalIdentity = prompt?.agentLogIdentity ?? (tool == .claude
      ? (line["commandUuid"] as? String ?? line["source_uuid"] as? String ?? attachment["source_uuid"] as? String)
        .map(AgentLogIdentity.claude) : ids.first)
    return event
  }
  public static func maskedPayload(_ text: String) -> String {
    sanitize(text, depth: 0)
  }
  /// Sanitize persisted/display text; classify schema values before calling this.
  public static func safeString(_ text: String) -> String { sanitizedString(text, depth: 0) }
  static func sanitizedIdentity(_ text: String) -> String { sanitizedString(text, depth: 0, identity: true) }
  public static func isNativePromptIdentity(_ id: String) -> Bool {
    ["claude:", "codex:"].contains(where: { id.utf8.starts(with: $0.utf8) })
      && !["claude:legacy:", "codex:legacy:", "claude:occurrence:", "codex:occurrence:"].contains(where: { id.utf8.starts(with: $0.utf8) })
  }
  static func credentialKey(_ key: String) -> Bool {
    Redaction.applyKnownSecrets(key + "=invented-value").text != Redaction.applyKnownSecrets(key).text + "=invented-value"
  }
  private static func sanitize(_ text: String, depth: Int, identity: Bool = false) -> String {
    guard depth < 12 else { return Redaction.secretMark }
    // Identity spellings are a deployed contract. Their inputs are already bounded,
    // so retain the original sorted/last-member encoding only for this small path.
    if identity, text.utf8.count <= AgentLogMetadata.tokenLimit,
      let value = AgentLogJSON.object(Data(text.utf8)) {
      return identityJSON(value, depth: depth)
    }
    var grammar = AgentLogMetadata()
    for byte in text.utf8 { grammar.consume(byte) }
    if grammar.complete {
      return AgentLogRecord.decode(Data(text.utf8), depth: depth, identity: identity, select: false).payload
    }
    // Recover string tokens independently of the enclosing JSON. Never retain undecodable
    // or unfinished tokens, whose escapes could otherwise preserve a reversible credential.
    let bytes = Array(text.utf8)
    var output = ""
    var index = 0
    var sensitiveDepth: Int?
    var nesting = 0
    while index < bytes.count {
      if bytes[index] != 34 {
        let start = index
        while index < bytes.count && bytes[index] != 34 { index += 1 }
        let part = String(decoding: bytes[start..<index], as: UTF8.self)
        let hide = sensitiveDepth != nil || part.contains("\\u")
        for byte in bytes[start..<index] {
          if byte == 123 || byte == 91 { nesting += 1 }
          else if byte == 125 || byte == 93 {
            nesting = max(0, nesting - 1)
            if let sensitive = sensitiveDepth, nesting <= sensitive { sensitiveDepth = nil }
          } else if byte == 44, let sensitive = sensitiveDepth, nesting <= sensitive {
            sensitiveDepth = nil
          }
        }
        output += hide ? Redaction.secretMark : part
        continue
      }
      let start = index
      index += 1
      var escaped = false
      var closed = false
      while index < bytes.count {
        let byte = bytes[index]
        index += 1
        if escaped { escaped = false }
        else if byte == 92 { escaped = true }
        else if byte == 34 { closed = true; break }
      }
      let token = Data(bytes[start..<index])
      var look = index
      while look < bytes.count && [9, 10, 13, 32].contains(bytes[look]) { look += 1 }
      let isKey = look < bytes.count && bytes[look] == 58
      if closed, let value = (try? JSONSerialization.jsonObject(with: token, options: [.fragmentsAllowed])) as? String {
        let hide = sensitiveDepth != nil
        let safe = hide ? Redaction.secretMark : sanitizedString(value, depth: depth + 1, identity: identity)
        let encoded = try? JSONSerialization.data(withJSONObject: safe, options: [.fragmentsAllowed])
        output += encoded.map { String(decoding: $0, as: UTF8.self) } ?? "\"[secret]\""
        if isKey && !hide && credentialKey(safe) { sensitiveDepth = nesting }
      } else { output += "\"[secret]\"" }
    }
    return identity ? Redaction.applyKnownSecrets(output).text : Redaction.apply(output).text
  }
  static func sanitizedString(_ string: String, depth: Int, identity: Bool = false) -> String {
    guard depth < 12 else { return Redaction.secretMark }
    if string.contains("\\u") {
      let quoted = "\"" + string.replacingOccurrences(of: "\"", with: "\\\"") + "\""
      guard let decoded = (try? JSONSerialization.jsonObject(with: Data(quoted.utf8), options: [.fragmentsAllowed])) as? String,
        decoded != string else { return Redaction.secretMark }
      return sanitizedString(decoded, depth: depth + 1, identity: identity)
    }
    let first = string.unicodeScalars.first { !CharacterSet.whitespacesAndNewlines.contains($0) }
    if first == "{" || first == "[" || first == "\"" {
      return sanitize(string, depth: depth, identity: identity)
    }
    return identity ? Redaction.applyKnownSecrets(string).text : Redaction.apply(string).text
  }
  private static func identityJSON(_ value: Any, depth: Int = 0, identity: Bool = true) -> String {
    var hasUnrepresentedNumber = false
    func mask(_ value: Any, level: Int) -> Any {
      guard level < 12 else { return Redaction.secretMark }
      if value is AgentLogJSON.Number { hasUnrepresentedNumber = true; return value }
      if let string = value as? String { return sanitizedString(string, depth: level + 1, identity: identity) }
      if let array = value as? [Any] { return array.map { mask($0, level: level + 1) } }
      if let dict = value as? [String: Any] {
        var safe: [String: Any] = [:]
        for (key, value) in dict {
          let safeKey = sanitizedString(key, depth: level + 1, identity: identity)
          safe[safeKey] = credentialKey(safeKey) ? Redaction.secretMark : mask(value, level: level + 1)
        }
        return safe
      }
      return value
    }
    func encode(_ value: Any) -> String {
      if let number = value as? AgentLogJSON.Number { return number.token }
      if let array = value as? [Any] { return "[" + array.map(encode).joined(separator: ",") + "]" }
      if let dict = value as? [String: Any] {
        return "{" + dict.keys.sorted().map { encode($0) + ":" + encode(dict[$0]!) }.joined(separator: ",") + "}"
      }
      guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else { return "null" }
      return String(decoding: data, as: UTF8.self)
    }
    let masked = mask(value, level: depth)
    if !hasUnrepresentedNumber,
      let data = try? JSONSerialization.data(withJSONObject: masked, options: [.sortedKeys, .fragmentsAllowed]) {
      return String(decoding: data, as: UTF8.self)
    }
    return encode(masked)
  }
  public static func timestamp(_ value: Any?) -> Int? {
    if let number = value as? NSNumber {
      guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
      let seconds = number.doubleValue
      guard seconds.isFinite, seconds > Double(Int.min), seconds < Double(Int.max) else { return nil }
      return Int(seconds)
    }
    guard let string = value as? String else { return nil }
    if let number = Double(string), number.isFinite, number > Double(Int.min), number < Double(Int.max) { return Int(number) }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return (fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)).map { Int($0.timeIntervalSince1970) }
  }
}
