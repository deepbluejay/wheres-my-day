import Foundation

public enum AgentLogTool: String, CaseIterable {
  case claude, codex
  public var homeVariable: String { self == .claude ? "CLAUDE_CONFIG_DIR" : "CODEX_HOME" }
  public var defaultHomeName: String { self == .claude ? ".claude" : ".codex" }
  public var logsFolder: String { self == .claude ? "projects" : "sessions" }
}

public struct AgentLogFile {
  public let path: String
  public let device: Int
  public let inode: Int
  public let size: Int
  public let logsRelativePath: String?
  public init(path: String, device: Int, inode: Int, size: Int, logsRelativePath: String? = nil) {
    self.path = path
    self.device = device
    self.inode = inode
    self.size = size
    self.logsRelativePath = logsRelativePath
  }
}

public struct AgentLogBatch {
  public var events: [AgentLogEvent] = []
  public var ownershipDeferred = false
  public var evidence: [EvidenceText]
  public var position: LogPosition
  public var malformedLines: Int
  public var ignored: [AgentLogIgnore: Int] = [:]
  public init(evidence: [EvidenceText], position: LogPosition, malformedLines: Int) {
    self.evidence = evidence
    self.position = position
    self.malformedLines = malformedLines
  }
}

/// Called by a shell background task. Each implementation represents one tool, across all its homes.
public protocol AgentLogReader {
  var name: String { get }
  func files() throws -> [AgentLogFile]
  func listing() throws -> AgentLogListing
  func read(_ file: AgentLogFile, position: LogPosition?, at time: Int) throws -> AgentLogBatch
  /// Changes whenever the own-source receipts a read consults may have changed; nil when unknown.
  func ownershipRevision() throws -> String?
  /// The hash-only receipt names now registered; nil when unknown.
  func ownershipReceipts() throws -> Set<String>?
  /// Every receipt name a read of this file from this checkpoint consults; nil when unknown.
  func ownershipCandidates(path: String, state: String) -> Set<String>?
}

public struct AgentLogListing {
  public let files: [AgentLogFile]
  public let folderFailures: Int
  public let discoveryFailures: Int
  public init(files: [AgentLogFile], folderFailures: Int = 0, discoveryFailures: Int = 0) {
    self.files = files
    self.folderFailures = folderFailures
    self.discoveryFailures = discoveryFailures
  }
}

extension AgentLogReader {
  public func listing() throws -> AgentLogListing { AgentLogListing(files: try files()) }
  public func ownershipRevision() throws -> String? { nil }
  public func ownershipReceipts() throws -> Set<String>? { nil }
  public func ownershipCandidates(path: String, state: String) -> Set<String>? { nil }
}

public enum AgentLogIgnore: String, Codable, CaseIterable {
  case meta, compactSummary, transcriptOnly, sidechain, subagent
  case taskNotification, peer, automation, nonHumanOrigin, toolUseResult, toolResult
  case timestampUnknownCwd, imported, ownWindow, localCommandOutput, shellOutput, interruption, empty
}

public enum AgentLogPolicy {
  public static func folders(tool: AgentLogTool, userHome: String, foundHomes: [String]) -> [String] {
    let defaultHome = URL(fileURLWithPath: userHome).appendingPathComponent(tool.defaultHomeName).path
    var folders: [AgentLogPhysicalSource: String] = [:]
    for home in [defaultHome] + foundHomes where home.hasPrefix("/") {
      let path = URL(fileURLWithPath: home).appendingPathComponent(tool.logsFolder).standardizedFileURL.path
      folders[AgentLogIdentity.decodedPath(path)] = path
    }
    return folders.values.sorted()
  }
  public static func continues(_ position: LogPosition?, file: AgentLogFile) -> Bool {
    guard let position else { return false }
    // Logs are append-only; an in-place rewrite past the saved offset cannot be detected by this identity.
    return position.device == file.device && position.inode == file.inode
      && position.offset >= 0 && position.offset <= file.size
  }
}

/// Checkpoints contain session metadata and old bounded receipts, never prompt text or environment blocks.
/// New queue receipts are durable log events; old content hashes no longer establish identity.
public struct AgentLogState: Codable, Equatable {
  public var metadataVersion = 5
  public var unusableMetadataValues = 0
  public var tool: String?
  public var session: AgentLogSessionSubject?
  public var sessionExact: Bool?
  // Main-format content/refusal proof only; never a session ownership subject.
  public var legacySession: AgentLogLegacyProof?
  public var ownWorkingFolder: Bool?
  public var project = ""
  public var gitOwnershipAuthority: [String]?
  public var cwdObservedAt: Int?
  public var cwdSession: AgentLogSessionSubject?
  public var ignoredSession: AgentLogIgnore?
  public var metadataRead = false
  public var ownershipScanOffset = 0
  public var ownershipSession: AgentLogSessionSubject?
  // Positive ownership proof, independent of metadata at either cursor.
  public var ownedSession: AgentLogSessionSubject?
  // Separate resumable metadata work; the committed collection cursor never moves backwards.
  public var metadataRecoveryOffset: Int?
  public var metadataRecoveryScanner: AgentLogMetadata?
  var queued: [QueuedInstruction] = []
  var legacyRefusalQueue: [AgentLogLegacyQueueReceipt] = []
  // Identity receipts remain decode-only; refusal receipts use the same legacy bound.
  static let queueLimit = 32
  struct QueuedInstruction: Codable, Equatable {
    let hash: AgentLogLegacyProof
    var id: AgentLogLegacyProof?
    let ts: Int
    var delivered: Bool
  }
  public init() {}
  /// Metadata recovery must not discard main's content-free refusal receipts.
  public mutating func resetMetadataForRecovery() {
    let refusals = legacyRefusalQueue
    self = AgentLogState()
    legacyRefusalQueue = refusals
    metadataRecoveryOffset = 0
    metadataRecoveryScanner = AgentLogMetadata()
  }
  private enum CodingKeys: String, CodingKey {
    case gitOwnershipAuthority, cwdObservedAt, cwdSession
    case metadataVersion, unusableMetadataValues, tool, session, sessionExact, legacySession, project, folder, threadID, queued, legacyRefusalQueue, ignoredSession, metadataRead, ownWorkingFolder, ownershipScanOffset, ownershipSession, ownedSession, metadataRecoveryOffset, metadataRecoveryScanner
  }
  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    metadataVersion = try values.decodeIfPresent(Int.self, forKey: .metadataVersion) ?? 0
    guard metadataVersion == 0 || metadataVersion == 5 else {
      throw DecodingError.dataCorruptedError(forKey: .metadataVersion, in: values,
        debugDescription: "Unsupported undeployed agent-log checkpoint")
    }
    gitOwnershipAuthority = try values.decodeIfPresent([String].self, forKey: .gitOwnershipAuthority)
    cwdObservedAt = try values.decodeIfPresent(Int.self, forKey: .cwdObservedAt)
    cwdSession = try values.decodeIfPresent(AgentLogSessionSubject.self, forKey: .cwdSession)
    unusableMetadataValues = try values.decodeIfPresent(Int.self, forKey: .unusableMetadataValues) ?? 0
    tool = try values.decodeIfPresent(String.self, forKey: .tool)
    session = try values.decodeIfPresent(AgentLogSessionSubject.self, forKey: .session)
      ?? values.decodeIfPresent(AgentLogSessionSubject.self, forKey: .threadID)
    sessionExact = try values.decodeIfPresent(Bool.self, forKey: .sessionExact)
    legacySession = try values.decodeIfPresent(AgentLogLegacyProof.self, forKey: .legacySession)
    project = try values.decodeIfPresent(String.self, forKey: .project)
      ?? values.decodeIfPresent(String.self, forKey: .folder) ?? ""
    ownWorkingFolder = try values.decodeIfPresent(Bool.self, forKey: .ownWorkingFolder)
    let legacy = try AgentLogLegacyQueueState(from: decoder)
    queued = legacy.queued
    legacyRefusalQueue = legacy.receipts
    ignoredSession = try values.decodeIfPresent(AgentLogIgnore.self, forKey: .ignoredSession)
    metadataRead = try values.decodeIfPresent(Bool.self, forKey: .metadataRead) ?? false
    ownershipScanOffset = try values.decodeIfPresent(Int.self, forKey: .ownershipScanOffset) ?? 0
    ownershipSession = try values.decodeIfPresent(AgentLogSessionSubject.self, forKey: .ownershipSession)
    ownedSession = try values.decodeIfPresent(AgentLogSessionSubject.self, forKey: .ownedSession)
    metadataRecoveryOffset = try values.decodeIfPresent(Int.self, forKey: .metadataRecoveryOffset)
    metadataRecoveryScanner = try values.decodeIfPresent(AgentLogMetadata.self, forKey: .metadataRecoveryScanner)
  }
  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encodeIfPresent(gitOwnershipAuthority, forKey: .gitOwnershipAuthority)
    try values.encodeIfPresent(cwdObservedAt, forKey: .cwdObservedAt)
    try values.encodeIfPresent(cwdSession, forKey: .cwdSession)
    try values.encode(metadataVersion, forKey: .metadataVersion)
    try values.encode(unusableMetadataValues, forKey: .unusableMetadataValues)
    try values.encodeIfPresent(tool.map { AgentLogIdentityCodec.component($0).storedKey }, forKey: .tool)
    try values.encodeIfPresent(session, forKey: .session)
    try values.encodeIfPresent(sessionExact, forKey: .sessionExact)
    try values.encodeIfPresent(legacySession, forKey: .legacySession)
    try values.encode(AgentLogEventParser.safeString(project), forKey: .project)
    try values.encodeIfPresent(ownWorkingFolder, forKey: .ownWorkingFolder)
    try values.encode(queued.map { QueuedInstruction(hash: $0.hash,
      id: $0.id, ts: $0.ts, delivered: $0.delivered) }, forKey: .queued)
    try values.encode(legacyRefusalQueue, forKey: .legacyRefusalQueue)
    try values.encodeIfPresent(ignoredSession, forKey: .ignoredSession)
    try values.encode(metadataRead, forKey: .metadataRead)
    try values.encode(ownershipScanOffset, forKey: .ownershipScanOffset)
    try values.encode(ownershipSession, forKey: .ownershipSession)
    try values.encode(ownedSession, forKey: .ownedSession)
    try values.encodeIfPresent(metadataRecoveryOffset, forKey: .metadataRecoveryOffset)
    try values.encodeIfPresent(metadataRecoveryScanner?.checkpoint(), forKey: .metadataRecoveryScanner)
  }
  public static func decode(_ string: String) throws -> AgentLogState {
    if string.isEmpty { return AgentLogState() }
    return try JSONDecoder().decode(Self.self, from: Data(string.utf8))
  }
  public func encoded() throws -> String {
    String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
  }
}

public enum AgentLogLine {
  case ignored
  case excluded(AgentLogIgnore)
  case malformed
  case prompt(EvidenceText)
}

/// The existing human-prompt projection, not an acquisition filter. Other roles and marked records
/// remain in AgentLogEventParser's local relation even when this projection returns excluded/ignored.
public enum AgentLogParser {
  /// The adapter supplies SHA-256, keeping Core independent of platform crypto modules.
  public static func parse(
    _ text: String, tool: AgentLogTool, file: String, state: inout AgentLogState,
    logsRelativePath: String? = nil, fingerprint: (String) -> String
  ) -> AgentLogLine {
    var metadata = AgentLogMetadata()
    for byte in text.utf8 { metadata.consume(byte) }
    AgentLogTransitionReducer.apply(metadata.facts(tool: tool), tool: tool, state: &state)
    guard metadata.complete else { return .malformed }
    return project(AgentLogRecord.decode(Data(text.utf8)).line, tool: tool, file: file, state: &state, logsRelativePath: logsRelativePath, fingerprint: fingerprint)
  }
  static func project(_ line: [String: Any], tool: AgentLogTool, file: String, state: inout AgentLogState,
    logsRelativePath: String?, fingerprint: (String) -> String) -> AgentLogLine {
    guard let type = line["type"] as? String else { return .malformed }
    let payload = line["payload"] as? [String: Any] ?? [:]
    if tool == .codex && type == "session_meta" { return .ignored }
    let attachment = line["attachment"] as? [String: Any] ?? [:]
    let queuedAttachment = type == "attachment" && attachment["type"] as? String == "queued_command"
    let userItem = type == "event_msg" && payload["type"] as? String == "item_completed"
      && (payload["item"] as? [String: Any])?["type"] as? String == "UserMessage"
    if tool == .claude, type == "user" || queuedAttachment {
      if let mark = claudeExclusion(line, attachment: attachment, queuedAttachment: queuedAttachment,
        file: file, logsRelativePath: logsRelativePath, state: state)
      {
        if type == "user", let message = line["message"] as? [String: Any],
          let body = content(message["content"]), let time = epoch(line["timestamp"]) {
          AgentLogLegacyRefusal.discardQueued(body: body, at: time, state: &state, fingerprint: fingerprint)
        }
        return .excluded(mark)
      }
    }
    if tool == .codex, userItem {
      if let mark = state.ignoredSession { return .excluded(mark) }
      let item = payload["item"] as? [String: Any] ?? [:]
      if (payload["turn_id"] as? String ?? "").hasPrefix("external-import-turn-") {
        return .excluded(.imported)
      }
      if let mark = codexMark(line) ?? codexMark(payload) ?? codexMark(item) { return .excluded(mark) }
    }
    if tool == .claude, type == "queue-operation" {
      if claudeMark(line) == nil, wrapperMark(line["content"] as? String ?? "") == nil,
        let body = line["content"] as? String, let time = epoch(line["timestamp"]) {
        AgentLogLegacyRefusal.observeQueue(line, body: body, at: time, state: &state, fingerprint: fingerprint)
      }
      return .ignored
    }
    let body: String?
    var id: AgentLogInstructionIdentity?
    var aliases: [AgentLogInstructionIdentity] = []
    var legacyRefusal = AgentLogLegacyRefusal()
    let stamp: Any?
    if tool == .claude, type == "user" {
      guard let message = line["message"] as? [String: Any] else { return .malformed }
      body = content(message["content"])
      id = (line["uuid"] as? String).map(AgentLogIdentity.claude)
      if let raw = line["uuid"] as? String { legacyRefusal.claude(raw) }
      stamp = line["timestamp"]
    } else if tool == .claude, queuedAttachment {
      body = attachment["prompt"] as? String
      id = (attachment["source_uuid"] as? String ?? line["uuid"] as? String).map(AgentLogIdentity.claude)
      if let raw = attachment["source_uuid"] as? String ?? line["uuid"] as? String { legacyRefusal.claude(raw) }
      stamp = line["timestamp"] ?? attachment["timestamp"]
    } else if tool == .codex, userItem, let item = payload["item"] as? [String: Any] {
      body = content(item["content"])
      stamp = line["timestamp"]
      let source = URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent
      let thread = (payload["thread_id"] as? String).map { AgentLogIdentity.decoded($0).component } ?? state.session?.nativeComponent
        ?? AgentLogIdentity.decoded(source).component
      let turn = payload["turn_id"] as? String ?? epoch(stamp).map(String.init) ?? ""
      id = (item["id"] as? String).map { AgentLogIdentity.codex(thread: thread, turn: turn, item: $0) }
      if let raw = item["id"] as? String {
        legacyRefusal.codex(thread: thread, explicitThread: payload["thread_id"] as? String,
          state: state, fallbackSource: source, turn: turn, item: raw)
      }
    } else {
      return .ignored
    }
    guard let body else { return .malformed }
    guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .excluded(.empty) }
    guard let time = epoch(stamp) else { return .malformed }
    let hash = AgentLogIdentityCodec.legacy(fingerprint(body))
    if tool == .claude {
      legacyRefusal.pairQueue(line, attachment: attachment, queuedAttachment: queuedAttachment,
        hash: hash, at: time, state: &state)
    }
    // Only explicit source/command ids establish lineage. Content equality never establishes identity.
    if tool == .claude, let command = line["commandUuid"] as? String ?? line["source_uuid"] as? String {
      let canonical = AgentLogIdentity.claude(command)
      legacyRefusal.claude(command)
      if let id, id != canonical { aliases = [id] }
      id = canonical
    }
    let source = URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent
    if id == nil {
      id = legacyRefusal.fallbackIdentity(tool: tool, at: time, hash: hash)
    }
    // The full masked cwd distinguishes projects sharing the same final folder name.
    var evidence = EvidenceText(
      ts: time, kind: .prompt, source: source, sourceID: id?.storedKey, sourceAliases: aliases.filter { $0 != id }.map(\.storedKey),
      project: state.project, text: body)
    evidence.legacyRefusal = legacyRefusal
    return .prompt(evidence)
  }
  private static func nonempty(_ value: Any?) -> Bool { !(value as? String ?? "").isEmpty }
  private static func claudeExclusion(
    _ line: [String: Any], attachment: [String: Any], queuedAttachment: Bool,
    file: String, logsRelativePath: String?, state: AgentLogState
  ) -> AgentLogIgnore? {
    let parts = URL(fileURLWithPath: file).pathComponents
    let logs = parts.lastIndex(of: AgentLogTool.claude.logsFolder)
    let belowLogs = logsRelativePath?.split(separator: "/").map(String.init)
      ?? logs.map { Array(parts.suffix(from: $0 + 1)) } ?? []
    if belowLogs.contains("subagents") { return .subagent }
    if state.ownWorkingFolder == true { return .ownWindow }
    if let mark = claudeMark(line) { return mark }
    if queuedAttachment {
      if let mark = claudeMark(attachment) { return mark }
      if attachment["commandMode"] as? String == "task-notification" { return .taskNotification }
      if attachment["humanTurn"] as? Bool == false { return .nonHumanOrigin }
      let humanOrigin = (attachment["origin"] as? [String: Any])?["kind"] as? String == "human"
      if attachment["humanTurn"] as? Bool != true && !humanOrigin { return .nonHumanOrigin }
      return wrapperMark(attachment["prompt"] as? String ?? "")
    }
    if line["toolUseResult"] != nil { return .toolUseResult }
    let message = line["message"] as? [String: Any] ?? [:]
    if let blocks = message["content"] as? AgentLogRecord.Content, blocks.valid, blocks.toolResult { return .toolResult }
    if let blocks = message["content"] as? [[String: Any]],
      blocks.contains(where: { $0["type"] as? String == "tool_result" }) { return .toolResult }
    return wrapperMark(content(message["content"]) ?? "")
  }
  private static func wrapperMark(_ text: String) -> AgentLogIgnore? {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.hasPrefix("<task-notification>") { return .taskNotification }
    if text.hasPrefix("<local-command-stdout>") || text.hasPrefix("<local-command-stderr>") {
      return .localCommandOutput
    }
    if text.hasPrefix("<bash-stdout>") || text.hasPrefix("<bash-stderr>") { return .shellOutput }
    if text.hasPrefix("[Request interrupted by user") { return .interruption }
    return nil
  }
  private static func claudeMark(_ fields: [String: Any]) -> AgentLogIgnore? {
    if fields["isMeta"] as? Bool == true { return .meta }
    if fields["isCompactSummary"] as? Bool == true { return .compactSummary }
    if fields["isVisibleInTranscriptOnly"] as? Bool == true { return .transcriptOnly }
    if fields["isSidechain"] as? Bool == true { return .sidechain }
    if nonempty(fields["scheduledTaskId"]) || nonempty(fields["scheduledFireId"]) { return .automation }
    if ["system", "sdk"].contains(fields["promptSource"] as? String ?? "") { return .nonHumanOrigin }
    return originMark(fields)
  }
  private static func originMark(_ fields: [String: Any]) -> AgentLogIgnore? {
    guard let origin = fields["origin"] as? [String: Any], let kind = origin["kind"] as? String,
      kind != "human" else { return nil }
    return namedMark(kind) ?? .nonHumanOrigin
  }
  static func namedMark(_ value: String) -> AgentLogIgnore? {
    switch value {
    case "subagent": return .subagent
    case "task-notification": return .taskNotification
    case "peer": return .peer
    case "automation", "scheduled-task": return .automation
    default: return nil
    }
  }
  private static func codexMark(_ fields: [String: Any]) -> AgentLogIgnore? {
    for key in ["source", "thread_source"] {
      if let name = fields[key] as? String, let mark = namedMark(name) { return mark }
      if let source = fields[key] as? [String: Any], source["subagent"] != nil { return .subagent }
    }
    if nonempty(fields["parent_thread_id"]) { return .subagent }
    return originMark(fields)
  }
  private static func content(_ value: Any?) -> String? {
    if let string = value as? String { return string }
    if let content = value as? AgentLogRecord.Content { return content.body }
    guard let blocks = value as? [[String: Any]] else { return nil }
    let words = blocks.filter { ["text", "Text"].contains($0["type"] as? String ?? "") }
      .compactMap { $0["text"] as? String }
    if !words.isEmpty { return words.joined(separator: "\n") }
    if blocks.contains(where: { ["image", "local_image"].contains($0["type"] as? String ?? "") }) {
      return "[image attached]"
    }
    return ""
  }
  private static func epoch(_ value: Any?) -> Int? {
    guard let string = value as? String else { return nil }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let plain = ISO8601DateFormatter()
    return (fractional.date(from: string) ?? plain.date(from: string)).map { Int($0.timeIntervalSince1970) }
  }
}

/// Current reader guards and transaction-time historical permission use the same rule.
public enum AgentLogRecordingPermission {
  public static func allows(enabled: Bool, pausedUntil: Int?, at time: Int) -> Bool {
    enabled && (pausedUntil ?? Int.min) <= time
  }
}

public struct LogRecordingState: Equatable {
  public let since: Int
  public let enabled: Bool
  public let pausedUntil: Int?
  public init(since: Int, enabled: Bool, pausedUntil: Int?) {
    self.since = since
    self.enabled = enabled
    self.pausedUntil = pausedUntil
  }
  public func allows(_ time: Int) -> Bool {
    AgentLogRecordingPermission.allows(enabled: enabled, pausedUntil: pausedUntil, at: time)
  }
}

public protocol LogPrivacyHistory {
  func logRecordingHistory() throws -> [LogRecordingState]
}
public protocol AgentLogStorage: SettingsStore, LogPositionStore, LogBatchWriter, LogPrivacyHistory {
  func prepareAgentLogCollection() throws
  /// Changes whenever an ownership receipt an append consults may have changed; nil when unknown.
  func agentLogOwnershipRevision() throws -> String?
  /// The part of that revision held in database tables; nil when unknown.
  func agentLogOwnershipCounts() throws -> String?
  /// The hash-only receipt names in the store's registry; nil when unknown.
  func agentLogOwnershipReceipts() throws -> Set<String>?
}
extension AgentLogStorage {
  public func prepareAgentLogCollection() throws {}
  public func agentLogOwnershipRevision() throws -> String? { nil }
  public func agentLogOwnershipCounts() throws -> String? { nil }
  public func agentLogOwnershipReceipts() throws -> Set<String>? { nil }
}
