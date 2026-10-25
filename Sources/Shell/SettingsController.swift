import AppKit
import Core
import Foundation
import SwiftUI

public extension SettingsSystemTarget {
  var url: URL {
    let pane: String
    switch self {
    case .accessibility: pane = "com.apple.preference.security?Privacy_Accessibility"
    case .inputMonitoring: pane = "com.apple.preference.security?Privacy_ListenEvent"
    case .screenRecording: pane = "com.apple.preference.security?Privacy_ScreenCapture"
    case .fileVault: pane = "com.apple.preference.security?FileVault"
    case .backups: pane = "com.apple.preference.timemachine"
    }
    return URL(string: "x-apple.systempreferences:" + pane)!
  }
}

public final class MacSettingsSystemActions: SettingsSystemActions {
  public init() {}
  public func open(_ target: SettingsSystemTarget) { NSWorkspace.shared.open(target.url) }
}

/// A host may supply a manual scheduler and clock; tests never wait for a pause deadline.
public typealias SettingsDeadlineSchedule = @MainActor (Int, @escaping @MainActor () -> Void) -> (() -> Void)

@MainActor private final class WeakSettingsController {
  weak var value: SettingsController?
  init(_ value: SettingsController) { self.value = value }
}

@MainActor public final class SettingsController: ObservableObject {
  @Published public private(set) var settings: StorageSettings
  @Published public private(set) var error: SettingsMessage?
  @Published public private(set) var errorSection: SettingsSection = .subscription
  @Published public private(set) var validationMessage: SettingsMessage?
  @Published public private(set) var validationRevision = 0
  @Published public private(set) var isConnecting = false
  @Published public private(set) var isClaudeConnecting = false
  @Published public private(set) var claudeError: SettingsMessage?
  /// nil until the first check of the person's own Claude Code login ends.
  @Published public private(set) var claudeLogin: ClaudeLoginState?
  @Published public private(set) var claudeAccount: ClaudeLoginSnapshot?
  @Published public private(set) var isCheckingClaude = false
  /// The terminal may keep its login in another Claude folder than the one checked.
  @Published public private(set) var claudeFolderUncertain = false
  @Published public private(set) var chatGPT = ChatGPTAccountOverview()
  /// The one-time "using your ChatGPT plan" confirmation is showing.
  @Published public private(set) var showsPlanWelcome = false
  public var chatGPTStatus: ChatGPTConnectionStatus { chatGPT.status }
  @Published public private(set) var apps: [SettingsApp] = []
  @Published public private(set) var now: Int
  @Published public var health: TimelineHealth
  @Published public var section: SettingsSection
  private let store: SettingsEditingStore
  private let connector: SubscriptionConnector
  private let claudeConnector: SubscriptionConnector?
  private let claudeLoginSource: ClaudeLoginSource?
  private let account: ChatGPTAccount?
  private var claudeCancelled = false
  private var claudeSectionVisible = false
  private var claudeVisibilityGeneration = 0
  private let ownBundleID: String
  private let clock: () -> Int
  private let pollSchedule: SettingsDeadlineSchedule
  private var pollCancellation: (() -> Void)?
  private var observers: [UUID: CheckedContinuation<Void, Never>] = [:]
  private let schedule: SettingsDeadlineSchedule
  private var pauseCancellation: (() -> Void)?
  private var scheduledEnd: Int?
  private var cancelled = false
  private static var sessions: [String: WeakSettingsController] = [:]
  init(store: SettingsEditingStore, connector: SubscriptionConnector, ownBundleID: String, claudeConnector: SubscriptionConnector? = nil,
    claudeLogin: ClaudeLoginSource? = nil, health: TimelineHealth = TimelineHealth(), section: SettingsSection = .recording,
    clock: @escaping () -> Int = { Int(Date().timeIntervalSince1970) },
    schedule: @escaping SettingsDeadlineSchedule = SettingsController.scheduleDeadline,
    pollSchedule: @escaping SettingsDeadlineSchedule = SettingsController.scheduleDeadline, chatGPT: ChatGPTAccount? = nil) throws {
    self.account = chatGPT
    self.claudeConnector = claudeConnector
    claudeLoginSource = claudeLogin ?? claudeConnector as? ClaudeLoginSource
    self.pollSchedule = pollSchedule
    self.store = store; self.connector = connector; self.ownBundleID = ownBundleID; self.clock = clock; self.schedule = schedule
    self.settings = try store.settings(); self.health = health; self.section = section; self.now = clock()
    reschedulePause()
  }
  deinit { pauseCancellation?(); pollCancellation?() }
  public static func scheduleDeadline(after seconds: Int, action: @escaping @MainActor () -> Void) -> (() -> Void) {
    let task = Task { @MainActor in
      do { try await Task.sleep(for: .seconds(seconds)); try Task.checkCancellation(); action() } catch {}
    }
    return { task.cancel() }
  }
  /// Hosts obtain and retain the database's controller here before setting health or routing notices.
  /// Views observe that exact instance. Independent clients are internal for cross-client tests.
  public static func forDatabase(store: SettingsEditingStore, connector: SubscriptionConnector, ownBundleID: String, claudeConnector: SubscriptionConnector? = nil,
    clock: @escaping () -> Int = { Int(Date().timeIntervalSince1970) },
    schedule: @escaping SettingsDeadlineSchedule = SettingsController.scheduleDeadline,
    pollSchedule: @escaping SettingsDeadlineSchedule = SettingsController.scheduleDeadline,
    chatGPT: ChatGPTAccount? = nil) throws -> SettingsController {
    if let shared = sessions[store.settingsIdentity]?.value { return shared }
    let controller = try SettingsController(store: store, connector: connector, ownBundleID: ownBundleID, claudeConnector: claudeConnector,
      clock: clock, schedule: schedule, pollSchedule: pollSchedule, chatGPT: chatGPT)
    sessions = sessions.filter { $0.value.value != nil }
    sessions[store.settingsIdentity] = WeakSettingsController(controller)
    return controller
  }
  public var model: SettingsViewModel { SettingsViewModel(settings: settings, health: health, ownBundleID: ownBundleID, now: now) }
  public func refresh() {
    do {
      let latest = try store.settings()
      if latest != settings { settings = latest }
      now = clock(); reschedulePause()
    } catch { self.error = .saveFailed; errorSection = section }
  }
  /// Visible pages hold observation leases; only the first starts the shared polling task.
  public func observe() async {
    let id = UUID()
    await withTaskCancellationHandler(operation: {
      await withCheckedContinuation { continuation in
        guard !Task.isCancelled else { continuation.resume(); return }
        observers[id] = continuation
        refresh()
        if observers.count == 1 { schedulePoll() }
      }
    }, onCancel: {
      Task { @MainActor [weak self] in self?.stopObserving(id) }
    })
  }
  private func stopObserving(_ id: UUID) {
    observers.removeValue(forKey: id)?.resume()
    if observers.isEmpty { pollCancellation?(); pollCancellation = nil }
  }
  private func schedulePoll() {
    pollCancellation = pollSchedule(1) { [weak self] in
      guard let self, !self.observers.isEmpty else { return }
      self.pollCancellation = nil
      self.refresh(); self.schedulePoll()
    }
  }
  private func reschedulePause() {
    let end = settings.pausedUntil.flatMap { $0 > now ? $0 : nil }
    guard end != scheduledEnd else { return }
    pauseCancellation?(); pauseCancellation = nil; scheduledEnd = end
    if let end {
      pauseCancellation = schedule(end - now) { [weak self] in
        guard let self else { return }
        self.scheduledEnd = nil; self.pauseCancellation = nil; self.refresh()
      }
    }
  }
  /// A production host may start a stopped recorder after an explicit successful enable.
  public var recordingEnabledByUser: (() -> Void)?
  private func committed(_ value: StorageSettings) {
    settings = value; now = clock(); reschedulePause()
  }
  public func loadApps(from catalog: SettingsAppCatalog) async {
    apps = await Task.detached { catalog.apps() }.value
  }
  public func chooseApp(using chooser: SettingsAppChooser) async {
    guard let app = await chooser.chooseApp() else { return }
    if !apps.contains(where: { $0.id == app.id }) { apps.append(app) }
    edit(.addApp(app.id))
  }
  public func retryBackup(using actions: SettingsBackupActions) {
    health.security.backupExclusionFailure = actions.retryBackupExclusion().backupExclusionFailure
  }
  public func navigate(from notice: TimelineNoticeKind) { refresh(); section = notice.settingsSection }
  public func edit(_ edit: SettingsEdit) {
    section = edit.section
    defer { validationRevision += 1 }
    do {
      committed(try store.patchSettings(.edit(edit, ownBundleID: ownBundleID, now: clock())))
      error = nil; validationMessage = .saved
      if case .recording(true) = edit { recordingEnabledByUser?() }
    } catch {
      errorSection = edit.section; self.error = SettingsMessage(error: error); validationMessage = self.error
      refresh()
    }
  }
  public func setChatSkipApprovals(_ enabled: Bool) {
    do { committed(try store.patchSettings(.chatSkipApprovals(enabled))); error = nil }
    catch { self.error = .saveFailed; errorSection = .conversation }
  }
  public func connectClaude() async {
    guard !isClaudeConnecting, let connector = claudeConnector else { return }
    let generation: String
    do {
      let started = try store.patchSettings(.beginClaudeConnection)
      committed(started); generation = started.claudeConnectionGeneration
    } catch { claudeError = .saveFailed; return }
    isClaudeConnecting = true; claudeCancelled = false; claudeError = nil
    defer { isClaudeConnecting = false }
    let work = Task.detached { try connector.connect() }
    do {
      try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { connector.cancel() })
      guard !claudeCancelled && !Task.isCancelled else { claudeError = .cancelled; refresh(); return }
      committed(try store.patchSettings(.completeClaudeConnection(generation: generation)))
      claudeLogin = .loggedIn
    } catch {
      claudeError = claudeCancelled || Task.isCancelled ? .cancelled : SettingsMessage(error: error)
      if error as? SubscriptionConnectionError == .notLoggedIn { claudeLogin = .loggedOut }
      if error as? SubscriptionConnectionError == .notInstalled { claudeLogin = .notInstalled }
      refresh()
    }
  }
  /// Asks the person's own Claude Code whether it is logged in. It runs the person's own CLI, so hosts
  /// ask only while the Claude section is on screen: see claudeSection(visible:) and appBecameActive().
  public func refreshClaudeLogin() async {
    guard claudeSectionVisible, let source = claudeLoginSource, !isCheckingClaude else { return }
    let generation = claudeVisibilityGeneration
    isCheckingClaude = true
    defer {
      isCheckingClaude = false
      if claudeSectionVisible, generation != claudeVisibilityGeneration {
        Task { await self.refreshClaudeLogin() }
      }
    }
    let (snapshot, known) = await Task.detached { (source.loginSnapshot(), source.loginFolderKnown()) }.value
    guard claudeSectionVisible, generation == claudeVisibilityGeneration else { return }
    claudeAccount = snapshot
    claudeLogin = snapshot.state; claudeFolderUncertain = !known
  }
  /// The page reports the Claude section scrolling into and out of view; each time it comes into view it is checked.
  public func claudeSection(visible: Bool) async {
    let appeared = visible && !claudeSectionVisible
    claudeSectionVisible = visible
    if !visible { claudeVisibilityGeneration += 1; claudeAccount = nil; claudeLogin = nil }
    if appeared { await refreshClaudeLogin() }
  }
  /// Back from Terminal the person may have logged in; only a Claude section on screen is checked again.
  public func appBecameActive() async {
    if claudeSectionVisible { await refreshClaudeLogin() }
  }
  /// The official login runs in Terminal, never in the app. The page checks again when the app is active again.
  public func openClaudeLogin() async {
    guard let source = claudeLoginSource else { return }
    do {
      try await Task.detached { try await source.openLogin() }.value
      claudeError = nil
    } catch { claudeError = SettingsMessage(error: error) }
  }
  public func cancelClaudeConnection() { claudeCancelled = true; claudeConnector?.cancel() }
  public func disconnectClaude() {
    if isClaudeConnecting { cancelClaudeConnection() }
    do { committed(try store.patchSettings(.disconnectClaude)); claudeError = nil }
    catch { claudeError = .saveFailed }
  }
  public func connect() async {
    let connector = connector
    await connect { try connector.connect() }
  }
  /// Signs in to another ChatGPT account; the saved one is replaced only once the new one validates and
  /// grants plan use. A failed or cancelled switch leaves the saved account as it was, so summaries go on
  /// as before. The grant left unused is revoked in the background after the attempt has returned.
  public func connectDifferentAccount() async {
    guard let account else { return }
    await connect(switching: true, restoreConsent: settings.subscriptionConnected) { try account.connectDifferentAccount() }
    await revokeUnusedGrants()
  }
  private func connect(switching: Bool = false, restoreConsent: Bool = false, _ signIn: @escaping () throws -> Void) async {
    guard !isConnecting else { return }
    section = .subscription
    let generation: String
    do {
      let started = try store.patchSettings(.beginConnection)
      committed(started); generation = started.connectionGeneration
    } catch { self.error = .saveFailed; errorSection = .subscription; return }
    isConnecting = true; cancelled = false; error = nil
    defer { isConnecting = false; Task { await refreshChatGPTStatus() } }
    let connector = connector
    let work = Task.detached { try signIn() }
    do {
      try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { connector.cancel() })
      // A switch that returned has already replaced the account; a Cancel that came too late is not a cancel.
      guard switching || (!cancelled && !Task.isCancelled) else { error = .cancelled; errorSection = .subscription; refresh(); return }
      committed(try store.patchSettings(.completeConnection(generation: generation)))
      if health.summary != nil { health.summary?.subscriptionConnected = true }
    } catch {
      errorSection = .subscription
      self.error = cancelled || Task.isCancelled ? .cancelled : SettingsMessage(error: error)
      // Every failed switch leaves the saved account unchanged, so the consent it had comes back. A disconnect
      // during the attempt wrote a newer generation, and then this restore is refused.
      if restoreConsent, let restored = try? store.patchSettings(.completeConnection(generation: generation)) { committed(restored) }
      refresh()
    }
  }
  private var revoking = false
  private func revokeUnusedGrants() async {
    guard let account, !revoking else { return }
    revoking = true
    defer { revoking = false }
    let confirmed = await Task.detached { account.revokeUnusedGrants() }.value
    guard !confirmed else { return }
    errorSection = .subscription
    error = error == .chatGPTDifferentAccountWithoutPlan ? .chatGPTDifferentAccountWithoutPlanUnconfirmed : .chatGPTUnusedRevocationUnconfirmed
  }
  public func cancelConnection() { cancelled = true; connector.cancel() }
  /// Read off the main thread: a Keychain read may wait on the system's own access prompt.
  public func refreshChatGPTStatus() async {
    guard let account else { return }
    chatGPT = await Task.detached { account.overview() }.value
    if chatGPT.status == .connected && chatGPT.conversationRequestRefused { chatGPT.status = .requestRefused }
    // A grant a quit or crash left queued is revoked now, in the background, and reported if unconfirmed.
    if chatGPT.revocationPending && !isConnecting && !revoking { Task { await revokeUnusedGrants() } }
    // Shown once, after plan use is first enabled and summaries are on. A status read that started before
    // the person dismissed it must not bring it back.
    if chatGPT.planWelcomePending && settings.subscriptionConnected && !planWelcomeDismissed { showsPlanWelcome = true }
  }
  private var planWelcomeDismissed = false
  public func acknowledgePlanWelcome() async {
    showsPlanWelcome = false; planWelcomeDismissed = true
    guard let account else { return }
    await Task.detached { account.acknowledgePlanWelcome() }.value
    await refreshChatGPTStatus()
  }
  /// Stops summaries at once, then revokes and clears the ChatGPT tokens in the background.
  public func signOut() async {
    disconnect()
    guard let account else { return }
    let confirmed = await Task.detached { account.signOut() }.value
    await refreshChatGPTStatus()
    if !confirmed { error = .chatGPTRevocationUnconfirmed; errorSection = .subscription }
  }
  public func disconnect() {
    section = .subscription
    if isConnecting { cancelConnection() }
    do {
      // Retain the login saved in the app's own folders; the fresh persisted generation revokes pending connections.
      committed(try store.patchSettings(.disconnect)); error = nil
      if health.summary != nil { health.summary?.subscriptionConnected = false }
    } catch { self.error = .saveFailed; errorSection = section }
  }
}
