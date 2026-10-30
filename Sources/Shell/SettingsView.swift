import AppKit
import Core
import SwiftUI

/// The page and renderer share exactly the same controls. Only the host supplies side effects.
public struct SettingsPage: View {
  public let model: SettingsViewModel
  public let strings: SettingsStrings
  public let width: Double
  public let apps: [SettingsApp]
  public var error: SettingsMessage?
  public var errorSection: SettingsSection
  public var isConnecting: Bool
  public var isClaudeConnecting: Bool
  public var claudeError: SettingsMessage?
  public var claudeLogin: ClaudeLoginState?
  public var claudeAccount: ClaudeLoginSnapshot?
  public var isCheckingClaude: Bool
  public var claudeFolderUncertain: Bool
  private let openClaudeLogin: () -> Void
  private let recheckClaude: () -> Void
  public var chatGPT: ChatGPTAccountOverview
  private let connectClaude: () -> Void
  private let disconnectClaude: () -> Void
  private let cancelClaude: () -> Void
  private let skipApprovals: (Bool) -> Void
  private let edit: (SettingsEdit) -> Void
  private let connect: () -> Void
  private let connectDifferentAccount: () -> Void
  private let manageUsage: () -> Void
  private let disconnect: () -> Void
  private let cancel: () -> Void
  private let chooseApp: () -> Void
  private let retryBackup: () -> Void
  private let system: (SettingsSystemTarget) -> Void
  @State private var draft: SettingsRetentionDraft
  @State private var pauseEnd: Date
  @Environment(\.colorScheme) private var scheme
  private var palette: TimelinePalette { TimelinePalette(dark: scheme == .dark) }
  public init(model: SettingsViewModel, strings: SettingsStrings, width: Double, apps: [SettingsApp] = [], error: SettingsMessage? = nil,
    errorSection: SettingsSection = .subscription, isConnecting: Bool = false, isClaudeConnecting: Bool = false, claudeError: SettingsMessage? = nil,
    claudeLogin: ClaudeLoginState? = nil, isCheckingClaude: Bool = false, claudeFolderUncertain: Bool = false,
    claudeAccount: ClaudeLoginSnapshot? = nil, openClaudeLogin: @escaping () -> Void = {}, recheckClaude: @escaping () -> Void = {},
    connectClaude: @escaping () -> Void = {}, disconnectClaude: @escaping () -> Void = {}, cancelClaude: @escaping () -> Void = {},
    skipApprovals: @escaping (Bool) -> Void = { _ in }, draft: SettingsRetentionDraft? = nil, edit: @escaping (SettingsEdit) -> Void = { _ in },
    connect: @escaping () -> Void = {}, disconnect: @escaping () -> Void = {}, cancel: @escaping () -> Void = {},
    chooseApp: @escaping () -> Void = {}, retryBackup: @escaping () -> Void = {},
    system: @escaping (SettingsSystemTarget) -> Void = { _ in }, chatGPT: ChatGPTAccountOverview = ChatGPTAccountOverview(),
    connectDifferentAccount: @escaping () -> Void = {}, manageUsage: @escaping () -> Void = {}) {
    self.chatGPT = chatGPT; self.connectDifferentAccount = connectDifferentAccount; self.manageUsage = manageUsage
    self.isClaudeConnecting = isClaudeConnecting; self.claudeError = claudeError
    self.claudeLogin = claudeLogin; self.isCheckingClaude = isCheckingClaude; self.openClaudeLogin = openClaudeLogin
    self.claudeFolderUncertain = claudeFolderUncertain
    self.claudeAccount = claudeAccount; self.recheckClaude = recheckClaude
    self.connectClaude = connectClaude; self.disconnectClaude = disconnectClaude; self.cancelClaude = cancelClaude; self.skipApprovals = skipApprovals
    self.model = model; self.strings = strings; self.width = width; self.apps = apps; self.error = error; self.errorSection = errorSection; self.isConnecting = isConnecting
    self.edit = edit; self.connect = connect; self.disconnect = disconnect; self.cancel = cancel; self.system = system; self.chooseApp = chooseApp; self.retryBackup = retryBackup
    _draft = State(initialValue: draft ?? SettingsRetentionDraft(model.settings))
    _pauseEnd = State(initialValue: Date(timeIntervalSince1970: Double(model.nextPauseEnd)))
  }
  private func text(_ label: SettingsLabel) -> Text { Text(verbatim: strings.text(label)) }
  private func button(_ label: SettingsLabel, _ action: @escaping () -> Void) -> some View {
    Button(action: action) { text(label).underline() }.buttonStyle(.plain).padding(.vertical, 4)
  }
  private func rule() -> some View { Rectangle().fill(palette.ink.opacity(0.25)).frame(height: 1) }
  /// The sections on the page, in order.
  var sections: [SettingsSection] { SettingsSection.allCases.filter(isShown) }
  private func isShown(_ section: SettingsSection) -> Bool {
    return true
  }
  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      text(.title).accessibilityAddTraits(.isHeader).font(.system(size: 34, weight: .semibold)).padding(.bottom, 28)
      ForEach(sections, id: \.self) { section in
        VStack(alignment: .leading, spacing: 14) {
          rule()
          text(SettingsLabel.section(section)).font(.system(size: 20, weight: .semibold))
            .accessibilityAddTraits(.isHeader).padding(.top, 4)
          if let error, section == errorSection {
            Text(verbatim: strings.text(error)).fontWeight(.medium).fixedSize(horizontal: false, vertical: true)
          }
          content(section)
        }.padding(.bottom, 28).id(section)
        .background {
          if section == .claude {
            GeometryReader { frame in Color.clear.preference(key: ClaudeSectionFrame.self, value: frame.frame(in: .named(Self.scrollSpace))) }
          }
        }
      }
    }
    .padding(width < 500 ? 20 : 36)
    .frame(width: width, alignment: .leading)
    .font(.system(size: 13))
    .foregroundStyle(palette.ink).tint(palette.ink).background(palette.paper)
    .environment(\.locale, Locale(identifier: strings.language))
    .onChange(of: SettingsRetention(model.settings)) { _, _ in draft.receive(model.settings) }
    .onChange(of: model.now) { _, now in
      if pauseEnd.timeIntervalSince1970 <= Double(now) { resetPauseEnd() }
    }
    .onChange(of: model.settings.pausedUntil) { _, _ in resetPauseEnd() }
    .onChange(of: model.isPaused) { _, paused in if !paused { resetPauseEnd() } }
    .onChange(of: draft.conflicting) { _, conflicting in
      if conflicting { Self.announce(strings.text(.retentionConflict)) }
    }
  }
  private func resetPauseEnd() { pauseEnd = Date(timeIntervalSince1970: Double(model.nextPauseEnd)) }
  static func announce(_ message: String) {
    NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested,
      userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
  }
  private func systemButton(_ target: SettingsSystemTarget) -> some View {
    button(.openSettings) { system(target) }.accessibilityLabel(strings.systemAction(target))
  }
  @ViewBuilder private func content(_ section: SettingsSection) -> some View {
    switch section {
    case .recording:
      Toggle(isOn: Binding(get: { model.settings.recordingEnabled }, set: { edit(.recording($0)) })) { text(.record) }
        .toggleStyle(.checkbox)
      if model.isPaused, let end = model.settings.pausedUntil {
        Text(verbatim: strings.pause(until: end)).fixedSize(horizontal: false, vertical: true)
        button(.resume) { edit(.pause(nil)) }
      } else {
        DatePicker(selection: $pauseEnd, displayedComponents: [.date, .hourAndMinute]) { text(.pauseEnd) }.datePickerStyle(.field)
        button(.pause) { edit(.pause(Int(pauseEnd.timeIntervalSince1970))) }
      }
    case .exclusions:
      ForEach(model.exclusions) { app in
        HStack(alignment: .firstTextBaseline) {
          Text(verbatim: app.alwaysExcluded ? "ActivityProbe" : apps.first(where: { $0.id == app.id })?.name ?? app.id).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 8)
          if app.alwaysExcluded { text(.always).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
          else { button(.remove) { edit(.removeApp(app.id)) }.accessibilityLabel(strings.text(.remove) + " " + app.id) }
        }
      }
      Menu {
        ForEach(apps.filter { candidate in !model.exclusions.contains(where: { $0.id == candidate.id }) }) { app in
          Button(app.name) { edit(.addApp(app.id)) }
        }
      } label: { text(.add) }
      .menuStyle(.borderlessButton).fixedSize()
      .disabled(apps.allSatisfy { app in model.exclusions.contains(where: { $0.id == app.id }) })
      .accessibilityLabel(strings.text(.chooseApp))
      button(.chooseBundle, chooseApp)
    case .retention:
      text(.retentionWarning).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      field(.screen, value: $draft.screen)
      field(.prompt, value: $draft.prompt)
      if draft.conflicting {
        if error != .retentionConflict { Text(verbatim: strings.text(.retentionConflict)).fixedSize(horizontal: false, vertical: true) }
        button(.reloadSaved) { draft = SettingsRetentionDraft(model.settings) }
      }
      button(.apply) { edit(draft.edit) }.disabled(draft.conflicting)
    case .dayStart:
      Stepper(value: Binding(get: { model.dayStartHour }, set: { edit(.dayStart($0)) }), in: 0...23) {
        Text(verbatim: strings.text(.hour) + ": " + String(format: "%02d:00", model.dayStartHour))
      }
    case .subscription:
      let row = ChatGPTRow(model: model, overview: chatGPT, isConnecting: isConnecting)
      text(row.headline).fontWeight(.medium)
      ForEach(row.notes, id: \.self) { text($0).fixedSize(horizontal: false, vertical: true) }
      text(.chatGPTPlan).fixedSize(horizontal: false, vertical: true)
      if row.offersManageUsage { button(.manageUsage, manageUsage) }
      if isConnecting {
        HStack { ProgressView().controlSize(.small); text(.chatGPTWaiting); Spacer(); button(.cancel, cancel) }
      } else {
        if row.offersContinue { ChatGPTButton(title: strings.text(.continueWithChatGPT), dark: scheme == .dark, action: connect) }
        if row.offersDifferentAccount { button(.differentAccount, connectDifferentAccount) }
        if row.offersSignOut { button(.signOut, disconnect) }
      }
      text(.chatGPTDeadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      text(.chatGPTStored).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    case .claude:
      if let claudeError { Text(verbatim: strings.text(claudeError)).fixedSize(horizontal: false, vertical: true) }
      text(.claudeLoginTitle).fontWeight(.medium)
      Text(verbatim: claudeLoginText).fixedSize(horizontal: false, vertical: true)
      button(.claudeRecheck, recheckClaude).disabled(isCheckingClaude)
      if claudeFolderUncertain { text(.claudeFolderUncertain).fixedSize(horizontal: false, vertical: true) }
      button(claudeLogin == .loggedIn ? .claudeOtherAccount : .claudeTerminalLogin, openClaudeLogin)
      text(claudeLogin == .loggedIn ? .claudeMacLoginNote : .claudeTerminalNote)
        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      text(.claudeAppUse).fontWeight(.medium).padding(.top, 8)
      text(claudeUseState)
      let summaries = ClaudeSummaryRow(model: model)
      if summaries.showsProblem { text(.problem) }
      ForEach(summaries.notes, id: \.self) { text($0).fixedSize(horizontal: false, vertical: true) }
      text(.consent).fixedSize(horizontal: false, vertical: true)
      if isClaudeConnecting {
        HStack { ProgressView().controlSize(.small); text(.connecting); Spacer(); button(.cancel, cancelClaude) }
      } else if model.settings.claudeConnected { button(claudeUseAction, disconnectClaude) }
      else { button(claudeUseAction, connectClaude) }
      text(.claudeAppUseNote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    case .conversation:
      Toggle(strings.text(key: ChatLabel.skipToggle.rawValue), isOn: Binding(get: { model.chatSkipApprovals }, set: skipApprovals)).toggleStyle(.checkbox)
      Text(verbatim: strings.text(key: ChatLabel.risk.rawValue)).fixedSize(horizontal: false, vertical: true)
    case .permissions:
      ForEach(TimelinePermission.allCases, id: \.rawValue) { permission in
        VStack(alignment: .leading, spacing: 4) {
          let label: SettingsLabel = permission == .accessibility ? .accessibility : permission == .inputMonitoring ? .inputMonitoring : .screenRecording
          text(label).fontWeight(.medium)
          text(model.health.missingPermissions.contains(permission) ? .missing : .granted)
          if model.health.missingPermissions.contains(permission) {
            systemButton(SettingsSystemTarget(rawValue: permission.rawValue)!)
          }
        }
      }
    case .security:
      text(.fileVault).fontWeight(.medium)
      text(model.health.security.fileVault == .on ? .on : model.health.security.fileVault == .off ? .off : .unknown)
      if model.health.security.fileVault == .off { systemButton(.fileVault) }
      text(backupLabel).fontWeight(.medium)
      text(backupWarning).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      if model.health.security.backupExclusionFailure == .backupExclusionFailed { button(.retryBackup, retryBackup) }
      if model.health.security.backupExclusionFailure == .backupExclusionSkippedOverride {
        text(.backupOverrideReason).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
    }
  }
  /// The scroll view's own space, so the Claude section's frame says whether it is on screen.
  static let scrollSpace = "settings-scroll"
  static func claudeSectionVisible(_ frame: CGRect, viewport: CGFloat) -> Bool {
    !frame.isEmpty && frame.maxY > 0 && frame.minY < viewport
  }
  var claudeLoginLabel: SettingsLabel {
    if isCheckingClaude && claudeLogin == nil { return .claudeChecking }
    switch claudeLogin {
    case .loggedIn: return .claudeLoggedIn
    case .loggedOut: return .claudeLoggedOut
    case .notInstalled: return .claudeNotInstalled
    case .unknown: return .claudeUnknown
    case nil: return .claudeChecking
    }
  }
  var claudeUseState: SettingsLabel { model.settings.claudeConnected ? .on : .off }
  var claudeUseAction: SettingsLabel { model.settings.claudeConnected ? .claudeTurnOff : .claudeTurnOn }
  var claudeLoginText: String {
    guard claudeLogin == .loggedIn, let account = claudeAccount else { return strings.text(claudeLoginLabel) }
    switch (account.email, account.plan) {
    case let (email?, plan?): return String(format: strings.text(.claudeAccountPlan), email, plan)
    case let (email?, nil): return String(format: strings.text(.claudeAccountOnly), email)
    case let (nil, plan?): return String(format: strings.text(.claudePlanOnly), plan)
    case (nil, nil): return strings.text(.claudeLoggedIn)
    }
  }
  var backupWarning: SettingsLabel {
    model.health.security.backupExclusionFailure == nil ? .backupWarning : .backupUnconfirmed
  }
  private var backupLabel: SettingsLabel {
    switch model.health.security.backupExclusionFailure {
    case nil: return .backup
    case .backupExclusionFailed: return .backupFailed
    case .backupExclusionSkippedOverride: return .backupSkipped
    }
  }
  private func field(_ label: SettingsLabel, value: Binding<String>) -> some View {
    HStack {
      text(label).fixedSize(horizontal: false, vertical: true)
      Spacer()
      TextField(strings.text(label), text: value).labelsHidden().multilineTextAlignment(.trailing)
        .textFieldStyle(.roundedBorder).frame(width: 78)
    }
  }
}
/// "Continue with ChatGPT" on black, or on white in dark mode, as the approved formats offer.
/// Text only: the docs ask for approved OpenAI assets but publish no logo file or terms for bundling it.
/// The one-time confirmation after plan use is first enabled (UI/UX guidelines: "You're using your ChatGPT plan" / "Got it").
public struct ChatGPTPlanWelcome: View {
  let strings: SettingsStrings
  let manageUsage: () -> Void
  let dismiss: () -> Void
  public init(strings: SettingsStrings, manageUsage: @escaping () -> Void = {}, dismiss: @escaping () -> Void = {}) {
    self.strings = strings; self.manageUsage = manageUsage; self.dismiss = dismiss
  }
  public var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(verbatim: strings.text(.planWelcomeTitle)).font(.system(size: 17, weight: .semibold)).accessibilityAddTraits(.isHeader)
      Text(verbatim: strings.text(.planWelcomeMessage)).fixedSize(horizontal: false, vertical: true)
      HStack {
        Button(action: manageUsage) { Text(verbatim: strings.text(.manageUsage)).underline() }.buttonStyle(.plain)
        Spacer()
        Button(action: dismiss) { Text(verbatim: strings.text(.gotIt)) }.keyboardShortcut(.defaultAction)
      }
    }.padding(24).frame(width: 380).font(.system(size: 13))
  }
}
struct ChatGPTButton: View {
  let title: String
  let dark: Bool
  let action: () -> Void
  var body: some View {
    Button(action: action) {
      Text(verbatim: title).font(.system(size: 13, weight: .semibold)).foregroundStyle(dark ? Color.black : Color.white)
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 999).fill(dark ? Color.white : Color.black))
    }.buttonStyle(.plain).padding(.vertical, 4)
  }
}
public struct SettingsView: View {
  @Environment(\.scenePhase) private var scenePhase
  @ObservedObject private var controller: SettingsController
  private let strings: SettingsStrings
  private let system: SettingsSystemActions
  private let appCatalog: SettingsAppCatalog
  private let appChooser: SettingsAppChooser
  private let backupActions: SettingsBackupActions
  /// Opens ChatGPT's usage settings in the person's browser; only ever on their click.
  private let manageUsage: () -> Void
  /// Pass the host's retained forDatabase controller after updating its health and notice destination.
  public init(controller: SettingsController, strings: SettingsStrings, system: SettingsSystemActions, appCatalog: SettingsAppCatalog,
    appChooser: SettingsAppChooser = MacSettingsAppChooser(), backupActions: SettingsBackupActions,
    manageUsage: @escaping () -> Void = { NSWorkspace.shared.open(AppPaths.chatGPTUsageSettings) }) {
    self.manageUsage = manageUsage
    self.controller = controller; self.appChooser = appChooser; self.backupActions = backupActions; self.strings = strings; self.system = system; self.appCatalog = appCatalog
  }
  public var body: some View {
    GeometryReader { geometry in
      ScrollViewReader { proxy in
        ScrollView {
          SettingsPage(model: controller.model, strings: strings, width: geometry.size.width, apps: controller.apps,
            error: controller.error, errorSection: controller.errorSection, isConnecting: controller.isConnecting,
            isClaudeConnecting: controller.isClaudeConnecting, claudeError: controller.claudeError,
            claudeLogin: controller.claudeLogin, isCheckingClaude: controller.isCheckingClaude,
            claudeFolderUncertain: controller.claudeFolderUncertain,
            claudeAccount: controller.claudeAccount,
            openClaudeLogin: { Task { await controller.openClaudeLogin() } },
            recheckClaude: { Task { await controller.refreshClaudeLogin() } },
            connectClaude: { Task { await controller.connectClaude() } }, disconnectClaude: controller.disconnectClaude,
            cancelClaude: controller.cancelClaudeConnection, skipApprovals: controller.setChatSkipApprovals, edit: controller.edit,
            connect: { Task { await controller.connect() } }, disconnect: { Task { await controller.signOut() } },
            cancel: controller.cancelConnection,
            chooseApp: { Task { await controller.chooseApp(using: appChooser) } },
            retryBackup: { controller.retryBackup(using: backupActions) }, system: system.open, chatGPT: controller.chatGPT,
            connectDifferentAccount: { Task { await controller.connectDifferentAccount() } }, manageUsage: manageUsage)
        }
        .sheet(isPresented: Binding(get: { controller.showsPlanWelcome },
          set: { if !$0 { Task { await controller.acknowledgePlanWelcome() } } })) {
          ChatGPTPlanWelcome(strings: strings, manageUsage: manageUsage, dismiss: { Task { await controller.acknowledgePlanWelcome() } })
        }
        .coordinateSpace(name: SettingsPage.scrollSpace)
        // The person's own Claude Code is asked only while its section is on screen.
        .onPreferenceChange(ClaudeSectionFrame.self) { [height = geometry.size.height] frame in
          let visible = SettingsPage.claudeSectionVisible(frame, viewport: height)
          Task { @MainActor in await controller.claudeSection(visible: visible) }
        }
        .onDisappear { Task { @MainActor in await controller.claudeSection(visible: false) } }
        .task { await controller.observe() }
        .task { await controller.refreshChatGPTStatus() }
        .task { await controller.loadApps(from: appCatalog) }
        // Back from Terminal: the person may have logged in there. Terminal's process is not observable here.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
          Task { await controller.appBecameActive() }
        }
        .onAppear { controller.refresh(); proxy.scrollTo(controller.section, anchor: .top) }
        .onChange(of: scenePhase) { _, phase in
          if phase == .active { controller.refresh(); Task { await controller.refreshChatGPTStatus() } }
        }
        .onChange(of: controller.validationRevision) { _, _ in
          if let message = controller.validationMessage { SettingsPage.announce(strings.text(message)) }
        }
        .onChange(of: controller.error) { _, error in if let error { SettingsPage.announce(strings.text(error)) } }
        .onChange(of: controller.claudeError) { _, error in if let error { SettingsPage.announce(strings.text(error)) } }
        .onChange(of: controller.section) { _, section in controller.refresh(); proxy.scrollTo(section, anchor: .top) }
      }
    }
  }
}
struct ClaudeSectionFrame: PreferenceKey {
  static var defaultValue = CGRect.zero
  static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
    let next = nextValue()
    if !next.isEmpty { value = next }
  }
}
public enum SettingsOffscreenRender {
  @MainActor public static func png(model: SettingsViewModel, strings: SettingsStrings, width: Double,
    dark: Bool, apps: [SettingsApp] = [], error: SettingsMessage? = nil,
    errorSection: SettingsSection = .subscription, draft: SettingsRetentionDraft? = nil, scale: Double = 2,
    chatGPT: ChatGPTAccountOverview = ChatGPTAccountOverview(), isConnecting: Bool = false,
    claudeAccount: ClaudeLoginSnapshot? = nil, claudeFolderUncertain: Bool = false) -> Data? {
    png(SettingsPage(model: model, strings: strings, width: width, apps: apps, error: error, errorSection: errorSection,
      isConnecting: isConnecting, claudeLogin: claudeAccount?.state, claudeFolderUncertain: claudeFolderUncertain,
      claudeAccount: claudeAccount, draft: draft, chatGPT: chatGPT), width: width, dark: dark, scale: scale)
  }
  /// The one-time plan confirmation, drawn the same way for review.
  @MainActor public static func planWelcomePNG(strings: SettingsStrings, dark: Bool, scale: Double = 2) -> Data? {
    png(ChatGPTPlanWelcome(strings: strings).background(TimelinePalette(dark: dark).paper), width: 380, dark: dark, scale: scale)
  }
  @MainActor static func png<V: View>(_ view: V, width: Double, dark: Bool, scale: Double) -> Data? {
    let content = view
      .environment(\.colorScheme, dark ? .dark : .light)
    // AppKit-backed fields cannot be drawn by ImageRenderer. A detached hosting view
    // draws the actual controls into a bitmap without constructing an NSWindow.
    let host = NSHostingView(rootView: content)
    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let height = host.fittingSize.height
    host.frame = NSRect(x: 0, y: 0, width: width, height: height)
    host.layoutSubtreeIfNeeded()
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale),
      pixelsHigh: Int(height * scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    bitmap.size = NSSize(width: width, height: height)
    host.cacheDisplay(in: host.bounds, to: bitmap)
    return bitmap.representation(using: .png, properties: [:])
  }
}
