import Foundation

public enum SettingsSection: String, CaseIterable { case recording, exclusions, retention, dayStart, subscription, claude, conversation, permissions, security }
public extension ChatProvider {
  var settingsSection: SettingsSection { self == .claude ? .claude : .subscription }
}
public extension TimelineNoticeKind {
  var settingsSection: SettingsSection {
    switch self {
    case .accessibility, .inputMonitoring, .screenRecording: return .permissions
    // Summaries use Claude, so their notices open the Claude section.
    case .subscription, .summaryFailure, .summaryPreparation, .summaryPaused: return .claude
    case .fileVaultOff, .fileVaultUnknown, .backupExclusion: return .security
    }
  }
}
public extension StorageSettings {
  var dayStartHour: Int {
    general["dayStartHour"].flatMap(Int.init).flatMap { (0...23).contains($0) ? $0 : nil } ?? TimelineDay.defaultDayStartHour
  }
}
public enum SettingsValidationError: String, Error, CaseIterable {
  case retention, retentionConflict, connectionSuperseded, dayStart, duplicateApp, ownApp, appIdentity, pause
}
public enum SettingsEdit {
  case recording(Bool), pause(Int?), retention(screen: Int, prompt: Int, expected: SettingsRetention? = nil), dayStart(Int)
  case addApp(String), removeApp(String)
  public var section: SettingsSection {
    switch self {
    case .recording, .pause: return .recording
    case .addApp, .removeApp: return .exclusions
    case .retention: return .retention
    case .dayStart: return .dayStart
    }
  }
}
public enum SettingsValidation {
  public static let retentionDays = 1...36500
  public static func validate(_ settings: StorageSettings) throws {
    guard retentionDays.contains(settings.screenRetentionDays), retentionDays.contains(settings.promptRetentionDays) else {
      throw SettingsValidationError.retention
    }
    if let hour = settings.general["dayStartHour"] {
      guard let value = Int(hour), (0...23).contains(value) else { throw SettingsValidationError.dayStart }
    }
    let apps = settings.excludedApps.map { $0.lowercased() }
    guard Set(apps).count == apps.count else { throw SettingsValidationError.duplicateApp }
  }
  public static func validIdentity(_ value: String) -> Bool {
    !value.isEmpty && value.unicodeScalars.allSatisfy {
      CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_").contains($0)
    }
  }
}
public enum SettingsSubscriptionState { case notConnected, connected, problem }
public struct SettingsExclusion: Equatable, Identifiable {
  public let id: String
  public let alwaysExcluded: Bool
}
/// Values only. Reading storage and performing actions belong to the shell.
public struct SettingsViewModel {
  public let settings: StorageSettings
  public let health: TimelineHealth
  public let ownBundleID: String
  public let now: Int
  public init(settings: StorageSettings, health: TimelineHealth, ownBundleID: String, now: Int) {
    self.settings = settings; self.health = health; self.ownBundleID = ownBundleID.lowercased(); self.now = now
  }
  public var nextPauseEnd: Int { isPaused ? settings.pausedUntil! : now + 3600 }
  public var isPaused: Bool { (settings.pausedUntil ?? Int.min) > now }
  public var dayStartHour: Int {
    settings.dayStartHour
  }
  /// Summaries use Claude, so their problems show on the Claude row.
  public var claudeConnection: SettingsSubscriptionState {
    guard settings.claudeConnected else { return .notConnected }
    if let summary = health.summary,
      !summary.subscriptionConnected || summary.localPreparationFailed || summary.planUsePaused || !summary.failedRanges.isEmpty { return .problem }
    return .connected
  }
  public var chatSkipApprovals: Bool { settings.chatSkipApprovals }
  /// ChatGPT use, for Codex conversations only.
  public var subscription: SettingsSubscriptionState { settings.subscriptionConnected ? .connected : .notConnected }
  public var exclusions: [SettingsExclusion] {
    let ids = Set(settings.excludedApps.map { $0.lowercased() }).subtracting([ownBundleID]).sorted()
    return [SettingsExclusion(id: ownBundleID, alwaysExcluded: true)] + ids.map { SettingsExclusion(id: $0, alwaysExcluded: false) }
  }
  public func applying(_ edit: SettingsEdit) throws -> StorageSettings {
    var result = settings
    switch edit {
    case .recording(let enabled): result.recordingEnabled = enabled
    case .pause(let end):
      if let end, end <= now { throw SettingsValidationError.pause }
      result.pausedUntil = end
    case .retention(let screen, let prompt, let expected):
      if let expected, expected != SettingsRetention(settings) { throw SettingsValidationError.retentionConflict }
      result.screenRetentionDays = screen; result.promptRetentionDays = prompt
    case .dayStart(let hour): result.general["dayStartHour"] = String(hour)
    case .addApp(let raw):
      let id = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      guard SettingsValidation.validIdentity(id) else { throw SettingsValidationError.appIdentity }
      guard id != ownBundleID else { throw SettingsValidationError.ownApp }
      guard !result.excludesApplication(id) else { throw SettingsValidationError.duplicateApp }
      result.excludedApps.append(id)
    case .removeApp(let id):
      guard id.lowercased() != ownBundleID else { throw SettingsValidationError.ownApp }
      result.excludedApps.removeAll { $0.lowercased() == id.lowercased() }
      result.excludedAppPrivacyIdentities.removeValue(forKey: id.lowercased())
    }
    try SettingsValidation.validate(result)
    result.excludedApps.sort()
    return result
  }
}
public struct SettingsRetention: Equatable {
  public let screen: Int
  public let prompt: Int
  public init(_ settings: StorageSettings) { screen = settings.screenRetentionDays; prompt = settings.promptRetentionDays }
}
public enum SettingsPatch {
  case edit(SettingsEdit, ownBundleID: String, now: Int)
  case chatSelection(ChatSelection), chatSkipApprovals(Bool)
  case resolveTimelineNotices(TimelineHealth)
  case beginClaudeConnection, completeClaudeConnection(generation: String), disconnectClaude
  case beginConnection, completeConnection(generation: String), disconnect
}
public enum SubscriptionConnectionError: Error, Equatable { case localPreparation, failed, cancelled, statusTimeout, notInstalled, notLoggedIn, terminalFailed }
public protocol SubscriptionConnector {
  /// Returns only after sign-in or the provider's login check succeeds. Never exposes credentials.
  func connect() throws
  func cancel()
}
/// What the person's own Claude Code reports about its login.
public enum ClaudeLoginState: String, Equatable { case loggedIn, loggedOut, notInstalled, unknown }
/// Display-only account details. Never encode, persist or include them in diagnostics.
public struct ClaudeLoginSnapshot: Equatable {
  public let state: ClaudeLoginState
  public let email: String?
  public let plan: String?
  public init(state: ClaudeLoginState, email: String? = nil, plan: String? = nil) {
    self.state = state; self.email = state == .loggedIn ? email : nil; self.plan = state == .loggedIn ? plan : nil
  }
}
/// The app shows Claude Code's login and offers the official login in Terminal; it never logs in itself.
public protocol ClaudeLoginSource {
  /// Runs the CLI's status check; may wait for it, so callers use a background task.
  func loginState() -> ClaudeLoginState
  func loginSnapshot() -> ClaudeLoginSnapshot
  /// False when the terminal may keep its login in another Claude folder than the one checked.
  func loginFolderKnown() -> Bool
  /// Hands the official login to Terminal. Returns once Terminal opened it, or throws when it could not.
  /// Finding the CLI may wait for the person's shell, so callers use a background task.
  func openLogin() async throws
}
public extension ClaudeLoginSource {
  func loginFolderKnown() -> Bool { true }
  func loginSnapshot() -> ClaudeLoginSnapshot { ClaudeLoginSnapshot(state: loginState()) }
}
public enum SettingsSystemTarget: String, CaseIterable {
  case accessibility, inputMonitoring, screenRecording, fileVault, backups
}
public protocol SettingsSystemActions { func open(_ target: SettingsSystemTarget) }

public struct SettingsApp: Equatable, Identifiable {
  public let id: String
  public let name: String
  public init(id: String, name: String) { self.id = id.lowercased(); self.name = name }
}
public protocol SettingsAppCatalog { func apps() -> [SettingsApp] }

public protocol SettingsAppChooser { @MainActor func chooseApp() async -> SettingsApp? }
public protocol SettingsBackupActions { func retryBackupExclusion() -> StorageSecurityHealth }
