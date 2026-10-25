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
}

public struct AgentLogListing {
  public let files: [AgentLogFile]
  public let folderFailures: Int
  public init(files: [AgentLogFile], folderFailures: Int = 0) {
    self.files = files
    self.folderFailures = folderFailures
  }
}

extension AgentLogReader {
  public func listing() throws -> AgentLogListing { AgentLogListing(files: try files()) }
}

public enum AgentLogIgnore: String, Codable, CaseIterable {
  case meta, compactSummary, transcriptOnly, sidechain, subagent
  case taskNotification, peer, automation, nonHumanOrigin, toolUseResult, toolResult
  case imported, ownWindow, localCommandOutput, shellOutput, interruption, empty
}

public enum AgentLogPolicy {
  public static func folders(tool: AgentLogTool, userHome: String, foundHomes: [String]) -> [String] {
    let defaultHome = URL(fileURLWithPath: userHome).appendingPathComponent(tool.defaultHomeName).path
    return Array(Set(([defaultHome] + foundHomes).filter { $0.hasPrefix("/") }.map {
      URL(fileURLWithPath: $0).appendingPathComponent(tool.logsFolder).standardizedFileURL.path
    })).sorted()
  }
  public static func continues(_ position: LogPosition?, file: AgentLogFile) -> Bool {
    guard let position else { return false }
    // Logs are append-only; an in-place rewrite past the saved offset cannot be detected by this identity.
    return position.device == file.device && position.inode == file.inode
      && position.offset >= 0 && position.offset <= file.size
  }
}

/// Checkpoints contain metadata and bounded queue hashes/ids/times, never prompt text or environment blocks.
public struct AgentLogState: Codable, Equatable {
  public var session: String?
  public var ownWorkingFolder: Bool?
  public var project = ""
  public var ignoredSession: AgentLogIgnore?
  public var metadataRead = false
  var queued: [QueuedInstruction] = []
  // Chosen memory bound, not measured. Each delivered hash can pair with one later user copy.
  static let queueLimit = 32
  struct QueuedInstruction: Codable, Equatable {
    let hash: String
    var id: String?
    let ts: Int
    var delivered: Bool
  }
  private struct OldQueuedInstruction: Decodable {
    let hash: String
    let id: String?
    let ts: Int
    let delivered: Bool?
    let sourceID: String?
  }
  public init() {}
  private enum CodingKeys: String, CodingKey {
    case session, project, folder, threadID, queued, ignoredSession, metadataRead, ownWorkingFolder
  }
  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    session = try values.decodeIfPresent(String.self, forKey: .session)
      ?? values.decodeIfPresent(String.self, forKey: .threadID)
    project = try values.decodeIfPresent(String.self, forKey: .project)
      ?? values.decodeIfPresent(String.self, forKey: .folder) ?? ""
    ownWorkingFolder = try values.decodeIfPresent(Bool.self, forKey: .ownWorkingFolder)
    if ownWorkingFolder == nil, !project.isEmpty {
      ownWorkingFolder = AgentWindowIdentity.containsWorkingFolder(project)
    }
    // Keep only hash/id/time from old queue entries, so a resumed delivery retains its enqueue timestamp.
    if values.contains(.metadataRead) {
      queued = Array((try values.decodeIfPresent([QueuedInstruction].self, forKey: .queued) ?? [])
        .suffix(Self.queueLimit))
    } else {
      let old = try values.decodeIfPresent([OldQueuedInstruction].self, forKey: .queued) ?? []
      queued = old.suffix(Self.queueLimit).map {
        QueuedInstruction(hash: $0.hash, id: $0.delivered == true
          ? $0.sourceID ?? $0.id.map { "claude:" + $0 } : $0.id, ts: $0.ts, delivered: $0.delivered ?? false)
      }
    }
    ignoredSession = try values.decodeIfPresent(AgentLogIgnore.self, forKey: .ignoredSession)
    metadataRead = try values.decodeIfPresent(Bool.self, forKey: .metadataRead) ?? false
  }
  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encodeIfPresent(session, forKey: .session)
    try values.encode(project, forKey: .project)
    try values.encodeIfPresent(ownWorkingFolder, forKey: .ownWorkingFolder)
    try values.encode(queued, forKey: .queued)
    try values.encodeIfPresent(ignoredSession, forKey: .ignoredSession)
    try values.encode(metadataRead, forKey: .metadataRead)
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

public enum AgentLogParser {
  /// The adapter supplies SHA-256, keeping Core independent of platform crypto modules.
  public static func parse(
    _ text: String, tool: AgentLogTool, file: String, state: inout AgentLogState,
    logsRelativePath: String? = nil, fingerprint: (String) -> String
  ) -> AgentLogLine {
    guard let line = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
      let type = line["type"] as? String
    else { return .malformed }
    let payload = line["payload"] as? [String: Any] ?? [:]
    if tool == .codex, type == "session_meta" {
      state.session = payload["id"] as? String ?? payload["session_id"] as? String ?? state.session
      setProject(payload["cwd"], state: &state)
      state.ignoredSession = codexMark(payload)
      state.metadataRead = true
      return .ignored
    }
    if tool == .claude {
      state.session = line["sessionId"] as? String ?? state.session
      setProject(line["cwd"], state: &state)
    }
    let attachment = line["attachment"] as? [String: Any] ?? [:]
    let queuedAttachment = type == "attachment" && attachment["type"] as? String == "queued_command"
    let userItem = type == "event_msg" && payload["type"] as? String == "item_completed"
      && (payload["item"] as? [String: Any])?["type"] as? String == "UserMessage"
    if tool == .claude, type == "user" || queuedAttachment {
      if let mark = claudeExclusion(line, attachment: attachment, queuedAttachment: queuedAttachment,
        file: file, logsRelativePath: logsRelativePath, state: state)
      {
        if type == "user", let message = line["message"] as? [String: Any],
          let body = content(message["content"]), let time = epoch(line["timestamp"])
        {
          let hash = fingerprint(body)
          state.queued.removeAll { $0.hash == hash && !$0.delivered && $0.ts <= time }
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
      // Enqueue bookkeeping is not a prompt candidate; only a delivery contributes ignore counts.
      if claudeMark(line) != nil || wrapperMark(line["content"] as? String ?? "") != nil { return .ignored }
      if let body = line["content"] as? String, let time = epoch(line["timestamp"]) {
        let hash = fingerprint(body)
        if line["operation"] as? String == "enqueue" {
          state.queued.removeAll { $0.hash == hash && !$0.delivered }
          state.queued.append(.init(hash: hash, id: line["commandUuid"] as? String, ts: time, delivered: false))
        } else if line["operation"] as? String == "remove" {
          if line["reason"] as? String == "absorbed_mid_turn" {
            if let index = state.queued.lastIndex(where: { $0.hash == hash && !$0.delivered }),
              let commandID = line["commandUuid"] as? String
            {
              state.queued[index].id = commandID
            }
          } else {
            state.queued.removeAll { $0.hash == hash && !$0.delivered }
          }
        }
        state.queued = Array(state.queued.suffix(AgentLogState.queueLimit))
      }
      return .ignored
    }
    let body: String?
    var id: String?
    var aliases: [String] = []
    let stamp: Any?
    if tool == .claude, type == "user" {
      guard let message = line["message"] as? [String: Any] else { return .malformed }
      body = content(message["content"])
      id = (line["uuid"] as? String).map { "claude:" + $0 }
      stamp = line["timestamp"]
    } else if tool == .claude, queuedAttachment {
      body = attachment["prompt"] as? String
      id = (attachment["source_uuid"] as? String ?? line["uuid"] as? String).map { "claude:" + $0 }
      stamp = attachment["timestamp"] ?? line["timestamp"]
    } else if tool == .codex, userItem, let item = payload["item"] as? [String: Any] {
      body = content(item["content"])
      stamp = line["timestamp"]
      let source = URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent
      let thread = payload["thread_id"] as? String ?? state.session ?? source
      let turn = payload["turn_id"] as? String ?? epoch(stamp).map(String.init) ?? ""
      id = (item["id"] as? String).map { "codex:" + thread + ":" + turn + ":" + $0 }
    } else {
      return .ignored
    }
    guard let body else { return .malformed }
    guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .excluded(.empty) }
    guard var time = epoch(stamp) else { return .malformed }
    let hash = fingerprint(body)
    if tool == .claude, queuedAttachment {
      let rawID = attachment["source_uuid"] as? String
      let pending = state.queued.lastIndex { !$0.delivered && rawID != nil && $0.id == rawID }
        ?? state.queued.lastIndex { !$0.delivered && $0.hash == hash && $0.ts <= time }
      if let pending {
        time = state.queued[pending].ts
        state.queued.remove(at: pending)
      }
      id = id ?? "claude:legacy:\(time):\(hash)"
      state.queued.append(.init(hash: hash, id: id, ts: time, delivered: true))
      state.queued = Array(state.queued.suffix(AgentLogState.queueLimit))
    } else if tool == .claude, line["promptSource"] as? String == "queued" {
      // A new enqueue wins over an unmatched earlier delivery with the same words.
      // A missing enqueue or backward clock can pair identical words with an older unconsumed delivery.
      let index = state.queued.lastIndex { $0.hash == hash && !$0.delivered && $0.ts <= time }
        ?? state.queued.firstIndex { $0.hash == hash && $0.delivered }
      if let index {
        let pair = state.queued.remove(at: index)
        if let id { aliases = [id] }
        time = pair.ts
        id = pair.delivered ? pair.id : pair.id.map { "claude:" + $0 } ?? id
      }
    }
    let source = URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent
    id = id ?? "\(tool.rawValue):legacy:\(time):\(hash)"
    // The full masked cwd distinguishes projects sharing the same final folder name.
    return .prompt(EvidenceText(
      ts: time, kind: .prompt, source: source, sourceID: id, sourceAliases: aliases.filter { $0 != id },
      project: state.project, text: body))
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
    if state.ownWorkingFolder ?? AgentWindowIdentity.containsWorkingFolder(state.project) { return .ownWindow }
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
  private static func namedMark(_ value: String) -> AgentLogIgnore? {
    switch value {
    case "subagent": return .subagent
    case "task-notification": return .taskNotification
    case "peer": return .peer
    case "automation", "scheduled-task": return .automation
    default: return nil
    }
  }
  private static func codexMark(_ fields: [String: Any]) -> AgentLogIgnore? {
    if let originator = fields["originator"] as? String,
      [AgentWindowIdentity.codexOriginator, AgentWindowIdentity.codexPlanOriginator].contains(originator) { return .ownWindow }
    for key in ["source", "thread_source"] {
      if let name = fields[key] as? String, let mark = namedMark(name) { return mark }
      if let source = fields[key] as? [String: Any], source["subagent"] != nil { return .subagent }
    }
    if nonempty(fields["parent_thread_id"]) { return .subagent }
    return originMark(fields)
  }
  private static func setProject(_ value: Any?, state: inout AgentLogState) {
    if state.project.isEmpty, let path = value as? String, !path.isEmpty {
      // Classify the first folder before content masking can remove a path component.
      state.ownWorkingFolder = AgentWindowIdentity.containsWorkingFolder(path)
      state.project = Redaction.apply(path).text
    }
  }
  private static func content(_ value: Any?) -> String? {
    if let string = value as? String { return string }
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

public struct LogRecordingState: Equatable {
  public let since: Int
  public let enabled: Bool
  public let pausedUntil: Int?
  public init(since: Int, enabled: Bool, pausedUntil: Int?) {
    self.since = since
    self.enabled = enabled
    self.pausedUntil = pausedUntil
  }
  public func allows(_ time: Int) -> Bool { enabled && (pausedUntil ?? Int.min) <= time }
}

public protocol LogPrivacyHistory {
  func logRecordingHistory() throws -> [LogRecordingState]
}
public protocol AgentLogStorage: SettingsStore, LogPositionStore, LogBatchWriter, LogPrivacyHistory {}
