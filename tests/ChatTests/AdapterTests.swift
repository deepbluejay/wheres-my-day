import Core
import Darwin
import Foundation
import Inbound
@testable import Outbound
import Shell
import Storage
import XCTest

final class NoConversationProcesses: AgentLogProcessSource {
  func processes() throws -> [AgentLogProcess] { [] }
  func homeVariable(_ name: String, processID: Int32) throws -> String? { nil }
}

final class AdapterTests: XCTestCase {
  var root: URL!
  override func setUpWithError() throws {
    root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ACTIVITYPROBE_TEST_ROOT"] ?? NSTemporaryDirectory())
      .appendingPathComponent("adapter-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }
  override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
  func configuration(_ provider: ChatProvider, mode: String = "normal", timeout: TimeInterval = 3) throws -> ConversationConfiguration {
    let home = root.appendingPathComponent(provider.rawValue + mode)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    for name in Self.settingsFiles {
      let file = home.appendingPathComponent(name)
      try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("Invented settings canary".utf8).write(to: file)
    }
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    try FileManager.default.copyItem(at: repo.appendingPathComponent("tests/ChatTests/Fixtures/interactive_pipe.py"),
      to: home.appendingPathComponent("interactive_pipe.py"))
    try FileManager.default.copyItem(at: repo.appendingPathComponent("tests/ChatTests/Fixtures/codex-0.163.0-errors.json"),
      to: home.appendingPathComponent("native-errors.json"))
    let executable = home.appendingPathComponent("invented-cli")
    try Data(Self.fixture.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let database = home.appendingPathComponent("invented.sqlite")
    let storage = try ActivityStorage(url: database, appDataDirectory: home, databaseScope: .directory(root))
    try storage.appendIntervals([NamedInterval(range: TimeRange(14400, 14580), name: "Invented task", kind: .work)])
    return ConversationConfiguration(executable: executable, userHome: home,
      toolServer: repo.appendingPathComponent(".build/debug/ActivityQueryServer"), database: database,
      environment: ["HOME": home.path, "PATH": "/usr/bin:/bin", "INVENTED_ROOT": home.path, "INVENTED_PROVIDER": provider.rawValue, "INVENTED_MODE": mode, "PYTHONPATH": home.path, "PYTHONDONTWRITEBYTECODE": "1",
        "CODEX_HOME": home.appendingPathComponent(".codex").path, "CODEX_SQLITE_HOME": home.appendingPathComponent(".codex").path, "CLAUDE_CONFIG_DIR": home.appendingPathComponent(".claude").path,
        // A terminal may export these; none may reach a conversation, and the app's own ceiling replaces this one.
        "GIT_DIR": home.appendingPathComponent("invented-repo/.git").path, "GIT_WORK_TREE": home.appendingPathComponent("invented-repo").path,
        "GIT_CONFIG_GLOBAL": home.appendingPathComponent("invented-gitconfig").path, "GIT_CONFIG_COUNT": "1",
        "GIT_CONFIG_KEY_0": "core.fsmonitor", "GIT_CONFIG_VALUE_0": "invented-command", "GIT_CEILING_DIRECTORIES": "/invented-ceiling"],
      timeout: timeout, appBinary: home.appendingPathComponent("ActivityProbe"))
  }
  func events(_ agent: ConversationAgent, _ selection: ChatSelection) async throws -> [ConversationEvent] {
    var events: [ConversationEvent] = []
    for try await event in agent.converse(messages: [.init(role: .user, text: "Invented question")], selection: selection) {
      events.append(event)
    }
    return events
  }
  // Ideal: both CLIs receive the selected pair, isolated app homes and our scoped server;
  // each yields started/tool-start/tool-end/text/completed, without exposing tool arguments.
  func testBothAdaptersAndOwnSessions() async throws {
    var sequences: [[ConversationEvent]] = []
    for provider in ChatProvider.allCases {
      let config = try configuration(provider)
      let agent: ConversationAgent = provider == .claude ? ClaudeConversationAgent(configuration: config)
        : CodexConversationAgent(configuration: config, tokens: FakeConversationTokens(), accountModels: FakeAccountModels())
      let models = try agent.models()
      XCTAssertFalse(models.isEmpty)
      let selection = ChatSelection(provider: provider, model: provider == .claude ? "sonnet" : "gpt-invented", reasoning: "high")
      do {
        sequences.append(try await events(agent, selection).map { event in
          switch event {
          case .toolStarted(_, let name): return .toolStarted(id: "paired-tool", name: name)
          case .toolFinished(_, let failed): return .toolFinished(id: "paired-tool", failed: failed)
          default: return event
          }
        })
      }
      catch { XCTFail("\(provider.rawValue): \(error)"); throw error }
      let captured = try JSONSerialization.jsonObject(with: Data(contentsOf: config.userHome.appendingPathComponent("launch.json"))) as! [String: Any]
      // Claude runs as the person's own install and writes its own state in their folder; Codex stays in the app's.
      let personalClaude = config.userHome.appendingPathComponent(".claude")
      for directory in [".claude", ".codex"] {
        let owned = provider == .claude && directory == ".claude" ? ["cli-owned-state"] : []
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: config.userHome.appendingPathComponent(directory).path)),
          Set(Self.settingsFiles.filter { $0.hasPrefix(directory + "/") }.map { URL(fileURLWithPath: $0).lastPathComponent } + owned))
      }
      XCTAssertEqual(FileManager.default.fileExists(atPath: personalClaude.appendingPathComponent("cli-owned-state").path), provider == .claude)
      XCTAssertFalse(FileManager.default.fileExists(atPath: config.appDataDirectory.appendingPathComponent("claude").path))
      XCTAssertEqual(captured["home"] as? String, provider == .claude ? config.userHome.path : captured["codex_home"] as? String)
      let registry = AgentLogFiles.ownSources(appDataDirectory: config.appDataDirectory)
      if provider == .codex {
        let isolated = try XCTUnwrap(captured["codex_home"] as? String)
        XCTAssertTrue(isolated.hasPrefix(config.codexHome.path + "/app-server/"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: isolated))
        XCTAssertTrue(try registry.contains(path: isolated + "/sessions/invented.jsonl", tool: .codex))
      } else {
        XCTAssertNil(captured["codex_home"] as? String)
        let arguments = try XCTUnwrap(captured["args"] as? [String])
        let flag = try XCTUnwrap(arguments.firstIndex(of: "--session-id"))
        XCTAssertTrue(try registry.containsSession(AgentLogIdentity.decoded(arguments[flag + 1]), tool: .claude))
      }
      XCTAssertTrue(captured["claude_home"] is NSNull, "no Claude child gets an app or inherited CLAUDE_CONFIG_DIR")
      XCTAssertTrue(AgentWindowIdentity.containsWorkingFolder(captured["cwd"] as! String))
      XCTAssertFalse(FileManager.default.fileExists(atPath: captured["cwd"] as! String))
      let toolEnvironment = try XCTUnwrap(captured["tool_environment"] as? [String: String])
      XCTAssertFalse(ActivityQueryServer.leaseIsValid(environment: toolEnvironment, at: Int(Date().timeIntervalSince1970)))
      for name in Self.settingsFiles {
        XCTAssertEqual(try String(contentsOf: config.userHome.appendingPathComponent(name)), "Invented settings canary")
      }
      // Claude saves no session (--no-session-persistence), so nothing lands in the person's history.
      let logs = (provider == .claude ? personalClaude : config.codexHome)
        .appendingPathComponent(provider == .claude ? "projects" : "sessions").appendingPathComponent("invented.jsonl")
      XCTAssertEqual(FileManager.default.fileExists(atPath: logs.path), false)
      let reader: AgentLogReader = provider == .claude
        ? ClaudeAgentLogReader(userHome: config.userHome.path, processes: NoConversationProcesses())
        : CodexAgentLogReader(userHome: config.userHome.path, processes: NoConversationProcesses())
      XCTAssertTrue(try reader.files().isEmpty)

    }
    let ideal: [ConversationEvent] = [.billing(.subscription), .started, .toolStarted(id: "paired-tool", name: "day_summary"),
      .toolFinished(id: "paired-tool", failed: false), .text("Invented answer"), .completed]
    XCTAssertEqual(sequences, [ideal, ideal])
  }

  func testCrashHostFixture() async throws {
    guard let path = ProcessInfo.processInfo.environment["AP_INVENTED_CRASH_ROOT"],
      let phase = ProcessInfo.processInfo.environment["AP_INVENTED_CRASH_PHASE"] else { return }
    root = URL(fileURLWithPath: path)
    let config = try configuration(.codex, mode: "host-" + phase, timeout: 60)
    let agent = CodexConversationAgent(configuration: config, tokens: FakeConversationTokens(), accountModels: FakeAccountModels())
    if phase == "catalog" { _ = try agent.models() }
    else { _ = try await events(agent, .init(provider: .codex, model: "gpt-invented", reasoning: "high")) }
  }

  func testHostSIGKILLCleansCatalogAndTurnHomes() throws {
    for phase in ["catalog", "turn"] {
      let hostRoot = root.appendingPathComponent("host-" + phase)
      try FileManager.default.createDirectory(at: hostRoot, withIntermediateDirectories: true)
      let child = Process()
      child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
      child.arguments = ["xctest", "-XCTest", "ChatTests.AdapterTests/testCrashHostFixture", Bundle(for: AdapterTests.self).bundlePath]
      var environment = ProcessInfo.processInfo.environment
      environment["AP_INVENTED_CRASH_ROOT"] = hostRoot.path
      environment["AP_INVENTED_CRASH_PHASE"] = phase
      child.environment = environment
      child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
      try child.run()
      defer { if child.isRunning { kill(child.processIdentifier, SIGKILL); child.waitUntilExit() } }
      let marker = hostRoot.appendingPathComponent("codexhost-" + phase + "/crash-ready.json")
      let deadline = Date().addingTimeInterval(25)
      while !FileManager.default.fileExists(atPath: marker.path), child.isRunning, Date() < deadline { usleep(10_000) }
      XCTAssertTrue(child.isRunning)
      let object = try XCTUnwrap(try? JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as? [String: Any])
      let home = try XCTUnwrap(object["home"] as? String)
      let group = try XCTUnwrap(object["group"] as? Int32)
      let lease = object["lease"] as? String
      XCTAssertTrue(FileManager.default.fileExists(atPath: home))
      XCTAssertEqual(kill(child.processIdentifier, SIGKILL), 0)
      child.waitUntilExit()
      let cleanupDeadline = Date().addingTimeInterval(10)
      while FileManager.default.fileExists(atPath: home), Date() < cleanupDeadline { usleep(10_000) }
      XCTAssertFalse(FileManager.default.fileExists(atPath: home))
      if let lease { XCTAssertFalse(FileManager.default.fileExists(atPath: lease)) }
      while kill(-group, 0) == 0, Date() < cleanupDeadline { usleep(10_000) }
      XCTAssertEqual(kill(-group, 0), -1)
    }
  }

  func testAccountCatalogCombinesReasoningAndRefreshesOnSwitch() async throws {
    let config = try configuration(.codex)
    let tokens = FakeConversationTokens()
    let server = try FakeOAuthServer(); defer { server.stop() }
    server.models = { authorization in
      let first = authorization == "Bearer invented-conversation-access"
      return (200, ["models": first ? [
        ["slug": "gpt-account-new", "display_name": "Invented current", "visibility": "list"],
        ["slug": "gpt-invented", "display_name": "Invented known", "visibility": "list"]] : [
        ["slug": "gpt-5.6-luna", "display_name": "Invented Luna", "visibility": "list"]]])
    }
    let agent = CodexConversationAgent(configuration: config, tokens: tokens,
      accountModels: ChatGPTAccountModels(loopback: server.url.appendingPathComponent("v1/models")))
    let first = try agent.models()
    XCTAssertEqual(first.map(\.id), ["gpt-account-new", "gpt-invented"])
    XCTAssertEqual(first.map(\.reasoningLevels), [["medium"], ["low", "high"]])
    tokens.value = "invented-renewed-access"
    XCTAssertEqual(try agent.models().map(\.id), ["gpt-5.6-luna"])
    do { _ = try await events(agent, .init(provider: .codex, model: "gpt-invented", reasoning: "high")); XCTFail() }
    catch { XCTAssertEqual(error as? ConversationError, .invalidSelection) }
    let launches = try String(contentsOf: config.userHome.appendingPathComponent("codex-arguments.jsonl")).split(separator: "\n")
    XCTAssertEqual(launches.count, 3, "unavailable selection never starts a turn")
    XCTAssertEqual(server.requests.count, 3, "every picker/turn refresh uses the current token")
    server.models = { _ in
      tokens.value = "invented-conversation-access"
      return (200, ["models": [["slug": "gpt-invented", "display_name": "Invented stale", "visibility": "list"]]])
    }
    XCTAssertThrowsError(try agent.models()) { XCTAssertEqual($0 as? ConversationError, .unavailable) }
  }

  func testPlanTokenErrorsNeverLaunchTheCLI() async throws {
    let config = try configuration(.codex)
    for failure in [ChatGPTTokenError.notSignedIn, .planRequired, .notAvailable, .signInAgain, .storage,
      .temporarilyUnavailable, .usageLimited, .notAccepted, .requestRefused] {
      let tokens = FakeConversationTokens(); tokens.failure = failure
      let agent = CodexConversationAgent(configuration: config, tokens: tokens, accountModels: FakeAccountModels())
      let expected: ConversationError = [.notSignedIn, .planRequired, .notAvailable, .signInAgain].contains(failure) ? .notLoggedIn : .unavailable
      XCTAssertThrowsError(try agent.models()) { XCTAssertEqual($0 as? ConversationError, expected) }
      do { _ = try await events(agent, .init(provider: .codex, model: "gpt-invented", reasoning: "high")); XCTFail() }
      catch { XCTAssertEqual(error as? ConversationError, expected) }
      XCTAssertFalse(FileManager.default.fileExists(atPath: config.userHome.appendingPathComponent("codex-arguments.jsonl").path))
    }
  }

  func testPlanFailuresUpdateTheTokenPortWithoutReplayingTools() async throws {
    for phase in ["rpc", "turn"] {
      for status in [400, 401, 403, 429] {
        let config = try configuration(.codex, mode: "plan-\(phase)-\(status)")
        let tokens = FakeConversationTokens()
        let agent = CodexConversationAgent(configuration: config, tokens: tokens, accountModels: FakeAccountModels())
        do { _ = try await events(agent, .init(provider: .codex, model: "gpt-invented", reasoning: "high")); XCTFail() }
        catch { XCTAssertEqual(error as? ConversationError, .unavailable) }
        XCTAssertEqual(tokens.rejected, status == 401 ? 1 : 0)
        XCTAssertEqual(tokens.notAccepted, status == 403 ? 1 : 0)
        XCTAssertEqual(tokens.limited, status == 429 ? 1 : 0)
        XCTAssertEqual(tokens.refused, status == 400 ? 1 : 0)
        XCTAssertEqual(tokens.shapes.count, 3)
        XCTAssertNotEqual(tokens.shapes.last, ChatGPTRequestShape.current)
        let launches = try String(contentsOf: config.userHome.appendingPathComponent("codex-arguments.jsonl")).split(separator: "\n")
        XCTAssertEqual(launches.count, 2, "one catalog and one turn, never an automatic replay")
        XCTAssertFalse(launches.contains { $0.contains("invented-conversation-access") })
        if status == 401 {
          XCTAssertFalse(try agent.models().isEmpty, "the next process receives the renewed token")
          XCTAssertEqual(tokens.value, "invented-renewed-access")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: config.codexHome.appendingPathComponent("app-server").path), [])
      }
    }
  }

  func testNativePlanFailuresUseTimedFallbackWithoutReplay() async throws {
    for phase in ["http", "stream"] {
      let config = try configuration(.codex, mode: "native-" + phase)
      let tokens = FakeConversationTokens()
      let agent = CodexConversationAgent(configuration: config, tokens: tokens, accountModels: FakeAccountModels())
      do { _ = try await events(agent, .init(provider: .codex, model: "gpt-invented", reasoning: "high")); XCTFail() }
      catch { XCTAssertEqual(error as? ConversationError, .unavailable) }
      XCTAssertEqual(tokens.notAccepted, phase == "http" ? 1 : 0)
      XCTAssertEqual(tokens.notEligible, 0)
      XCTAssertEqual(tokens.limited, 0)
      XCTAssertEqual(tokens.rejected, 0)
      XCTAssertEqual(tokens.refused, 0)
      let launches = try String(contentsOf: config.userHome.appendingPathComponent("codex-arguments.jsonl")).split(separator: "\n")
      XCTAssertEqual(launches.count, 2)
    }
  }

  func testPlanTokenRefreshFailuresUseTheExistingConnectionError() async throws {
    for phase in ["rpc", "turn"] {
      let config = try configuration(.codex, mode: "plan-\(phase)-401")
      for failure in [ChatGPTTokenError.signInAgain, .temporarilyUnavailable] {
        let tokens = FakeConversationTokens(); tokens.rejectionFailure = failure
        let agent = CodexConversationAgent(configuration: config, tokens: tokens, accountModels: FakeAccountModels())
        do { _ = try await events(agent, .init(provider: .codex, model: "gpt-invented", reasoning: "high")); XCTFail() }
        catch { XCTAssertEqual(error as? ConversationError, failure == .signInAgain ? .notLoggedIn : .unavailable) }
        XCTAssertEqual(tokens.rejected, 1)
      }
    }
  }

  func testPlanTokenRefreshCancelsDescendantApprovalsBeforeRenewal() async throws {
    final class Capture {
      let lock = NSLock()
      var request: ConversationApproval?
      var result: (ConversationApprovalOutcome?, Bool) = (nil, true)
      func keep(_ value: ConversationApproval) { lock.lock(); defer { lock.unlock() }; request = value }
      func inspect() {
        lock.lock(); defer { lock.unlock() }
        result = (request?.outcome, request?.answer(choiceID: "approve") ?? true)
      }
      func snapshot() -> (ConversationApprovalOutcome?, Bool) { lock.lock(); defer { lock.unlock() }; return result }
    }
    let capture = Capture(), tokens = FakeConversationTokens()
    tokens.onRejected = { capture.inspect() }
    let config = try configuration(.codex, mode: "plan-pending-401")
    let agent = CodexConversationAgent(configuration: config, tokens: tokens, accountModels: FakeAccountModels())
    do {
      for try await event in agent.converse(messages: [.init(role: .user, text: "Invented question")],
        selection: .init(provider: .codex, model: "gpt-invented", reasoning: "high")) {
        if case .approval(let request) = event {
          capture.keep(request)
          try Data("ready".utf8).write(to: config.userHome.appendingPathComponent("invented-approval-ready"))
        }
      }
      XCTFail()
    } catch { XCTAssertEqual(error as? ConversationError, .unavailable) }
    XCTAssertEqual(tokens.rejected, 1)
    XCTAssertEqual(capture.snapshot().0, .cancelled)
    XCTAssertFalse(capture.snapshot().1, "a late approval must be refused before token renewal starts")
  }
  func testBadInventoryAndUnexpectedToolFailClosed() async throws {
    for provider in ChatProvider.allCases {
      for mode in ["inventory", "wrong-thread", "early-eof", "partial-eof", "overlong"] {
        let config = try configuration(provider, mode: mode)
        let agent: ConversationAgent = provider == .claude ? ClaudeConversationAgent(configuration: config)
          : CodexConversationAgent(configuration: config, tokens: FakeConversationTokens(), accountModels: FakeAccountModels())
        let selection = ChatSelection(provider: provider, model: provider == .claude ? "sonnet" : "gpt-invented", reasoning: "high")
        do { _ = try await events(agent, selection); XCTFail("Unexpected success") }
        catch { XCTAssertTrue(error is ConversationError) }
      }
    }
  }
  // Ideal: a logged-out Claude Code is reported as such before anything else starts.
  func testLoggedOutClaudeStopsBeforeTheConversation() async throws {
    let config = try configuration(.claude, mode: "logged-out")
    do { _ = try await events(ClaudeConversationAgent(configuration: config), .init(provider: .claude, model: "sonnet", reasoning: "high")); XCTFail() }
    catch { XCTAssertEqual(error as? ConversationError, .notLoggedIn) }
    XCTAssertFalse(FileManager.default.fileExists(atPath: config.userHome.appendingPathComponent("launch.json").path))
  }
  func testSelectionAndTimeoutFailWithoutSettingsWrites() async throws {
    let config = try configuration(.claude, mode: "hang", timeout: 0.1)
    let agent = ClaudeConversationAgent(configuration: config)
    do { _ = try await events(agent, .init(provider: .claude, model: "sonnet", reasoning: "high")); XCTFail() }
    catch { XCTAssertEqual(error as? ConversationError, .timeout) }
    do { _ = try await events(agent, .init(provider: .claude, model: "unknown", reasoning: "high")); XCTFail() }
    catch { XCTAssertEqual(error as? ConversationError, .invalidSelection) }
  }
  func testAlternateModelsAndLevels() async throws {
    for provider in ChatProvider.allCases {
      let config = try configuration(provider, mode: "alternate")
      let agent: ConversationAgent = provider == .claude ? ClaudeConversationAgent(configuration: config)
        : CodexConversationAgent(configuration: config, tokens: FakeConversationTokens(), accountModels: FakeAccountModels())
      let selection = ChatSelection(provider: provider, model: provider == .claude ? "opus" : "gpt-alternate",
        reasoning: provider == .claude ? "max" : "medium")
      let result = try await events(agent, selection)
      XCTAssertEqual(result.last, .completed)
    }
  }
  func testFailedMetadataAndSymlinkedRuntimeAreRefused() async throws {
    let failed = try configuration(.codex, mode: "metadata-failure")
    do {
      _ = try await events(CodexConversationAgent(configuration: failed, tokens: FakeConversationTokens(), accountModels: FakeAccountModels()), .init(provider: .codex, model: "gpt-invented", reasoning: "high"))
      XCTFail()
    } catch { XCTAssertEqual(error as? ConversationError, .unavailable) }
    XCTAssertFalse(FileManager.default.fileExists(atPath: failed.userHome.appendingPathComponent("launch.json").path))
    let config = try configuration(.claude, mode: "symlink")
    let support = config.userHome.appendingPathComponent("Library/Application Support")
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: support.appendingPathComponent("ActivityProbe"),
      withDestinationURL: config.userHome.appendingPathComponent(".claude"))
    do {
      _ = try await events(ClaudeConversationAgent(configuration: config), .init(provider: .claude, model: "sonnet", reasoning: "high"))
      XCTFail()
    } catch { XCTAssertEqual(error as? ConversationError, .unavailable) }
    XCTAssertFalse(FileManager.default.fileExists(atPath: config.userHome.appendingPathComponent(".claude/agent-window").path))
  }
  func testExternalBillingEventIsProviderNeutral() async throws {
    for provider in ChatProvider.allCases {
      let config = try configuration(provider, mode: "external")
      let agent: ConversationAgent = provider == .claude ? ClaudeConversationAgent(configuration: config)
        : CodexConversationAgent(configuration: config, tokens: FakeConversationTokens(), accountModels: FakeAccountModels())
      let result = try await events(agent, .init(provider: provider, model: provider == .claude ? "sonnet" : "gpt-invented", reasoning: "high"))
      XCTAssertEqual(result.first, .billing(provider == .codex ? .subscription : .external))
    }
  }
  func testCancellationEndsOwnedGroup() async throws {
    let config = try configuration(.claude, mode: "hang", timeout: 30)
    let agent = ClaudeConversationAgent(configuration: config)
    let task = Task { try await events(agent, .init(provider: .claude, model: "sonnet", reasoning: "high")) }
    let started = config.userHome.appendingPathComponent("started")
    // A loaded machine can take seconds to start the child; a slow start fails here alone.
    for _ in 0..<1000 where !FileManager.default.fileExists(atPath: started.path) {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    guard FileManager.default.fileExists(atPath: started.path) else {
      task.cancel(); _ = await task.result
      return XCTFail("The fake Claude child did not start within 10 seconds")
    }
    task.cancel()
    _ = await task.result
    let runtime = config.userHome.appendingPathComponent(AgentWindowIdentity.relativeFolder)
    for _ in 0..<100 {
      if (try FileManager.default.contentsOfDirectory(atPath: runtime.path)).isEmpty { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: runtime.path), [])
  }

  // Every process uses the app's plan provider, without a Codex login or the account's connected apps.
  func testEveryCodexChildUsesPlanTokenAndEphemeralCredentialStore() async throws {
    let config = try configuration(.codex)
    _ = try await events(CodexConversationAgent(configuration: config, tokens: FakeConversationTokens(), accountModels: FakeAccountModels()), .init(provider: .codex, model: "gpt-invented", reasoning: "high"))
    let lines = try String(contentsOf: config.userHome.appendingPathComponent("codex-arguments.jsonl")).split(separator: "\n")
    // The conversation checks the model catalog first, then starts its own app-server.
    XCTAssertEqual(lines.count, 2)
    for line in lines {
      let arguments = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String])
      XCTAssertEqual(arguments.filter { $0.hasPrefix("cli_auth_credentials_store=") }, ["cli_auth_credentials_store=\"ephemeral\""])
      XCTAssertFalse(arguments.contains { $0.contains("keyring") })
      for feature in ConversationDiagnostics.codexFeaturesOff {
        XCTAssertEqual(arguments.filter { $0.hasPrefix("features.\(feature)=") }, ["features.\(feature)=false"])
      }
    }
  }

  // Ideal: inherited content logging cannot send even invented metadata to a sink.
  func testCatalogDisablesInheritedTelemetryAndDiagnosticEnvironment() throws {
    let original = try configuration(.codex, mode: "telemetry")
    let home = original.userHome
    try Data(Self.enabledCodexTelemetry.utf8)
      .write(to: home.appendingPathComponent(".codex/config.toml"))
    var inherited = original.inheritedEnvironment
    inherited.merge(["OTEL_EXPORTER_OTLP_ENDPOINT": "http://127.0.0.1:4318", "OTEL_LOG_USER_PROMPTS": "1",
      "OTEL_LOG_TOOL_CONTENT": "1", "DEBUG": "1", "RUST_LOG": "trace",
      "CLAUDE_CODE_DEBUG_LOGS_DIR": home.appendingPathComponent("invented-debug").path,
      "CODEX_TRACE_FILE": home.appendingPathComponent("invented-trace").path,
      "BETA_TRACING_ENDPOINT": "http://127.0.0.1:4318",
      "TRACEPARENT": "00-11111111111111111111111111111111-2222222222222222-01"]) { _, value in value }
    let config = ConversationConfiguration(command: original.command, userHome: home, toolServer: original.toolServer,
      database: original.database, environment: inherited, appBinary: original.appBinary)
    _ = try ConversationProcess.metadata(executable: try config.launch().executable, arguments: ["--telemetry-probe"],
      environment: config.environment, cwd: home)
    let sink = home.appendingPathComponent("telemetry-sink")
    XCTAssertTrue(try String(contentsOf: sink).contains("Invented catalog canary"))
    try FileManager.default.removeItem(at: sink)
    XCTAssertFalse(try CodexConversationAgent(configuration: config, tokens: FakeConversationTokens(), accountModels: FakeAccountModels()).models().isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("telemetry-sink").path))
    XCTAssertNil(config.environment["OTEL_EXPORTER_OTLP_ENDPOINT"])
    XCTAssertEqual(config.environment["RUST_LOG"], "off")
    XCTAssertEqual(config.environment["OTEL_LOG_TOOL_CONTENT"], "0")
    XCTAssertNil(config.environment["CODEX_TRACE_FILE"])
    XCTAssertNil(config.environment["BETA_TRACING_ENDPOINT"])
    XCTAssertNil(config.environment["TRACEPARENT"])
    XCTAssertNil(config.environment["CLAUDE_CODE_DEBUG_LOGS_DIR"])
    let claude = try config.claudeLaunch().environment
    for key in ["OTEL_EXPORTER_OTLP_ENDPOINT", "CODEX_TRACE_FILE", "BETA_TRACING_ENDPOINT", "TRACEPARENT", "CLAUDE_CODE_DEBUG_LOGS_DIR"] {
      XCTAssertNil(claude[key], key)
    }
    XCTAssertEqual(claude["OTEL_LOG_TOOL_CONTENT"], "0"); XCTAssertEqual(claude["RUST_LOG"], "off")
  }

  func testTransportContentTelemetryIsOffDespitePersonalSettings() async throws {
    for provider in ChatProvider.allCases {
      let original = try configuration(provider, mode: "telemetry")
      let home = original.userHome
      let enabled = ["CLAUDE_CODE_ENABLE_TELEMETRY": "1", "OTEL_LOG_USER_PROMPTS": "1",
        "OTEL_LOG_ASSISTANT_RESPONSES": "1", "OTEL_LOG_TOOL_CONTENT": "1", "OTEL_LOG_RAW_API_BODIES": "1",
        "OTEL_LOGS_EXPORTER": "otlp", "OTEL_TRACES_EXPORTER": "otlp", "DEBUG": "1"]
      if provider == .claude {
        try JSONSerialization.data(withJSONObject: ["env": enabled])
          .write(to: home.appendingPathComponent(".claude/settings.json"))
      } else {
        try Data(Self.enabledCodexTelemetry.utf8)
          .write(to: home.appendingPathComponent(".codex/config.toml"))
      }
      let config = ConversationConfiguration(command: original.command, userHome: home, toolServer: original.toolServer,
        database: original.database, environment: original.inheritedEnvironment.merging(enabled) { _, value in value }, appBinary: original.appBinary)
      let agent: ConversationAgent = provider == .claude ? ClaudeConversationAgent(configuration: config)
        : CodexConversationAgent(configuration: config, tokens: FakeConversationTokens(), accountModels: FakeAccountModels())
      _ = try ConversationProcess.metadata(executable: try config.launch().executable, arguments: ["--telemetry-probe"],
        environment: provider == .claude ? try config.claudeLaunch().environment : config.environment, cwd: home)
      let sink = home.appendingPathComponent("telemetry-sink")
      XCTAssertTrue(FileManager.default.fileExists(atPath: sink.path))
      try FileManager.default.removeItem(at: sink)
      let result = try await events(agent, .init(provider: provider,
        model: provider == .claude ? "sonnet" : "gpt-invented", reasoning: "high"))
      XCTAssertEqual(result.last, .completed)
      XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("telemetry-sink").path))
      XCTAssertEqual(config.environment["HOME"], config.agentHome.path)
      XCTAssertEqual(config.environment["CODEX_HOME"], original.environment["CODEX_HOME"])
      XCTAssertNil(config.environment["CLAUDE_CONFIG_DIR"])
    }
  }

  func testApprovalsAndFullAbilityTools() async throws {
    for provider in ChatProvider.allCases {
      for answer in ["approve", "deny", "timeout", "session"] {
        let original = try configuration(provider, mode: answer)
        let config = ConversationConfiguration(command: original.command, userHome: original.userHome,
          toolServer: original.toolServer, database: original.database, environment: original.inheritedEnvironment,
          timeout: 3, appBinary: original.appBinary, approvalTimeout: 0.1)
        let agent: ConversationAgent = provider == .claude ? ClaudeConversationAgent(configuration: config)
          : CodexConversationAgent(configuration: config, tokens: FakeConversationTokens(), accountModels: FakeAccountModels())
        var requests = 0
        for try await event in agent.converse(messages: [.init(role: .user, text: "Invented question")],
          selection: .init(provider: provider, model: provider == .claude ? "sonnet" : "gpt-invented", reasoning: "high")) {
          if case .approval(let request) = event {
            requests += 1
            XCTAssertTrue(request.details.contains("Invented action"))
            XCTAssertFalse(request.answer(choiceID: "nonexistent"))
            if answer != "timeout" { XCTAssertTrue(request.answer(choiceID: answer)) }
          }
        }
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(try String(contentsOf: original.userHome.appendingPathComponent("decision")),
          answer == "timeout" ? "deny" : answer)
      }
    }
  }
  func testCodexDescendantApprovalsAndInterleavedLifecycles() async throws {
    let config = try configuration(.codex, mode: "descendants")
    var requests: [ConversationApproval] = [], resolved = Set<String>(), completed = 0
    var activeTools = Set<String>()
    for try await event in CodexConversationAgent(configuration: config, tokens: FakeConversationTokens(), accountModels: FakeAccountModels()).converse(
      messages: [.init(role: .user, text: "Invented question")],
      selection: .init(provider: .codex, model: "gpt-invented", reasoning: "high")) {
      switch event {
      case .approval(let request):
        requests.append(request)
        if requests.count < 3 { XCTAssertTrue(request.answer(choiceID: requests.count == 1 ? "approve" : "deny")) }
      case .approvalResolved(let id): resolved.insert(id)
      case .completed: completed += 1
      case .toolStarted(let id, _): XCTAssertTrue(activeTools.insert(id).inserted)
      case .toolFinished(let id, _): XCTAssertNotNil(activeTools.remove(id))
      default: break
      }
    }
    XCTAssertEqual(requests.count, 3)
    XCTAssertEqual(resolved, Set(requests.map(\.id)))
    XCTAssertEqual(completed, 1)
    XCTAssertTrue(activeTools.isEmpty)
    XCTAssertFalse(requests.last?.answer(choiceID: "approve") ?? true)
    XCTAssertEqual(try String(contentsOf: config.userHome.appendingPathComponent("child-decisions")), "accept,decline")
  }
  // Ideal: child traffic can precede the spawn receipt, and retries never end a turn.
  func testCodexEarlyDescendantEventsAndScopedErrors() async throws {
    for mode in ["early-descendants", "child-terminal", "child-retry", "root-retry"] {
      let config = try configuration(.codex, mode: mode)
      var requests = 0, completed = 0, sawChildTool = false
      do {
        for try await event in CodexConversationAgent(configuration: config, tokens: FakeConversationTokens(), accountModels: FakeAccountModels()).converse(
          messages: [.init(role: .user, text: "Invented question")],
          selection: .init(provider: .codex, model: "gpt-invented", reasoning: "high")) {
          if case .toolStarted(let id, _) = event, id.contains("child1"), id.hasSuffix("shared-id") { sawChildTool = true }
          if case .approval(let request) = event {
            requests += 1
            if mode == "early-descendants", requests == 1 { XCTAssertTrue(sawChildTool, "Replay must publish preceding child events before its approval") }
            XCTAssertTrue(request.answer(choiceID: requests == 1 ? "approve" : "deny"))
          }
          if event == .completed { completed += 1 }
        }
        XCTAssertEqual(completed, 1, mode)
        XCTAssertEqual(requests, 3, mode)
      } catch { XCTFail("\(mode): \(error)") }
    }
  }
  func testCodexUnrelatedThreadCannotAcquireApprovalThroughNonSpawnItem() async throws {
    let config = try configuration(.codex, mode: "foreign-child")
    var approvals = 0, foreignText = 0, completed = 0
    for try await event in CodexConversationAgent(configuration: config, tokens: FakeConversationTokens(), accountModels: FakeAccountModels()).converse(
      messages: [.init(role: .user, text: "Invented question")],
      selection: .init(provider: .codex, model: "gpt-invented", reasoning: "high")) {
      if case .approval = event { approvals += 1 }
      if case .text(let text) = event, text.contains("Foreign") { foreignText += 1 }
      if event == .completed { completed += 1 }
    }
    XCTAssertEqual(approvals, 0)
    XCTAssertEqual(foreignText, 0)
    XCTAssertEqual(completed, 1)
  }

  func testClaudeNativeSendMessageResumeOverOpenPipe() async throws {
    for shape in ["send", "spawn", "absent"] {
      let config = try configuration(.claude, mode: "resume-" + shape)
      var approvals = 0, completed = 0, resumedText = 0, admitted = false
      for try await event in ClaudeConversationAgent(configuration: config).converse(
        messages: [.init(role: .user, text: "Invented question")],
        selection: .init(provider: .claude, model: "sonnet", reasoning: "high")) {
        if case .text("Admission follows") = event { admitted = true }
        if case .text("Resumed output") = event { XCTAssertTrue(admitted); resumedText += 1 }
        if case .approval(let request) = event {
          XCTAssertTrue(admitted); approvals += 1
          XCTAssertTrue(request.answer(choiceID: "approve"))
        }
        if event == .completed { completed += 1 }
      }
      XCTAssertEqual(approvals, 1, shape); XCTAssertEqual(completed, 1, shape)
      XCTAssertEqual(resumedText, 1, shape)
    }
  }

  func testCumulativeAnswerBoundAcrossFrames() async throws {
    for provider in ChatProvider.allCases {
      let config = try configuration(provider, mode: "answer-overflow")
      let agent: ConversationAgent = provider == .claude ? ClaudeConversationAgent(configuration: config)
        : CodexConversationAgent(configuration: config, tokens: FakeConversationTokens(), accountModels: FakeAccountModels())
      do {
        _ = try await events(agent, .init(provider: provider, model: provider == .claude ? "sonnet" : "gpt-invented", reasoning: "high"))
        XCTFail("Answer must be bounded across otherwise valid frames")
      } catch { XCTAssertEqual(error as? ConversationError, .outputLimit) }
    }
  }
  func testAllFiveQueryToolsRunWithoutCardsInBothEngines() async throws {
    for provider in ChatProvider.allCases {
      let config = try configuration(provider, mode: "queries")
      let agent: ConversationAgent = provider == .claude ? ClaudeConversationAgent(configuration: config) : CodexConversationAgent(configuration: config, tokens: FakeConversationTokens(), accountModels: FakeAccountModels())
      let result = try await events(agent, .init(provider: provider, model: provider == .claude ? "sonnet" : "gpt-invented", reasoning: "high"))
      XCTAssertEqual(result.last, .completed)
      XCTAssertFalse(result.contains { if case .approval = $0 { return true }; return false })
      XCTAssertEqual(Set(result.compactMap { if case .toolStarted(_, let name) = $0 { return name }; return nil }), Set(QueryToolContract.names))
    }
  }

  func testSkipSettingChangesOnlyPermissionPolicy() async throws {
    for provider in ChatProvider.allCases {
      let original = try configuration(provider, mode: "skip")
      let config = ConversationConfiguration(command: original.command, userHome: original.userHome,
        toolServer: original.toolServer, database: original.database, environment: original.inheritedEnvironment,
        appBinary: original.appBinary, skipApprovals: true)
      let agent: ConversationAgent = provider == .claude ? ClaudeConversationAgent(configuration: config)
        : CodexConversationAgent(configuration: config, tokens: FakeConversationTokens(), accountModels: FakeAccountModels())
      let result = try await events(agent, .init(provider: provider,
        model: provider == .claude ? "sonnet" : "gpt-invented", reasoning: "high"))
      XCTAssertEqual(result.last, .completed)
      XCTAssertTrue(config.approvalStatus.contains("prompt injection"))
      XCTAssertTrue(config.approvalStatus.contains("direct deletion"))
    }
  }

  func testBothEnginesDenyLoginFilesWithAndWithoutApprovals() throws {
    let original = try configuration(.codex, mode: "fence")
    let inheritedGit = ["GIT_DIR": "/tmp/invented-repo/.git", "GIT_WORK_TREE": "/tmp/invented-repo", "GIT_CONFIG_GLOBAL": "/tmp/invented-gitconfig",
      "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "core.fsmonitor", "GIT_CONFIG_VALUE_0": "invented-command", "GIT_CEILING_DIRECTORIES": "/invented-ceiling"]
    for skip in [false, true] {
      let config = ConversationConfiguration(command: original.command, userHome: original.userHome,
        toolServer: original.toolServer, database: original.database, environment: original.inheritedEnvironment.merging(inheritedGit) { _, git in git },
        appBinary: original.appBinary, skipApprovals: skip)
      let codexHome = config.codexHome.path, legacyClaude = config.appDataDirectory.appendingPathComponent("claude").path
      let user = config.userHome.path
      let work = config.appDataDirectory.appendingPathComponent("agent-window/invented-run")
      // The person's own Claude folder: the default one, and one their login shell names.
      for override in [nil, user + "/invented-claude-folder"] {
        let personal = ClaudePersonalHome(userHome: config.userHome, configOverride: override)
        let folder = override ?? user + "/.claude"
        let claude = config.claudeConversationSettings(work: work, personal: personal)
        let deny = try XCTUnwrap((claude["permissions"] as? [String: Any])?["deny"] as? [String])
        let sandbox = try XCTUnwrap(claude["sandbox"] as? [String: Any])
        let files = try XCTUnwrap(sandbox["filesystem"] as? [String: [String]])
        // Login files, the keychain files, and the person's CLI settings: settings can carry keys or a command
        // that prints one, and the global configuration names the account.
        let globalConfiguration = override.map { $0 + "/.claude.json" } ?? user + "/.claude.json"
        // Copies of the global configuration too: the CLI's rotating backups, its legacy file and an older CLI's home backup.
        let settings = [folder + "/settings.json", folder + "/settings.local.json", globalConfiguration, user + "/.codex/config.toml",
          folder + "/backups", folder + "/.config.json", user + "/.claude.json.backup"]
        for path in [codexHome, legacyClaude, folder + "/.credentials.json", user + "/.codex/auth.json", user + "/Library/Keychains"] + settings {
          for rule in ["Read(/\(path))", "Read(/\(path)/**)", "Edit(/\(path))", "Edit(/\(path)/**)"] { XCTAssertTrue(deny.contains(rule), rule) }
          XCTAssertTrue(files["denyRead"]?.contains(path) == true, path); XCTAssertTrue(files["denyWrite"]?.contains(path) == true, path)
        }
        XCTAssertFalse(deny.contains("Read(/\(folder))"), "the CLI's own folder stays readable to its shell")
        for rule in ["Bash(security *)", "Bash(/usr/bin/security *)"] { XCTAssertTrue(deny.contains(rule), rule) }
        XCTAssertEqual(sandbox["enabled"] as? Bool, true); XCTAssertEqual(sandbox["failIfUnavailable"] as? Bool, true)
        XCTAssertEqual(sandbox["autoAllowBashIfSandboxed"] as? Bool, false); XCTAssertEqual(sandbox["allowUnsandboxedCommands"] as? Bool, false)
        XCTAssertNotNil(claude["env"])
        // Files a later process would run outside the sandbox, and the person's Claude folder, stay closed to writes in
        // both modes: the person's start-up files and git configuration, Codex's in the agent home, which Codex
        // still starts with, and the script Terminal runs for the login.
        let startup = [".zshenv", ".zprofile", ".zshrc", ".zlogin", ".zlogout", ".bashrc", ".bash_profile", ".bash_login", ".profile",
          ".gitconfig", ".config/git"].map { user + "/" + $0 }
        let agentStartup = [".zshenv", ".zprofile", ".zshrc", ".zlogin", ".zlogout", ".bashrc", ".bash_profile", ".bash_login", ".profile",
          ".gitconfig", "xdg_config_home/git"].map { config.agentHome.appendingPathComponent($0).path }
        let login = config.appDataDirectory.appendingPathComponent("claude-login").path
        for path in [folder, work.path + "/.claude", login, config.appDataDirectory.appendingPathComponent(AgentLogOwnSources.folderName).path] + startup + agentStartup {
          for rule in ["Edit(/\(path))", "Edit(/\(path)/**)"] { XCTAssertTrue(deny.contains(rule), rule) }
          XCTAssertFalse(deny.contains("Read(/\(path))"), path)
          XCTAssertTrue(files["denyWrite"]?.contains(path) == true, path); XCTAssertFalse(files["denyRead"]?.contains(path) == true, path)
        }
        XCTAssertEqual(claude["disableAllHooks"] as? Bool, true)
        XCTAssertEqual(claude["includeGitInstructions"] as? Bool, false)
        XCTAssertEqual(claude["autoMemoryEnabled"] as? Bool, false)
        XCTAssertEqual(claude["pluginConfigs"] as? [String: [String: [String: String]]],
          ["cc-plugin-agents-md@builtin": ["options": ["instructionFiles": "managed-only"]]])
        XCTAssertEqual(claude["disableClaudeAiConnectors"] as? Bool, true)
      }
      // Codex keeps its app-only home and shell folders.
      let startup = [".zshenv", ".zprofile", ".zshrc", ".zlogin", ".zlogout", ".bashrc", ".bash_profile", ".bash_login", ".profile",
        ".gitconfig", "xdg_config_home/git"].map { config.agentHome.appendingPathComponent($0).path }
      XCTAssertEqual(config.environment["XDG_CONFIG_HOME"], config.agentHome.appendingPathComponent("xdg_config_home").path)
      let runRoot = config.appDataDirectory.appendingPathComponent("agent-window")
      try FileManager.default.createDirectory(at: config.appDataDirectory, withIntermediateDirectories: true)
      for launched in [try config.launch().environment, try config.claudeLaunch().environment] {
        let ceiling = try XCTUnwrap(launched["GIT_CEILING_DIRECTORIES"]).split(separator: ":").map(String.init)
        XCTAssertEqual(ceiling, ConversationConfiguration.spellings(runRoot) + ConversationConfiguration.spellings(config.appDataDirectory))
        let resolved = try XCTUnwrap(realpath(config.appDataDirectory.path, nil))
        let realAppData = String(cString: resolved); free(resolved)
        for path in [runRoot.path, config.appDataDirectory.path, realAppData + "/agent-window", realAppData] {
          XCTAssertTrue(ceiling.contains(path), path + " not in " + ceiling.joined(separator: ":"))
        }
        XCTAssertEqual(launched.keys.filter { $0.hasPrefix("GIT_") }, ["GIT_CEILING_DIRECTORIES"])
      }
      // Claude keeps the inherited HOME and gets no folder of the app's; inherited CLAUDE_CONFIG_DIR is dropped.
      let claudeLaunch = try config.claudeLaunch()
      XCTAssertEqual(claudeLaunch.environment["HOME"], user)
      for key in ["CLAUDE_CONFIG_DIR", "CFFIXED_USER_HOME", "ZDOTDIR", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME",
        "CODEX_HOME", "CODEX_SQLITE_HOME", "CODEX_INTERNAL_ORIGINATOR_OVERRIDE"] {
        XCTAssertNil(claudeLaunch.environment[key], key)
      }
      XCTAssertEqual(claudeLaunch.environment["CLAUDE_CODE_DISABLE_AUTO_MEMORY"], "1")
      XCTAssertEqual(claudeLaunch.environment["ACTIVITYPROBE_DB"], config.database.path)
      XCTAssertEqual(claudeLaunch.personal, ClaudePersonalHome(userHome: config.userHome, configOverride: nil))
      let codex = config.codexPermissions
      XCTAssertEqual(codex.profile, skip ? "activityprobe-conversation-open" : "activityprobe-conversation")
      XCTAssertEqual(codex.settings["default_permissions"] as? String, codex.profile)
      let profile = try XCTUnwrap((codex.settings["permissions"] as? [String: Any])?[codex.profile] as? [String: Any])
      let filesystem = try XCTUnwrap(profile["filesystem"] as? [String: String])
      for path in [legacyClaude, codexHome + "/auth.json", codexHome + "/.credentials.json", user + "/.claude", user + "/.codex/auth.json",
        user + "/.claude.json", user + "/.codex/config.toml", user + "/.claude/backups", user + "/.claude/.config.json",
        user + "/.claude.json.backup"] {
        XCTAssertEqual(filesystem[path], "deny", path)
      }
      for path in ConversationConfiguration.spellings(config.userHome.appendingPathComponent("Library/Keychains")) {
        XCTAssertEqual(filesystem[path], "deny", path)
      }
      for path in [codexHome, config.appDataDirectory.appendingPathComponent("claude-login").path,
        config.appDataDirectory.appendingPathComponent(AgentLogOwnSources.folderName).path] + startup {
        XCTAssertEqual(filesystem[path], "read", path)
      }
      XCTAssertEqual(filesystem[":root"], skip ? "write" : nil)
      XCTAssertEqual(profile["extends"] as? String, skip ? nil : ":workspace")
      XCTAssertEqual(codex.extends, skip ? nil : ":workspace")
      XCTAssertEqual(codex.settings["project_root_markers"] as? [String], [])
      let arguments = try ConversationEncoding.overrides(codex.settings)
      XCTAssertTrue(arguments.contains("project_root_markers=[]"))
      XCTAssertTrue(arguments.contains { $0.hasPrefix("permissions=") && $0.contains("\"" + legacyClaude + "\"=\"deny\"") })
    }
    let aliased = ConversationConfiguration.spellings(URL(fileURLWithPath: "/tmp/invented-login"))
    XCTAssertEqual(aliased, ["/tmp/invented-login", "/private/tmp/invented-login"])
  }

  static let fixture = #"""
#!/usr/bin/python3
import json, os, re, select, subprocess, sys, time
from interactive_pipe import LinePeer, verify_query_server
args = sys.argv[1:]
provider, mode = os.environ['INVENTED_PROVIDER'], os.environ['INVENTED_MODE']
names = ['recent_work', 'what_was_i_doing', 'search_activity', 'time_breakdown', 'day_summary']
home, cwd = os.environ['INVENTED_ROOT'], os.getcwd()
wire = LinePeer(sys.stdin.fileno(), sys.stdout.fileno(), timeout=5)
if provider == 'claude':
    # The person's own install: their HOME, no config folder of the app's or inherited one, no app folders.
    assert os.environ['HOME'] == home and 'CLAUDE_CONFIG_DIR' not in os.environ, sorted(os.environ)
    assert not [k for k in os.environ if k in ('CFFIXED_USER_HOME', 'ZDOTDIR', 'TMPDIR') or k.startswith('XDG_') or k.startswith('CODEX_')], sorted(os.environ)
    assert os.environ['CLAUDE_CODE_DISABLE_AUTO_MEMORY'] == '1'
agent_home = home + '/.claude' if provider == 'claude' else os.environ['CODEX_HOME']
if provider == 'codex' and 'app-server' in args: assert set(os.listdir(agent_home)) == {'config.toml', 'activityprobe-owned-home'}
os.makedirs(agent_home, exist_ok=True)
with open(agent_home + '/cli-owned-state', 'a') as f: f.write('invented state\n')
if provider == 'codex' and 'app-server' in args:
    assert os.environ['ACTIVITYPROBE_CHATGPT_ACCESS_TOKEN'] in ['invented-conversation-access', 'invented-renewed-access']
    assert os.environ['ACTIVITYPROBE_CHATGPT_ACCESS_TOKEN'] not in ' '.join(args)
    assert not os.path.exists(agent_home + '/AGENTS.md')
    assert not os.path.exists(agent_home + '/AGENTS.override.md')
    assert not os.path.exists(agent_home + '/auth.json')
    assert 'model_provider="activityprobe_chatgpt_plan"' in args
    assert 'project_root_markers=[]' in args
    assert 'project_doc_max_bytes=0' in args
    for key in ['hooks', 'memories', 'shell_snapshot', 'shell_snapshot_v2', 'code_mode_only_strict_3p_tools']:
        assert 'features.' + key + '=false' in args
    assert 'shell_environment_policy={"exclude"=["ACTIVITYPROBE_CHATGPT_ACCESS_TOKEN"]}' in args
    provider_config = next(s for s in args if s.startswith('model_providers='))
    assert '"base_url"="https://api.openai.com/v1"' in provider_config
    assert '"requires_openai_auth"=false' in provider_config and '"supports_websockets"=false' in provider_config
    assert '"env_key"="ACTIVITYPROBE_CHATGPT_ACCESS_TOKEN"' in provider_config
    assert os.environ['CODEX_SQLITE_HOME'] == os.environ['CODEX_HOME']
    if 'app-server' in args:
        with open(home + '/codex-arguments.jsonl', 'a') as f: f.write(json.dumps(args) + '\n')

def emit(value):
    wire.send(value)
def response(message, value):
    emit({'id': message['id'], 'result': value})
def save(tool_environment):
    with open(home + '/launch.json', 'w') as f:
        json.dump({'args': args, 'home': os.environ['HOME'], 'cwd': cwd, 'codex_home': os.environ.get('CODEX_HOME'), 'claude_home': os.environ.get('CLAUDE_CONFIG_DIR'), 'tool_environment': tool_environment}, f)
def query_server(command, env):
    verify_query_server(command, env, expected_minutes=3)
    wrong = dict(env, ACTIVITYPROBE_QUERY_TOKEN='wrong')
    assert subprocess.run([command], env=dict(os.environ, **wrong), input='', capture_output=True, text=True).returncode != 0
def assert_git_ceiling():
    def spellings(path):
        resolved = os.path.join(os.path.realpath(os.path.dirname(path)), os.path.basename(path))
        return [path] + ([resolved] if resolved != path else [])
    ceiling = os.environ['GIT_CEILING_DIRECTORIES'].split(':')
    app = os.path.dirname(os.path.dirname(os.path.dirname(os.environ['CODEX_HOME']))) if provider == 'codex' else home + '/Library/Application Support/ActivityProbe'
    run_root = app + '/agent-window'
    assert ceiling == spellings(run_root) + spellings(app), ceiling
    assert os.path.realpath(run_root) in ceiling and os.path.realpath(app) in ceiling and os.path.dirname(cwd) in ceiling, ceiling
    assert [k for k in os.environ if k.startswith('GIT_')] == ['GIT_CEILING_DIRECTORIES'], sorted(os.environ)
def log(origin=''):
    # Like the real CLI, a run without session persistence saves no transcript.
    if '--no-session-persistence' in args or provider == 'codex': return
    folder = home + '/.claude/projects' if provider == 'claude' else os.environ['CODEX_HOME'] + '/sessions'
    os.makedirs(folder, exist_ok=True)
    path = folder + '/invented.jsonl'
    lines = ([{'type': 'session_meta', 'payload': {'id': 'invented', 'cwd': cwd, 'originator': origin, 'source': 'cli'}},
              {'type': 'event_msg', 'timestamp': '1970-01-01T04:00:00Z', 'payload': {'type': 'item_completed', 'item': {'type': 'UserMessage', 'id': 'invented', 'content': [{'type': 'input_text', 'text': 'Invented question'}]}}}]
             if provider == 'codex' else
             [{'type': 'user', 'uuid': 'invented', 'sessionId': 'invented', 'cwd': cwd, 'timestamp': '1970-01-01T04:00:00Z', 'message': {'role': 'user', 'content': 'Invented question'}}])
    with open(path, 'w') as f:
        f.write(''.join(json.dumps(x) + '\n' for x in lines))
telemetry = False
if mode == 'telemetry':
    if provider == 'codex':
        with open(home + '/.codex/config.toml') as f: assert 'log_user_prompt = true' in f.read()
        disabled = all(setting in args for setting in ['otel.log_user_prompt=false', 'otel.log_agent_responses=false', 'otel.tool_result.max_bytes=0', 'otel.exporter="none"', 'otel.trace_exporter="none"', 'otel.metrics_exporter="none"', 'analytics.enabled=false', 'feedback.enabled=false'])
        telemetry = not disabled or os.environ.get('RUST_LOG') != 'off'
    else:
        with open(home + '/.claude/settings.json') as f: personal = json.load(f)['env']
        effective = dict(os.environ, **personal)
        if '--settings' in args:
            effective.update(json.loads(args[args.index('--settings') + 1])['env'])
        telemetry = any(effective.get(k) != '0' for k in ['CLAUDE_CODE_ENABLE_TELEMETRY', 'OTEL_LOG_USER_PROMPTS', 'OTEL_LOG_ASSISTANT_RESPONSES', 'OTEL_LOG_TOOL_CONTENT', 'OTEL_LOG_RAW_API_BODIES', 'DEBUG']) or effective.get('OTEL_LOGS_EXPORTER') != 'none'
def export_content(text):
    if telemetry:
        with open(home + '/telemetry-sink', 'a') as f: f.write(text + '\n')
export_content('Invented catalog canary')
if args == ['--telemetry-probe']: sys.exit(0)
if mode == 'metadata-failure' and 'app-server' in args:
    print('{}')
    sys.exit(7 if mode == 'metadata-failure' else 0)
if 'auth' in args and 'status' in args:
    if mode == 'logged-out':
        emit({'loggedIn': False})
        sys.exit(1)
    emit({'loggedIn': True, 'authMethod': 'api_key' if mode == 'external' else 'claude.ai'})
    sys.exit(0)
if args[:2] == ['mcp', 'list']:
    print('Name       Command Args Env Cwd Status  Auth\ninvented   fake    -    -   -   enabled Unsupported')
    sys.exit(0)
if mode == 'hang':
    with open(os.environ['INVENTED_ROOT'] + '/started', 'w') as f: f.write(str(os.getpid()))
    time.sleep(30)
if mode == 'partial-eof':
    os.write(sys.stdout.fileno(), b'{"incomplete":')
    sys.exit(0)
if mode == 'overlong':
    os.write(sys.stdout.fileno(), b'x' * 1048577)
    sys.exit(0)
if provider == 'claude':
    assert args[args.index('--model') + 1] == ('opus' if mode == 'alternate' else 'sonnet')
    assert args[args.index('--effort') + 1] == ('max' if mode == 'alternate' else 'high')
    assert '--tools' not in args and '--disallowedTools' not in args
    assert set(args[args.index('--allowedTools') + 1].split(',')) == {'mcp__activityprobe__' + n for n in names}
    assert args[args.index('--permission-mode') + 1] == 'manual'
    settings = json.loads(args[args.index('--settings') + 1])
    sandbox, deny = settings['sandbox'], settings['permissions']['deny']
    assert sandbox['enabled'] and sandbox['failIfUnavailable'] and sandbox['autoAllowBashIfSandboxed'] is False and sandbox['allowUnsandboxedCommands'] is False
    app = home + '/Library/Application Support/ActivityProbe'
    for denied in [app + '/codex', app + '/claude', home + '/.claude/.credentials.json', home + '/.codex/auth.json', home + '/Library/Keychains',
                   home + '/.claude/settings.json', home + '/.claude/settings.local.json', home + '/.claude.json', home + '/.codex/config.toml']:
        assert all(tool + '(/' + denied + tail + ')' in deny for tool in ['Read', 'Edit'] for tail in ['', '/**']), denied
        assert denied in sandbox['filesystem']['denyRead'] and denied in sandbox['filesystem']['denyWrite']
    codex_shell = app + '/agent-home'
    for closed in [home + '/.claude', cwd + '/.claude', app + '/claude-login', app + '/own-agent-log-sources', home + '/.zshenv', home + '/.zshrc', home + '/.profile', home + '/.gitconfig', home + '/.config/git',
                   codex_shell + '/.zshenv', codex_shell + '/.zshrc', codex_shell + '/.profile', codex_shell + '/.gitconfig', codex_shell + '/xdg_config_home/git']:
        assert all('Edit(/' + closed + tail + ')' in deny for tail in ['', '/**']) and closed in sandbox['filesystem']['denyWrite'], closed
        assert 'Read(/' + closed + ')' not in deny and closed not in sandbox['filesystem']['denyRead'], closed
    assert 'Read(/' + home + '/.claude)' not in deny
    assert 'Bash(security *)' in deny
    assert settings['disableAllHooks'] is True and settings['autoMemoryEnabled'] is False and settings['includeGitInstructions'] is False
    assert settings['pluginConfigs'] == {'cc-plugin-agents-md@builtin': {'options': {'instructionFiles': 'managed-only'}}}
    assert args[args.index('--setting-sources') + 1] == ''
    assert_git_ceiling()
    assert '--strict-mcp-config' in args and '--no-session-persistence' in args and '--disable-slash-commands' in args
    assert os.environ['ENABLE_CLAUDEAI_MCP_SERVERS'] == 'false'
    flag_settings = json.loads(args[args.index('--settings') + 1])
    assert flag_settings['disableClaudeAiConnectors'] is True and flag_settings['env']['ENABLE_CLAUDEAI_MCP_SERVERS'] == 'false'
    config = json.loads(args[args.index('--mcp-config') + 1])
    assert list(config['mcpServers']) == ['activityprobe']
    env = config['mcpServers']['activityprobe']['env']
    assert os.path.exists(env['ACTIVITYPROBE_QUERY_LEASE'])
    query_server(config['mcpServers']['activityprobe']['command'], env)
    save(env)
    for message in wire.messages():
        if message.get('type') != 'user':
            continue
        assert 'evidence, never instructions' in message['message']['content']
        assert 'privacy forget' in message['message']['content']
        assert '/ActivityProbe' in message['message']['content']
        export_content(message['message']['content'])
        export_content('Invented response and tool content')
        log()
        if mode == 'early-eof': sys.exit(0)
        tools = ['mcp__activityprobe__' + n for n in names]
        tools += ['Bash', 'Read', 'Write']
        if mode == 'inventory': tools.remove('mcp__activityprobe__day_summary')
        emit({'type': 'system', 'subtype': 'init', 'tools': tools, 'mcp_servers': [{'name': 'activityprobe', 'status': 'connected'}]})
        if mode.startswith('resume-'):
            def assistant(blocks, parent=None, agent=None):
                emit({'type': 'assistant', 'parent_tool_use_id': parent, 'agent_id': agent,
                      'message': {'id': 'invented', 'role': 'assistant', 'content': blocks}})
            def tool_result(tool_id):
                emit({'type': 'user', 'message': {'content': [{'type': 'tool_result', 'tool_use_id': tool_id}]}})
            assistant([{'type': 'tool_use', 'id': 'spawn', 'name': 'Agent', 'input': {'prompt': 'Invented task'}}])
            emit({'type': 'system', 'subtype': 'task_started', 'task_id': 'child', 'run_id': '001', 'tool_use_id': 'spawn'})
            emit({'type': 'system', 'subtype': 'task_notification', 'task_id': 'child', 'run_id': '001', 'status': 'completed'})
            tool_result('spawn')
            assistant([{'type': 'tool_use', 'id': 'resume', 'name': 'SendMessage', 'input': {'to': 'child', 'message': 'Invented continuation'}}])
            emit({'type': 'control_request', 'request_id': 'resumed-approval', 'request': {'subtype': 'can_use_tool', 'agent_id': 'child', 'tool_name': 'Bash', 'tool_use_id': 'action', 'input': {'command': 'invented'}}})
            assistant([{'type': 'text', 'text': 'Resumed output'}], 'spawn', 'child')
            assert not select.select([sys.stdin.fileno()], [], [], 0.1)[0], 'Answered before run admission'
            assistant([{'type': 'text', 'text': 'Admission follows'}])
            start = {'type': 'system', 'subtype': 'task_started', 'task_id': 'child', 'run_id': '002'}
            if mode == 'resume-send': start['tool_use_id'] = 'resume'
            if mode == 'resume-spawn': start['tool_use_id'] = 'spawn'
            emit(start)
            emit({'type': 'system', 'subtype': 'task_notification', 'task_id': 'child', 'run_id': '001', 'status': 'completed'})
            assert wire.read()['response']['response']['behavior'] == 'allow'
            emit({'type': 'system', 'subtype': 'task_notification', 'task_id': 'child', 'run_id': '002', 'status': 'completed'})
            tool_result('resume')
            emit({'type': 'result', 'is_error': False})
            continue
        if mode == 'wrong-thread':
            emit({'type': 'assistant', 'message': {'id': 'a1', 'role': 'invalid', 'content': [{'type': 'text', 'text': 'Foreign answer'}]}})
            sys.exit(0)
        if mode in ['approve', 'deny', 'timeout', 'session']:
            emit({'type': 'control_request', 'request_id': 'approval1', 'request': {'subtype': 'can_use_tool', 'tool_name': 'Bash', 'tool_use_id': 'q1', 'title': 'Invented action', 'input': {'command': 'invented'}, 'permission_suggestions': [{'type': 'addRules', 'rules': [{'toolName': 'Bash', 'ruleContent': 'invented'}], 'behavior': 'allow', 'destination': 'session'}]}})
            reply = wire.read()['response']['response']
            decision = 'session' if reply.get('updatedPermissions') else 'approve' if reply['behavior'] == 'allow' else 'deny'
            with open(home + '/decision', 'w') as f: f.write(decision)
            assert decision == ('deny' if mode == 'timeout' else mode)
        if mode == 'queries':
            for index, name in enumerate(names):
                tool = 'mcp__activityprobe__' + name
                emit({'type': 'control_request', 'request_id': 'query-' + str(index), 'request': {'subtype': 'can_use_tool', 'tool_name': tool, 'input': {'at': 14400}}})
                assert wire.read()['response']['response'] == {'behavior': 'allow', 'updatedInput': {'at': 14400}}
                emit({'type': 'assistant', 'message': {'id': 'a' + str(index), 'role': 'assistant', 'content': [{'type': 'tool_use', 'id': 'q' + str(index), 'name': tool, 'input': {'at': 14400}}]}})
                emit({'type': 'user', 'message': {'content': [{'type': 'tool_result', 'tool_use_id': 'q' + str(index), 'content': 'Invented', 'is_error': False}]}})
            emit({'type': 'result', 'is_error': False})
            continue
        if mode == 'skip': assert '--dangerously-skip-permissions' in args
        tool = 'Bash' if mode in ['write', 'approve', 'deny', 'timeout', 'session'] else 'mcp__activityprobe__day_summary'
        emit({'type': 'assistant', 'message': {'id': 'a1', 'role': 'assistant', 'content': [{'type': 'tool_use', 'id': 'q1', 'name': tool, 'input': {'at': 14400}}]}})
        emit({'type': 'user', 'message': {'content': [{'type': 'tool_result', 'tool_use_id': 'q1', 'content': 'Private tool content', 'is_error': False}]}})
        emit({'type': 'stream_event', 'event': {'type': 'message_start', 'message': {'id': 'a2'}}})
        if mode == 'answer-overflow':
            for _ in range(5): emit({'type': 'stream_event', 'event': {'type': 'content_block_delta', 'delta': {'type': 'text_delta', 'text': 'x' * 900000}}})
        emit({'type': 'stream_event', 'event': {'type': 'content_block_delta', 'delta': {'type': 'text_delta', 'text': 'Invented answer'}}})
        emit({'type': 'assistant', 'message': {'id': 'a2', 'role': 'assistant', 'content': [{'type': 'text', 'text': 'Invented answer'}]}})
        emit({'type': 'result', 'is_error': False})
else:
    for message in wire.messages():
        method, params = message.get('method'), message.get('params', {})
        if method == 'initialize':
            origin = params['clientInfo']['name']
            assert origin == 'ActivityProbe'
            assert 'CODEX_INTERNAL_ORIGINATOR_OVERRIDE' not in os.environ
            response(message, {})
        elif method == 'model/list':
            if mode == 'host-catalog':
                # The test waits only for the marker to exist, so publish it complete.
                with open(home + '/crash-ready.json.tmp', 'w') as f: json.dump({'home': agent_home, 'group': os.getpgrp()}, f)
                os.replace(home + '/crash-ready.json.tmp', home + '/crash-ready.json')
                time.sleep(60)
            response(message, {'data': [{'id': 'invented-id', 'model': 'gpt-alternate' if mode == 'alternate' else 'gpt-invented', 'supportedReasoningEfforts': [{'reasoningEffort': 'medium'}] if mode == 'alternate' else [{'reasoningEffort': 'low'}, {'reasoningEffort': 'invented-level'}, {'reasoningEffort': 'high'}]}, {'id': 'invented-new', 'model': 'gpt-invented-new', 'supportedReasoningEfforts': [{'reasoningEffort': 'invented-level'}]}], 'nextCursor': None})
        elif method == 'account/read':
            raise AssertionError('Native Codex login must not be consulted')
        elif method == 'thread/start':
            assert 'cli_auth_credentials_store="ephemeral"' in args
            assert params['ephemeral'] is True
            assert params['modelProvider'] == 'activityprobe_chatgpt_plan'
            assert params['config']['project_root_markers'] == []
            assert params['config']['project_doc_max_bytes'] == 0
            assert 'developerInstructions' in params
            effort = 'medium' if mode == 'alternate' else 'high'
            assert params['model'] == ('gpt-alternate' if mode == 'alternate' else 'gpt-invented')
            assert 'baseInstructions' not in params
            assert 'model_reasoning_effort="' + effort + '"' in args
            assert not any('shell_tool' in s for s in args)
            profile = 'activityprobe-conversation' + ('-open' if mode == 'skip' else '')
            assert params['permissions'] == profile and 'sandbox' not in params
            assert 'default_permissions="' + profile + '"' in args and not any(s.startswith('sandbox_mode=') for s in args)
            fence = next(s for s in args if s.startswith('permissions='))
            for denied in [os.path.dirname(os.path.dirname(os.path.dirname(os.environ['CODEX_HOME']))) + '/claude', os.path.dirname(os.path.dirname(os.environ['CODEX_HOME'])) + '/auth.json', home + '/.claude', home + '/.codex/auth.json',
                           home + '/Library/Keychains', home + '/.claude.json', home + '/.codex/config.toml']:
                assert json.dumps(denied) + '="deny"' in fence
            shell_home = os.environ['ZDOTDIR']
            for closed in [os.path.dirname(os.path.dirname(os.environ['CODEX_HOME'])), os.path.dirname(os.path.dirname(os.path.dirname(os.environ['CODEX_HOME']))) + '/claude-login', os.path.dirname(os.path.dirname(os.path.dirname(os.environ['CODEX_HOME']))) + '/own-agent-log-sources']:
                assert json.dumps(closed) + '="read"' in fence
            assert os.environ['XDG_CONFIG_HOME'] == shell_home == os.environ['HOME'] == os.environ['CODEX_HOME']
            assert_git_ceiling()
            assert 'project_root_markers=[]' in args
            assert ('":root"="write"' in fence) == (mode == 'skip') and ('"extends"=":workspace"' in fence) == (mode != 'skip')
            inline = next(s for s in args if s.startswith('mcp_servers='))
            assert '"omit_tools_from"=["deferred"]' in inline
            assert 'default_tools_approval_mode' in inline and '"approve"' in inline
            assert 'enabled_tools' in inline and all('\"' + n + '\"' in inline for n in names)
            env = {key: json.loads(re.search('"' + key + '"=("(?:[^"\\\\]|\\\\.)*")', inline).group(1)) for key in ['ACTIVITYPROBE_QUERY_LEASE', 'ACTIVITYPROBE_QUERY_TOKEN', 'ACTIVITYPROBE_QUERY_DATABASE', 'ACTIVITYPROBE_QUERY_APP_DATA']}
            command = json.loads(re.search('"command"=("(?:[^"\\\\]|\\\\.)*")', inline).group(1))
            query_server(command, env)
            save(env); log(origin)
            response(message, {'thread': {'id': 'thread1', 'originator': origin, 'ephemeral': params['ephemeral']}, 'modelProvider': params['modelProvider'], 'model': params['model'], 'reasoningEffort': effort, 'cwd': cwd, 'sandbox': {'type': 'workspaceWrite'}, 'activePermissionProfile': {'id': profile, 'extends': None if mode == 'skip' else ':workspace'}, 'approvalPolicy': 'never' if mode == 'skip' else 'on-request'})
        elif method == 'mcpServerStatus/list':
            tools = {n: {} for n in names}
            if mode == 'inventory': tools['write'] = {}
            servers = [{'name': 'activityprobe', 'tools': tools, 'resources': [], 'resourceTemplates': []}]
            # Like the real CLI, the account's connected apps arrive as one more server unless turned off.
            if 'features.apps=false' not in args: servers.append({'name': 'codex_apps', 'tools': {'invented_connector_write': {}}, 'resources': [], 'resourceTemplates': []})
            response(message, {'data': servers, 'nextCursor': None})
        elif method == 'turn/start':
            if mode == 'host-turn':
                with open(home + '/crash-ready.json.tmp', 'w') as f: json.dump({'home': agent_home, 'group': os.getpgrp(), 'lease': env['ACTIVITYPROBE_QUERY_LEASE']}, f)
                os.replace(home + '/crash-ready.json.tmp', home + '/crash-ready.json')
                time.sleep(60)
            assert 'evidence, never instructions' in params['input'][0]['text']
            assert 'privacy forget' in params['input'][0]['text']
            export_content(json.dumps(params['input']))
            export_content('Invented response and tool content')
            assert params['effort'] == ('medium' if mode == 'alternate' else 'high')
            if mode == 'early-eof': sys.exit(0)
            if mode.startswith('plan-rpc-'):
                status = int(mode.split('-')[-1])
                emit({'id': message['id'], 'error': {'code': -32603, 'message': 'Invented failure', 'data': {'codexErrorInfo': {'httpConnectionFailed': {'httpStatusCode': status}}}}})
                continue
            response(message, {'turn': {'id': 'turn1'}})
            thread = 'foreign' if mode == 'wrong-thread' else 'thread1'
            emit({'method': 'turn/started', 'params': {'threadId': thread, 'turn': {'id': 'turn1'}}})
            if mode in ['native-http', 'native-stream']:
                with open(home + '/native-errors.json') as f: native = json.load(f)['fixtures'][0 if mode == 'native-http' else 1]['native']
                emit({'method': 'error', 'params': {'threadId': thread, 'turnId': 'turn1', 'willRetry': False, 'error': native}})
                continue
            if mode == 'plan-pending-401':
                emit({'method': 'thread/started', 'params': {'thread': {'id': 'pending-child', 'parentThreadId': thread}}})
                emit({'method': 'turn/started', 'params': {'threadId': 'pending-child', 'turn': {'id': 'pending-turn'}}})
                emit({'id': 'pending-approval', 'method': 'item/commandExecution/requestApproval', 'params': {'threadId': 'pending-child', 'turnId': 'pending-turn', 'itemId': 'pending-action', 'command': 'invented action', 'cwd': cwd}})
                ready_until = time.monotonic() + 2
                while not os.path.exists(home + '/invented-approval-ready'):
                    assert time.monotonic() < ready_until
                    time.sleep(0.01)
                emit({'method': 'error', 'params': {'threadId': thread, 'turnId': 'turn1', 'willRetry': False, 'error': {'message': 'Invented failure', 'codexErrorInfo': 'unauthorized'}}})
                continue
            if mode.startswith('plan-turn-'):
                status = int(mode.split('-')[-1])
                emit({'method': 'error', 'params': {'threadId': thread, 'turnId': 'turn1', 'willRetry': False, 'error': {'message': 'Invented failure', 'codexErrorInfo': {'httpConnectionFailed': {'httpStatusCode': status}}}}})
                continue
            if mode in ['descendants', 'foreign-child', 'early-descendants', 'child-terminal', 'child-retry', 'root-retry']:
                def item_event(phase, tid, turn, item):
                    emit({'method': 'item/' + phase, 'params': {'threadId': tid, 'turnId': turn, 'item': item}})
                spawn = {'id': 'spawn', 'type': 'collabAgentToolCall', 'tool': 'wait' if mode == 'foreign-child' else 'spawnAgent', 'senderThreadId': thread, 'receiverThreadIds': ['child1'], 'status': 'completed'}
                item_event('started', thread, 'turn1', dict(spawn, receiverThreadIds=[]))
                if mode != 'early-descendants':
                    item_event('completed', thread, 'turn1', spawn)
                    emit({'method': 'thread/started', 'params': {'thread': {'id': 'child1'}}})
                emit({'method': 'turn/started', 'params': {'threadId': 'child1', 'turn': {'id': 'child-turn'}}})
                if mode == 'foreign-child':
                    emit({'id': 61, 'method': 'item/commandExecution/requestApproval', 'params': {'threadId': 'child1', 'turnId': 'child-turn', 'itemId': 'shared-id', 'reason': 'Foreign action'}})
                    emit({'method': 'item/agentMessage/delta', 'params': {'threadId': 'child1', 'turnId': 'child-turn', 'delta': 'Foreign output'}})
                    emit({'method': 'turn/completed', 'params': {'threadId': thread, 'turn': {'id': 'turn1', 'status': 'completed'}}})
                    assert wire.read()['error']['message'] == 'unverified_thread'
                    sys.exit(0)
                child_item = {'id': 'shared-id', 'type': 'commandExecution', 'status': 'completed'}
                item_event('started', 'child1', 'child-turn', child_item)
                if mode == 'early-descendants':
                    emit({'id': 60, 'method': 'item/commandExecution/requestApproval', 'params': {'threadId': 'child1', 'turnId': 'child-turn', 'itemId': 'shared-id', 'reason': 'Invented provisional action'}})
                    assert not select.select([sys.stdin.fileno()], [], [], 0.1)[0], 'Approval answered before ancestry verification'
                    item_event('completed', thread, 'turn1', spawn)
                    assert wire.read()['result']['decision'] == 'accept'
                item_event('started', thread, 'turn1', child_item)
                decisions = []
                for request_id in ([62] if mode == 'early-descendants' else [61, 62]):
                    emit({'id': request_id, 'method': 'item/commandExecution/requestApproval', 'params': {'threadId': 'child1', 'turnId': 'child-turn', 'itemId': 'shared-id', 'reason': 'Invented child action'}})
                    decisions.append(wire.read()['result']['decision'])
                # The grandchild may be announced before its parent's spawn item completes.
                emit({'method': 'thread/started', 'params': {'thread': {'id': 'grandchild', 'parentThreadId': 'child1'}}})
                emit({'method': 'turn/started', 'params': {'threadId': 'grandchild', 'turn': {'id': 'grand-turn'}}})
                emit({'id': 63, 'method': 'item/permissions/requestApproval', 'params': {'threadId': 'grandchild', 'turnId': 'grand-turn', 'permissions': {}}})
                emit({'method': 'serverRequest/resolved', 'params': {'threadId': 'grandchild', 'requestId': 63}})
                emit({'method': 'turn/completed', 'params': {'threadId': 'grandchild', 'turn': {'id': 'grand-turn', 'status': 'completed'}}})
                item_event('completed', thread, 'turn1', child_item)
                item_event('completed', 'child1', 'child-turn', child_item)
                emit({'method': 'turn/completed', 'params': {'threadId': 'child1', 'turn': {'id': 'child-turn', 'status': 'completed'}}})
                if mode in ['child-terminal', 'child-retry', 'root-retry']:
                    target, turn = (thread, 'turn1') if mode == 'root-retry' else ('child1', 'child-turn-2')
                    if target == 'child1':
                        emit({'method': 'turn/started', 'params': {'threadId': target, 'turn': {'id': turn}}})
                    emit({'method': 'error', 'params': {'threadId': target, 'turnId': turn, 'willRetry': mode != 'child-terminal', 'error': {'message': 'Invented error', 'codexErrorInfo': None, 'additionalDetails': None, 'misalignment': None}}})
                    if target == 'child1':
                        emit({'method': 'turn/completed', 'params': {'threadId': target, 'turn': {'id': turn, 'status': 'failed' if mode == 'child-terminal' else 'completed'}}})
                # A known child can start a later turn without completing the root.
                emit({'method': 'turn/started', 'params': {'threadId': 'child1', 'turn': {'id': 'child-turn-2'}}})
                emit({'method': 'turn/completed', 'params': {'threadId': 'child1', 'turn': {'id': 'child-turn-2', 'status': 'interrupted'}}})
                with open(home + '/child-decisions', 'w') as f: f.write(','.join(decisions))
            if mode in ['approve', 'deny', 'timeout', 'session']:
                emit({'id': 51, 'method': 'item/commandExecution/requestApproval', 'params': {'threadId': thread, 'turnId': 'turn1', 'itemId': 'q1', 'reason': 'Invented action', 'command': 'invented', 'availableDecisions': ['accept', 'acceptForSession', 'decline', 'cancel']}})
                reply = wire.read()['result']['decision']
                decision = {'accept': 'approve', 'acceptForSession': 'session', 'decline': 'deny'}[reply]
                with open(home + '/decision', 'w') as f: f.write(decision)
                assert decision == ('deny' if mode == 'timeout' else mode)
            if mode == 'queries':
                for index, name in enumerate(names):
                    item = {'id': 'query-' + str(index), 'type': 'mcpToolCall', 'server': 'activityprobe', 'tool': name, 'arguments': {'at': 14400}, 'status': 'completed', 'result': {}, 'error': None}
                    for phase in ['started', 'completed']:
                        emit({'method': 'item/' + phase, 'params': {'threadId': thread, 'turnId': 'turn1', 'item': item}})
                emit({'method': 'turn/completed', 'params': {'threadId': thread, 'turn': {'id': 'turn1', 'status': 'completed'}}})
                continue
            item = {'id': 'q1', 'type': 'mcpToolCall', 'server': 'activityprobe', 'tool': 'day_summary', 'arguments': {'at': 14400}}
            if mode in ['write', 'approve', 'deny', 'timeout', 'session']: item = {'id': 'q1', 'type': 'fileChange', 'changes': []}
            for phase in ['started', 'completed']:
                item.update({'status': 'completed', 'result': {}, 'error': None})
                emit({'method': 'item/' + phase, 'params': {'threadId': thread, 'turnId': 'turn1', 'item': item}})
            if mode == 'answer-overflow':
                for _ in range(5): emit({'method': 'item/agentMessage/delta', 'params': {'threadId': thread, 'turnId': 'turn1', 'delta': 'x' * 900000}})
            emit({'method': 'item/agentMessage/delta', 'params': {'threadId': thread, 'turnId': 'turn1', 'delta': 'Invented answer'}})
            emit({'method': 'turn/completed', 'params': {'threadId': thread, 'turn': {'id': 'turn1', 'status': 'completed'}}})
"""#
  static let enabledCodexTelemetry = """
[otel]
log_user_prompt = true
log_agent_responses = true
log_guardian_assessments = true
exporter = {otlp-http = {endpoint = "http://127.0.0.1:4318/v1/logs", protocol = "json"}}
trace_exporter = {otlp-http = {endpoint = "http://127.0.0.1:4318/v1/traces", protocol = "json"}}
metrics_exporter = {otlp-http = {endpoint = "http://127.0.0.1:4318/v1/metrics", protocol = "json"}}
[otel.tool_result]
max_bytes = 4096
"""
  static let settingsFiles = [".claude/settings.json", ".claude/settings.local.json", ".claude/CLAUDE.md", ".claude.json",
    ".codex/config.toml", ".codex/AGENTS.md", ".codex/auth.json"]
}
