import AppKit
import Core
import Darwin
import Foundation
@testable import Outbound
import XCTest
@testable import Shell
@testable import Storage

final class MenuAndLaunchTests: XCTestCase {
  // Ideal: a recorder for one database never marks another database active or delays its controls.
  func testSharedAppDataKeepsRecorderStateAndWaitingPerDatabase() throws {
    let root = URL(fileURLWithPath: "/tmp/ap-menu-launch-tests").appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    func paths(_ leaf: String) -> AppPaths {
      AppPaths(userHome: root, appData: root, database: root.appendingPathComponent(leaf),
        appBinary: root.appendingPathComponent("ActivityProbe"), queryHelper: root.appendingPathComponent("helper"))
    }
    let active = paths("first.sqlite"), inactive = paths("second.sqlite")
    let owner = try RecorderStartupGuard(paths: active)
    let recorder = try ActivityStorage(url: active.database, appDataDirectory: root, role: .recorder, databaseScope: active.databaseScope, recorderLock: owner.recorderLock)
    let other = try ActivityStorage(url: inactive.database, appDataDirectory: root, databaseScope: inactive.databaseScope)
    let control = RecorderControl(wait: { XCTFail("Unrelated recorder must not delay stop") }, uptime: { 0 }, timeout: 0)
    XCTAssertTrue(try control.isRunning(paths: active))
    let running = try control.isRunning(paths: inactive)
    XCTAssertFalse(running)
    XCTAssertEqual(RecorderMenuSnapshot(settings: try other.settings(), running: running, now: 100).state, .off)
    var resume = RecorderResumeRequest(), starts = 0
    resume.request(); resume.update(enabled: true, running: running, now: 100) { starts += 1 }
    XCTAssertEqual(starts, 1)
    XCTAssertEqual(try control.stop(paths: inactive).status, 0)
    XCTAssertTrue(try recorder.settings().recordingEnabled)
    withExtendedLifetime((owner, recorder)) {}
  }
  // Ideal: uninstall unloads by label without a plist, and removes a plist when already unloaded.
  func testUninstallReconcilesBothPartialStates() throws {
    let root = URL(fileURLWithPath: "/tmp/ap-menu-launch-tests").appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var calls: [[String]] = []
    XCTAssertEqual(LaunchAgentCommand.run(["uninstall", "--live-switch"], userHome: root, service: {
      calls.append($0); return .init(0)
    }).status, 0)
    XCTAssertEqual(calls.first, ["bootout", "gui/\(getuid())/\(RecorderLaunchAgent.label)"])
    let file = root.appendingPathComponent("Library/LaunchAgents/\(RecorderLaunchAgent.label).plist")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("invented plist".utf8).write(to: file)
    XCTAssertEqual(LaunchAgentCommand.run(["uninstall", "--live-switch"], userHome: root, service: {
      calls.append($0); return .init($0[0] == "bootout" ? 3 : 113,
        error: "Bad request.\nCould not find service \"\(RecorderLaunchAgent.label)\" in domain for user gui: \(getuid())\n")
    }).status, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
  }
  // Ideal: either install partial state converges to a matching plist and one loaded job.
  func testInstallReconcilesBothPartialStates() throws {
    let absent = "Could not find service \"\(RecorderLaunchAgent.label)\" in domain for user gui: \(getuid())"
    // The two-line form is what launchctl print writes on macOS when the job is not loaded.
    for (hasPlist, printError) in [(false, absent + "\n"), (true, absent + "\n"), (true, "Bad request.\n" + absent + "\n")] {
      let root = URL(fileURLWithPath: "/tmp/ap-menu-launch-tests").appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      let file = root.appendingPathComponent("Library/LaunchAgents/\(RecorderLaunchAgent.label).plist")
      if hasPlist {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("invented old plist".utf8).write(to: file)
      }
      var loaded = !hasPlist, calls: [String] = []
      let result = LaunchAgentCommand.run(["install", "/invented/new/ActivityProbe", "--live-switch"], userHome: root, service: { args in
        calls.append(args[0])
        switch args[0] {
        case "bootout":
          XCTAssertEqual(args, ["bootout", "gui/\(getuid())/\(RecorderLaunchAgent.label)"])
          guard loaded else { return .init(3, error: "Boot-out failed: 3: No such process\n") }
          loaded = false; return .init(0)
        case "print":
          XCTAssertEqual(args, ["print", "gui/\(getuid())/\(RecorderLaunchAgent.label)"])
          XCTAssertFalse(loaded)
          return .init(113, error: printError)
        case "bootstrap":
          XCTAssertEqual(args, ["bootstrap", "gui/\(getuid())", file.path])
          XCTAssertFalse(loaded); loaded = true; return .init(0)
        default: XCTFail("Unexpected service operation"); return .init(1)
        }
      }, pause: { _ in XCTFail("An absent job needs no wait") })
      XCTAssertEqual(result.status, 0); XCTAssertTrue(loaded)
      XCTAssertEqual(calls, ["bootout", "print", "bootstrap"])
      XCTAssertEqual(try Data(contentsOf: file), try RecorderLaunchAgent.propertyList(executable: URL(fileURLWithPath: "/invented/new/ActivityProbe")))
    }
  }
  // Ideal: an arbitrary nonzero result never proves absence or permits changing an existing plist.
  func testServiceFailuresPreservePlistForInstallAndUninstall() throws {
    let root = URL(fileURLWithPath: "/tmp/ap-menu-launch-tests").appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("Library/LaunchAgents/\(RecorderLaunchAgent.label).plist")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let original = Data("invented existing plist".utf8)
    try original.write(to: file)
    let absent = "Could not find service \"\(RecorderLaunchAgent.label)\" in domain for user gui: \(getuid())"
    for args in [["uninstall", "--live-switch"], ["install", "/invented/ActivityProbe", "--live-switch"]] {
      for failure in [LaunchAgentServiceResult(3), .init(1, error: "Operation not permitted"),
        .init(0, error: absent), .init(113, error: absent + " extra"),
        .init(113, error: absent.replacingOccurrences(of: RecorderLaunchAgent.label, with: "invented.other")),
        .init(0, error: "Bad request.\n" + absent), .init(113, error: "Bad request."),
        .init(113, error: "Bad request.\n" + absent.replacingOccurrences(of: RecorderLaunchAgent.label, with: "invented.other")),
        .init(113, error: "Bad request.\n" + absent + "\ninvented extra line"),
        .init(113, error: "Bad request.\nBad request.\n" + absent), .init(113, error: absent + "\n" + absent),
        .init(113, error: "Bad request.\n\n" + absent)] {
        var calls: [String] = []
        let result = LaunchAgentCommand.run(args, userHome: root) { operation in
          calls.append(operation[0]); return operation[0] == "bootout" ? .init(3) : failure
        }
        XCTAssertEqual(result.status, 1); XCTAssertEqual(calls, ["bootout", "print"])
        XCTAssertEqual(try Data(contentsOf: file), original)
      }
    }
  }
  // Ideal: startup and storage share one database lock without a gap, including after guard release.
  func testRecorderLockSpansStartupStorageAndDrain() throws {
    let root = URL(fileURLWithPath: "/tmp/ap-menu-launch-tests").appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = AppPaths(userHome: root, appData: root, database: root.appendingPathComponent("invented.sqlite"),
      appBinary: root.appendingPathComponent("ActivityProbe"), queryHelper: root.appendingPathComponent("helper"))
    var owner: RecorderStartupGuard? = try RecorderStartupGuard(paths: paths)
    XCTAssertTrue(try RecorderControl().isRunning(paths: paths))
    var store: ActivityStorage? = try AppFactories().storage(paths, .recorder, owner!.recorderLock)
    owner = nil
    XCTAssertTrue(try RecorderControl().isRunning(paths: paths))
    XCTAssertThrowsError(try RecorderStartupGuard(paths: paths))
    let different = try RecorderDatabaseLock(database: root.appendingPathComponent("different.sqlite"), scope: paths.databaseScope)
    XCTAssertThrowsError(try ActivityStorage(url: paths.database, appDataDirectory: root,
      role: .recorder, databaseScope: paths.databaseScope, recorderLock: different))
    withExtendedLifetime(store) {}
    store = nil
    XCTAssertFalse(try RecorderControl().isRunning(paths: paths))
  }
  func testStopBeforeFirstStartupCreatesOnlyItsInventedAppData() throws {
    let root = URL(fileURLWithPath: "/tmp/ap-menu-launch-tests").appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let data = root.appendingPathComponent("data")
    let paths = AppPaths(userHome: root, appData: data, database: data.appendingPathComponent("invented.sqlite"),
      appBinary: root.appendingPathComponent("ActivityProbe"), queryHelper: root.appendingPathComponent("helper"))
    XCTAssertEqual(try RecorderControl(wait: { XCTFail("No recorder to drain") }).stop(paths: paths).status, 0)
    XCTAssertFalse(try ActivityStorage(url: paths.database, appDataDirectory: data,
      readOnly: true, databaseScope: paths.databaseScope).settings().recordingEnabled)
  }
  // Ideal: settings and actual recorder/session status decide the icon, never stale UI state.
  func testStateIncludesStoppedPausedBoundaryAndSuspendedSession() {
    var settings = StorageSettings()
    XCTAssertEqual(RecorderMenuSnapshot(settings: settings, running: true, now: 100).state, .recording)
    settings.pausedUntil = 101
    XCTAssertEqual(RecorderMenuSnapshot(settings: settings, running: true, now: 100).state, .paused)
    XCTAssertEqual(RecorderMenuSnapshot(settings: settings, running: true, now: 101).state, .recording)
    XCTAssertEqual(RecorderMenuSnapshot(settings: settings, running: true, suspended: true, now: 101).state, .paused)
    settings.recordingEnabled = false
    XCTAssertEqual(RecorderMenuSnapshot(settings: settings, running: true, now: 100).state, .off)
    XCTAssertEqual(RecorderMenuSnapshot(settings: StorageSettings(), running: false, now: 100).state, .off)
    XCTAssertEqual(RecorderMenuSnapshot(settings: nil, running: true, now: 100).state, .off)
  }
  // Ideal: exactly three native lines and two explicit actions; creating a menu never launches UI.
  @MainActor func testThreeNativeLinesAndAccessibilityInEveryState() {
    var opened: [AppWindowTarget] = []
    let controller = RecorderMenuController(snapshot: { .init(state: .recording) }, open: { opened.append($0) })
    for state in RecorderMenuState.allCases {
      let menu = controller.makeMenu(.init(state: state))
      XCTAssertEqual(menu.items.map(\.title), [state.key, "Open window", "Settings"])
      XCTAssertFalse(menu.items[0].isEnabled)
      XCTAssertNil(menu.items[0].action)
      XCTAssertEqual(menu.items.map { $0.accessibilityLabel() }, menu.items.map(\.title))
      XCTAssertEqual(menu.items.filter { $0.action != nil }.count, 2)
      XCTAssertEqual(RecorderMenuDrawing.icon(state).size, NSSize(width: 18, height: 18))
      XCTAssertTrue(RecorderMenuDrawing.icon(state).isTemplate)
    }
    XCTAssertTrue(opened.isEmpty)
    let menu = controller.makeMenu(.init(state: .recording))
    for item in menu.items.dropFirst() { _ = controller.perform(item.action, with: item) }
    XCTAssertEqual(opened, [.timeline, .settings(.recording)])
    XCTAssertEqual(RecorderWindowLauncher.arguments(target: .timeline), ["timeline"])
    XCTAssertEqual(RecorderWindowLauncher.arguments(target: .settings(.recording)), ["settings", "recording"])
  }
  // Ideal: every menu state/action has a deliberate translation in all supported languages.
  func testMenuTranslationsAndUnsupportedFormReason() throws {
    let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Resources/Localizable.xcstrings")
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    let catalog = try XCTUnwrap(object["strings"] as? [String: [String: Any]])
    for key in ["Recording activity", "Paused", "Off", "Open window", "Settings", ChatLabel.fieldsUnavailable.rawValue] {
      let entry = try XCTUnwrap(catalog[key]); XCTAssertEqual(entry["extractionState"] as? String, "manual")
      let translations = try XCTUnwrap(entry["localizations"] as? [String: [String: Any]])
      for language in ["ko", "ja", "zh-Hans", "zh-Hant", "de", "fr", "es", "ru"] {
        let text = (translations[language]?["stringUnit"] as? [String: String])?["value"]
        XCTAssertFalse(try XCTUnwrap(text, key + language).isEmpty)
      }
    }
    XCTAssertEqual(ChatLabel.fieldsUnavailable.rawValue, "Unsupported form request. The request was declined.")
  }
  // Ideal: a menu-only host does not construct a real window or any of its adapters.
  @MainActor func testBackgroundHostIsLazyAndClosePreservesOwner() {
    var creations = 0
    let host = AppWindowHost(strings: AppWindowStrings(language: "en", resources: nil)) {
      creations += 1; throw AppCommandError.arguments
    }
    XCTAssertEqual(creations, 0); XCTAssertNil(host.model)
    host.windowWillClose(Notification(name: NSWindow.willCloseNotification))
    XCTAssertEqual(creations, 0); XCTAssertNil(host.model)
    XCTAssertEqual(RecorderWindowLauncher.arguments(target: nil), ["menu-bar"])
  }
  // Ideal: enabling during an old stop waits for the recorder lock; another stop cancels it.
  func testExplicitEnableWaitsForStopAndRetriesOnlyAfterThirtySeconds() throws {
    var request = RecorderResumeRequest(), starts = 0
    request.request()
    request.update(enabled: true, running: true, now: 100) { starts += 1 }
    XCTAssertTrue(request.pending); XCTAssertEqual(starts, 0)
    request.update(enabled: true, running: false, now: 101) { starts += 1 }
    XCTAssertFalse(request.pending); XCTAssertEqual(starts, 1)
    request.update(enabled: true, running: false, now: 102) { starts += 1 }
    XCTAssertEqual(starts, 1)
    request.request()
    XCTAssertThrowsError(try request.update(enabled: true, running: false, now: 103) { throw AppCommandError.recorder })
    request.update(enabled: true, running: false, now: 132) { starts += 1 }
    XCTAssertEqual(starts, 1)
    request.update(enabled: true, running: false, now: 133) { starts += 1 }
    XCTAssertEqual(starts, 2)
    request.request(); request.update(enabled: false, running: false, now: 200) { starts += 1 }
    XCTAssertFalse(request.pending); XCTAssertEqual(starts, 2)
  }
  // Ideal: explicit enable wakes the registered supervisor; isolated enable never contacts it.
  func testResumeKeepsSupervisorAndIsolation() throws {
    let root = URL(fileURLWithPath: "/tmp/ap-menu-launch-tests/invented")
    let paths = AppPaths(userHome: root, appData: root, database: root.appendingPathComponent("activity.sqlite"), appBinary: root.appendingPathComponent("ActivityProbe"), queryHelper: root.appendingPathComponent("helper"))
    var calls: [[String]] = [], starts: [[String]] = []
    try RecorderWindowLauncher.resumeRecorder(paths: paths, isolated: false, environment: [:],
      service: { calls.append($0); return 0 }, start: { arguments, _ in starts.append(arguments) })
    XCTAssertEqual(calls, [["kickstart", "gui/\(getuid())/" + RecorderLaunchAgent.label]])
    XCTAssertTrue(starts.isEmpty)
    try RecorderWindowLauncher.resumeRecorder(paths: paths, isolated: true, environment: [:],
      service: { _ in XCTFail("Isolated mode must not call launchctl"); return 0 }, start: { arguments, _ in starts.append(arguments) })
    XCTAssertEqual(starts.count, 1); XCTAssertEqual(starts[0][1], "--isolated-root")
    try RecorderWindowLauncher.resumeRecorder(paths: paths, isolated: false, environment: [:],
      service: { _ in 3 }, start: { arguments, _ in starts.append(arguments) })
    XCTAssertEqual(starts.last, ["collect"])
    let overridden = AppPaths(userHome: root, appData: root, database: root.appendingPathComponent("override.sqlite"), appBinary: paths.appBinary, queryHelper: paths.queryHelper)
    try RecorderWindowLauncher.resumeRecorder(paths: overridden, isolated: false, environment: [:],
      service: { _ in XCTFail("A DB override must not wake the default database's job"); return 0 }, start: { arguments, _ in starts.append(arguments) })
    XCTAssertEqual(starts.count, 3)

  }
  // Ideal: the menu process survives its launcher's group, and an override pins its exact DB.
  func testDetachedLaunchUsesOwnGroupAndPinnedEnvironment() throws {
    let root = URL(fileURLWithPath: "/tmp/ap-menu-launch-tests").appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let script = root.appendingPathComponent("invented-launch.py"), marker = root.appendingPathComponent("marker.json")
    try """
    #!/usr/bin/python3
    import json, os, sys
    with open(sys.argv[1] + '.partial', 'w') as f:
        json.dump({'pid':os.getpid(), 'group':os.getpgrp(), 'db':os.environ.get('ACTIVITYPROBE_DB'), 'args':sys.argv[2:]}, f)
    os.rename(sys.argv[1] + '.partial', sys.argv[1])
    """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    let paths = AppPaths(userHome: root, appData: root, database: root.appendingPathComponent("invented.sqlite"), appBinary: script, queryHelper: script)
    try RecorderWindowLauncher.launch(paths: paths, arguments: [marker.path, "menu-bar"], environment: ["ACTIVITYPROBE_DB": "wrong"])
    // The script renames a finished file into place, so existence means the whole marker is there.
    let deadline = ProcessInfo.processInfo.systemUptime + 5
    while !FileManager.default.fileExists(atPath: marker.path), ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.01) }
    let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as? [String: Any])
    XCTAssertEqual(result["pid"] as? Int, result["group"] as? Int)
    XCTAssertNotEqual(result["group"] as? Int, Int(getpgrp()))
    XCTAssertEqual(result["db"] as? String, paths.database.path)
    XCTAssertEqual(result["args"] as? [String], ["menu-bar"])
    // Summaries run no CLI, so a recorder is told only its folders.
    XCTAssertEqual(try RecorderWindowLauncher.recorderLaunch(paths: paths, isolated: true),
      ["collect", "--isolated-root", root.path, "--app-data", root.path])
    XCTAssertEqual(try RecorderWindowLauncher.recorderLaunch(paths: paths, isolated: false), ["collect"])
  }
  // Ideal: an isolated resume looks nothing up: it starts at once with the environment as given.
  func testIsolatedResumeStartsWithoutAnAgentLookup() throws {
    let root = URL(fileURLWithPath: "/tmp/ap-menu-launch-tests/invented")
    let paths = AppPaths(userHome: root, appData: root, database: root.appendingPathComponent("activity.sqlite"), appBinary: root.appendingPathComponent("ActivityProbe"), queryHelper: root.appendingPathComponent("helper"))
    var launched: (arguments: [String], environment: [String: String])?
    try RecorderWindowLauncher.resumeRecorder(paths: paths, isolated: true,
      environment: ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"], service: { _ in XCTFail("Isolated mode must not call launchctl"); return 0 },
      start: { launched = ($0, $1) })
    XCTAssertEqual(launched?.arguments, ["collect", "--isolated-root", root.path, "--app-data", root.path])
    XCTAssertEqual(launched?.environment, ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"])
  }
  // Ideal: login starts once; a crash restarts; a deliberate stop persists across the next login.
  func testGeneratedPlistAndFakeSupervisorWithCleanStop() throws {
    let root = URL(fileURLWithPath: "/tmp/ap-menu-launch-tests").appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = AppPaths(userHome: root, appData: root, database: root.appendingPathComponent("invented.sqlite"),
      appBinary: root.appendingPathComponent("Space & invented/ActivityProbe"), queryHelper: root.appendingPathComponent("helper"))
    let data = try RecorderLaunchAgent.propertyList(executable: paths.appBinary)
    let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    XCTAssertEqual(plist["Label"] as? String, "dev.local.ActivityProbe.recorder")
    XCTAssertEqual(plist["ProgramArguments"] as? [String], [paths.appBinary.path, "collect"])
    XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
    XCTAssertEqual(plist["KeepAlive"] as? [String: Bool], ["SuccessfulExit": false])
    XCTAssertEqual(plist["ThrottleInterval"] as? Int, 30)
    XCTAssertEqual(plist["ExitTimeOut"] as? Int, 60)
    XCTAssertEqual(TimeInterval(RecorderLaunchAgent.exitTimeOut), RecorderControl().timeout)
    XCTAssertNil(plist["StartInterval"])
    XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("healthcheck"))
    XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("--isolated-root"))
    let store = try ActivityStorage(url: paths.database, appDataDirectory: root, databaseScope: paths.databaseScope)
    let supervisor = try FakeSupervisor(plist: plist)
    var attempts = 0
    let crashes = try supervisor.login {
      attempts += 1
      if attempts == 1 { return 9 }
      XCTAssertEqual(try RecorderControl().stop(paths: paths).status, 0)
      return 0
    }
    XCTAssertEqual(crashes, 1)
    XCTAssertEqual(attempts, 2)
    XCTAssertFalse(try store.settings().recordingEnabled)
    var restartsAfterLogin = 0
    XCTAssertEqual(try supervisor.login {
      restartsAfterLogin += 1
      return try store.settings().recordingEnabled ? 7 : 0
    }, 0)
    XCTAssertEqual(restartsAfterLogin, 1)
  }
  // Ideal: unapproved install/uninstall do not inspect a home or call the service manager.
  func testLaunchAgentGatesAndInventedInstallUninstall() throws {
    let root = URL(fileURLWithPath: "/tmp/ap-menu-launch-tests").appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var calls: [[String]] = []
    let absent = "Could not find service \"\(RecorderLaunchAgent.label)\" in domain for user gui: \(getuid())"
    let service: ([String]) throws -> LaunchAgentServiceResult = {
      calls.append($0); return $0[0] == "print" ? .init(113, error: absent) : .init(0)
    }
    for args in [["install", "/invented/ActivityProbe"], ["uninstall"]] {
      XCTAssertEqual(LaunchAgentCommand.run(args, userHome: root, service: service).output, "live_switch_required")
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.path)); XCTAssertTrue(calls.isEmpty)
    let printed = LaunchAgentCommand.run(["print", "/invented/ActivityProbe"], userHome: root, service: service)
    XCTAssertEqual(printed.status, 0); XCTAssertTrue(calls.isEmpty)
    XCTAssertEqual(LaunchAgentCommand.run(["install", "/invented/ActivityProbe", "--live-switch"], userHome: root, service: service).status, 0)
    let file = root.appendingPathComponent("Library/LaunchAgents/\(RecorderLaunchAgent.label).plist")
    XCTAssertEqual(try Data(contentsOf: file), try RecorderLaunchAgent.propertyList(executable: URL(fileURLWithPath: "/invented/ActivityProbe")))
    XCTAssertEqual(calls.map { $0.first! }, ["bootout", "print", "bootstrap"])
    XCTAssertEqual(LaunchAgentCommand.run(["uninstall", "--live-switch"], userHome: root, service: service).status, 0)
    XCTAssertEqual(calls.last?.first, "bootout"); XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
  }
  /// Runs install against invented service replies, with a clock that only moves when install pauses.
  private func installWithFakeClock(_ reply: (String) throws -> LaunchAgentServiceResult)
    throws -> (result: AppCommandResult, calls: [String], elapsed: TimeInterval, plist: Data?) {
    let root = URL(fileURLWithPath: "/tmp/ap-menu-launch-tests").appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("Library/LaunchAgents/\(RecorderLaunchAgent.label).plist")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("invented old plist".utf8).write(to: file)
    var calls: [String] = [], now: TimeInterval = 100
    let result = LaunchAgentCommand.run(["install", "/invented/new/ActivityProbe", "--live-switch"], userHome: root,
      service: { calls.append($0[0]); return try reply($0[0]) }, clock: { now }, pause: { now += $0 })
    return (result, calls, now - 100, try? Data(contentsOf: file))
  }
  // Ideal: install waits until the booted-out job is proven gone before it bootstraps the new plist.
  func testInstallWaitsForBootedOutJobToLeave() throws {
    let absent = "Could not find service \"\(RecorderLaunchAgent.label)\" in domain for user gui: \(getuid())"
    var prints = 0
    let run = try installWithFakeClock { operation in
      guard operation == "print" else { return .init(0) }
      prints += 1; return prints <= 2 ? .init(0) : .init(113, error: absent)
    }
    XCTAssertEqual(run.result.status, 0); XCTAssertEqual(run.result.output, "launch_agent_installed")
    XCTAssertEqual(run.calls, ["bootout", "print", "print", "print", "bootstrap"])
    XCTAssertEqual(run.elapsed, 2 * LaunchAgentCommand.pollInterval, accuracy: 1e-9)
    XCTAssertEqual(run.plist, try RecorderLaunchAgent.propertyList(executable: URL(fileURLWithPath: "/invented/new/ActivityProbe")))
  }
  // Ideal: a bootstrap refused while the old job is torn down is retried after absence is proven again.
  func testInstallRetriesBootstrapAfterTransientFailures() throws {
    let absent = "Could not find service \"\(RecorderLaunchAgent.label)\" in domain for user gui: \(getuid())"
    var bootstraps = 0
    let run = try installWithFakeClock { operation in
      switch operation {
      case "print": return .init(113, error: absent)
      case "bootstrap":
        bootstraps += 1; return bootstraps <= 2 ? .init(5, error: "Bootstrap failed: 5: Input/output error\n") : .init(0)
      default: return .init(0)
      }
    }
    XCTAssertEqual(run.result.status, 0); XCTAssertEqual(run.result.output, "launch_agent_installed")
    XCTAssertEqual(run.calls, ["bootout", "print", "bootstrap", "print", "bootstrap", "print", "bootstrap"])
    XCTAssertEqual(run.plist, try RecorderLaunchAgent.propertyList(executable: URL(fileURLWithPath: "/invented/new/ActivityProbe")))
  }
  // Ideal: when the bound runs out, install refuses, keeps the new plist for the next login and says the job is not loaded.
  func testInstallGivesUpAtBoundButKeepsNewPlist() throws {
    let absent = "Could not find service \"\(RecorderLaunchAgent.label)\" in domain for user gui: \(getuid())"
    let expected = try RecorderLaunchAgent.propertyList(executable: URL(fileURLWithPath: "/invented/new/ActivityProbe"))
    let failing = try installWithFakeClock { operation in
      switch operation {
      case "print": return .init(113, error: absent)
      case "bootstrap": return .init(37, error: "Bootstrap failed: 37: Operation already in progress\n")
      default: return .init(0)
      }
    }
    XCTAssertEqual(failing.result.status, 1)
    XCTAssertEqual(failing.result.output, "launch_agent_refused job_not_loaded plist_kept")
    XCTAssertGreaterThanOrEqual(failing.elapsed, LaunchAgentCommand.settleBound)
    XCTAssertLessThan(failing.elapsed, LaunchAgentCommand.settleBound + 2 * LaunchAgentCommand.pollInterval)
    XCTAssertGreaterThan(failing.calls.filter { $0 == "bootstrap" }.count, 3)
    XCTAssertEqual(failing.plist, expected)
    // A job that never leaves is never bootstrapped over, and its state is not claimed either way.
    let stuck = try installWithFakeClock { _ in .init(0) }
    XCTAssertEqual(stuck.result.status, 1)
    XCTAssertEqual(stuck.result.output, "launch_agent_refused job_state_unknown plist_kept")
    XCTAssertFalse(stuck.calls.contains("bootstrap"))
    XCTAssertGreaterThanOrEqual(stuck.elapsed, LaunchAgentCommand.settleBound)
    XCTAssertEqual(stuck.plist, expected)
    // A bootstrap that reports failure yet leaves the job loaded is not claimed as unloaded.
    var bootstrapped = false
    let ambiguous = try installWithFakeClock { operation in
      switch operation {
      case "print": return bootstrapped ? .init(0) : .init(113, error: absent)
      case "bootstrap": bootstrapped = true; return .init(5, error: "Bootstrap failed: 5: Input/output error\n")
      default: return .init(0)
      }
    }
    XCTAssertEqual(ambiguous.result.output, "launch_agent_refused job_state_unknown plist_kept")
    XCTAssertEqual(ambiguous.calls.filter { $0 == "bootstrap" }.count, 1)
  }
  // Ideal: an old job that stays until launchd kills it at ExitTimeOut is still replaced.
  func testInstallOutwaitsTheOldJobsKillDeadline() throws {
    let absent = "Could not find service \"\(RecorderLaunchAgent.label)\" in domain for user gui: \(getuid())"
    let lingering = Int((TimeInterval(RecorderLaunchAgent.exitTimeOut) + 1) / LaunchAgentCommand.pollInterval)
    var prints = 0
    let run = try installWithFakeClock { operation in
      guard operation == "print" else { return .init(0) }
      prints += 1; return prints <= lingering ? .init(0) : .init(113, error: absent)
    }
    XCTAssertEqual(run.result.status, 0); XCTAssertEqual(run.result.output, "launch_agent_installed")
    XCTAssertGreaterThan(run.elapsed, TimeInterval(RecorderLaunchAgent.exitTimeOut))
    XCTAssertEqual(run.calls.last, "bootstrap"); XCTAssertEqual(run.calls.filter { $0 == "bootstrap" }.count, 1)
    XCTAssertEqual(run.plist, try RecorderLaunchAgent.propertyList(executable: URL(fileURLWithPath: "/invented/new/ActivityProbe")))
  }
  // Ideal: a plist that cannot be written after the old job left says that no job is loaded.
  func testInstallWriteFailureAfterBootoutSaysJobNotLoaded() throws {
    let root = URL(fileURLWithPath: "/tmp/ap-menu-launch-tests").appendingPathComponent(UUID().uuidString)
    let folder = root.appendingPathComponent("Library/LaunchAgents")
    defer { chmod(folder.path, 0o755); try? FileManager.default.removeItem(at: root) }
    for old in [false, true] {
      try? FileManager.default.removeItem(at: root)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let file = folder.appendingPathComponent("\(RecorderLaunchAgent.label).plist")
      if old { try Data("invented old plist".utf8).write(to: file) }
      var calls: [String] = []
      // The folder turns read-only once the job is booted out, so the old plist cannot go or the new one cannot be created.
      let result = LaunchAgentCommand.run(["install", "/invented/new/ActivityProbe", "--live-switch"], userHome: root,
        service: { calls.append($0[0]); if $0[0] == "bootout" { chmod(folder.path, 0o555) }; return .init(0) },
        clock: { 0 }, pause: { _ in XCTFail("A failed write needs no wait") })
      chmod(folder.path, 0o755)
      XCTAssertEqual(result.status, 1); XCTAssertEqual(result.output, "launch_agent_refused job_not_loaded")
      XCTAssertEqual(calls, ["bootout"])
      XCTAssertEqual(try? Data(contentsOf: file), old ? Data("invented old plist".utf8) : nil)
    }
  }
  // Ideal: a service that throws inside the wait counts as not proven or not bootstrapped, and install goes on.
  func testInstallSurvivesServiceThrowingInsideTheWait() throws {
    struct Invented: Error {}
    let absent = "Could not find service \"\(RecorderLaunchAgent.label)\" in domain for user gui: \(getuid())"
    var prints = 0, bootstraps = 0
    let recovering = try installWithFakeClock { operation in
      switch operation {
      case "print": prints += 1; if prints == 1 { throw Invented() }; return .init(113, error: absent)
      case "bootstrap": bootstraps += 1; if bootstraps == 1 { throw Invented() }; return .init(0)
      default: return .init(0)
      }
    }
    XCTAssertEqual(recovering.result.status, 0); XCTAssertEqual(recovering.result.output, "launch_agent_installed")
    XCTAssertEqual(recovering.calls, ["bootout", "print", "print", "bootstrap", "print", "bootstrap"])
    XCTAssertEqual(recovering.elapsed, 2 * LaunchAgentCommand.pollInterval, accuracy: 1e-9)
    // A service that keeps throwing runs to the bound, keeps the plist and claims no state.
    let failing = try installWithFakeClock { operation in
      guard operation == "bootout" else { throw Invented() }
      return .init(0)
    }
    XCTAssertEqual(failing.result.status, 1)
    XCTAssertEqual(failing.result.output, "launch_agent_refused job_state_unknown plist_kept")
    XCTAssertFalse(failing.calls.contains("bootstrap"))
    XCTAssertGreaterThanOrEqual(failing.elapsed, LaunchAgentCommand.settleBound)
    XCTAssertEqual(failing.plist, try RecorderLaunchAgent.propertyList(executable: URL(fileURLWithPath: "/invented/new/ActivityProbe")))
  }
}

/// An invented supervisor interprets the generated policy, rather than a second production path.
private struct FakeSupervisor {
  let startsAtLogin: Bool
  let restartOnSuccessfulExit: Bool
  init(plist: [String: Any]) throws {
    startsAtLogin = try XCTUnwrap(plist["RunAtLoad"] as? Bool)
    restartOnSuccessfulExit = try XCTUnwrap((plist["KeepAlive"] as? [String: Bool])?["SuccessfulExit"])
  }
  func login(_ run: () throws -> Int32) throws -> Int {
    guard startsAtLogin else { return 0 }
    var restarts = 0
    while true {
      let status = try run()
      guard (status == 0) == restartOnSuccessfulExit else { return restarts }
      restarts += 1
      guard restarts < 4 else { throw AppCommandError.recorder }
    }
  }
}
