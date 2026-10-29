import AppKit
import ApplicationServices
import Core
import CoreGraphics
import Foundation
import Inbound
import Outbound
import Storage
import SwiftUI

/// Passive checks only. Permission requests and System Settings actions stay behind explicit clicks.
final class AppWindowHealthSource {
  private let security: SecurityHealthTask
  private let paths: AppPaths
  init(paths: AppPaths) {
    self.paths = paths
    security = SecurityHealthTask(fileVault: FileVaultReader(), storage: StorageSecurityHealth())
  }
  func read() -> TimelineHealth {
    let now = Int(Date().timeIntervalSince1970)
    try? security.maintenanceTask.run(now)
    var value = security.health
    if (try? FileLocation.same(paths.database.deletingLastPathComponent(), paths.appData)) != true {
      value.backupExclusionFailure = .backupExclusionSkippedOverride
    } else if (try? paths.appData.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup) != true {
      value.backupExclusionFailure = .backupExclusionFailed
    }
    var missing = Set<TimelinePermission>()
    if !AXIsProcessTrusted() { missing.insert(.accessibility) }
    if !CGPreflightListenEventAccess() { missing.insert(.inputMonitoring) }
    if !CGPreflightScreenCaptureAccess() { missing.insert(.screenRecording) }
    return TimelineHealth(missingPermissions: missing, security: value)
  }
}

/// One persistent Dock process owns the menu. The actual window/model is lazy and disposable.
/// Background menu requests never create a window, permission source, conversation or login client.
@MainActor final class AppWindowHost: NSObject, NSWindowDelegate, NSApplicationDelegate {
  private(set) var model: AppWindowModel?
  private var window: NSWindow?
  private let makeModel: () throws -> (AppWindowModel, ActivityStorage)
  private let strings: AppWindowStrings
  /// Runs once when the Dock's Quit ends the process, since `terminate` never returns to the caller.
  var terminating: (() -> Void)?
  init(strings: AppWindowStrings, makeModel: @escaping () throws -> (AppWindowModel, ActivityStorage)) {
    self.strings = strings; self.makeModel = makeModel
  }
  @discardableResult func show(_ target: AppWindowTarget) -> Bool {
    if window == nil {
      do {
        let (model, backup) = try makeModel()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 780),
          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        self.model = model; self.window = window
        window.isReleasedWhenClosed = false; window.delegate = self
        window.title = "ActivityProbe"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: AppWindowLayout.minimumWidth, height: 480)
        window.contentView = NSHostingView(rootView: AppWindowView(model: model, strings: strings, backup: backup))
        window.center()
      } catch { return false }
    }
    guard let model, let window else { return false }
    model.navigate(target); model.startConversationObservation()
    bringForward(window)
    return true
  }
  func reopen() {
    switch AppWindowReopen.route(windowOpen: window != nil) {
    case .focus: if let window { bringForward(window) }
    case .open(let target): show(target)
    }
  }
  private func bringForward(_ window: NSWindow) {
    if window.isMiniaturized { window.deminiaturize(nil) }
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
  func windowWillClose(_ notification: Notification) {
    model?.close(); model = nil
    window?.contentView = nil; window = nil
    // The menu and channel keep running so an off recorder remains visible and reopenable.
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    reopen(); return false
  }
  // Only this process quits. The recorder is a separate process that the Dock never sees.
  func applicationWillTerminate(_ notification: Notification) {
    let terminating = terminating; self.terminating = nil; terminating?()
  }
}

public enum AppWindowEntry {
  /// No recorder is constructed here. A delivered request exits before settings or UI composition,
  /// and before the application is asked for.
  /// `reopen` asks a running window process for a Dock click's answer; a first launch opens `target`.
  public static func run(paths: AppPaths, target: AppWindowTarget?, reopen: Bool = false, codex: AgentExecutable, claude: AgentExecutable, environment: [String: String] = [:], isolated: Bool = false,
    application: @MainActor () -> NSApplication? = { NSApplication.shared }) -> Int32 {
    guard Thread.isMainThread else { return 2 }
    return MainActor.assumeIsolated {
      guard let socket = try? AppWindowChannel.prepareSocket(paths: paths) else { return 1 }
      let channel = AppWindowChannel(socket: socket)
      var host: AppWindowHost?
      let line = reopen ? AppWindowReopen.line : target?.line ?? "menu-bar"
      switch channel.claim(sending: line, receive: { receive($0, host: host) }) {
      case .delivered: return 0
      case .unavailable: return 1
      case .owner: break
      }
      defer { channel.close() }
      guard let app = application() else { return 1 }
      // The person's shell is asked off the main thread now, so Connect and the catalog rarely wait for it.
      DispatchQueue.global(qos: .utility).async { _ = codex.resolve(); _ = claude.resolve() }
      let strings = AppWindowStrings(language: AppWindowStrings.preferredLanguage())
      var resume = RecorderResumeRequest()
      let statusReader = ChatGPTStatusReader(account: AppComposition(paths: paths).factories.chatGPT(paths))
      host = AppWindowHost(strings: strings) {
        try AgentDirectories.prepare(appData: paths.appData, ownedDirectories: [paths.appData])
        let source = AppWindowHealthSource(paths: paths)
        let (model, edits) = try AppComposition(paths: paths).windowModel(codex: codex, claude: claude, health: source.read, statusReader: statusReader)
        model.settings.recordingEnabledByUser = { resume.request() }
        return (model, edits)
      }
      let menu = RecorderMenuController(snapshot: {
        let settings = try? AppComposition(paths: paths).queryStorage().settings()
        let running = (try? RecorderControl().isRunning(paths: paths)) ?? false
        if let settings {
          try? resume.update(enabled: settings.recordingEnabled, running: running, now: ProcessInfo.processInfo.systemUptime) {
            try RecorderWindowLauncher.resumeRecorder(paths: paths, isolated: isolated, environment: environment)
          }
        }
        return RecorderMenuSnapshot(settings: settings, running: running, now: Int(Date().timeIntervalSince1970))
      }, open: { target in host?.show(target) })
      app.delegate = host
      var finished = false
      let finish = {
        guard !finished else { return }
        finished = true; menu.remove(); host?.model?.close(); channel.close()
      }
      host?.terminating = finish
      let mainMenu = AppMainMenu(strings: SettingsStrings(language: strings.language, resources: strings.resources)) { host?.show($0) }
      let status = start(application: { app }, mainMenu: mainMenu, target: target, show: { host?.show($0) == true }, install: menu.install) {
        withExtendedLifetime((host, menu, mainMenu)) { app.run() }
      }
      finish(); app.delegate = nil; host = nil
      return status
    }
  }
  /// Lines from later launches. The bare menu line opens nothing.
  @MainActor static func receive(_ line: String, host: AppWindowHost?) {
    if line == AppWindowReopen.line { host?.reopen() }
    else if let target = AppWindowTarget(line: line) { host?.show(target) }
  }
  /// The Dock policy and the main menu are set before the first window or status item exists.
  @MainActor static func start(application: () -> ActivationPolicyTarget & MainMenuTarget, mainMenu: AppMainMenu,
    target: AppWindowTarget?, show: (AppWindowTarget) -> Bool, install: () -> Void, run: () -> Void) -> Int32 {
    ProcessPresentation.dock.apply(to: application)
    mainMenu.install(for: .dock, on: application)
    if let target, !show(target) { return 1 }
    install(); run(); return 0
  }
}
