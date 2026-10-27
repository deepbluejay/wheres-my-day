import Foundation

/// A line has one retained byte buffer, one masked output, and only schema-selected values.
/// Unknown arrays/objects are walked without allocating a value for each member.
enum AgentLogRecord {
  struct Content {
    var valid = true
    var text = ""
    var words = false
    var image = false
    var toolResult = false
    var body: String? { valid ? (words ? text : image ? "[image attached]" : "") : nil }
  }
  struct Result {
    let line: [String: Any]
    let payload: String
    let flags: [String]
  }
  private static let flags: Set<String> = ["origin", "source", "thread_source", "parent_thread_id",
    "promptSource", "humanTurn", "commandMode", "scheduledTaskId", "scheduledFireId", "operation"]
  private static let fields: Set<String> = flags.union(["type", "timestamp", "role", "uuid", "commandUuid",
    "source_uuid", "isMeta", "isCompactSummary", "isVisibleInTranscriptOnly", "isSidechain", "toolUseResult",
    "message", "payload", "attachment", "item", "content", "prompt", "thread_id", "turn_id", "id",
    "kind", "subagent", "reason", "text"])
  private static let scopes: Set<String> = ["", "payload", "attachment", "payload.item", "message"]

  /// The metadata scanner has already validated grammar, UTF-8 and nesting for this line.
  static func decode(_ data: Data, depth: Int = 0, identity: Bool = false, select: Bool = true) -> Result {
    data.withUnsafeBytes { raw in
      var reader = Reader(bytes: raw.bindMemory(to: UInt8.self), identity: identity)
      reader.output.reserveCapacity(data.count)
      let value = reader.value(path: select ? "" : nil, depth: depth, hidden: false, tracePath: AgentLogEventParser.gitTracingJSON ? [] : nil)
      return Result(line: value as? [String: Any] ?? [:],
        payload: String(decoding: reader.output, as: UTF8.self), flags: reader.flagsByScope.values.flatMap { $0.map { $0.key + ":" + $0.value } })
    }
  }

  private struct Reader {
    let bytes: UnsafeBufferPointer<UInt8>
    let identity: Bool
    var index = 0
    var output = Data()
    var flagsByScope: [String: [String: String]] = [:]
    mutating func whitespace() {
      while index < bytes.count, bytes[index] == 32 || bytes[index] == 9 || bytes[index] == 10 || bytes[index] == 13 { index += 1 }
    }
    mutating func quoted(_ string: String) {
      // Encode straight into the output; Foundation would make another whole-token buffer.
      output.append(34)
      for byte in string.utf8 {
        switch byte {
        case 34, 92: output.append(92); output.append(byte)
        case 0...31:
          let hex: [UInt8] = Array("0123456789abcdef".utf8)
          output.append(contentsOf: [92, 117, 48, 48, hex[Int(byte >> 4)], hex[Int(byte & 15)]])
        default: output.append(byte)
        }
      }
      output.append(34)
    }
    mutating func string() -> String {
      let start = index
      index += 1
      var escaped = false
      var hasEscape = false
      while index < bytes.count {
        let byte = bytes[index]; index += 1
        if escaped { escaped = false }
        else if byte == 92 { escaped = true; hasEscape = true }
        else if byte == 34 { break }
      }
      if !hasEscape { return String(decoding: bytes[(start + 1)..<(index - 1)], as: UTF8.self) }
      // Only one string token is materialized, never an enclosing Foundation object tree.
      return autoreleasepool {
        (try? JSONSerialization.jsonObject(with: Data(bytes[start..<index]), options: [.fragmentsAllowed])) as? String ?? ""
      }
    }
    mutating func value(path: String?, depth: Int, hidden: Bool, tracePath: [String]?) -> Any? {
      whitespace()
      let suppressed = hidden || depth >= 12
      if suppressed && !hidden { AgentLogEventParser.gitTraceValue(tracePath); quoted(Redaction.secretMark) }
      let selected = path != nil
      if let path, AgentLogRecord.scopes.contains(path) {
        for scope in AgentLogRecord.scopes where scope == path || scope.hasPrefix(path + ".") {
          flagsByScope.removeValue(forKey: scope)
        }
      }
      switch bytes[index] {
      case 123:
        index += 1
        if !suppressed { output.append(123) }
        var object: [String: Any] = [:]
        var first = true
        whitespace()
        while bytes[index] != 125 {
          if !first { index += 1; whitespace() }
          let key = string()
          whitespace(); index += 1
          let safeKey = suppressed ? "" : autoreleasepool { AgentLogEventParser.gitTraceString(key, depth: depth + 1, identity: identity, path: tracePath.map { $0 + ["key:" + key] }) }
          if !suppressed {
            if !first { output.append(44) }
            quoted(safeKey); output.append(58)
          }
          let childPath = path.flatMap { parent in
            let keep = AgentLogRecord.scopes.contains(parent) ? AgentLogRecord.fields.contains(key)
              : parent == "block" ? ["type", "text"].contains(key)
              : parent.hasSuffix("origin") ? key == "kind"
              : parent.hasSuffix("source") ? key == "subagent" : false
            return keep ? (parent.isEmpty ? key : parent + "." + key) : nil
          }
          let flag = path.map { AgentLogRecord.scopes.contains($0) && AgentLogRecord.flags.contains(key) } ?? false
          let flagStart = output.count
          let conceal = !suppressed && autoreleasepool { AgentLogEventParser.credentialKey(safeKey) }
          if conceal { AgentLogEventParser.gitTraceValue(tracePath.map { $0 + ["k:" + key] }); quoted(Redaction.secretMark) }
          let child = value(path: childPath, depth: depth + 1, hidden: suppressed || conceal, tracePath: suppressed || conceal ? nil : tracePath.map { $0 + ["k:" + key] })
          if selected, childPath != nil { object[key] = child ?? NSNull() }
          if flag, !suppressed {
            flagsByScope[path!, default: [:]][key] = String(decoding: output[flagStart..<output.count], as: UTF8.self)
          }
          whitespace(); first = false
        }
        index += 1
        if !suppressed { output.append(125) }
        return selected ? object : nil
      case 91:
        index += 1
        if !suppressed { output.append(91) }
        let content = path == "content" || path == "message.content" || path == "payload.item.content"
        var projection = Content()
        var element = 0
        var first = true
        whitespace()
        while bytes[index] != 93 {
          if !first { index += 1 }
          if !suppressed, !first { output.append(44) }
          let child = value(path: content ? "block" : nil, depth: depth + 1, hidden: suppressed, tracePath: suppressed ? nil : tracePath.map { $0 + ["a:\(element)"] })
          element += 1
          if content {
            if let block = child as? [String: Any] {
              let type = block["type"] as? String ?? ""
              if ["text", "Text"].contains(type), let text = block["text"] as? String {
                if projection.words { projection.text += "\n" }
                projection.text += text; projection.words = true
              }
              if ["image", "local_image"].contains(type) { projection.image = true }
              if type == "tool_result" { projection.toolResult = true }
            } else { projection.valid = false }
          }
          whitespace(); first = false
        }
        index += 1
        if !suppressed { output.append(93) }
        return content ? projection : selected ? NSNull() : nil
      case 34:
        let text = string()
        if !suppressed { quoted(autoreleasepool { AgentLogEventParser.gitTraceString(text, depth: depth + 1, identity: identity, path: suppressed ? nil : tracePath) }) }
        return selected ? text : nil
      default:
        let start = index
        while index < bytes.count, ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) { index += 1 }
        let number = bytes[start] == 45 || (48...57).contains(bytes[start])
        let decoded: Any? = selected || (!suppressed && number) ? autoreleasepool {
          try? JSONSerialization.jsonObject(with: Data(bytes[start..<index]), options: [.fragmentsAllowed])
        } : nil
        if !suppressed {
          // Preserve Foundation's finite-number spelling without retaining a number tree.
          let encoded: Data? = number ? autoreleasepool {
            guard let value = decoded as? NSNumber, value.doubleValue.isFinite else { return nil }
            return try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
          } : nil
          if let encoded { output.append(encoded) }
          else { output.append(contentsOf: bytes[start..<index]) }
        }
        return selected ? (decoded ?? NSNull()) : nil
      }
    }
  }
}
