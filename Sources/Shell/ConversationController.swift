import Core
import Foundation
import SwiftUI

/// The host constructs adapters from app-only directories. The screen only sees the common port.
public typealias ConversationAgentFactory = (ChatSelection, Bool) -> ConversationAgent
@MainActor public final class ConversationController: ObservableObject {
  @Published public private(set) var presentation = ConversationPresentation()
  @Published public private(set) var settings: StorageSettings
  @Published public private(set) var provider: ChatProvider
  @Published public private(set) var selection: ChatSelection?
  @Published public private(set) var catalog: [ChatModel] = []
  @Published public private(set) var isLoadingCatalog = false
  @Published public private(set) var error: ChatLabel?
  @Published public private(set) var revision = 0
  @Published public private(set) var conversationID = UUID()
  public private(set) var history: [ConversationMessage] = []
  private let store: SettingsEditingStore
  private let makeAgent: ConversationAgentFactory
  private var turn: Task<Void, Never>?
  private var generation = UUID()
  private var catalogGeneration = UUID()
  private var catalogAccountGeneration: String?
  private var catalogConnected: Bool?
  private struct ApprovalTick: Equatable { let outcome: ConversationApprovalOutcome; let seconds: Int }
  private var approvalTicks: [ApprovalTick] = []
  public init(store: SettingsEditingStore, makeAgent: @escaping ConversationAgentFactory) throws {
    let settings = try store.settings()
    self.store = store; self.makeAgent = makeAgent; self.settings = settings
    // A stored choice whose level this build does not know still names the person's provider.
    self.selection = settings.chatSelection; self.provider = settings.storedChatSelection?.provider ?? .codex
  }
  deinit { turn?.cancel() }
  public var connected: Bool { provider == .codex ? settings.subscriptionConnected : settings.claudeConnected }
  public var skipApprovals: Bool { settings.chatSkipApprovals }
  @discardableResult public func refresh() -> Bool {
    do {
      let previousSkip = skipApprovals
      let refreshed = try store.settings()
      if refreshed != settings { settings = refreshed }
      if presentation.isRunning && (!connected || previousSkip != skipApprovals) {
        stop(); presentation.notice(!connected ? .connectionStopped : .approvalStopped)
      }
      let ticks = presentation.requests.map { ApprovalTick(outcome: $0.outcome, seconds: $0.remainingSeconds) }
      if ticks != approvalTicks { approvalTicks = ticks; revision += 1 }
      return true
    } catch {
      let wasRunning = presentation.isRunning; stop()
      if wasRunning { presentation.notice(.settingsStopped) }
      self.error = .readFailed; return false
    }
  }
  /// Sign-in and account switches change the consent generation, even if both accounts are connected.
  public func refreshAccountCatalogIfNeeded() async {
    guard refresh() else { return }
    if catalogConnected != connected || (provider == .codex && catalogAccountGeneration != settings.connectionGeneration) {
      await loadCatalog()
    }
  }
  public func chooseProvider(_ provider: ChatProvider) async {
    guard !presentation.isRunning else { return }
    guard self.provider != provider else { return }
    history = []; presentation.boundary(provider)
    self.provider = provider; selection = nil; await loadCatalog()
  }
  public func loadCatalog() async {
    guard !Task.isCancelled, !presentation.isRunning else { return }
    catalog = []; error = nil
    guard refresh() else { return }
    let token = UUID(); catalogGeneration = token
    let accountGeneration = settings.connectionGeneration
    catalogAccountGeneration = accountGeneration; catalogConnected = connected
    guard connected else { isLoadingCatalog = false; return }
    isLoadingCatalog = true
    let requested = provider
    let initial = ChatSelection(provider: requested, model: "catalog", reasoning: "low")
    let agent = makeAgent(initial, skipApprovals)
    let result = await Task.detached { Result { try agent.models() } }.value
    guard token == catalogGeneration, provider == requested else { return }
    isLoadingCatalog = false
    guard !Task.isCancelled, refresh(), connected,
      requested != .codex || settings.connectionGeneration == accountGeneration else { return }
    switch result {
    case .success(let models):
      catalog = models.compactMap(\.known)
      let saved = settings.storedChatSelection.flatMap { $0.provider == requested ? $0 : nil }
      if let saved, catalog.contains(where: { $0.accepts(saved) }) { selection = saved }
      // A saved level the catalog stopped offering keeps its model and takes that model's first level.
      else if let model = saved.flatMap({ saved in catalog.first { $0.id == saved.model } })
        ?? (requested == .codex ? catalog.first { $0.id == SummaryPolicy.model } : nil) ?? catalog.first,
        let reasoning = (saved?.model != model.id && requested == .codex && model.reasoningLevels.contains("low") ? "low" : model.reasoningLevels.first) {
        choose(model: model.id, reasoning: reasoning)
      }
      if catalog.isEmpty { error = .catalogFailed }
    case .failure(let failure):
      switch failure as? ConversationError {
      case .notInstalled?: error = .notInstalled
      case .notLoggedIn?: error = requested == .claude ? .claudeNotLoggedIn : .notConnected
      default: error = .catalogFailed
      }
    }
  }
  public func choose(model: String, reasoning: String) {
    guard !presentation.isRunning else { return }
    let value = ChatSelection(provider: provider, model: model, reasoning: reasoning)
    guard catalog.contains(where: { $0.accepts(value) }) else { return }
    do { settings = try store.patchSettings(.chatSelection(value)); selection = value; error = nil }
    catch { self.error = .saveFailed }
  }
  @discardableResult public func send(_ text: String) -> Bool {
    guard refresh() else { return false }
    guard connected, !presentation.isRunning, let selection,
      catalog.contains(where: { $0.accepts(selection) }), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
    guard error != .historyLimit else { return false }
    let previousHistory = history
    let messages = history + [ConversationMessage(role: .user, text: text)]
    do { _ = try ConversationHistory.encoded(messages) }
    catch { self.error = .historyLimit; return false }
    error = nil; history = messages; presentation.begin(text)
    let token = UUID(); generation = token
    let agent = makeAgent(selection, skipApprovals)
    turn = Task { [weak self] in
      do {
        for try await event in agent.converse(messages: messages, selection: selection) {
          guard let self, self.generation == token, !Task.isCancelled else {
            if case .approval(let request) = event { request.invalidate() }; break
          }
          // Keep Send disabled until transport cleanup succeeds and the reply joins history.
          if case .completed = event { continue }
          self.presentation.receive(event); self.revision += 1
        }
        guard let self, self.generation == token else { return }
        self.saveReply(); self.presentation.finish(); self.turn = nil
      } catch {
        guard let self, self.generation == token else { return }
        if error as? ConversationError == .historyLimit {
          self.history = previousHistory; self.error = .historyLimit
        } else if error as? ConversationError == .notInstalled {
          self.history = previousHistory; self.error = .notInstalled
        } else if error as? ConversationError == .notLoggedIn {
          self.history = previousHistory; self.error = selection.provider == .claude ? .claudeNotLoggedIn : .notConnected
        } else {
          self.saveReply(); self.error = .turnFailed
        }
        self.presentation.finish(); self.turn = nil
      }
    }
    return true
  }
  private func saveReply() {
    let start = presentation.rows.lastIndex { $0.kind == .person } ?? 0
    let reply = presentation.rows.dropFirst(start).filter { $0.kind == .agent }.map(\.text).joined(separator: "\n")
    if !reply.isEmpty { history.append(.init(role: .assistant, text: reply)) }
  }
  public func answer(_ request: ConversationApproval, choice: String) {
    guard presentation.isRunning else { return }
    _ = request.answer(choiceID: choice); revision += 1
  }
  @discardableResult public func answer(_ request: ConversationApproval, json: String) -> Bool {
    guard presentation.isRunning else { return false }
    let accepted = request.answer(responseJSON: json); revision += 1; return accepted
  }
  public func stop() {
    guard presentation.isRunning || turn != nil else { return }
    generation = UUID(); turn?.cancel(); turn = nil
    if presentation.isRunning { saveReply() }; presentation.stop(); revision += 1
  }
  public func newConversation() { stop(); history = []; presentation = ConversationPresentation(); error = nil; conversationID = UUID() }
}
