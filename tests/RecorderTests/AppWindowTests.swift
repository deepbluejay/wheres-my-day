import Core
import Darwin
import Foundation
import Outbound
import Storage
import XCTest
@testable import Shell

private final class WindowConnector: SubscriptionConnector {
  var connected = 0, cancelled = 0
  func connect() throws { connected += 1 }
  func cancel() { cancelled += 1 }
}
private final class WindowAgent: ConversationAgent {
  let provider: ChatProvider
  init(provider: ChatProvider = .codex) { self.provider = provider }
  var catalogs = 0
  var stream: AsyncThrowingStream<ConversationEvent, Error>.Continuation?
  func models() throws -> [ChatModel] { catalogs += 1; return [.init(id: "invented", reasoningLevels: ["low"])] }
  func converse(messages: [ConversationMessage], selection: ChatSelection) -> AsyncThrowingStream<ConversationEvent, Error> {
    AsyncThrowingStream { stream = $0 }
  }
}

final class AppWindowTests: XCTestCase {
  private func root() throws -> URL {
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ACTIVITYPROBE_TEST_ROOT"] ?? "/tmp/ap-window-tests")
      .appendingPathComponent("w-" + UUID().uuidString.prefix(8))
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return root
  }
  private func store(_ root: URL) throws -> ActivityStorage {
    try ActivityStorage(url: root.appendingPathComponent("invented.sqlite"), appDataDirectory: root, databaseScope: .directory(root))
  }
  // Ideal: opening the timeline/settings starts no chat work; panel toggles preserve one conversation.
  @MainActor func testLazyPanelNavigationAndPerWindowWidth() throws {
    let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
    let store = try store(root), agent = WindowAgent()
    let settings = try SettingsController.forDatabase(store: store, connector: WindowConnector(), ownBundleID: AppPaths.bundleID, claudeConnector: WindowConnector())
    var creations = 0
    let model = AppWindowModel(settings: settings, makeConversation: {
      creations += 1; return try ConversationController(store: store, makeAgent: { _, _ in agent })
    }, read: { throw ConversationError.unavailable })
    XCTAssertFalse(model.panelOpen); XCTAssertFalse(model.settingsVisible); XCTAssertNil(model.conversation)
    model.navigate(.settings(.retention)); XCTAssertEqual(creations, 0)
    XCTAssertTrue(model.settingsVisible); XCTAssertEqual(settings.section, .retention)
    model.back(); XCTAssertFalse(model.settingsVisible)
    model.toggleConversation(); let first = try XCTUnwrap(model.conversation)
    XCTAssertEqual(creations, 1); XCTAssertTrue(model.panelOpen); XCTAssertEqual(agent.catalogs, 0)
    model.choosePanelWidth(510, available: 1280)
    model.closePanel(); model.toggleConversation()
    XCTAssertTrue(model.conversation === first); XCTAssertEqual(creations, 1)
    let previousID = first.conversationID; first.newConversation()
    XCTAssertNotEqual(first.conversationID, previousID); XCTAssertTrue(first.history.isEmpty)
    XCTAssertEqual(model.layout.panelWidth(in: 1280), 510)
    XCTAssertEqual(model.layout.panelWidth(in: 800), 431)
    XCTAssertEqual(model.layout.panelWidth(in: 1280), 510)
    for notice in TimelineNoticeKind.allCases {
      model.route(notice); XCTAssertTrue(model.settingsVisible); XCTAssertEqual(settings.section, notice.settingsSection)
      XCTAssertTrue(model.panelOpen); XCTAssertTrue(model.conversation === first)
      model.back()
    }
    var other = AppWindowLayout(); XCTAssertEqual(other.panelWidth(in: 1280), 400)
    other.choosePanelWidth(-1, in: 1280); XCTAssertEqual(other.panelWidth(in: 1280), 360)
    model.close(); model.openConversation(); XCTAssertFalse(model.panelOpen); XCTAssertTrue(model.closed)
  }
  // Ideal: hiding chat preserves a running turn; closing the window cancels all pending approvals.
  @MainActor func testWindowCloseCancelsTurnAndPendingApprovals() async throws {
    let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
    let store = try store(root), agent = WindowAgent()
    try store.saveFixtureSettings(StorageSettings(subscriptionConnected: true))
    let settings = try SettingsController.forDatabase(store: store, connector: WindowConnector(), ownBundleID: AppPaths.bundleID, claudeConnector: WindowConnector())
    let model = AppWindowModel(settings: settings, makeConversation: {
      try ConversationController(store: store, makeAgent: { _, _ in agent })
    }, read: { throw ConversationError.unavailable })
    model.openConversation(); let conversation = try XCTUnwrap(model.conversation)
    await conversation.loadCatalog(); XCTAssertTrue(conversation.send("Invented question"))
    for _ in 0..<100 where agent.stream == nil { await Task.yield() }
    let request = ConversationApproval(method: "invented", details: "Invented action", choices: [.init(id: "deny", label: "decline")])
    agent.stream?.yield(.approval(request))
    for _ in 0..<100 where conversation.presentation.requests.isEmpty { await Task.yield() }
    XCTAssertEqual(request.outcome, .pending)
    model.closePanel(); XCTAssertTrue(conversation.presentation.isRunning)
    model.close(); XCTAssertFalse(conversation.presentation.isRunning); XCTAssertEqual(request.outcome, .cancelled)
    agent.stream?.yield(.text("Late invented output")); agent.stream?.finish()
    for _ in 0..<10 { await Task.yield() }
    XCTAssertFalse(conversation.presentation.rows.contains { $0.text == "Late invented output" })
  }
  // Ideal: every runtime gets exact shared paths and latest approvals; timeline reads are read-only/off-main.
  @MainActor func testCompositionOrderLazinessAndReadOnlyRefresh() async throws {
    let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
    let database = try store(root)
    let paths = AppPaths(userHome: root.appendingPathComponent("user"), appData: root,
      database: root.appendingPathComponent("invented.sqlite"), appBinary: root.appendingPathComponent("bin/ActivityProbe"),
      queryHelper: root.appendingPathComponent("bin/ActivityQueryServer"))
    var factories = AppFactories(); let original = factories
    var events: [String] = [], configurations: [ConversationConfiguration] = []
    factories.claudeConnector = { received, _ in
      XCTAssertEqual(received, paths); events.append("connectors"); return WindowConnector()
    }
    factories.queryStorage = {
      XCTAssertFalse(Thread.isMainThread); XCTAssertEqual($0, paths)
      let store = try original.queryStorage($0)
      XCTAssertThrowsError(try store.patchSettings(.chatSkipApprovals(true)))
      return store
    }
    let conversationTokens = ChatGPTSession(store: InMemoryChatGPTCredentialStore(), lock: ChatGPTCredentialLock(file: nil), openBrowser: { _ in false })
    factories.chatGPTTokens = { received in XCTAssertEqual(received, paths); return conversationTokens }
    factories.conversationAgent = { provider, _, tokens in
      XCTAssertTrue(tokens === conversationTokens); return WindowAgent(provider: provider)
    }
    // A never signed-in account in memory: the timeline reads its status, never a Keychain.
    factories.chatGPT = { _ in ChatGPTSession(store: InMemoryChatGPTCredentialStore(), lock: ChatGPTCredentialLock(file: nil), openBrowser: { _ in false }) }
    factories.conversation = {
      events.append("configuration")
      let value = original.conversation($0, $1, $2); configurations.append(value); return value
    }
    let (model, _) = try AppComposition(paths: paths, factories: factories).windowModel(
      codex: .fixed(root.appendingPathComponent("absent-codex")), claude: .fixed(root.appendingPathComponent("absent-claude")), health: { TimelineHealth() })
    XCTAssertEqual(events, ["connectors"]); XCTAssertNil(model.conversation)
    await model.refresh(); XCTAssertNotNil(model.snapshot); XCTAssertFalse(model.readFailed)
    let start = try XCTUnwrap(model.snapshot).day.range.start
    _ = try database.appendModelCall(ModelCall(ts: start + 60, range: TimeRange(start, start + 60), model: "invented", succeeded: false))
    await model.refresh()
    XCTAssertTrue(model.snapshot?.day.notices.contains { $0.kind == .summaryFailure } == true)
    // Ideal: a successful retry clears its notice, while another failed range still appears.
    _ = try database.appendModelCall(ModelCall(ts: start + 120, range: TimeRange(start, start + 60), model: "invented", succeeded: true))
    await model.refresh()
    XCTAssertNotNil(model.snapshot); XCTAssertFalse(model.readFailed)
    XCTAssertFalse(model.snapshot?.day.notices.contains { $0.kind == .summaryFailure } == true)
    let unresolved = TimeRange(start + 60, start + 120)
    _ = try database.appendModelCall(ModelCall(ts: start + 180, range: unresolved, model: "invented", succeeded: false))
    await model.refresh()
    XCTAssertEqual(model.snapshot?.health.summary?.failedRanges, [unresolved])
    XCTAssertTrue(model.snapshot?.day.notices.contains { $0.kind == .summaryFailure } == true)
    // An unrelated day's failure never follows the selection into an empty past day.
    model.stepDay(-1); await model.refresh()
    XCTAssertEqual(model.snapshot?.health.summary?.failedRanges, [])
    XCTAssertFalse(model.snapshot?.day.notices.contains { $0.kind == .summaryFailure } == true)
    model.showToday(); await model.refresh()
    XCTAssertEqual(model.snapshot?.health.summary?.failedRanges, [unresolved])
    XCTAssertEqual(model.snapshot?.health.chatGPT, .notConnected)
    XCTAssertFalse(model.snapshot?.day.notices.contains { $0.kind == .summaryPaused } == true)
    model.openConversation(); XCTAssertEqual(events, ["connectors"])
    // Disconnected providers cannot start a catalog or runtime.
    await model.conversation?.loadCatalog(); XCTAssertTrue(configurations.isEmpty)
    try database.saveFixtureSettings(StorageSettings(subscriptionConnected: true))
    // Consent on without a ChatGPT sign-in: the timeline says summaries are paused.
    await model.refresh()
    XCTAssertTrue(model.snapshot?.day.notices.contains { $0.kind == .summaryPaused } == true)
    _ = try database.patchSettings(.chatSkipApprovals(true))
    await model.conversation?.loadCatalog()
    XCTAssertEqual(configurations.count, 1)
    XCTAssertTrue(try XCTUnwrap(configurations.first).skipApprovals)
    XCTAssertEqual(configurations.first?.command.resolve()?.executable, root.appendingPathComponent("absent-codex"))
    _ = try database.patchSettings(.chatSkipApprovals(false))
    XCTAssertTrue(try XCTUnwrap(model.conversation).send("Invented question"))
    XCTAssertFalse(try XCTUnwrap(configurations.last).skipApprovals)
    model.conversation?.stop()
    let pending = try database.patchSettings(.beginClaudeConnection)
    _ = try database.patchSettings(.completeClaudeConnection(generation: pending.claudeConnectionGeneration))
    await model.conversation?.chooseProvider(.claude)
    XCTAssertEqual(configurations.last?.command.resolve()?.executable, root.appendingPathComponent("absent-claude"))
    // Configuration factories themselves remain pure for both providers and approval modes.
    let composition = AppComposition(paths: paths, factories: factories)
    for skip in [false, true] {
      for executable in ["absent-codex", "absent-claude"] {
        let value = composition.conversation(command: .fixed(root.appendingPathComponent(executable)), skipApprovals: skip)
        XCTAssertEqual(value.appDataDirectory, paths.appData); XCTAssertEqual(value.database, paths.database)
        XCTAssertEqual(value.toolServer, paths.queryHelper); XCTAssertEqual(value.appBinary, paths.appBinary)
        XCTAssertEqual(value.skipApprovals, skip); XCTAssertEqual(value.codexHome, paths.codexHome); XCTAssertEqual(value.userHome, paths.userHome)
      }
    }
    model.close()
    XCTAssertFalse(FileManager.default.fileExists(atPath: paths.codexHome.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: paths.appData.appendingPathComponent("claude").path))
  }
  // Ideal: notice cleanup never undoes a newer privacy/consent edit.
  func testNoticeResolutionPatchesLatestSettings() throws {
    let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
    let first = try store(root), second = try store(root)
    var initial = StorageSettings(); TimelineNotices.deferNotice(.screenRecording, in: &initial)
    TimelineNotices.deferNotice(.summaryPreparation, in: &initial)
    try first.saveSettings(initial)
    _ = try second.patchSettings(.edit(.recording(false), ownBundleID: AppPaths.bundleID, now: 100))
    let result = try first.patchSettings(.resolveTimelineNotices(TimelineHealth()))
    XCTAssertFalse(result.recordingEnabled)
    XCTAssertEqual(result.general[TimelineNotices.deferredSettingKey], "[\"summaryPreparation\"]")
  }
  func testExplicitWindowTargetsAndLanguageResolution() {
    for (arguments, target) in [([], AppWindowTarget.timeline), (["timeline"], .timeline),
      (["settings"], .settings(.recording)), (["settings", "security"], .settings(.security)), (["agent-window"], .conversation)] {
      XCTAssertEqual(AppWindowTarget(arguments: arguments), target); XCTAssertEqual(AppWindowTarget(line: target.line), target)
    }
    for arguments in [["collect"], ["status"], ["agent-window", "extra"], ["settings", "extra"]] { XCTAssertNil(AppWindowTarget(arguments: arguments)) }
    XCTAssertNil(AppWindowTarget(line: "")); XCTAssertNil(AppWindowTarget(line: "unknown"))
    XCTAssertEqual(AppWindowStrings.preferredLanguage(["zh-Hant-TW"]), "zh-Hant")
    XCTAssertEqual(AppWindowStrings.preferredLanguage(["de-DE"]), "de")
  }
  // Ideal: a second open reaches the existing owner; other databases have independent lifetime locks.
  func testPerDatabaseChannelAndConcurrentOpens() throws {
    let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
    let socket = root.appendingPathComponent("w.sock"), queue = DispatchQueue(label: "window-test")
    let owner = AppWindowChannel(socket: socket)
    var received: [String] = []
    XCTAssertEqual(owner.claim(sending: "timeline", on: queue) { received.append($0) }, .owner)
    XCTAssertEqual(fcntl(owner.listener, F_GETFD) & FD_CLOEXEC, FD_CLOEXEC)
    for target in [AppWindowTarget.timeline, .conversation, .settings(.security)] {
      XCTAssertEqual(AppWindowChannel(socket: socket).claim(sending: target.line, on: queue) { _ in XCTFail() }, .delivered)
    }
    XCTAssertEqual(queue.sync { received }, ["timeline", "agent-window", "settings security"])
    let other = AppWindowChannel(socket: root.appendingPathComponent("other.sock"))
    XCTAssertEqual(other.claim(sending: "timeline", on: queue) { _ in }, .owner)
    other.close(); owner.close()
    let next = AppWindowChannel(socket: socket)
    XCTAssertEqual(next.claim(sending: "timeline", on: queue) { _ in }, .owner); next.close()
    let group = DispatchGroup(), lock = NSLock()
    var claims: [AppWindowChannel.Claim] = [], channels: [AppWindowChannel] = []
    for _ in 0..<8 {
      group.enter(); DispatchQueue.global().async {
        let channel = AppWindowChannel(socket: socket)
        let claim = channel.claim(sending: "timeline", on: queue) { _ in }
        lock.lock(); claims.append(claim); channels.append(channel); lock.unlock(); group.leave()
      }
    }
    XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
    XCTAssertEqual(claims.filter { $0 == .owner }.count, 1)
    XCTAssertEqual(claims.filter { $0 == .delivered }.count, 7)
    channels.forEach { $0.close() }
    XCTAssertFalse(FileManager.default.fileExists(atPath: socket.path))
  }
  // Ideal: a second launch that only forwards to the running owner never asks for the application.
  @MainActor func testForwardingLaunchNeverAsksForTheApplication() throws {
    let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
    let data = root.appendingPathComponent("data")
    let paths = AppPaths(userHome: root, appData: data, database: data.appendingPathComponent("invented.sqlite"),
      appBinary: root.appendingPathComponent("ActivityProbe"), queryHelper: root.appendingPathComponent("ActivityQueryServer"),
      databaseScope: .directory(root))
    let queue = DispatchQueue(label: "window-forward-test")
    let owner = AppWindowChannel(socket: try AppWindowChannel.prepareSocket(paths: paths))
    var received: [String] = []
    XCTAssertEqual(owner.claim(sending: "menu-bar", on: queue) { received.append($0) }, .owner)
    defer { owner.close() }
    let unavailable = AgentExecutable.fixed(root.appendingPathComponent("unavailable"))
    XCTAssertEqual(AppWindowEntry.run(paths: paths, target: .settings(.security), codex: unavailable, claude: unavailable,
      application: { XCTFail("A forwarding launch must not ask for the application"); return nil }), 0)
    XCTAssertEqual(queue.sync { received }, ["settings security"])
  }
  // Ideal: aliases for the same DB reach one owner, and distinct DBs cannot focus each other.
  func testDatabaseSocketIdentityResolvesAliases() throws {
    let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
    let database = root.appendingPathComponent("invented.sqlite")
    try Data().write(to: database)
    let alias = root.appendingPathComponent("alias.sqlite")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: database)
    func paths(_ database: URL) -> AppPaths {
      AppPaths(userHome: root, appData: root, database: database,
        appBinary: root.appendingPathComponent("ActivityProbe"), queryHelper: root.appendingPathComponent("ActivityQueryServer"))
    }
    XCTAssertEqual(try AppWindowChannel.socket(paths: paths(database)), try AppWindowChannel.socket(paths: paths(alias)))
    let other = paths(root.appendingPathComponent("other.sqlite"))
    XCTAssertNotEqual(try AppWindowChannel.socket(paths: paths(database)), try AppWindowChannel.socket(paths: other))
    let alternate = AppPaths(userHome: root, appData: root.appendingPathComponent(String(repeating: "가", count: 80)), database: database,
      appBinary: root.appendingPathComponent("ActivityProbe"), queryHelper: root.appendingPathComponent("ActivityQueryServer"))
    XCTAssertEqual(try AppWindowChannel.socket(paths: paths(database)), try AppWindowChannel.socket(paths: alternate))
    XCTAssertLessThan(try AppWindowChannel.socket(paths: alternate).path.utf8.count, 104)
  }
  // Ideal: the first open and later equivalent spellings retain exactly one owner.
  func testDatabaseChannelStableAcrossCreationAndEquivalentSpellings() throws {
    let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
    let parent = root.appendingPathComponent("CaseCaf\u{e9}")
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    let sensitive = try XCTUnwrap(parent.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames)
    let direct = parent.appendingPathComponent("Fut\u{e9}re.sqlite")
    let unicode = root.appendingPathComponent("CaseCafe\u{301}/Fute\u{301}re.sqlite")
    let alternate = root.appendingPathComponent("cASEcAFE\u{301}/fUTE\u{301}RE.SQLITE")
    func paths(_ database: URL) -> AppPaths {
      AppPaths(userHome: root, appData: parent, database: database,
        appBinary: root.appendingPathComponent("ActivityProbe"), queryHelper: root.appendingPathComponent("ActivityQueryServer"),
        databaseScope: .directory(root))
    }
    let spellings = sensitive ? [direct, unicode] : [direct, unicode, alternate]
    let before = try spellings.map { try AppWindowChannel.prepareSocket(paths: paths($0)) }
    XCTAssertEqual(Set(before).count, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: direct.path))
    let store = try ActivityStorage(url: spellings.last!, appDataDirectory: parent, databaseScope: .directory(root))
    let after = try spellings.map { try AppWindowChannel.prepareSocket(paths: paths($0)) }
    XCTAssertEqual(before, after)
    XCTAssertEqual(store.settingsIdentity, try FileLocation.key(direct))
    for database in spellings {
      let other = try ActivityStorage(url: database, appDataDirectory: parent, databaseScope: .directory(root))
      XCTAssertEqual(store.settingsIdentity, other.settingsIdentity)
      XCTAssertEqual(try store.previewDeletion(in: TimeRange(100, 200)).confirmation,
        try other.previewDeletion(in: TimeRange(100, 200)).confirmation)
    }
    // Use the actual computed endpoint names, but keep all socket files in the fixture.
    let queue = DispatchQueue(label: "window-identity-delivery"), group = DispatchGroup(), lock = NSLock()
    var claims: [AppWindowChannel.Claim] = [], channels: [AppWindowChannel] = []
    for endpoint in [before[0], after.last!] {
      group.enter(); DispatchQueue.global().async {
        let channel = AppWindowChannel(socket: root.appendingPathComponent(endpoint.lastPathComponent))
        let claim = channel.claim(sending: "timeline", on: queue) { _ in }
        lock.lock(); claims.append(claim); channels.append(channel); lock.unlock(); group.leave()
      }
    }
    XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
    XCTAssertEqual(claims.filter { $0 == .owner }.count, 1)
    XCTAssertEqual(claims.filter { $0 == .delivered }.count, 1)
    let independent = try AppWindowChannel.socket(paths: paths(parent.appendingPathComponent("different.sqlite")))
    XCTAssertNotEqual(independent, before[0])
    let other = AppWindowChannel(socket: root.appendingPathComponent(independent.lastPathComponent))
    XCTAssertEqual(other.claim(sending: "timeline", on: queue) { _ in }, .owner)
    other.close(); channels.forEach { $0.close() }
  }

  func testWindowChannelPreflightChecksAllPathsBeforeCreatingParent() throws {
    let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
    let protected = root.appendingPathComponent("Protected")
    try FileManager.default.createDirectory(at: protected, withIntermediateDirectories: true)
    func paths(_ database: URL, _ appData: URL) -> AppPaths {
      AppPaths(userHome: root, appData: appData, database: database,
        appBinary: root.appendingPathComponent("ActivityProbe"), queryHelper: root.appendingPathComponent("ActivityQueryServer"),
        databaseScope: .directory(root, excluding: [protected]))
    }
    let refused = protected.appendingPathComponent("missing/child.sqlite")
    XCTAssertThrowsError(try AppWindowChannel.prepareSocket(paths: paths(refused, root)))
    let safe = root.appendingPathComponent("safe/missing/child.sqlite")
    XCTAssertThrowsError(try AppWindowChannel.prepareSocket(paths: paths(safe, protected)))
    XCTAssertFalse(FileManager.default.fileExists(atPath: safe.deletingLastPathComponent().path))
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: protected.path), [])
    XCTAssertThrowsError(try AppWindowChannel.socket(paths: paths(safe, root)))
    let endpoint = try AppWindowChannel.prepareSocket(paths: paths(safe, root))
    XCTAssertEqual(endpoint, try AppWindowChannel.socket(paths: paths(safe, root)))
    XCTAssertTrue(FileManager.default.fileExists(atPath: safe.deletingLastPathComponent().path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: safe.path))
  }

  // Ideal: an owner with a busy UI queue is never replaced by a second window.
  func testOpenWaitsForLivingOwner() throws {
    let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
    let queue = DispatchQueue(label: "window-delivery"), busy = DispatchSemaphore(value: 0)
    let socket = root.appendingPathComponent("w.sock")
    let owner = AppWindowChannel(socket: socket)
    XCTAssertEqual(owner.claim(sending: "timeline", on: queue) { _ in }, .owner)
    queue.async { busy.wait() }
    let result = WindowChannelResult()
    DispatchQueue.global().async {
      let second = AppWindowChannel(socket: socket)
      result.value = second.claim(sending: "settings", on: queue) { _ in }
      result.done.signal()
    }
    XCTAssertEqual(result.done.wait(timeout: .now() + 0.05), .timedOut)
    busy.signal()
    XCTAssertEqual(result.done.wait(timeout: .now() + 5), .success)
    XCTAssertEqual(result.value, .delivered)
    owner.close()
  }

}

private final class WindowChannelResult {
  let done = DispatchSemaphore(value: 0)
  var value: AppWindowChannel.Claim?
}

extension AppWindowTests {
  @MainActor func testUnavailableHealthAndStatusCacheSurviveWindowReopening() async throws {
    final class Account: ChatGPTAccount {
      var reads = 0
      func status() -> ChatGPTConnectionStatus { .connected }
      func overview() -> ChatGPTAccountOverview { reads += 1; return ChatGPTAccountOverview(status: .connected, registered: true) }
      func connect() throws {}
      func connectDifferentAccount() throws {}
      func revokeUnusedGrants() -> Bool { true }
      func cancel() {}
      func acknowledgePlanWelcome() {}
      func signOut() -> Bool { true }
    }
    let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
    let database = try store(root)
    try database.saveFixtureSettings(StorageSettings(subscriptionConnected: true))
    let paths = AppPaths(userHome: root.appendingPathComponent("user"), appData: root,
      database: root.appendingPathComponent("invented.sqlite"), appBinary: root.appendingPathComponent("bin/ActivityProbe"),
      queryHelper: root.appendingPathComponent("bin/ActivityQueryServer"))
    let account = Account()
    var factories = AppFactories()
    factories.claudeConnector = { _, _ in WindowConnector() }
    factories.chatGPT = { _ in ChatGPTSession(store: InMemoryChatGPTCredentialStore(), lock: ChatGPTCredentialLock(file: nil), openBrowser: { _ in false }) }
    let composition = AppComposition(paths: paths, factories: factories)
    var now: TimeInterval = 100
    let reader = ChatGPTStatusReader(account: account, clock: { now })
    func make() throws -> AppWindowModel {
      let pair = try composition.windowModel(codex: .fixed(root.appendingPathComponent("absent-a")),
        claude: .fixed(root.appendingPathComponent("absent-b")), health: { TimelineHealth() }, statusReader: reader)
      return pair.0
    }
    let first = try make(); await first.refresh(); XCTAssertEqual(account.reads, 1)
    XCTAssertFalse(first.snapshot?.day.notices.contains { $0.kind == .summaryPaused } == true)
    first.close()
    // The recorder publishes only a time/reason; window health and settings consume that same value.
    let until = Date().timeIntervalSince1970 + 300
    try database.saveSummaryUnavailableUntil(until)
    let second = try make(); await second.refresh()
    XCTAssertEqual(account.reads, 1)
    XCTAssertEqual(second.snapshot?.health.summary?.serviceUnavailableUntil, until)
    XCTAssertTrue(second.snapshot?.day.notices.contains { $0.kind == .summaryPaused } == true)
    XCTAssertTrue(second.settings.health.summary?.planUsePaused == true)
    let row = ChatGPTRow(model: second.settings.model, overview: account.overview(), isConnecting: false)
    XCTAssertTrue(row.notes.contains(.serviceUnavailableNote)); XCTAssertTrue(row.showsProblem)
    XCTAssertFalse(row.offersContinue)
    let before = account.reads
    now += 30; await second.refresh(); XCTAssertEqual(account.reads, before + 1)
    XCTAssertTrue(second.snapshot?.day.notices.contains { $0.kind == .summaryPaused } == true)
    try database.saveSummaryUnavailableUntil(Date().timeIntervalSince1970 - 1)
    await second.refresh()
    XCTAssertFalse(second.snapshot?.day.notices.contains { $0.kind == .summaryPaused } == true)
    XCTAssertNil(second.snapshot?.health.summary?.serviceUnavailableUntil)
    second.close()
  }
}


extension AppWindowTests {
  @MainActor func testDaySelectionSurvivesRefreshAndTodayFollowsBoundary() async throws {
    let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
    let database = try store(root)
    let settings = try SettingsController.forDatabase(store: database, connector: WindowConnector(),
      ownBundleID: AppPaths.bundleID, claudeConnector: WindowConnector())
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    var now = 3 * 86400 + 3 * 3600
    var selectedReads: [Date?] = []
    let model = AppWindowModel(settings: settings, makeConversation: { throw ConversationError.unavailable }, readDay: { selected in
      selectedReads.append(selected)
      let range = try selected.map { try TimelineDay.range(on: $0, dayStartHour: 4, calendar: calendar) }
        ?? TimelineDay.range(containing: now, dayStartHour: 4, calendar: calendar)
      let day = TimelineDay.make(range: range, minutes: [:], intervals: [], now: now, calendar: calendar)
      return AppWindowSnapshot(day: day, health: TimelineHealth(), dayStartHour: 4, now: now)
    }, readMonth: { _ in [] })
    await model.refresh()
    XCTAssertEqual(model.snapshot?.day.range.start, 2 * 86400 + 4 * 3600)
    model.stepDay(-1, calendar: calendar); await model.refresh()
    XCTAssertEqual(model.snapshot?.day.range.start, 86400 + 4 * 3600)
    let chosen = model.selectedDate
    now += 2 * 3600; await model.refresh()
    XCTAssertEqual(model.selectedDate, chosen)
    XCTAssertEqual(model.snapshot?.day.range.start, 86400 + 4 * 3600)
    model.stepDay(1, calendar: calendar); await model.refresh()
    XCTAssertEqual(model.snapshot?.day.range.start, 2 * 86400 + 4 * 3600)
    model.showToday(); await model.refresh()
    XCTAssertNil(model.selectedDate); XCTAssertEqual(model.snapshot?.day.range.start, 3 * 86400 + 4 * 3600)
    now += 86400; await model.refresh()
    XCTAssertEqual(model.snapshot?.day.range.start, 4 * 86400 + 4 * 3600)
    model.stepDay(1, calendar: calendar); await model.refresh()
    XCTAssertNil(model.selectedDate)
    XCTAssertTrue(selectedReads.contains { $0 != nil })
    let todayStart = try XCTUnwrap(model.snapshot).day.range.start
    let oldDate = Date(timeIntervalSince1970: Double(todayStart - 3 * 86400))
    model.chooseDay(oldDate, calendar: calendar); await model.refresh()
    // Repeated keys before a background read completes must stop at today, never wrap back.
    for _ in 0..<4 { model.stepDay(1, calendar: calendar) }
    await model.refresh()
    XCTAssertEqual(model.snapshot?.day.range.start, todayStart); XCTAssertNil(model.selectedDate)
    model.chooseDay(oldDate, calendar: calendar); await model.refresh()
    model.showToday(); model.stepDay(-1, calendar: calendar); await model.refresh()
    XCTAssertEqual(model.snapshot?.day.range.start, todayStart - 86400)
    model.close()
  }
}
