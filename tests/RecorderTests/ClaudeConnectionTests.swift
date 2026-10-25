import Core
import Foundation
@testable import Outbound
@testable import Shell
import Storage
import XCTest

final class ClaudeConnectionTests: XCTestCase {
  var root: URL!
  override func setUpWithError() throws {
    root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ACTIVITYPROBE_TEST_ROOT"] ?? NSTemporaryDirectory())
      .appendingPathComponent("claude-connect-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }
  override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
  func store() throws -> ActivityStorage { try ActivityStorage(url: root.appendingPathComponent("invented.sqlite"), appDataDirectory: root, databaseScope: .directory(root)) }
  var home: URL { root.appendingPathComponent("invented-user") }
  /// An invented CLI that only accepts the person's own home: no config folder of the app's, no login run.
  func cli(status: Int = 0, delay: String = "",
    response: String = "{\"loggedIn\":true,\"email\":\"person@example.com\",\"subscriptionType\":\"max\"}") throws -> URL {
    let executable = root.appendingPathComponent("invented-cli")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let script = """
    #!/bin/sh
    [ "$HOME" = '\(home.path)' ] || exit 9
    [ -z "${CLAUDE_CONFIG_DIR+set}" ] || exit 9
    echo "$*" >> "$HOME/commands"
    [ "$*" = "auth status --json" ] || exit 8
    echo '\(response.replacingOccurrences(of: "'", with: "'\\''"))'
    \(delay) exit \(status)
    """
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    return executable
  }
  func connector(status: Int = 0, timeout: TimeInterval = ClaudeSubscriptionConnector.statusTimeoutSeconds,
    delay: String = "") throws -> ClaudeSubscriptionConnector {
    ClaudeSubscriptionConnector(executable: try cli(status: status, delay: delay), userHome: home,
      environment: ["HOME": home.path, "PATH": "/usr/bin:/bin", "CLAUDE_CONFIG_DIR": root.appendingPathComponent("app-owned").path],
      statusTimeout: timeout)
  }
  // Ideal: status must succeed before consent, and the app never runs a login; later revocations win even when already off.
  @MainActor func testStatusBeforeConsentAndIndependentSettings() async throws {
    let db = try store()
    XCTAssertFalse(try db.settings().claudeConnected)
    XCTAssertFalse(try db.settings().chatSkipApprovals)
    let failed = try SettingsController(store: db, connector: ClaudeImmediateConnection(), ownBundleID: "org.example.self",
      claudeConnector: connector(status: 1))
    await failed.connectClaude()
    XCTAssertFalse(try db.settings().claudeConnected)
    XCTAssertEqual(failed.claudeError, .claudeNotLoggedIn)
    XCTAssertEqual(failed.claudeLogin, .loggedOut)
    let successful = try SettingsController(store: db, connector: ClaudeImmediateConnection(), ownBundleID: "org.example.self",
      claudeConnector: connector())
    await successful.connectClaude()
    XCTAssertTrue(try db.settings().claudeConnected)
    XCTAssertEqual(successful.claudeLogin, .loggedIn)
    XCTAssertFalse(try db.settings().subscriptionConnected)
    XCTAssertEqual(try String(contentsOf: home.appendingPathComponent("commands")), "auth status --json\nauth status --json\n")
    successful.setChatSkipApprovals(true)
    _ = try store().patchSettings(.edit(.addApp("org.example.excluded"), ownBundleID: "org.example.self", now: 10))
    successful.disconnectClaude()
    let result = try db.settings()
    XCTAssertFalse(result.claudeConnected)
    XCTAssertTrue(result.chatSkipApprovals)
    XCTAssertTrue(result.excludedApps.contains("org.example.excluded"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("claude").path))
  }
  // Status JSON is used for display only; error exits never expose account fields.
  func testLoginStateChecksExitCodeAndJSON() throws {
    for (status, state): (Int, ClaudeLoginState) in [(0, .loggedIn), (1, .loggedOut), (2, .unknown)] {
      XCTAssertEqual(try connector(status: status).loginState(), state)
    }
    let missing = ClaudeSubscriptionConnector(command: AgentExecutable(name: "claude") { nil }, userHome: home)
    XCTAssertEqual(missing.loginState(), .notInstalled)
    XCTAssertEqual(try connector(timeout: 0.05, delay: "sleep 1;").loginState(), .unknown)
  }
  func testLoginStatusParsingPlansAndMissingFields() throws {
    for (given, expected) in [("max", "Max"), ("pro", "Pro"), ("team", "Team"), ("enterprise", "Enterprise"), ("future", "future")] {
      let data = Data("{\"loggedIn\":true,\"email\":\"person@example.com\",\"subscriptionType\":\"\(given)\",\"orgName\":\"Invented\"}".utf8)
      XCTAssertEqual(ClaudeSubscriptionConnector.parseLoginStatus(data, exitCode: 0),
        ClaudeLoginSnapshot(state: .loggedIn, email: "person@example.com", plan: expected))
      for exit: Int32 in [1, 2] {
        let result = ClaudeSubscriptionConnector.parseLoginStatus(data, exitCode: exit)
        XCTAssertEqual(result.state, exit == 1 ? .loggedOut : .unknown)
        XCTAssertNil(result.email); XCTAssertNil(result.plan)
      }
    }
    for json in ["{\"loggedIn\":true}", "{\"loggedIn\":true,\"email\":null,\"subscriptionType\":null}",
      "{\"loggedIn\":true,\"email\":\" \",\"subscriptionType\":\"\"}"] {
      XCTAssertEqual(ClaudeSubscriptionConnector.parseLoginStatus(Data(json.utf8), exitCode: 0), ClaudeLoginSnapshot(state: .loggedIn))
    }
    for json in ["{}", "invalid", "{\"email\":\"person@example.com\"}"] {
      XCTAssertEqual(ClaudeSubscriptionConnector.parseLoginStatus(Data(json.utf8), exitCode: 0), ClaudeLoginSnapshot(state: .unknown))
    }
    XCTAssertEqual(ClaudeSubscriptionConnector.parseLoginStatus(Data("{\"loggedIn\":false,\"email\":\"person@example.com\"}".utf8), exitCode: 0),
      ClaudeLoginSnapshot(state: .loggedOut))
    let snapshot = try connector().loginSnapshot()
    XCTAssertEqual(snapshot, ClaudeLoginSnapshot(state: .loggedIn, email: "person@example.com", plan: "Max"))
    XCTAssertEqual(ClaudeSubscriptionConnector.parseLoginStatus(Data("{\"loggedIn\":true,\"subscriptionType\":\"pro\"}".utf8), exitCode: 0),
      ClaudeLoginSnapshot(state: .loggedIn, plan: "Pro"))
    XCTAssertEqual(ClaudeSubscriptionConnector.parseLoginStatus(Data("{\"loggedIn\":true,\"email\":\"person@example.com\"}".utf8), exitCode: 0),
      ClaudeLoginSnapshot(state: .loggedIn, email: "person@example.com"))
  }
  func testDisplayRejectsMalformedAndOversizedJSONWithoutBlocking() throws {
    for response in ["invalid", String(repeating: " ", count: 70_000) + "{\"loggedIn\":true}"] {
      let source = ClaudeSubscriptionConnector(executable: try cli(response: response), userHome: home,
        environment: ["HOME": home.path, "PATH": "/usr/bin:/bin"], statusTimeout: 3)
      XCTAssertEqual(source.loginSnapshot(), ClaudeLoginSnapshot(state: .unknown))
    }
  }
  @MainActor func testAccountDetailsStayOnlyInVisibleSettingsMemory() async throws {
    let db = try store()
    let source = try connector()
    let fixture = try Data(contentsOf: root.appendingPathComponent("invented-cli"))
    let controller = try SettingsController(store: db, connector: ClaudeImmediateConnection(), ownBundleID: "org.example.self",
      claudeConnector: ClaudeImmediateConnection(), claudeLogin: source)
    await controller.claudeSection(visible: true)
    XCTAssertEqual(controller.claudeAccount?.email, "person@example.com")
    await controller.connectClaude(); controller.disconnectClaude()
    await controller.claudeSection(visible: false)
    XCTAssertNil(controller.claudeAccount)
    let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
      .allObjects.compactMap { $0 as? URL }
    for file in files where (try file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
      let bytes = try Data(contentsOf: file)
      if file.lastPathComponent == "invented-cli" { XCTAssertEqual(bytes, fixture) }
      else { XCTAssertNil(bytes.range(of: Data("person@example.com".utf8)), "account detail persisted") }
    }
  }
  @MainActor func testHiddenSectionDiscardsAnInFlightAccountCheck() async throws {
    let source = GatedLoginSource()
    let controller = try SettingsController(store: store(), connector: ClaudeImmediateConnection(), ownBundleID: "org.example.self",
      claudeLogin: source)
    let pending = Task { await controller.claudeSection(visible: true) }
    while !source.started { await Task.yield() }
    await controller.claudeSection(visible: false)
    source.finish()
    await pending.value
    XCTAssertNil(controller.claudeAccount); XCTAssertNil(controller.claudeLogin)
    XCTAssertFalse(controller.isCheckingClaude)
  }
  func testStatusDetailsHaveNoPersistenceOrDiagnosticSink() throws {
    let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Sources")
    let connector = try String(contentsOf: sources.appendingPathComponent("Outbound/ClaudeSubscriptionConnector.swift"))
    let display = String(connector.prefix(through: try XCTUnwrap(connector.range(of: "public func openLogin()")?.lowerBound)))
    for sink in [".write(", "print(", "NSLog(", "Logger(", "UserDefaults", "saveSettings", "patchSettings", "Data(contentsOf:"] {
      XCTAssertFalse(display.contains(sink), "status display must not acquire a persistence or diagnostic sink: " + sink)
    }
    let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
    let allowed: Set<String> = ["Settings.swift", "ClaudeSubscriptionConnector.swift", "SettingsController.swift", "SettingsView.swift", "SettingsPresentation.swift"]
    for case let file as URL in files where file.pathExtension == "swift" {
      let text = try String(contentsOf: file)
      if text.contains("ClaudeLoginSnapshot") || text.contains("claudeAccount") {
        XCTAssertTrue(allowed.contains(file.lastPathComponent), file.lastPathComponent + ": account details escaped the Settings display path")
        XCTAssertFalse(file.path.contains("/Storage/"), "account details entered storage")
      }
    }
  }
  // Ideal: the login button writes one 0700 script running the resolved CLI's own `auth login`, opens only it,
  // and runs nothing itself.
  func testTerminalLoginWritesAndOpensOnlyTheOfficialLogin() async throws {
    let app = root.appendingPathComponent("app's data")
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    let executable = try cli()
    var opened: [URL] = []
    let connector = ClaudeSubscriptionConnector(executable: executable, userHome: home, environment: ["HOME": home.path],
      loginScript: ClaudeLoginScript(appData: app), openTerminal: { opened.append($0) })
    try await connector.openLogin()
    try await connector.openLogin()
    let folder = app.appendingPathComponent("claude-login"), script = folder.appendingPathComponent("claude-login.command")
    XCTAssertEqual(opened, [script, script])
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["claude-login.command"])
    XCTAssertEqual(try String(contentsOf: script), "#!/bin/sh\nexec '\(executable.path)' auth login\n")
    XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: script.path)[.posixPermissions] as? Int, 0o700)
    XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int, 0o700)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: app.path).sorted(), ["claude-login"])
    XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("commands").path), "the app ran the CLI")
    // A quote in the CLI's path stays one argument.
    XCTAssertEqual(ClaudeLoginScript.contents(executable: URL(fileURLWithPath: "/invented/it's/claude")),
      "#!/bin/sh\nexec '/invented/it'\\''s/claude' auth login\n")
    // A planted link in place of the folder is refused before anything is written or opened.
    try FileManager.default.removeItem(at: folder)
    let outside = root.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: outside)
    await expectLoginError(.localPreparation) { try await connector.openLogin() }
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    XCTAssertEqual(opened.count, 2)
    let missing = ClaudeSubscriptionConnector(command: AgentExecutable(name: "claude") { nil }, userHome: home,
      loginScript: ClaudeLoginScript(appData: app), openTerminal: { opened.append($0) })
    await expectLoginError(.notInstalled) { try await missing.openLogin() }
    XCTAssertEqual(opened.count, 2)
  }
  // Ideal: the page's button and its re-check go through the login source only.
  @MainActor func testControllerChecksAndOpensThroughTheLoginSource() async throws {
    let source = InventedLoginSource()
    let controller = try SettingsController(store: store(), connector: ClaudeImmediateConnection(), ownBundleID: "org.example.self",
      claudeConnector: ClaudeImmediateConnection(), claudeLogin: source)
    XCTAssertNil(controller.claudeLogin)
    await controller.claudeSection(visible: true)
    XCTAssertEqual(controller.claudeLogin, .loggedOut)
    await controller.openClaudeLogin()
    XCTAssertEqual(source.opened, 1); XCTAssertNil(controller.claudeError)
    source.state = .loggedIn
    await controller.refreshClaudeLogin()
    XCTAssertEqual(controller.claudeLogin, .loggedIn)
    source.failure = .notInstalled
    await controller.openClaudeLogin()
    XCTAssertEqual(controller.claudeError, .notInstalled)
    source.failure = .terminalFailed
    await controller.openClaudeLogin()
    XCTAssertEqual(controller.claudeError, .terminalFailed)
    XCTAssertFalse(controller.claudeFolderUncertain)
    source.folderKnown = false
    await controller.refreshClaudeLogin()
    XCTAssertTrue(controller.claudeFolderUncertain)
  }
  // Ideal: the person's CLI runs only while the Claude section is on screen: once as it comes into view,
  // and on app activation only while it stays in view.
  @MainActor func testClaudeLoginIsCheckedOnlyWhileItsSectionIsVisible() async throws {
    let source = InventedLoginSource()
    let controller = try SettingsController(store: store(), connector: ClaudeImmediateConnection(), ownBundleID: "org.example.self",
      claudeConnector: ClaudeImmediateConnection(), claudeLogin: source)
    await controller.refreshClaudeLogin()
    await controller.appBecameActive()
    await controller.claudeSection(visible: false)
    XCTAssertEqual(source.checks, 0); XCTAssertNil(controller.claudeLogin)
    await controller.claudeSection(visible: true)
    XCTAssertEqual(source.checks, 1); XCTAssertEqual(controller.claudeLogin, .loggedOut)
    await controller.claudeSection(visible: true)
    XCTAssertEqual(source.checks, 1, "still in view is not a new appearance")
    await controller.appBecameActive()
    XCTAssertEqual(source.checks, 2)
    await controller.claudeSection(visible: false)
    await controller.appBecameActive()
    XCTAssertEqual(source.checks, 2)
    XCTAssertNil(controller.claudeAccount)
    XCTAssertNil(controller.claudeLogin)
    await controller.refreshClaudeLogin()
    XCTAssertEqual(source.checks, 2, "manual recheck is ignored while hidden")
    await controller.claudeSection(visible: true)
    XCTAssertEqual(source.checks, 3)
    // The page's own visibility rule: any part of the section inside the scroll view's height.
    XCTAssertTrue(SettingsPage.claudeSectionVisible(CGRect(x: 0, y: 500, width: 400, height: 300), viewport: 600))
    XCTAssertTrue(SettingsPage.claudeSectionVisible(CGRect(x: 0, y: -250, width: 400, height: 300), viewport: 600))
    XCTAssertFalse(SettingsPage.claudeSectionVisible(CGRect(x: 0, y: 600, width: 400, height: 300), viewport: 600))
    XCTAssertFalse(SettingsPage.claudeSectionVisible(CGRect(x: 0, y: -300, width: 400, height: 300), viewport: 600))
    XCTAssertFalse(SettingsPage.claudeSectionVisible(.zero, viewport: 600))
  }
  // Ideal: Terminal's refusal or failure to open the script is reported; one still opening at the limit is not.
  func testTerminalOpenFailureIsReported() async throws {
    let script = URL(fileURLWithPath: "/invented/claude-login.command"), terminal = URL(fileURLWithPath: "/invented/Terminal.app")
    let opened = LockedURLs()
    try await TerminalLogin.open(script, terminal: terminal) { document, app, done in
      opened.set([document, app]); DispatchQueue.global().async { done(nil) }
    }
    XCTAssertEqual(opened.value, [script, terminal])
    await expectLoginError(.terminalFailed) {
      try await TerminalLogin.open(script, terminal: terminal) { _, _, done in
        DispatchQueue.global().async { done(CocoaError(.fileReadNoPermission)) }
      }
    }
    await expectLoginError(.terminalFailed) {
      try await TerminalLogin.open(script, terminal: nil) { _, _, _ in XCTFail("opened without Terminal") }
    }
    // Still pending at the limit: not reported, and no thread waits meanwhile. A late answer is ignored.
    let late = LockedURLs()
    try await TerminalLogin.open(script, terminal: terminal, limit: 0.05) { document, _, done in
      DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { late.set([document]); done(CocoaError(.fileReadNoPermission)) }
    }
    try await Task.sleep(for: .milliseconds(400))
    XCTAssertEqual(late.value, [script])
    // An answer on the opener's own thread, before it returns, resumes once.
    try await TerminalLogin.open(script, terminal: terminal) { _, _, done in done(nil) }
    XCTAssertEqual(SettingsMessage(error: SubscriptionConnectionError.terminalFailed), .terminalFailed)
  }
  func expectLoginError(_ expected: SubscriptionConnectionError, file: StaticString = #filePath, line: UInt = #line,
    _ body: () async throws -> Void) async {
    do { try await body(); XCTFail("no error", file: file, line: line) }
    catch { XCTAssertEqual(error as? SubscriptionConnectionError, expected, file: file, line: line) }
  }
  // Ideal: a display check running beside Connect keeps its own child; Cancel ends only Connect's,
  // and the check's end does not clear Connect's cancellation.
  func testDisplayCheckAndConnectKeepTheirOwnState() throws {
    let connection = try connector(timeout: 10, delay: "sleep 1;")
    let commands = home.appendingPathComponent("commands")
    func started(_ count: Int) -> Bool {
      let deadline = ProcessInfo.processInfo.systemUptime + 5
      while ProcessInfo.processInfo.systemUptime < deadline {
        if let text = try? String(contentsOf: commands), text.split(separator: "\n").count >= count { return true }
        usleep(10_000)
      }
      return false
    }
    let group = DispatchGroup()
    var connectError: Error?, state: ClaudeLoginState?
    DispatchQueue.global().async(group: group) {
      do { try connection.connect() } catch { connectError = error }
    }
    XCTAssertTrue(started(1))
    DispatchQueue.global().async(group: group) { state = connection.loginState() }
    XCTAssertTrue(started(2))
    connection.cancel()
    XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
    XCTAssertEqual(connectError as? SubscriptionConnectionError, .cancelled)
    XCTAssertEqual(state, .loggedIn)
    // Cancel with no connection running leaves the next check and connection alone.
    connection.cancel()
    XCTAssertEqual(connection.loginState(), .loggedIn)
    XCTAssertNoThrow(try connection.connect())
  }
  @MainActor func testLaterDisconnectWinsAcrossClients() async throws {
    let db = try store()
    let started = expectation(description: "login pending")
    let gate = ClaudeGatedConnection { started.fulfill() }
    let a = try SettingsController(store: db, connector: ClaudeImmediateConnection(), ownBundleID: "org.example.self", claudeConnector: gate)
    let b = try SettingsController(store: store(), connector: ClaudeImmediateConnection(), ownBundleID: "org.example.self", claudeConnector: ClaudeImmediateConnection())
    let task = Task { await a.connectClaude() }
    await fulfillment(of: [started], timeout: 3)
    b.disconnectClaude(); gate.finish(); await task.value
    XCTAssertFalse(try db.settings().claudeConnected)
    XCTAssertNotNil(a.claudeError)
    await b.connectClaude()
    XCTAssertTrue(try db.settings().claudeConnected)
    for patch: SettingsPatch in [.beginClaudeConnection, .disconnectClaude] {
      let older = try db.patchSettings(.beginClaudeConnection)
      _ = try store().patchSettings(patch)
      XCTAssertThrowsError(try db.patchSettings(.completeClaudeConnection(generation: older.claudeConnectionGeneration)))
    }
  }
  func testStaleWholeSettingsSaveCannotRestoreConnectionGeneration() throws {
    let db = try store()
    let pending = try db.patchSettings(.beginClaudeConnection)
    let revoked = try store().patchSettings(.disconnectClaude)
    try db.saveSettings(pending)
    XCTAssertEqual(try db.settings().claudeConnectionGeneration, revoked.claudeConnectionGeneration)
    XCTAssertThrowsError(try db.patchSettings(.completeClaudeConnection(generation: pending.claudeConnectionGeneration))) {
      XCTAssertEqual($0 as? SettingsValidationError, .connectionSuperseded)
    }
    XCTAssertFalse(try db.settings().claudeConnected)
  }
  // Ideal: status carries only options it lists; telemetry-off rides in the environment, and the child keeps the
  // person's HOME and folders. CLAUDE_CONFIG_DIR is the login shell's, never an inherited or app-owned one.
  func testStrictCLIStatusRunsInThePersonsHome() throws {
    let executable = root.appendingPathComponent("strict-cli")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let script = """
    #!/bin/sh
    echo "$*" >> '\(root.path)/arguments'
    [ "$1" = auth ] || exit 1
    command=$2; shift 2
    while [ $# -gt 0 ]; do
      case "$command:$1" in
        status:--json|status:--text|status:-h|status:--help) ;;
        *) echo "error: unknown option '$1'" >&2; exit 1;;
      esac
      shift
    done
    [ "$command" = status ] || exit 1
    env > '\(root.path)/environment-'"${CLAUDE_CONFIG_DIR:+shell}"
    echo '{"loggedIn":true}'
    exit 0
    """
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let inherited = ["HOME": home.path, "PATH": "/usr/bin:/bin", "CLAUDE_CODE_ENABLE_TELEMETRY": "1", "OTEL_LOGS_EXPORTER": "otlp",
      "XDG_CONFIG_HOME": home.appendingPathComponent("invented-xdg").path, "ZDOTDIR": home.appendingPathComponent("invented-zdot").path,
      "CLAUDE_CONFIG_DIR": root.appendingPathComponent("app-owned").path, "ANTHROPIC_API_KEY": "invented", "CLAUDE_CODE_OAUTH_TOKEN": "invented"]
    let shellFolder = home.appendingPathComponent("invented-claude-folder").path
    for shell in [nil, shellFolder] {
      let command = AgentExecutable(name: "claude", claudeConfigDirectory: { shell }) {
        AgentInstall(executable: executable, origin: .fixed, childPath: nil)
      }
      try ClaudeSubscriptionConnector(command: command, userHome: home, environment: inherited, statusTimeout: 3).connect()
      let lines = try String(contentsOf: root.appendingPathComponent("environment-" + (shell == nil ? "" : "shell"))).split(separator: "\n")
      let values = Dictionary(lines.compactMap { line in line.firstIndex(of: "=").map { (String(line[..<$0]), String(line[line.index(after: $0)...])) } }) { _, last in last }
      for (key, value) in ConversationDiagnostics.contentOff { XCTAssertEqual(values[key], value, key) }
      XCTAssertEqual(values["ENABLE_CLAUDEAI_MCP_SERVERS"], "false")
      XCTAssertEqual(values["CLAUDE_CODE_DISABLE_AUTO_MEMORY"], "1")
      XCTAssertEqual(values["CLAUDE_CONFIG_DIR"], shell)
      for key in ["HOME", "XDG_CONFIG_HOME", "ZDOTDIR"] { XCTAssertEqual(values[key], inherited[key], key) }
      for key in ["CFFIXED_USER_HOME", "XDG_CACHE_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN"] {
        XCTAssertNil(values[key], key)
      }
    }
    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("arguments")), "auth status --json\nauth status --json\n")
  }
  // Ideal: login files and the keychain are named only to deny them to the agents; no code asks the keychain
  // or reads those files, and the app never runs a Claude login itself.
  func testOnlyDenialsNameLoginFiles() throws {
    let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Sources")
    let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)).compactMap { $0 as? URL }
      .filter { $0.pathExtension == "swift" }
    XCTAssertGreaterThan(files.count, 50)
    let denials: Set<String> = ["ConversationReadDenials.swift", "ClaudePersonalHome.swift"]
    // The app's own ChatGPT sign-in is the one item it keeps in the keychain; it names no Claude login file.
    let keychainStore = "ChatGPTCredentials.swift"
    for file in files {
      let text = try String(contentsOf: file)
      for token in [".credentials.json", "Library/Keychains", ".claude.json", "auth.json"] where text.contains(token) {
        XCTAssertTrue(denials.contains(file.lastPathComponent), file.lastPathComponent + " names " + token)
      }
      for token in [".credentials", "globalConfiguration", "personalCodexLogins"] where text.contains(token) && !denials.contains(file.lastPathComponent) {
        XCTFail(file.lastPathComponent + " uses " + token)
      }
      for token in ["SecItemCopyMatching", "SecKeychain", "kSecClassGenericPassword", "kSecClassInternetPassword"]
        where file.lastPathComponent != keychainStore {
        XCTAssertFalse(text.contains(token), file.lastPathComponent + " asks the keychain")
      }
      if text.contains(" auth login") {
        XCTAssertEqual(file.lastPathComponent, "ClaudeSubscriptionConnector.swift", "only the Terminal script names the login")
      }
    }
  }
  func testStatusTimeout() throws {
    let connection = try connector(timeout: 0.05, delay: "sleep 1;")
    XCTAssertThrowsError(try connection.connect()) { XCTAssertEqual($0 as? SubscriptionConnectionError, .statusTimeout) }
  }
}
private final class InventedLoginSource: ClaudeLoginSource {
  var state = ClaudeLoginState.loggedOut
  var account = ClaudeLoginSnapshot(state: .loggedIn, email: "person@example.com", plan: "Max")
  var opened = 0
  var failure: SubscriptionConnectionError?
  var checks = 0
  var folderKnown = true
  func loginState() -> ClaudeLoginState { checks += 1; return state }
  func loginSnapshot() -> ClaudeLoginSnapshot {
    let value = loginState()
    return value == .loggedIn ? account : ClaudeLoginSnapshot(state: value)
  }
  func loginFolderKnown() -> Bool { folderKnown }
  func openLogin() async throws {
    if let failure { throw failure }
    opened += 1
  }
}
private final class GatedLoginSource: ClaudeLoginSource {
  private let condition = NSCondition()
  private var running = false
  private var done = false
  var started: Bool { condition.lock(); defer { condition.unlock() }; return running }
  func loginState() -> ClaudeLoginState { .loggedIn }
  func loginSnapshot() -> ClaudeLoginSnapshot {
    condition.lock(); running = true
    while !done { condition.wait() }
    condition.unlock()
    return ClaudeLoginSnapshot(state: .loggedIn, email: "person@example.com", plan: "Max")
  }
  func finish() { condition.lock(); done = true; condition.signal(); condition.unlock() }
  func openLogin() async throws {}
}
private final class ClaudeImmediateConnection: SubscriptionConnector {
  func connect() throws {}
  func cancel() {}
}
private final class ClaudeGatedConnection: SubscriptionConnector {
  private let condition = NSCondition()
  private var done = false
  let started: () -> Void
  init(_ started: @escaping () -> Void) { self.started = started }
  func connect() throws {
    condition.lock(); started()
    while !done { condition.wait() }
    condition.unlock()
  }
  func finish() { condition.lock(); done = true; condition.signal(); condition.unlock() }
  func cancel() { finish() }
}

private final class LockedURLs: @unchecked Sendable {
  private let lock = NSLock()
  private var urls: [URL] = []
  func set(_ value: [URL]) { lock.lock(); urls = value; lock.unlock() }
  var value: [URL] { lock.lock(); defer { lock.unlock() }; return urls }
}
