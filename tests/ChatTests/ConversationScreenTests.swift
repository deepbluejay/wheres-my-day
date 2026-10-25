import Combine
import Core
import Foundation
@testable import Shell
@testable import Outbound
import Storage
import XCTest

final class ConversationScreenTests: XCTestCase {
  @MainActor func testCodexDefaultUsesLunaLowAndPreservesSavedChoices() async throws {
    let choices: [(ChatSelection?, String)] = [(nil, "low"),
      (.init(provider: .codex, model: "invented-missing", reasoning: "high"), "low"),
      (.init(provider: .codex, model: "gpt-5.6-luna", reasoning: "high"), "high")]
    for (previous, effort) in choices {
      let store = ScreenSettings(); store.value.subscriptionConnected = true
      if let previous { _ = try store.patchSettings(.chatSelection(previous)) }
      let agent = ScreenAgent()
      agent.availableModels = [.init(id: "invented-first", reasoningLevels: ["high"]),
        .init(id: SummaryPolicy.model, reasoningLevels: ["high", "low"])]
      let controller = try ConversationController(store: store, makeAgent: { _, _ in agent })
      await controller.loadCatalog()
      XCTAssertEqual(controller.selection, .init(provider: .codex, model: "gpt-5.6-luna", reasoning: effort))
    }
  }
  @MainActor func testAccountSwitchAndSignInRefreshChoicesWhileConnected() async throws {
    let store = ScreenSettings(); store.value.subscriptionConnected = true
    let agent = ScreenAgent()
    agent.availableModels = [.init(id: "invented-old", reasoningLevels: ["high"])]
    let controller = try ConversationController(store: store, makeAgent: { _, _ in agent })
    await controller.loadCatalog()
    for generation in ["invented-switch", "invented-sign-in"] {
      agent.availableModels = [.init(id: SummaryPolicy.model, reasoningLevels: ["high", "low"])]
      store.value.connectionGeneration = generation
      await controller.refreshAccountCatalogIfNeeded()
      XCTAssertEqual(controller.catalog.map(\.id), [SummaryPolicy.model])
      XCTAssertEqual(controller.selection?.reasoning, "low")
    }
  }
  // Ideal: provider identity never changes message order, text boundaries, or tool lines.
  @MainActor func testIdenticalProviderEventsHaveIdenticalPresentation() async throws {
    let events: [ConversationEvent] = [.started, .text("First "), .text("answer"),
      .toolStarted(id: "q", name: "activity_recent"), .toolFinished(id: "q", failed: false),
      .text("After query"), .completed]
    var models: [ConversationPresentation] = []
    var histories: [[ConversationMessage]] = []
    for provider in ChatProvider.allCases {
      let store = ScreenSettings(); store.value.subscriptionConnected = true; store.value.general["chat.claude.connected"] = "1"
      let selection = ChatSelection(provider: provider, model: "invented", reasoning: "low")
      _ = try store.patchSettings(.chatSelection(selection))
      let agent = ScreenAgent(provider: provider, script: events)
      let controller = try ConversationController(store: store, makeAgent: { selected, skip in
        XCTAssertEqual(selected.provider, provider); XCTAssertFalse(skip); return agent
      })
      await controller.loadCatalog(); controller.send("Invented question")
      for _ in 0..<100 where controller.presentation.isRunning { await Task.yield() }
      XCTAssertFalse(controller.presentation.isRunning)
      XCTAssertEqual(controller.selection, selection)
      models.append(controller.presentation); histories.append(controller.history)
    }
    XCTAssertEqual(models[0].rows, models[1].rows); XCTAssertEqual(histories[0], histories[1])
    XCTAssertEqual(models[0].rows.map(\.text), ["Invented question", "First answer", "activity_recent", "After query"])
    XCTAssertEqual(models[0].rows[2].kind, .tool(.done))
  }
  func testApprovalDeadlineAndExactlyOneAnswer() {
    var now = 100.0
    let request = ConversationApproval(method: "command", details: "Invented command", choices: [
      .init(id: "approve", label: "accept"), .init(id: "deny", label: "decline")], timeout: 10, clock: { now })
    XCTAssertEqual(request.remainingSeconds, 10)
    XCTAssertTrue(request.answer(choiceID: "approve")); XCTAssertFalse(request.answer(choiceID: "deny"))
    XCTAssertEqual(request.takeAnswer(expired: false), "approve"); XCTAssertNil(request.takeAnswer(expired: false))
    XCTAssertEqual(request.outcome, .answered("approve"))
    let expired = ConversationApproval(method: "command", details: "Invented", choices: [.init(id: "deny", label: "decline")], timeout: 10, clock: { now })
    now = 110
    XCTAssertEqual(expired.outcome, .expired); XCTAssertFalse(expired.answer(choiceID: "deny"))
    XCTAssertEqual(expired.takeAnswer(expired: false), "deny"); XCTAssertEqual(expired.outcome, .expired)
  }
  func testStopCancelsEveryPendingRequestAndRunningTool() {
    var model = ConversationPresentation(); model.begin("Invented")
    let requests = (0..<3).map { _ in ConversationApproval(method: "command", details: "Invented", choices: [.init(id: "deny", label: "decline")]) }
    model.receive(.toolStarted(id: "q", name: "activity_recent"))
    for request in requests { model.receive(.approval(request)) }
    model.stop()
    XCTAssertFalse(model.isRunning)
    for request in requests { XCTAssertEqual(request.outcome, .cancelled); XCTAssertFalse(request.answer(choiceID: "deny")) }
    XCTAssertEqual(model.rows[1].kind, .tool(.cancelled))
  }
  func testNativeQuestionFormsReturnEachProvidersRequiredShapeOnce() throws {
    for provider in ChatProvider.allCases {
      var events: [ConversationEvent] = []
      let broker = ConversationApprovals(timeout: 60) { events.append($0) }
      if provider == .codex {
        _ = try broker.codex(["id": 1, "method": "item/tool/requestUserInput", "params": ["threadId": "root", "turnId": "turn",
          "questions": [["id": "period", "question": "Invented period?"], ["id": "topic", "question": "Invented topic?"]]]], thread: "root", turn: "turn")
      } else {
        try broker.claude(["request_id": "1", "request": ["subtype": "can_use_tool", "tool_name": "AskUserQuestion", "input": [
          "questions": [["question": "Invented period?"], ["question": "Invented topic?"]]]]])
      }
      guard case .approval(let request) = events.first, let form = ConversationQuestions(request: request) else { return XCTFail() }
      XCTAssertEqual(form.fields.count, 2)
      let state = ConversationQuestionState()
      for field in form.fields {
        state.values[field.id] = "Invented answer"
      }
      let json = try XCTUnwrap(form.response(state: state))
      XCTAssertTrue(request.answer(responseJSON: json)); XCTAssertFalse(request.answer(responseJSON: json))
      var replies: [Data] = []
      try broker.flush { replies.append($0) }; try broker.flush { replies.append($0) }
      XCTAssertEqual(replies.count, 1); XCTAssertEqual(request.outcome, .answered("form"))
      let reply = String(decoding: replies[0], as: UTF8.self)
      XCTAssertTrue(reply.contains("Invented answer")); XCTAssertTrue(reply.contains("answers"))
    }
  }
  @MainActor func testDisconnectedProviderNeverLoadsModelsOrStartsTurn() async throws {
    let store = ScreenSettings()
    let agent = ScreenAgent()
    let controller = try ConversationController(store: store, makeAgent: { _, _ in agent })
    await controller.loadCatalog(); controller.send("Invented")
    await controller.chooseProvider(.claude)
    XCTAssertEqual(agent.catalogCalls, 0); XCTAssertNil(agent.continuation)
    XCTAssertFalse(controller.connected); XCTAssertNil(controller.selection)
    XCTAssertEqual(ChatProvider.claude.settingsSection, .claude)
    XCTAssertEqual(ChatProvider.codex.settingsSection, .subscription)
  }
  @MainActor func testSettingsFailureAndApprovalModeChangeStopWithoutReusingOldConsent() async throws {
    let store = ScreenSettings(); store.value.subscriptionConnected = true
    let agent = ScreenAgent()
    let controller = try ConversationController(store: store, makeAgent: { _, _ in agent })
    await controller.loadCatalog(); controller.send("Invented")
    XCTAssertTrue(controller.presentation.isRunning)
    store.value.general["chat.skipApprovals"] = "1"; controller.refresh()
    XCTAssertFalse(controller.presentation.isRunning); XCTAssertTrue(controller.skipApprovals)
    store.fail = true; controller.send("Invented again")
    XCTAssertFalse(controller.presentation.isRunning); XCTAssertEqual(controller.error, .readFailed)
  }
  @MainActor func testTurnCompletesOnlyAfterReplyIsAddedToHistory() async throws {
    let store = ScreenSettings(); store.value.subscriptionConnected = true
    let agent = ScreenAgent()
    let controller = try ConversationController(store: store, makeAgent: { _, _ in agent })
    await controller.loadCatalog(); controller.send("Invented question")
    await Task.yield()
    agent.emit(.text("Invented reply")); agent.emit(.completed)
    for _ in 0..<10 { await Task.yield() }
    XCTAssertTrue(controller.presentation.isRunning)
    controller.send("Too early"); XCTAssertEqual(controller.history.count, 1)
    agent.continuation?.finish()
    for _ in 0..<100 where controller.presentation.isRunning { await Task.yield() }
    XCTAssertFalse(controller.presentation.isRunning)
    XCTAssertEqual(controller.history, [.init(role: .user, text: "Invented question"), .init(role: .assistant, text: "Invented reply")])
  }
  @MainActor func testControllerStopRejectsLateEventsAndNewConversationClearsHistory() async throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try ActivityStorage(url: root.appendingPathComponent("invented.sqlite"), appDataDirectory: root, databaseScope: .directory(root))
    let begun = try store.patchSettings(.beginConnection)
    _ = try store.patchSettings(.completeConnection(generation: begun.connectionGeneration))
    let agent = ScreenAgent()
    let controller = try ConversationController(store: store, makeAgent: { _, _ in agent })
    await controller.loadCatalog()
    XCTAssertEqual(controller.selection?.model, "invented")
    controller.send("Invented question")
    await Task.yield()
    let request = ConversationApproval(method: "command", details: "Invented", choices: [.init(id: "deny", label: "decline")])
    agent.emit(.approval(request)); agent.emit(.text("Before stop"))
    for _ in 0..<10 { await Task.yield() }
    controller.stop(); agent.emit(.text("Late"))
    for _ in 0..<10 { await Task.yield() }
    XCTAssertEqual(request.outcome, .cancelled)
    XCTAssertFalse(controller.presentation.rows.contains { $0.text.contains("Late") })
    controller.newConversation()
    XCTAssertTrue(controller.presentation.rows.isEmpty); XCTAssertTrue(controller.history.isEmpty)
    controller.refresh(); XCTAssertFalse(controller.skipApprovals)
    _ = try store.patchSettings(.chatSkipApprovals(true)); controller.refresh(); XCTAssertTrue(controller.skipApprovals)
  }
  @MainActor func testProviderBoundaryKeepsTranscriptAndRefreshPublishesOnlyChanges() async throws {
    let store = ScreenSettings(); store.value.subscriptionConnected = true
    let agent = ScreenAgent(script: [.text("Invented answer"), .completed])
    let controller = try ConversationController(store: store, makeAgent: { _, _ in agent })
    await controller.loadCatalog(); XCTAssertTrue(controller.send("Invented prompt"))
    for _ in 0..<100 where controller.presentation.isRunning { await Task.yield() }
    let before = controller.presentation.rows
    var publications = 0
    let subscription = controller.objectWillChange.sink { publications += 1 }
    for _ in 0..<100 { XCTAssertTrue(controller.refresh()) }
    XCTAssertEqual(publications, 0)
    await controller.chooseProvider(.claude)
    XCTAssertEqual(Array(controller.presentation.rows.prefix(before.count)), before)
    XCTAssertEqual(controller.presentation.rows.last?.kind, .boundary(.claude))
    XCTAssertTrue(controller.history.isEmpty); XCTAssertFalse(controller.connected)
    withExtendedLifetime(subscription) {}
  }
  @MainActor func testAutomaticStopsShowReasonsAndExecutedActionCaveat() async throws {
    for reason in [ChatLabel.connectionStopped, .approvalStopped, .settingsStopped] {
      let store = ScreenSettings(); store.value.subscriptionConnected = true
      let agent = ScreenAgent()
      let controller = try ConversationController(store: store, makeAgent: { _, _ in agent })
      await controller.loadCatalog(); XCTAssertTrue(controller.send("Invented"))
      switch reason {
      case .connectionStopped: store.value.subscriptionConnected = false
      case .approvalStopped: store.value.general["chat.skipApprovals"] = "1"
      default: store.fail = true
      }
      controller.refresh()
      XCTAssertFalse(controller.presentation.isRunning)
      XCTAssertEqual(controller.presentation.rows.last?.kind, .notice(reason))
      XCTAssertTrue(ConversationStrings(language: "en").text(reason).contains("not undone"))
    }
  }

  func testHistoryBudgetCountsExactlyEncodedJSONBytes() throws {
    for unit in ["a", "가", "\"\\\n"] {
      let overhead = try JSONEncoder().encode([ConversationMessage(role: .user, text: "")]).count
      let unitBytes = try JSONEncoder().encode([ConversationMessage(role: .user, text: unit)]).count - overhead
      let count = (65536 - overhead) / unitBytes
      let remaining = 65536 - overhead - count * unitBytes
      let exact = [ConversationMessage(role: .user, text: String(repeating: unit, count: count) + String(repeating: "a", count: remaining))]
      XCTAssertEqual(try ConversationHistory.encoded(exact).count, 65536)
      XCTAssertNoThrow(try ConversationEncoding.transcript(exact, guidance: String(repeating: "Invented guidance", count: 5000)))
      let over = [ConversationMessage(role: .user, text: exact[0].text + "a")]
      XCTAssertThrowsError(try ConversationEncoding.transcript(over, guidance: "")) { XCTAssertEqual($0 as? ConversationError, .historyLimit) }
    }
  }

  @MainActor func testOversizedHistoryKeepsTranscriptAndRejectsFollowupWithoutAccumulatingIt() async throws {
    for provider in ChatProvider.allCases {
      let store = ScreenSettings(); store.value.subscriptionConnected = true; store.value.general["chat.claude.connected"] = "1"
      _ = try store.patchSettings(.chatSelection(.init(provider: provider, model: "invented", reasoning: "low")))
      let agent = EncodingScreenAgent(provider: provider)
      let controller = try ConversationController(store: store, makeAgent: { _, _ in agent })
      await controller.loadCatalog(); XCTAssertTrue(controller.send("Invented initial prompt"))
      for _ in 0..<200 where controller.presentation.isRunning { await Task.yield() }
      let transcript = controller.presentation.rows, history = controller.history
      XCTAssertEqual(history.count, 2)
      XCTAssertGreaterThan(try JSONEncoder().encode(history).count, 65536)
      for _ in 0..<2 {
        XCTAssertFalse(controller.send("Invented rejected followup"))
        for _ in 0..<200 where controller.presentation.isRunning { await Task.yield() }
        XCTAssertTrue(controller.history == history)
        XCTAssertTrue(controller.presentation.rows == transcript)
        XCTAssertEqual(controller.error?.rawValue, "This conversation exceeds the history limit. Start a new conversation to continue; this transcript stays visible until then.")
      }
      XCTAssertEqual(agent.turns, 1)
      controller.newConversation()
      XCTAssertTrue(controller.history.isEmpty); XCTAssertTrue(controller.presentation.rows.isEmpty); XCTAssertNil(controller.error)
      XCTAssertTrue(controller.send("Invented new prompt"))
      for _ in 0..<200 where controller.presentation.isRunning { await Task.yield() }
      XCTAssertEqual(agent.turns, 2)
    }
  }

  @MainActor func testCountdownPublishesOnlyChangedSecondsIncludingFinalExpiry() async throws {
    let store = ScreenSettings(); store.value.subscriptionConnected = true
    let agent = ScreenAgent()
    let active = try ConversationController(store: store, makeAgent: { _, _ in agent })
    await active.loadCatalog(); XCTAssertTrue(active.send("Invented")); await Task.yield()
    var now = 100.0
    let request = ConversationApproval(method: "invented", details: "", choices: [.init(id: "deny", label: "deny")], timeout: 10, clock: { now })
    agent.emit(.approval(request)); for _ in 0..<10 { await Task.yield() }
    active.refresh(); let initial = active.revision
    for _ in 0..<10 { active.refresh() }; XCTAssertEqual(active.revision, initial)
    now = 110.01; active.refresh()
    XCTAssertEqual(request.outcome, .expired); XCTAssertEqual(active.revision, initial + 1)
    active.refresh(); XCTAssertEqual(active.revision, initial + 1)
    active.stop()
  }
  // Ideal: a CLI that is not installed says so, offers a retry, and leaves nothing half-sent.
  @MainActor func testMissingCLIShowsNotInstalledForCatalogAndTurn() async throws {
    let store = ScreenSettings(); store.value.subscriptionConnected = true; store.value.general["chat.claude.connected"] = "1"
    let missing = MissingCLIAgent(provider: .codex)
    let codex = try ConversationController(store: store, makeAgent: { _, _ in missing })
    await codex.loadCatalog()
    XCTAssertEqual(codex.error, .notInstalled); XCTAssertTrue(codex.catalog.isEmpty)
    XCTAssertFalse(codex.send("Invented"))
    let claude = MissingCLIAgent(provider: .claude)
    let controller = try ConversationController(store: store, makeAgent: { _, _ in claude })
    await controller.chooseProvider(.claude)
    XCTAssertNil(controller.error); XCTAssertFalse(controller.catalog.isEmpty)
    XCTAssertTrue(controller.send("Invented question"))
    for _ in 0..<100 where controller.presentation.isRunning { await Task.yield() }
    XCTAssertEqual(controller.error, .notInstalled); XCTAssertTrue(controller.history.isEmpty)
    XCTAssertEqual(SettingsMessage(error: SubscriptionConnectionError.notInstalled), .notInstalled)
  }
  // Ideal: a Claude Code without a login says so and where to fix it, and leaves nothing half-sent.
  @MainActor func testLoggedOutClaudeSaysWhatToDo() async throws {
    let store = ScreenSettings(); store.value.general["chat.claude.connected"] = "1"
    let agent = MissingCLIAgent(provider: .claude, failure: .notLoggedIn)
    let controller = try ConversationController(store: store, makeAgent: { _, _ in agent })
    await controller.chooseProvider(.claude)
    XCTAssertTrue(controller.send("Invented question"))
    for _ in 0..<100 where controller.presentation.isRunning { await Task.yield() }
    XCTAssertEqual(controller.error, .claudeNotLoggedIn); XCTAssertTrue(controller.history.isEmpty)
    XCTAssertEqual(SettingsMessage(error: SubscriptionConnectionError.notLoggedIn), .claudeNotLoggedIn)
  }

  @MainActor func testSignedOutChatGPTDoesNotShowAClaudeLoginInstruction() async throws {
    let store = ScreenSettings(); store.value.subscriptionConnected = true
    let agent = MissingCLIAgent(provider: .codex, failure: .notLoggedIn)
    let controller = try ConversationController(store: store, makeAgent: { _, _ in agent })
    await controller.loadCatalog()
    XCTAssertEqual(controller.error, .notConnected)
    XCTAssertTrue(controller.catalog.isEmpty)
    XCTAssertFalse(controller.send("Invented question"))
  }
}
/// Its catalog is static for Claude, like the real adapter; everything that starts the CLI fails.
private final class MissingCLIAgent: ConversationAgent {
  let provider: ChatProvider
  let failure: ConversationError
  init(provider: ChatProvider, failure: ConversationError = .notInstalled) { self.provider = provider; self.failure = failure }
  func models() throws -> [ChatModel] {
    guard provider == .claude else { throw failure }
    return [.init(id: "invented", reasoningLevels: ["low"])]
  }
  func converse(messages: [ConversationMessage], selection: ChatSelection) -> AsyncThrowingStream<ConversationEvent, Error> {
    AsyncThrowingStream { [failure] in $0.finish(throwing: failure) }
  }
}
private final class ScreenAgent: ConversationAgent {
  let provider: ChatProvider
  let script: [ConversationEvent]?
  init(provider: ChatProvider = .codex, script: [ConversationEvent]? = nil) { self.provider = provider; self.script = script }
  var catalogCalls = 0
  var availableModels = [ChatModel(id: "invented", reasoningLevels: ["low", "high"])]
  var continuation: AsyncThrowingStream<ConversationEvent, Error>.Continuation?
  func models() throws -> [ChatModel] { catalogCalls += 1; return availableModels }
  func converse(messages: [ConversationMessage], selection: ChatSelection) -> AsyncThrowingStream<ConversationEvent, Error> {
    AsyncThrowingStream { stream in
      continuation = stream
      if let script { for event in script { stream.yield(event) }; stream.finish() }
    }
  }
  func emit(_ event: ConversationEvent) { continuation?.yield(event) }
}

private final class ScreenSettings: SettingsEditingStore {
  var value = StorageSettings()
  var fail = false
  var settingsIdentity: String { "invented-screen" }
  func settings() throws -> StorageSettings { if fail { throw ConversationError.unavailable }; return value }
  func patchSettings(_ patch: SettingsPatch) throws -> StorageSettings {
    if case .chatSelection(let selection) = patch {
      value.general["chat.selection"] = String(decoding: try JSONEncoder().encode(selection), as: UTF8.self)
    }
    return value
  }
  func saveSettings(_ value: StorageSettings) throws { self.value = value }
}

private final class EncodingScreenAgent: ConversationAgent {
  let provider: ChatProvider
  var turns = 0
  init(provider: ChatProvider) { self.provider = provider }
  func models() throws -> [ChatModel] { [.init(id: "invented", reasoningLevels: ["low"])] }
  func converse(messages: [ConversationMessage], selection: ChatSelection) -> AsyncThrowingStream<ConversationEvent, Error> {
    turns += 1
    return AsyncThrowingStream { stream in
      do {
        _ = try ConversationEncoding.transcript(messages, guidance: "Invented guidance")
        stream.yield(.text(String(repeating: "a", count: 65536))); stream.finish()
      } catch { stream.finish(throwing: error) }
    }
  }
}
