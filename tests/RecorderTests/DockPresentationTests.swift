import AppKit
import Core
import Foundation
import XCTest
@testable import Shell

/// Records the policy and main menu calls instead of changing the real Dock or menu bar.
@MainActor private final class PolicyRecorder: ActivationPolicyTarget, MainMenuTarget {
  var events: [String]
  var mainMenu: NSMenu? { didSet { events.append("main menu") } }
  var windowsMenu: NSMenu? { didSet { events.append("windows menu") } }
  init(_ events: [String] = []) { self.events = events }
  func setActivationPolicy(_ activationPolicy: NSApplication.ActivationPolicy) -> Bool {
    events.append(activationPolicy == .regular ? "regular" : "other(\(activationPolicy.rawValue))"); return true
  }
}

final class DockPresentationTests: XCTestCase {
  // Ideal: only the window/menu process asks for the Dock; every other mode stays background.
  func testEveryModeHasOnePresentation() {
    let isolated = ["--isolated-root", "/tmp/ap-dock-tests/root", "--app-data", "/tmp/ap-dock-tests/root/data"]
    var window: [[String]] = [[], ["menu-bar"], ["reopen"], ["timeline"], ["agent-window"], ["settings"]]
    window += SettingsSection.allCases.map { ["settings", $0.rawValue] }
    for arguments in window {
      XCTAssertEqual(ProcessPresentation.mode(arguments: arguments), .dock, arguments.joined(separator: " "))
      XCTAssertEqual(ProcessPresentation.mode(arguments: arguments + isolated), .dock, arguments.joined(separator: " "))
      XCTAssertEqual(ProcessPresentation.mode(arguments: isolated + arguments), .dock, arguments.joined(separator: " "))
    }
    let background: [[String]] = [["collect"], ["collect"] + isolated, ["stop"], ["status"],
      ["privacy", "forget", "2026-01-01T00:00", "2026-01-01T01:00"], ["privacy", "mask"], ["privacy", "verdicts"],
      ["convert"], ["selftest"] + isolated, ["leaktest"] + isolated, ["launch-agent", "install"], ["launch-agent", "uninstall"],
      ["settings", "invented"], ["timeline", "extra"], ["menu-bar", "extra"], ["reopen", "extra"], ["invented"]]
    for arguments in background {
      XCTAssertEqual(ProcessPresentation.mode(arguments: arguments), .background, arguments.joined(separator: " "))
    }
  }
  // Ideal: background never even asks for the application object; the Dock mode asks once for regular.
  @MainActor func testBackgroundNeverTouchesTheApplication() {
    ProcessPresentation.background.apply(to: { XCTFail("Background must not create the application"); return PolicyRecorder() })
    let app = PolicyRecorder()
    ProcessPresentation.dock.apply(to: { app })
    XCTAssertEqual(app.events, ["regular"])
  }
  // Ideal: the Dock policy and main menu are set before the window and the status item, which come before the event loop.
  @MainActor func testPolicyPrecedesWindowAndStatusItem() {
    let strings = SettingsStrings(language: "en", resources: nil)
    let menu = AppMainMenu(strings: strings) { _ in XCTFail("Starting never opens through the menu") }
    let app = PolicyRecorder()
    XCTAssertEqual(AppWindowEntry.start(application: { app }, mainMenu: menu, target: .settings(.recording),
      show: { app.events.append("show \($0)"); return true }, install: { app.events.append("install") }, run: { app.events.append("run") }), 0)
    XCTAssertEqual(app.events, ["regular", "main menu", "windows menu", "show settings(Core.SettingsSection.recording)", "install", "run"])
    XCTAssertEqual(app.mainMenu?.items.count, 3)
    let menuOnly = PolicyRecorder()
    XCTAssertEqual(AppWindowEntry.start(application: { menuOnly }, mainMenu: menu, target: nil,
      show: { _ in XCTFail("A menu-only start opens no window"); return true },
      install: { menuOnly.events.append("install") }, run: { menuOnly.events.append("run") }), 0)
    XCTAssertEqual(menuOnly.events, ["regular", "main menu", "windows menu", "install", "run"])
    let refused = PolicyRecorder()
    XCTAssertEqual(AppWindowEntry.start(application: { refused }, mainMenu: menu, target: .timeline, show: { _ in false },
      install: { XCTFail("No status item after a refused window") }, run: { XCTFail("No event loop after a refused window") }), 1)
    XCTAssertEqual(refused.events, ["regular", "main menu", "windows menu"])
  }
  // Ideal: a Dock click brings an open window forward unchanged, and opens the timeline otherwise.
  @MainActor func testReopenRouting() {
    XCTAssertEqual(AppWindowReopen.route(windowOpen: true), .focus)
    XCTAssertEqual(AppWindowReopen.route(windowOpen: false), .open(.timeline))
    var creations = 0
    let host = AppWindowHost(strings: AppWindowStrings(language: "en", resources: nil)) {
      creations += 1; throw AppCommandError.arguments
    }
    host.reopen()
    XCTAssertEqual(creations, 1); XCTAssertNil(host.model)
  }
  // Ideal: the Dock's Quit ends only this process, and its cleanup runs exactly once.
  @MainActor func testQuitCleansUpOnce() {
    var runs = 0
    let host = AppWindowHost(strings: AppWindowStrings(language: "en", resources: nil)) { throw AppCommandError.arguments }
    host.terminating = { runs += 1 }
    host.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
    host.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
    XCTAssertEqual(runs, 1)
  }
  // Ideal: the recorder, the commands and the query helper never reach AppKit presentation.
  // Only the recorder's hidden event loop may hold the application object, and nothing else visible.
  func testBackgroundSourcesNeverReachPresentation() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    var files = ["Sources/Shell/ActivityProbeEntry.swift", "Sources/Shell/RecorderLifecycle.swift", "Sources/Shell/RecorderLoop.swift",
      "Sources/Shell/RecorderStartup.swift", "Sources/Shell/RecorderControl.swift", "Sources/Shell/RetainedCommands.swift",
      "Sources/Shell/ConversionCommand.swift", "Sources/Query/ActivityQueryServer.swift", "tools/activity-query-server/main.swift",
      "Sources/Shell/LaunchAgent.swift", "Sources/Shell/StorageCommandTests.swift", "Sources/Shell/SummaryTask.swift",
      "Sources/Shell/SecurityHealthTask.swift", "Sources/Shell/AgentLogTasks.swift", "Sources/Shell/CommandSupport.swift",
      "Sources/Shell/AppPaths.swift", "Sources/Shell/RecorderWindowLauncher.swift",
      "Sources/Outbound/AgentInstall.swift", "Sources/Outbound/UserShell.swift"]
    files += try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Sources/Inbound").path)
      .filter { $0.hasSuffix(".swift") }.map { "Sources/Inbound/" + $0 }
    let forbidden = ["NSApplication", "NSApp.", "NSApp ", "setActivationPolicy", "NSStatusBar", "NSStatusItem", "NSWindow", "NSMenu",
      "apply(to:", "AppWindowHost", "AppMainMenu", "MainMenuTarget", "mainMenu", "windowsMenu", "install(for:"]
    let eventLoop = "Sources/Shell/RecorderEventLoop.swift"
    let application = ["NSApplication", "NSApp.", "NSApp ", "setActivationPolicy"]
    for file in files + [eventLoop] {
      let source = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
      for name in forbidden where file != eventLoop || !application.contains(name) {
        XCTAssertFalse(source.contains(name), "\(file) mentions \(name)")
      }
    }
    let plist = try XCTUnwrap(NSDictionary(contentsOf: root.appendingPathComponent("Info.plist")))
    XCTAssertEqual(plist["LSUIElement"] as? Bool, true, "Every process starts hidden; only the window turns visible")
  }
}
