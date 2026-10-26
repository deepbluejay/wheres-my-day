import Foundation

/// Validates every byte, including unselected values. Paths are decoded JSON components.
public struct AgentLogMetadata: Codable, Equatable {
  public static let tokenLimit = 4096
  public static let nestingLimit = 512
  private static let paths: [[String]] = [
    ["type"], ["sessionId"], ["cwd"], ["originator"], ["payload", "id"], ["payload", "session_id"],
    ["payload", "thread_id"], ["payload", "cwd"], ["payload", "originator"], ["payload", "item", "originator"],
    ["payload", "source"], ["payload", "thread_source"], ["payload", "parent_thread_id"], ["payload", "origin", "kind"],
    ["payload", "source", "subagent"], ["payload", "thread_source", "subagent"]]
  private static let identities: Set<String> = ["sessionId", "payload.id", "payload.session_id", "payload.thread_id"]
  private struct Frame: Codable, Equatable {
    var object: Bool
    var path: [String]?
    // Object: first key, colon, value, comma, required key. Array: first value, comma, required value.
    var phase = 0
    var key: String?
  }
  /// The wire object stays string-valued; session entries are transitions in memory.
  private struct SelectedValues: Codable, Equatable, ExpressibleByDictionaryLiteral, Sequence {
    private var text: [String: String] = [:]
    private var sessions: [String: AgentLogSessionTransition] = [:]
    init(dictionaryLiteral elements: (String, String)...) {
      for (key, value) in elements { self[key] = value }
    }
    subscript(_ key: String) -> String? {
      get {
        if let transition = sessions[key] { return transition.subject?.storedKey ?? "" }
        return text[key]
      }
      set {
        guard let newValue else { text.removeValue(forKey: key); sessions.removeValue(forKey: key); return }
        if AgentLogMetadata.identities.contains(key) {
          sessions[key] = newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? .unusable : .subject(AgentLogIdentityCodec.session(newValue))
        } else { text[key] = newValue }
      }
    }
    mutating func setSession(_ value: AgentLogSessionTransition, for key: String) { sessions[key] = value }
    func session(_ key: String) -> AgentLogSessionSubject? { sessions[key]?.subject }
    mutating func removeValue(forKey key: String) { self[key] = nil }
    var dictionary: [String: String] {
      var result = text
      for (key, value) in sessions { result[key] = value.subject?.storedKey ?? "" }
      return result
    }
    func makeIterator() -> Dictionary<String, String>.Iterator { dictionary.makeIterator() }
    init(from decoder: Decoder) throws {
      let values = try decoder.singleValueContainer().decode([String: String].self)
      for (key, value) in values { self[key] = value }
    }
    func encode(to encoder: Encoder) throws {
      var container = encoder.singleValueContainer(); try container.encode(dictionary)
    }
  }
  private struct State: Codable, Equatable {
    var version = 6
    var tooDeep = false
    var frames: [Frame] = []
    var values: SelectedValues = [:]
    var ownFields: Set<String> = []
    var subagentFields: Set<String> = []
    var unusableFields: Set<String> = []
    var stringFields: Set<String> = []
    var marks: [String: AgentLogIgnore] = [:]
    var sessionMeta = false
    var exactIdentities: Set<String> = []
    var presentIdentities: Set<String> = []
    var legacyIdentities: [String: AgentLogLegacyProof] = [:]
    var started = false
    var finished = false
    var invalid = false
    var string = false
    var keyToken = false
    var field: String?
    var token: [UInt8] = []
    var overflow = false
    var digest: AgentLogIdentity.ScannerDigest?
    var nonWhitespace = false
    var escape = false
    var unicodeDigits = 0
    var unicodeValue: UInt32 = 0
    var highSurrogate: UInt32 = 0
    var lowSurrogatePhase = 0
    var utfRemaining = 0
    var utfValue: UInt32 = 0
    var utfMinimum: UInt32 = 0
    var primitive = 0 // number states 1...8; literal 9
    var literal = ""
    var literalIndex = 0
  }
  private var s = State()
  public init() {}
  public init(from decoder: Decoder) throws {
    s = try State(from: decoder)
    guard s.version == 6 else {
      throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Obsolete metadata scanner"))
    }
  }
  public func encode(to encoder: Encoder) throws { try checkpoint().s.encode(to: encoder) }
  public var checkpointSafe: Bool {
    s.invalid || (!s.string || ((s.overflow || (!s.keyToken && s.field == nil))
      && s.unicodeDigits == 0 && s.utfRemaining == 0 && s.highSurrogate == 0
      && (s.digest?.checkpointSafe ?? true)))
  }
  public func checkpoint() throws -> Self {
    guard checkpointSafe else {
      throw EncodingError.invalidValue("metadata", .init(codingPath: [], debugDescription: "Unfinished bounded metadata token"))
    }
    if s.invalid { var empty = Self(); empty.s.invalid = true; empty.s.tooDeep = s.tooDeep; return empty }
    var safe = self
    safe.s.token = []
    let names = Set(Self.paths.map { $0.joined(separator: ".") })
    safe.s.values = s.values.reduce(into: [:]) { result, pair in
      guard Self.paths.contains(where: { $0.joined(separator: ".") == pair.key }) else { return }
      result[pair.key] = Self.identities.contains(pair.key)
        ? AgentLogIdentityCodec.component(pair.value).storedKey : AgentLogEventParser.safeString(pair.value)
    }
    safe.s.frames = s.frames.map { frame in
      var frame = frame
      if let path = frame.path, !Self.paths.contains(where: { $0.starts(with: path) }) { frame.path = nil }
      if let key = frame.key, frame.path.map({ parent in Self.paths.contains(where: { $0.starts(with: parent + [key]) }) }) != true {
        frame.key = nil
      }
      return frame
    }
    safe.s.legacyIdentities = s.legacyIdentities.reduce(into: [:]) { result, pair in
      if Self.identities.contains(pair.key) { result[pair.key] = pair.value }
    }
    safe.s.exactIdentities = s.exactIdentities.intersection(Self.identities)
    safe.s.presentIdentities = s.presentIdentities.intersection(Self.identities)
    safe.s.ownFields = s.ownFields.intersection(names)
    safe.s.subagentFields = s.subagentFields.intersection(names)
    safe.s.unusableFields = s.unusableFields.intersection(names)
    safe.s.stringFields = s.stringFields.intersection(names)
    safe.s.marks = s.marks.filter { names.contains($0.key) }
    if let field = s.field, !names.contains(field) { safe.s.field = nil; safe.s.digest = nil }
    if !["", "true", "false", "null"].contains(s.literal) { safe.s.literal = "" }
    safe.s.utfValue = 0; safe.s.utfMinimum = 0
    return safe
  }
  public var complete: Bool {
    !s.invalid && !s.string && s.frames.isEmpty && s.started
      && (s.finished || primitiveComplete)
  }
  public var ownMarker: Bool {
    complete && (s.ownFields.contains(where: { $0.hasSuffix("originator") })
      || s.ownFields.contains(s.values["cwd"] != nil || s.unusableFields.contains("cwd") ? "cwd" : "payload.cwd"))
  }
  public var exceededNestingLimit: Bool { s.tooDeep }
  public var unusableValueCount: Int { s.unusableFields.count }
  // Used by differential tests, with the same sanitization as ordinary parsing.
  var selectedValues: [String: String] { complete ? s.values.dictionary : [:] }
  private var primitiveComplete: Bool {
    [2, 3, 5, 8].contains(s.primitive) || (s.primitive == 9 && s.literalIndex == s.literal.utf8.count)
  }
  public mutating func consume(_ byte: UInt8) {
    guard !s.invalid else { return }
    if s.string { consumeString(byte); return }
    if s.primitive != 0 {
      if consumePrimitive(byte) { return }
      guard primitiveComplete else { s.invalid = true; return }
      s.primitive = 0
      if s.frames.isEmpty { s.finished = true }
    }
    if [9, 10, 13, 32].contains(byte) { return }
    if s.finished { s.invalid = true; return }
    if !s.started { s.started = true; beginValue(byte, path: []); return }
    guard let frame = s.frames.last else { s.invalid = true; return }
    if frame.object {
      switch frame.phase {
      case 0, 4:
        if byte == 125 && frame.phase == 0 { close(object: true) }
        else if byte == 34 { beginString(field: nil, key: true) }
        else { s.invalid = true }
      case 1:
        if byte == 58 { s.frames[s.frames.count-1].phase = 2 } else { s.invalid = true }
      case 2:
        let path = frame.path.flatMap { parent in frame.key.map { parent + [$0] } }
        s.frames[s.frames.count-1].phase = 3
        if let path { clear(path) }
        beginValue(byte, path: path)
      default:
        if byte == 44 { s.frames[s.frames.count-1].phase = 4 }
        else if byte == 125 { close(object: true) }
        else { s.invalid = true }
      }
    } else {
      switch frame.phase {
      case 0, 2:
        if byte == 93 && frame.phase == 0 { close(object: false) }
        else { s.frames[s.frames.count-1].phase = 1; beginValue(byte, path: nil) }
      default:
        if byte == 44 { s.frames[s.frames.count-1].phase = 2 }
        else if byte == 93 { close(object: false) }
        else { s.invalid = true }
      }
    }
  }
  private mutating func clear(_ path: [String]) {
    for selected in Self.paths where selected.starts(with: path) {
      let name = selected.joined(separator: ".")
      s.values.removeValue(forKey: name)
      s.ownFields.remove(name)
      s.subagentFields.remove(name)
      s.unusableFields.remove(name)
      s.stringFields.remove(name)
      s.exactIdentities.remove(name)
      s.presentIdentities.remove(name)
      s.legacyIdentities.removeValue(forKey: name)
      s.marks.removeValue(forKey: name)
      if name == "type" { s.sessionMeta = false }
    }
  }
  private mutating func beginValue(_ byte: UInt8, path: [String]?) {
    let selected = path.flatMap { Self.paths.contains($0) ? $0.joined(separator: ".") : nil }
    if let selected, ["payload.source.subagent", "payload.thread_source.subagent"].contains(selected) {
      s.subagentFields.insert(selected)
    }
    if let selected, Self.identities.contains(selected) { s.presentIdentities.insert(selected) }
    switch byte {
    case 34: beginString(field: selected, key: false)
    case 123, 91:
      guard s.frames.count < Self.nestingLimit else { s.tooDeep = true; s.invalid = true; return }
      let prefix = path.flatMap { value in Self.paths.contains(where: { $0.starts(with: value) }) ? value : nil }
      s.frames.append(Frame(object: byte == 123, path: byte == 123 ? prefix : nil))
    case 116, 102, 110:
      s.primitive = 9
      s.literal = byte == 116 ? "true" : byte == 102 ? "false" : "null"
      s.literalIndex = 1
    case 45: s.primitive = 1
    case 48: s.primitive = 2
    case 49...57: s.primitive = 3
    default: s.invalid = true
    }
  }
  private mutating func close(object: Bool) {
    guard s.frames.last?.object == object else { s.invalid = true; return }
    s.frames.removeLast()
    if s.frames.isEmpty { s.finished = true }
  }
  /// Returns false only when a token delimiter needs structural processing.
  private mutating func consumePrimitive(_ byte: UInt8) -> Bool {
    if s.primitive == 9 {
      let bytes = Array(s.literal.utf8)
      if s.literalIndex < bytes.count {
        if byte == bytes[s.literalIndex] { s.literalIndex += 1 } else { s.invalid = true }
        return true
      }
    } else {
      switch (s.primitive, byte) {
      case (1,48): s.primitive = 2
      case (1,49...57), (3,48...57): s.primitive = 3
      case (2,46), (3,46): s.primitive = 4
      case (4,48...57), (5,48...57): s.primitive = 5
      case (2,69), (2,101), (3,69), (3,101), (5,69), (5,101): s.primitive = 6
      case (6,43), (6,45): s.primitive = 7
      case (6,48...57), (7,48...57), (8,48...57): s.primitive = 8
      default:
        if ![9,10,13,32,44,93,125].contains(byte) { s.invalid = true; return true }
        return false
      }
      return true
    }
    if ![9,10,13,32,44,93,125].contains(byte) { s.invalid = true; return true }
    return false
  }
  private mutating func beginString(field: String?, key: Bool) {
    s.string = true; s.keyToken = key; s.field = field; s.token = []; s.overflow = false; s.digest = nil
    s.nonWhitespace = false
    s.escape = false; s.unicodeDigits = 0; s.unicodeValue = 0; s.highSurrogate = 0
    s.lowSurrogatePhase = 0; s.utfRemaining = 0; s.utfValue = 0; s.utfMinimum = 0
  }
  private mutating func decoded(_ byte: UInt8) {
    guard s.keyToken || s.field != nil else { return }
    if s.overflow { s.digest?.consume(byte); return }
    let limit = s.keyToken ? 256 : Self.tokenLimit
    if s.token.count < limit { s.token.append(byte); return }
    s.overflow = true
    if let field = s.field, Self.identities.contains(field) {
      s.digest = AgentLogIdentity.decoded(s.token + [byte]).scannerDigest
    }
    s.token = []
  }
  private mutating func scalar(_ value: UInt32) {
    guard let scalar = UnicodeScalar(value) else { s.invalid = true; return }
    guard s.keyToken || s.field != nil else { return }
    if !CharacterSet.whitespacesAndNewlines.contains(scalar) { s.nonWhitespace = true }
    for byte in String(scalar).utf8 { decoded(byte) }
  }
  private mutating func consumeString(_ byte: UInt8) {
    if s.utfRemaining > 0 {
      guard (128...191).contains(byte) else { s.invalid = true; return }
      s.utfValue = (s.utfValue << 6) | UInt32(byte & 63)
      s.utfRemaining -= 1
      if s.utfRemaining == 0 {
        guard s.utfValue >= s.utfMinimum, s.utfValue <= 0x10ffff,
          !(0xd800...0xdfff).contains(s.utfValue) else { s.invalid = true; return }
        scalar(s.utfValue)
      }
      return
    }
    if s.unicodeDigits > 0 {
      let digit: UInt32
      switch byte { case 48...57: digit = UInt32(byte-48)
      case 65...70: digit = UInt32(byte-55)
      case 97...102: digit = UInt32(byte-87)
      default: s.invalid = true; return }
      s.unicodeValue = s.unicodeValue * 16 + digit; s.unicodeDigits -= 1
      if s.unicodeDigits == 0 {
        let value = s.unicodeValue; s.unicodeValue = 0
        if s.highSurrogate != 0 {
          guard (0xdc00...0xdfff).contains(value) else { s.invalid = true; return }
          scalar(0x10000 + ((s.highSurrogate - 0xd800) << 10) + value - 0xdc00)
          s.highSurrogate = 0
        } else if (0xd800...0xdbff).contains(value) { s.highSurrogate = value; s.lowSurrogatePhase = 1 }
        else if (0xdc00...0xdfff).contains(value) { s.invalid = true }
        else { scalar(value) }
      }
      return
    }
    if s.lowSurrogatePhase > 0 {
      if s.lowSurrogatePhase == 1 && byte == 92 { s.lowSurrogatePhase = 2 }
      else if s.lowSurrogatePhase == 2 && byte == 117 { s.lowSurrogatePhase = 0; s.unicodeDigits = 4 }
      else { s.invalid = true }
      return
    }
    if s.escape {
      s.escape = false
      switch byte {
      case 34,47,92: s.nonWhitespace = true; decoded(byte)
      case 98: s.nonWhitespace = true; decoded(8)
      case 102: decoded(12)
      case 110: decoded(10)
      case 114: decoded(13)
      case 116: decoded(9)
      case 117: s.unicodeDigits = 4
      default: s.invalid = true
      }
      return
    }
    switch byte {
    case 34: autoreleasepool { finishString() }
    case 92: s.escape = true
    case 0...31: s.invalid = true
    case 32...127:
      if byte != 32 { s.nonWhitespace = true }
      decoded(byte)
    case 194...223: s.utfRemaining = 1; s.utfValue = UInt32(byte & 31); s.utfMinimum = 0x80
    case 224...239: s.utfRemaining = 2; s.utfValue = UInt32(byte & 15); s.utfMinimum = 0x800
    case 240...244: s.utfRemaining = 3; s.utfValue = UInt32(byte & 7); s.utfMinimum = 0x10000
    default: s.invalid = true
    }
  }
  private mutating func finishString() {
    s.string = false
    if s.keyToken {
      guard !s.frames.isEmpty else { s.invalid = true; return }
      let key = s.overflow ? nil : String(bytes: s.token, encoding: .utf8)
      let parent = s.frames.last?.path
      s.frames[s.frames.count-1].key = key.flatMap { key in
        guard let parent, Self.paths.contains(where: { $0.starts(with: parent + [key]) }) else { return nil }
        return key
      }
      s.frames[s.frames.count-1].phase = 1
    } else if let field = s.field {
      s.stringFields.insert(field)
      if let digest = s.digest {
        s.values.setSession(s.nonWhitespace ? .subject(AgentLogIdentityCodec.session(digest.component.storedKey)) : .unusable, for: field)
        s.legacyIdentities[field] = s.values[field].map(AgentLogIdentityCodec.legacy)
      }
      else if s.overflow {
        s.unusableFields.insert(field)
        if field == "payload.parent_thread_id" { s.values[field] = "[oversized metadata]" }
        if field == "payload.origin.kind" { s.marks[field] = .nonHumanOrigin }
      }
      else {
        let value = String(decoding: s.token, as: UTF8.self)
        if field == "type" { s.sessionMeta = value == "session_meta" }
        if ["payload.source", "payload.thread_source", "payload.origin.kind"].contains(field) {
          s.marks[field] = AgentLogParser.namedMark(value)
          if field == "payload.origin.kind", value != "human", s.marks[field] == nil { s.marks[field] = .nonHumanOrigin }
        }
        if ["cwd", "payload.cwd"].contains(field), AgentWindowIdentity.containsWorkingFolder(value) { s.ownFields.insert(field) }
        let safe: String
        if Self.identities.contains(field) {
          let decoded = AgentLogIdentity.decoded(value)
          // Session usability is independent of the native component key.
          s.values.setSession(decoded.session, for: field)
          safe = decoded.component.storedKey
        } else {
          safe = AgentLogEventParser.safeString(value); s.values[field] = safe
        }
        if Self.identities.contains(field) {
          if safe.utf8.elementsEqual(value.utf8) { s.exactIdentities.insert(field) }
          s.legacyIdentities[field] = AgentLogLegacyRefusal.legacyThread(value)
        }
        if field.hasSuffix("originator"), [AgentWindowIdentity.codexOriginator, AgentWindowIdentity.codexPlanOriginator].contains(value) {
          s.ownFields.insert(field)
        }
      }
    }
    s.token = []; s.field = nil; s.digest = nil
    if s.frames.isEmpty { s.finished = true }
  }
  public func explicitSession(tool: AgentLogTool) -> AgentLogSessionSubject? {
    sessionTransition(tool: tool).subject
  }
  public func sessionTransition(tool: AgentLogTool) -> AgentLogSessionTransition {
    guard complete else { return .missing }
    let field = tool == .claude ? "sessionId" : s.sessionMeta
      ? (s.stringFields.contains("payload.id") ? "payload.id" : "payload.session_id") : "payload.thread_id"
    if let subject = s.values.session(field) { return .subject(subject) }
    let present = s.presentIdentities.contains(field)
      || (tool == .codex && s.sessionMeta && s.presentIdentities.contains("payload.id"))
    return present ? .unusable : .missing
  }
  /// Extraction has no state effects. The reducer alone interprets missing/unusable boundaries.
  public func facts(tool: AgentLogTool) -> AgentLogRecordFacts? {
    guard complete else { return nil }
    let field = tool == .claude ? "sessionId" : s.sessionMeta
      ? (s.stringFields.contains("payload.id") ? "payload.id" : "payload.session_id") : "payload.thread_id"
    var mark: AgentLogIgnore? = s.ownFields.contains("payload.originator") ? .ownWindow : nil
    for field in ["payload.source", "payload.thread_source"] where mark == nil {
      mark = s.marks[field]
      if mark == nil && s.subagentFields.contains(field + ".subagent") { mark = .subagent }
    }
    if mark == nil && !(s.values["payload.parent_thread_id"] ?? "").isEmpty { mark = .subagent }
    let defaultCwdField = s.values["cwd"] != nil ? "cwd" : "payload.cwd"
    let headerCwd = tool == .codex && s.sessionMeta && !(s.values["payload.cwd"] ?? "").isEmpty
    let cwdField = headerCwd ? "payload.cwd" : defaultCwdField
    let cwd = !headerCwd && s.unusableFields.contains("cwd") ? nil : s.values[cwdField]
    return AgentLogRecordFacts(session: sessionTransition(tool: tool), isHeader: s.sessionMeta,
      sessionExact: s.exactIdentities.contains(field), legacySession: s.legacyIdentities[field],
      project: cwd, projectOwned: s.ownFields.contains(cwdField), headerOrigin: mark ?? s.marks["payload.origin.kind"],
      ownMarker: ownMarker || (tool == .codex && s.sessionMeta && s.ownFields.contains("payload.cwd")), unusableValues: unusableValueCount)
  }
  public func authoritativeSession(tool: AgentLogTool) -> AgentLogSessionSubject? {
    tool == .claude || s.sessionMeta ? explicitSession(tool: tool) : nil
  }
  /// Metadata replay never produces historical content.
  public func apply(tool: AgentLogTool, file: String, state: inout AgentLogState, fingerprint: (String) -> String) {
    AgentLogTransitionReducer.apply(facts(tool: tool), tool: tool, state: &state)
  }
}
