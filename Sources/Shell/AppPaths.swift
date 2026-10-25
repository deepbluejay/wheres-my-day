import Core
import Foundation
import Inbound
import Outbound
import Storage

/// Computed at the entry. A database override never changes the app-owned directories.
public struct AppPaths: Equatable {
  public static let bundleID = "dev.local.ActivityProbe"
  public let userHome: URL
  public let appData: URL
  public let database: URL
  public let databaseScope: DatabaseOpenScope
  public let appBinary: URL
  public let queryHelper: URL
  public var codexHome: URL { AppDataPaths.summaryCodexHome(in: appData) }
  public var prompts: URL { appData.appendingPathComponent("summary-prompts") }
  public var summaryLog: URL { appData.appendingPathComponent("summary-attempts.jsonl") }
  public init(userHome: URL, appData: URL, database: URL, appBinary: URL, queryHelper: URL, databaseScope: DatabaseOpenScope? = nil) {
    precondition(TestPathGuard.permits(appData) && TestPathGuard.permits(database), "Tests must inject invented paths")
    self.databaseScope = databaseScope ?? .directory(database.deletingLastPathComponent())
    self.userHome = userHome; self.appData = appData; self.database = database
    self.appBinary = appBinary; self.queryHelper = queryHelper
  }
  public static func resolve(userHome: URL, environment: [String: String], appBinary: URL) throws -> AppPaths {
    try FileLocation.validate(userHome)
    if let override = environment["ACTIVITYPROBE_DB"] { try FileLocation.validate(override) }
    let data = AppDataPaths.directory(in: userHome)
    let database = environment["ACTIVITYPROBE_DB"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
      ?? data.appendingPathComponent("activity.sqlite")
    return AppPaths(userHome: userHome, appData: data, database: database, appBinary: appBinary,
      queryHelper: appBinary.deletingLastPathComponent().appendingPathComponent("ActivityQueryServer"))
  }
}

/// Every factory receives the same explicit context, including deferred window composition.
public struct AppFactories {
  public var storage: (AppPaths, ActivityStorage.Role, RecorderDatabaseLock?) throws -> ActivityStorage = {
    try ActivityStorage(url: $0.database, appDataDirectory: $0.appData, role: $1, databaseScope: $0.databaseScope, recorderLock: $2)
  }
  /// Summaries on the ChatGPT plan, with the token port the recorder shares with the window's sign-in.
  public var summary: (AppPaths, ChatGPTAccessTokens) -> SummaryCaller = {
    ChatGPTSummaryCaller(tokens: $1, attemptLog: $0.summaryLog, legacyPrompts: $0.prompts)
  }
  /// The recorder's token port: the same Keychain items and lock as the window, without a browser.
  public var chatGPTTokens: (AppPaths) -> ChatGPTAccessTokens = { ChatGPTSignInHost.tokens(paths: $0) }
  public var claudeConnector: (AppPaths, AgentExecutable) -> SubscriptionConnector = {
    ClaudeSubscriptionConnector(command: $1, userHome: $0.userHome, loginScript: ClaudeLoginScript(appData: $0.appData),
      openTerminal: TerminalLogin.open)
  }
  /// The Codex row's sign-in and the token port summaries and conversations use.
  public var chatGPT: (AppPaths) -> ChatGPTSession = { ChatGPTSignInHost.session(paths: $0) }
  public var logs: (AppPaths, ActivityStorage, AgentLogProcessSource) -> [AgentLogTask] = {
    RecorderConnections.makeLogTasks(database: $1, appDataDirectory: $0.appData,
      userHome: $0.userHome.path, processes: $2, summaryCodexHome: $0.codexHome)
  }
  public var conversation: (AppPaths, AgentExecutable, Bool) -> ConversationConfiguration = {
    ConversationConfiguration(command: $1, userHome: $0.userHome, toolServer: $0.queryHelper,
      database: $0.database, appDataDirectory: $0.appData, appBinary: $0.appBinary, skipApprovals: $2)
  }
  public var conversationAgent: (ChatProvider, ConversationConfiguration, ChatGPTAccessTokens) -> ConversationAgent = { provider, configuration, tokens in
    switch provider {
    case .codex: return CodexConversationAgent(configuration: configuration, tokens: tokens)
    case .claude: return ClaudeConversationAgent(configuration: configuration)
    }
  }
  public var queryStorage: (AppPaths) throws -> ActivityStorage = {
    try ActivityStorage(url: $0.database, appDataDirectory: $0.appData, readOnly: true, databaseScope: $0.databaseScope)
  }
  public init() {}
}

public struct AppComposition {
  public let paths: AppPaths
  public var factories: AppFactories
  private let includesPassiveLogs: Bool
  public init(paths: AppPaths, factories: AppFactories = AppFactories(), includesPassiveLogs: Bool = true) {
    self.paths = paths; self.factories = factories; self.includesPassiveLogs = includesPassiveLogs
  }
  @MainActor public func settings(claude: AgentExecutable) throws -> SettingsController {
    let store = try factories.storage(paths, .client, nil)
    let claudeConnector = factories.claudeConnector(paths, claude)
    let chatGPT = factories.chatGPT(paths)
    return try SettingsController.forDatabase(store: store, connector: chatGPT,
      ownBundleID: AppPaths.bundleID, claudeConnector: claudeConnector, chatGPT: chatGPT)
  }
  public func conversation(command: AgentExecutable, skipApprovals: Bool) -> ConversationConfiguration {
    factories.conversation(paths, command, skipApprovals)
  }
  public func recordingEnabledAtStartup() throws -> Bool {
    try factories.storage(paths, .client, nil).settings().recordingEnabled
  }
  public func queryStorage() throws -> ActivityStorage { try factories.queryStorage(paths) }
  public func recorder(processes: AgentLogProcessSource, fileVault: FileVaultStatusSource,
    from: Int, dayStart: @escaping (Int) -> Int, locale: @escaping () -> String,
    recorderLock: RecorderDatabaseLock? = nil) throws -> RecorderConnections {
    let recorder = try factories.storage(paths, .recorder, recorderLock)
    let client = try factories.storage(paths, .client, nil)
    let tokens = factories.chatGPTTokens(paths)
    let logTasks = includesPassiveLogs ? factories.logs(paths, client, processes) : []
    for task in logTasks { task.planUseSignedIn = { tokens.signedInForPlanUse } }
    let connections = RecorderConnections(recorder: recorder, client: client, logTasks: logTasks, fileVault: fileVault)
    try connections.configureSummary(caller: factories.summary(paths, tokens), from: from, dayStart: dayStart, locale: locale)
    return connections
  }
}

public struct NoAgentLogProcesses: AgentLogProcessSource {
  public init() {}
  public func processes() throws -> [AgentLogProcess] { [] }
  public func homeVariable(_ name: String, processID: Int32) throws -> String? { nil }
}
