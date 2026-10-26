import Core
import Foundation

public enum SettingsMessage: String, CaseIterable {
  case retention = "Retention must be between 1 and 36500 days."
  case retentionConflict = "Retention changed elsewhere. Your draft is kept. Reload saved values before applying."
  case connectionSuperseded = "A newer connection or disconnect replaced this attempt. Connect again to allow access."
  case saved = "Settings saved."
  case statusTimeout = "The login status check timed out. Try connecting again."
  case dayStart = "Day start must be an hour from 0 to 23."
  case duplicateApp = "This app is already excluded."
  case ownApp = "ActivityProbe is always excluded."
  case appIdentity = "Enter a valid app bundle identifier."
  case pause = "Choose a pause end in the future."
  case saveFailed = "Settings could not be saved. Try again."
  case preparation = "The subscription connection could not be prepared."
  case connection = "Connection failed. Try connecting again."
  case cancelled = "Connection cancelled."
  case notInstalled = "The command-line tool was not found. Install it, then connect again."
  case claudeNotLoggedIn = "Claude Code is not logged in. Log in to Claude in Terminal, then connect again."
  case terminalFailed = "Terminal could not be opened for the Claude login. Try again."
  case chatGPTTimedOut = "Sign-in took longer than 10 minutes and was stopped. Try again."
  case chatGPTDeclined = "ChatGPT plan use was not allowed in the browser. Continue with ChatGPT again to allow it."
  case chatGPTRegistration = "ChatGPT did not finish registering ActivityProbe. Try again."
  case chatGPTClientMismatch = "The browser returned a different app registration. Nothing was saved. Try again."
  case chatGPTDifferentAccount = "That ChatGPT account is not the one this Mac signed in with before. Nothing was saved. To switch accounts, choose Use a different ChatGPT account."
  case chatGPTIdentity = "The ChatGPT sign-in could not be verified. Nothing was saved. Try again."
  case chatGPTPlanRequired = "Signed in, but this account cannot use its ChatGPT plan here. ChatGPT Plus or Pro is required."
  case chatGPTExchange = "ChatGPT did not complete the sign-in. Try again."
  case chatGPTNetwork = "ChatGPT could not be reached. Check the connection and try again."
  case chatGPTListener = "The sign-in could not start because no local port was available. Try again."
  case chatGPTBrowser = "The browser could not be opened. Try again."
  case chatGPTStorage = "The sign-in could not be saved in the Keychain. Try again."
  case chatGPTRevocationUnconfirmed = "Signed out on this Mac, but ChatGPT did not confirm the sign-out. You can disconnect ActivityProbe in ChatGPT settings."
  case chatGPTDifferentAccountWithoutPlan = "That ChatGPT account cannot use its ChatGPT plan here, so the account already signed in is kept. ChatGPT Plus or Pro is required."
  case chatGPTDifferentAccountWithoutPlanUnconfirmed = "That ChatGPT account cannot use its ChatGPT plan here, so the account already signed in is kept. ChatGPT did not confirm removing that account's sign-in. You can disconnect ActivityProbe in its ChatGPT settings."
  case chatGPTUnusedRevocationUnconfirmed = "ChatGPT did not confirm removing the sign-in of the account no longer used here. You can disconnect ActivityProbe in that account's ChatGPT settings."
  public init(error: Error) {
    if let error = error as? SettingsValidationError { self = SettingsMessage(rawValue: Self.validationKey(error))! }
    else if let error = error as? SubscriptionConnectionError {
      switch error { case .localPreparation: self = .preparation; case .failed: self = .connection; case .cancelled: self = .cancelled; case .statusTimeout: self = .statusTimeout; case .notInstalled: self = .notInstalled
      case .notLoggedIn: self = .claudeNotLoggedIn; case .terminalFailed: self = .terminalFailed }
    } else if let error = error as? ChatGPTSignInError {
      switch error {
      case .cancelled: self = .cancelled; case .timedOut: self = .chatGPTTimedOut; case .declined: self = .chatGPTDeclined
      case .registrationIncomplete: self = .chatGPTRegistration
      case .clientMismatch: self = .chatGPTClientMismatch; case .differentAccount: self = .chatGPTDifferentAccount
      case .invalidIDToken: self = .chatGPTIdentity; case .planRequired: self = .chatGPTPlanRequired
      case .exchangeFailed: self = .chatGPTExchange; case .network: self = .chatGPTNetwork; case .listener: self = .chatGPTListener
      case .browser: self = .chatGPTBrowser; case .storage: self = .chatGPTStorage
      case .differentAccountWithoutPlan: self = .chatGPTDifferentAccountWithoutPlan
      }
    } else { self = .saveFailed }
  }
  private static func validationKey(_ error: SettingsValidationError) -> String {
    switch error {
    case .retentionConflict: return Self.retentionConflict.rawValue
    case .connectionSuperseded: return Self.connectionSuperseded.rawValue
    case .retention: return Self.retention.rawValue
    case .dayStart: return Self.dayStart.rawValue
    case .duplicateApp: return Self.duplicateApp.rawValue
    case .ownApp: return Self.ownApp.rawValue
    case .appIdentity: return Self.appIdentity.rawValue
    case .pause: return Self.pause.rawValue
    }
  }
}
public enum SettingsLabel: String, CaseIterable {
  case claude = "Claude connection", conversation = "Conversation"
  case title = "Settings", recording = "Recording", exclusions = "Excluded apps", retention = "Evidence retention"
  case dayStart = "Day start", subscription = "Subscription", permissions = "Permissions", security = "Security"
  case record = "Record activity", pause = "Pause", resume = "Resume recording", pauseUntil = "Paused until %@"
  case pauseEnd = "Pause end", always = "Always excluded", remove = "Remove", add = "Add app"
  case chooseApp = "Choose an app", screen = "Screen text (days)", prompt = "Agent instructions (days)"
  case apply = "Apply", hour = "Hour (0–23)", notConnected = "Not connected", connected = "Connected"
  case problem = "Connection problem", connect = "Connect subscription", disconnect = "Disconnect", cancel = "Cancel"
  case connecting = "Connecting…", consent = "We read and summarize agent conversations."
  case accessibility = "Accessibility", inputMonitoring = "Input Monitoring", screenRecording = "Screen Recording"
  case granted = "Allowed", missing = "Permission missing", openSettings = "Open System Settings"
  case fileVault = "FileVault", on = "On", off = "Off", unknown = "Unknown"
  case backup = "Excluded from backups", backupFailed = "Backup exclusion failed", backupSkipped = "Backup exclusion skipped for this database"
  case backupWarning = "Records cannot be restored after disk loss or moving to another Mac."
  case backupUnconfirmed = "Records may still be backed up because backup exclusion has not been established."
  case chooseBundle = "Choose app bundle…", reloadSaved = "Reload saved values"
  case retryBackup = "Retry backup exclusion"
  case backupOverrideReason = "This database is outside the app data folder. Exclusion was skipped to avoid changing another folder. Use the default database location to protect backups."
  case retentionWarning = "Evidence expires even when your subscription is disconnected."
  case claudeLoggedIn = "Claude Code is logged in on this Mac."
  case claudeLoggedOut = "Not logged in"
  case claudeLoginTitle = "Claude Code login"
  case claudeAppUse = "Use Claude in this app"
  case claudeTurnOn = "Turn on", claudeTurnOff = "Turn off"
  case claudeRecheck = "Check again"
  case claudeOtherAccount = "Log in to a different account in Terminal"
  case claudeMacLoginNote = "This changes the Claude Code login for the whole Mac."
  case claudeAppUseNote = "Turning this off keeps your Claude Code login and only stops Claude conversations in this app."
  case claudeAccountPlan = "%@ · Logged in with the %@ plan"
  case claudeAccountOnly = "%@ · Logged in"
  case claudePlanOnly = "Logged in with the %@ plan"
  case claudeNotInstalled = "Claude Code was not found on this Mac."
  case claudeUnknown = "The Claude Code login could not be checked."
  case claudeChecking = "Checking the Claude Code login…"
  case claudeTerminalLogin = "Log in to Claude in Terminal"
  case claudeTerminalNote = "Terminal opens Claude Code’s own login. When you come back, this page checks again."
  case claudeFolderUncertain = "The app could not learn which Claude folder your terminal uses, so it may be checking a different Claude folder than Terminal."
  case continueWithChatGPT = "Continue with ChatGPT", signOut = "Sign out"
  case planRequired = "ChatGPT Plus or Pro required", signInAgain = "Sign in again"
  case chatGPTPlan = "Summaries and conversations use your ChatGPT sign-in. Only ChatGPT Plus and Pro plans can be used."
  case chatGPTWaiting = "Waiting for the browser…"
  case chatGPTDeadline = "Sign-in opens your browser and stops after at most 10 minutes."
  case chatGPTStored = "The sign-in is kept only in this Mac's Keychain. Signing out removes it."
  case chatGPTCallbackReturn = "Return to ActivityProbe to see whether sign-in finished. You can close this tab."
  case unavailable = "Not available for this account"
  case unavailableNote = "ChatGPT plan use is not available for this account, workspace or region, so summaries stay off. Signing in again does not change this. Use a different ChatGPT account, or sign out."
  case usageLimited = "Usage limit reached"
  case notAccepted = "ChatGPT did not accept requests"
  case requestRefused = "ChatGPT refused a request"
  case requestRefusedNote = "ChatGPT refused a request from this version of ActivityProbe. That request stays off until ActivityProbe is updated; other requests may still work."
  case pausedUntilSignIn = "Summaries and agent-log reading are paused until you continue with ChatGPT."
  case usageLimitedNote = "ChatGPT reported a usage limit, so summaries are paused and try again later. You can check usage in ChatGPT settings."
  case notAcceptedNote = "ChatGPT did not accept summary requests, so summaries are paused and try again later. If this continues, continue with ChatGPT to sign in again."
  case serviceUnavailableNote = "ChatGPT is temporarily unavailable. Summaries are paused and retry automatically after a short wait."
  case summariesOff = "Summaries and agent-log reading are off. Continue with ChatGPT to turn them on."
  case differentAccount = "Use a different ChatGPT account"
  case manageUsage = "Manage usage"
  case planWelcomeTitle = "You're using your ChatGPT plan"
  case planWelcomeMessage = "Summaries in ActivityProbe use your ChatGPT plan. You can manage usage in ChatGPT settings."
  case gotIt = "Got it"
  public static func section(_ section: SettingsSection) -> Self {
    switch section {
    case .recording: return .recording; case .exclusions: return .exclusions; case .retention: return .retention
    case .dayStart: return .dayStart; case .subscription: return .subscription
    case .claude: return .claude; case .conversation: return .conversation
    case .permissions: return .permissions; case .security: return .security
    }
  }
}
public struct SettingsStrings {
  public let language: String
  private let bundle: Bundle?
  public init(language: String, resources: URL? = Bundle.main.resourceURL) {
    self.language = language
    bundle = resources.flatMap { Bundle(path: $0.appendingPathComponent(language + ".lproj").path) }
  }
  public func text(_ label: SettingsLabel) -> String { text(key: label.rawValue) }
  public func text(_ message: SettingsMessage) -> String { text(key: message.rawValue) }
  public func text(_ status: ChatGPTConnectionStatus) -> String { text(ChatGPTRow.label(status)) }
  public func text(key: String) -> String { bundle?.localizedString(forKey: key, value: key, table: "Localizable") ?? key }
  public func systemAction(_ target: SettingsSystemTarget) -> String {
    let label: SettingsLabel
    switch target {
    case .accessibility: label = .accessibility
    case .inputMonitoring: label = .inputMonitoring
    case .screenRecording: label = .screenRecording
    case .fileVault: label = .fileVault
    case .backups: label = .backup
    }
    return text(.openSettings) + ": " + text(label)
  }
  public func pause(until time: Int) -> String {
    let formatter = DateFormatter(); formatter.locale = Locale(identifier: language)
    formatter.dateStyle = .medium; formatter.timeStyle = .short
    return String(format: text(.pauseUntil), locale: formatter.locale,
      formatter.string(from: Date(timeIntervalSince1970: Double(time))))
  }
}

/// What the Codex row shows and offers. Pure, so every state is checked without drawing.
/// Summaries run with consent and a ChatGPT sign-in with plan use. Local recording is independent.
public struct ChatGPTRow: Equatable {
  /// The ChatGPT status. With consent on but no usable sign-in, a note says summaries are paused.
  public let headline: SettingsLabel
  public let notes: [SettingsLabel]
  public let showsProblem: Bool
  public let offersContinue: Bool
  public let offersDifferentAccount: Bool
  public let offersSignOut: Bool
  public let offersManageUsage: Bool
  public init(model: SettingsViewModel, overview: ChatGPTAccountOverview, isConnecting: Bool) {
    let status = overview.status
    let consented = model.settings.subscriptionConnected
    headline = Self.label(status)
    var notes: [SettingsLabel] = []
    if consented && !status.signedInForPlanUse && status != .unavailable { notes.append(.pausedUntilSignIn) }
    if status == .usageLimited { notes.append(.usageLimitedNote) }
    if status == .notAccepted { notes.append(.notAcceptedNote) }
    if status == .requestRefused { notes.append(.requestRefusedNote) }
    if status.signedInForPlanUse && !consented { notes.append(.summariesOff) }
    if status == .unavailable { notes.append(.unavailableNote) }
    if consented, model.health.summary?.serviceUnavailableUntil != nil { notes.append(.serviceUnavailableNote) }
    self.notes = notes
    showsProblem = model.subscription == .problem
    // Signing in again cannot change "not available", a usage limit or a refused request; offering it would
    // loop through OAuth.
    let continues = status != .unavailable && status != .requestRefused
      && (!consented || !status.signedInForPlanUse || status == .notAccepted)
    offersContinue = !isConnecting && continues
    offersDifferentAccount = !isConnecting && overview.registered
    offersSignOut = !isConnecting && (status != .notConnected || consented)
    offersManageUsage = status == .connected || status == .usageLimited
  }
  public static func label(_ status: ChatGPTConnectionStatus) -> SettingsLabel {
    switch status {
    case .notConnected: return .notConnected; case .connected: return .connected; case .planRequired: return .planRequired
    case .unavailable: return .unavailable; case .signInAgain: return .signInAgain
    case .usageLimited: return .usageLimited; case .notAccepted: return .notAccepted
    case .requestRefused: return .requestRefused
    }
  }
}
