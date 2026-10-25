import Foundation

public enum ChatProvider: String, Codable, CaseIterable { case claude, codex }
public struct ChatSelection: Codable, Equatable {
  public var provider: ChatProvider
  public var model: String
  public var reasoning: String
  public init(provider: ChatProvider, model: String, reasoning: String) {
    self.provider = provider; self.model = model; self.reasoning = reasoning
  }
  /// Only levels with a label in every language. Vendors may offer more; those are left out, not refused.
  public static let reasoningLevels = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]
  public static func isValidModel(_ model: String) -> Bool {
    !model.isEmpty && model.utf8.count <= 128 && Redaction.applyKnownSecrets(model).text == model && model.unicodeScalars.allSatisfy {
      CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._:/").contains($0)
    }
  }
  public var isValid: Bool { Self.isValidModel(model) && Self.reasoningLevels.contains(reasoning) }
}
public struct ChatModel: Equatable {
  public let id: String
  public let reasoningLevels: [String]
  public let displayName: String
  public init(id: String, reasoningLevels: [String], displayName: String? = nil) {
    self.id = id; self.reasoningLevels = reasoningLevels; self.displayName = displayName ?? id
  }
  public func accepts(_ selection: ChatSelection) -> Bool {
    selection.isValid && selection.model == id && reasoningLevels.contains(selection.reasoning)
  }
  /// The vendor's order of the levels this app knows; nil when the id is unusable or no level is known.
  public var known: ChatModel? {
    let levels = reasoningLevels.filter { ChatSelection.reasoningLevels.contains($0) }
    return ChatSelection.isValidModel(id) && !levels.isEmpty ? ChatModel(id: id, reasoningLevels: levels, displayName: displayName) : nil
  }
}
public extension StorageSettings {
  var chatSelection: ChatSelection? { storedChatSelection.flatMap { $0.isValid ? $0 : nil } }
  /// Not checked: a level the app no longer knows still names the model to fall back within.
  var storedChatSelection: ChatSelection? {
    general["chat.selection"].flatMap { try? JSONDecoder().decode(ChatSelection.self, from: Data($0.utf8)) }
  }
}
public struct ConversationMessage: Codable, Equatable {
  public enum Role: String, Codable { case user, assistant }
  public let role: Role
  public let text: String
  public init(role: Role, text: String) { self.role = role; self.text = text }
}
public enum ConversationBilling: String, Equatable { case subscription, external }
public enum ConversationEvent: Equatable {
  case billing(ConversationBilling)
  case started
  case approval(ConversationApproval)
  case approvalResolved(id: String)
  case text(String)
  case toolStarted(id: String, name: String)
  case toolFinished(id: String, failed: Bool)
  case completed
}
public enum ConversationError: String, Error { case invalidSelection, unavailable, incompatible, timeout, cancelled, outputLimit, historyLimit, notInstalled, notLoggedIn }
public protocol ConversationAgent {
  var provider: ChatProvider { get }
  func models() throws -> [ChatModel]
  func converse(messages: [ConversationMessage], selection: ChatSelection) -> AsyncThrowingStream<ConversationEvent, Error>
}

public struct ConversationApprovalChoice: Equatable {
  public let id: String
  public enum Meaning: Equatable { case once, turn, session, deny, cancel, grant, native }
  public let label: String
  public let meaning: Meaning
  public let scope: String
  public let nativeJSON: String?
  public let conciseScope: String
  public init(id: String, label: String, meaning: Meaning? = nil, scope: String = "", nativeJSON: String? = nil, conciseScope: String = "") {
    self.id = id; self.label = label; self.scope = scope
    self.nativeJSON = nativeJSON; self.conciseScope = conciseScope
    self.meaning = meaning ?? (["approve": .once, "deny": .deny, "session": .session, "cancel": .cancel][id] ?? .native)
  }
}
/// Live request state is never persisted. Only one offered answer can win.
public enum ConversationApprovalOutcome: Equatable {
  case pending, answered(String), expired, cancelled
}
public final class ConversationApproval: Equatable {
  public let id = UUID().uuidString
  public let method: String
  public let details: String
  public let choices: [ConversationApprovalChoice]
  public let responseSchema: String?
  public let presentation: ConversationRequestPresentation
  public let fullDetails: String
  private let validateResponse: ((String) -> Bool)?
  private let clock: () -> TimeInterval
  private let deadline: TimeInterval
  private let lock = NSLock()
  private var selected: String?
  private var active = true
  private var result = ConversationApprovalOutcome.pending
  public init(method: String, details: String, choices: [ConversationApprovalChoice],
    presentation: ConversationRequestPresentation = .init(), fullDetails: String? = nil,
    responseSchema: String? = nil, validateResponse: ((String) -> Bool)? = nil,
    timeout: TimeInterval = 60, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
    self.method = method; self.details = details; self.choices = choices
    self.responseSchema = responseSchema; self.validateResponse = validateResponse
    self.presentation = presentation; self.fullDetails = fullDetails ?? method + "\n" + details
    self.clock = clock; self.deadline = clock() + max(0.01, min(60, timeout))
  }
  public static func == (lhs: ConversationApproval, rhs: ConversationApproval) -> Bool { lhs === rhs }
  private func expireIfNeeded(_ force: Bool = false) {
    if active && selected == nil && result == .pending && (force || clock() >= deadline) {
      selected = "deny"; result = .expired
    }
  }
  public var outcome: ConversationApprovalOutcome {
    lock.lock(); defer { lock.unlock() }; expireIfNeeded(); return result
  }
  public var remainingSeconds: Int {
    lock.lock(); defer { lock.unlock() }; expireIfNeeded()
    return result == .pending ? max(0, Int(ceil(deadline - clock()))) : 0
  }
  @discardableResult public func answer(choiceID: String) -> Bool {
    lock.lock(); defer { lock.unlock() }; expireIfNeeded()
    guard active, selected == nil, choices.contains(where: { $0.id == choiceID }) else { return false }
    selected = choiceID; result = .answered(choiceID); return true
  }
  @discardableResult public func answer(responseJSON: String) -> Bool {
    guard responseJSON.utf8.count <= 65536, validateResponse?(responseJSON) == true else { return false }
    lock.lock(); defer { lock.unlock() }; expireIfNeeded()
    guard active, selected == nil else { return false }
    selected = "json:" + responseJSON; result = .answered("form"); return true
  }
  /// Transport consumes a reply once; the terminal outcome remains available to the screen.
  public func takeAnswer(expired: Bool) -> String? {
    lock.lock(); defer { lock.unlock() }
    guard active else { return nil }
    expireIfNeeded(expired)
    guard let selected else { return nil }
    active = false; return selected
  }
  public func invalidate() {
    lock.lock(); defer { lock.unlock() }
    if active && result != .expired { result = .cancelled }
    active = false; selected = nil
  }
}
public extension StorageSettings {
  var chatSkipApprovals: Bool { general["chat.skipApprovals"] == "1" }
  var claudeConnected: Bool { general["chat.claude.connected"] == "1" }
  var claudeConnectionGeneration: String { general["chat.claude.generation"] ?? "" }
}

/// The byte budget covers JSON-encoded messages, excluding guidance and tool instructions.
public enum ConversationHistory {
  public static let maximumBytes = 65_536
  public static func encoded(_ messages: [ConversationMessage]) throws -> Data {
    let data = try JSONEncoder().encode(messages)
    guard data.count <= maximumBytes else { throw ConversationError.historyLimit }
    return data
  }
}
