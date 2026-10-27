import Core
import Foundation
import Inbound
import Outbound
import XCTest
@testable import Shell
@testable import Storage

private struct NoProcesses: AgentLogProcessSource {
  func processes() throws -> [AgentLogProcess] { [] }
  func homeVariable(_ name: String, processID: Int32) throws -> String? { nil }
}
private struct NoVault: FileVaultStatusSource { func fileVaultStatus() -> FileVaultStatus { .unknown } }
private struct NoSummary: SummaryCaller { func call(_ prompt: String) throws -> SummaryAnswer { throw SummaryError.notConnected } }

private final class CountingLogReader: AgentLogReader {
  var listings = 0
  let name = "invented"
  func files() throws -> [AgentLogFile] { [] }
  func listing() throws -> AgentLogListing { listings += 1; return AgentLogListing(files: []) }
  func read(_ file: AgentLogFile, position: LogPosition?, at time: Int) throws -> AgentLogBatch { throw AgentLogReadError.fileUnavailable }
}
private final class SignedInTokens: ChatGPTAccessTokens {
  var signedInForPlanUse = false
  func currentAccessToken() throws -> ChatGPTAccessToken { throw ChatGPTTokenError.notSignedIn }
  func reportRejected(_ token: ChatGPTAccessToken) throws -> ChatGPTAccessToken { throw ChatGPTTokenError.notSignedIn }
  func reportNotEligible(_ token: ChatGPTAccessToken) {}
  func reportUsageLimited(_ token: ChatGPTAccessToken) {}
  func reportNotAccepted(_ token: ChatGPTAccessToken) {}
  func reportRequestRefused(_ token: ChatGPTAccessToken) {}
  func reportSignInRequired() {}
}

final class AppCompositionTests: XCTestCase {
  // Local log collection follows recording controls independently of the summary account.
  func testAgentLogsCollectBeforeSignInAndKeepRecordingControls() throws {
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ACTIVITYPROBE_TEST_ROOT"] ?? NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("data"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = AppPaths(userHome: root.appendingPathComponent("user"), appData: root.appendingPathComponent("data"),
      database: root.appendingPathComponent("invented.sqlite"), appBinary: root.appendingPathComponent("ActivityProbe"),
      queryHelper: root.appendingPathComponent("ActivityQueryServer"))
    let reader = CountingLogReader(), tokens = SignedInTokens()
    var factories = AppFactories()
    factories.chatGPTTokens = { _ in tokens }
    factories.logs = { _, client, _ in [AgentLogTask(reader: reader, storage: client)] }
    let connections = try AppComposition(paths: paths, factories: factories).recorder(processes: NoProcesses(), fileVault: NoVault(),
      from: 0, dayStart: { $0 }, locale: { "en" })
    let task = try XCTUnwrap(connections.logTasks.first)
    try task.scan(at: 10)
    XCTAssertEqual(reader.listings, 1)
    try connections.client.saveFixtureSettings(StorageSettings(subscriptionConnected: true), at: 0)
    try task.scan(at: 20)
    XCTAssertEqual(reader.listings, 2)
    tokens.signedInForPlanUse = true
    try task.scan(at: 30)
    XCTAssertEqual(reader.listings, 3)
    try connections.client.saveFixtureSettings(StorageSettings(subscriptionConnected: false), at: 40)
    try task.scan(at: 50)
    XCTAssertEqual(reader.listings, 4)
    try connections.client.saveSettings(StorageSettings(recordingEnabled: false), at: 60)
    try task.scan(at: 70)
    XCTAssertEqual(reader.listings, 4)
    try connections.client.saveSettings(StorageSettings(pausedUntil: 100), at: 80)
    try task.scan(at: 90)
    XCTAssertEqual(reader.listings, 4)
  }

  // Ideal: each context remains independent; a DB override never becomes an app home.
  @MainActor func testEveryFactoryReceivesEachExplicitPair() throws {
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ACTIVITYPROBE_TEST_ROOT"] ?? NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for index in 1...2 {
      let appData = root.appendingPathComponent("data\(index)")
      try FileManager.default.createDirectory(at: appData, withIntermediateDirectories: true)
      let paths = AppPaths(userHome: root.appendingPathComponent("user\(index)"), appData: appData,
        database: root.appendingPathComponent("database\(index).sqlite"),
        appBinary: root.appendingPathComponent("ActivityProbe"), queryHelper: root.appendingPathComponent("ActivityQueryServer"))
      var seen: [String: Int] = [:]
      func receive(_ component: String, _ received: AppPaths) {
        XCTAssertEqual(received, paths); seen[component, default: 0] += 1
      }
      var factories = AppFactories()
      let original = factories
      factories.storage = { receive("storage", $0); return try original.storage($0, $1, $2) }
      let tokens = ChatGPTSession(store: InMemoryChatGPTCredentialStore(), lock: ChatGPTCredentialLock(file: nil), openBrowser: { _ in false })
      factories.chatGPTTokens = { receive("tokens", $0); return tokens }
      factories.summary = {
        receive("summary", $0)
        // Summaries use the person's own Claude Code, never ChatGPT tokens or the app's codex home.
        XCTAssertEqual($1.name, "claude")
        // A test process never resolves the person's own CLI.
        XCTAssertNil($1.resolve())
        let caller = original.summary($0, $1)
        XCTAssertTrue(caller is ClaudeSummaryCaller)
        XCTAssertEqual(caller.model, "claude-haiku-5-5")
        return caller
      }
      factories.summaryClaude = { receive("summaryClaude", $0); return original.summaryClaude($0) }
      factories.claudeConnector = {
        receive("connectors", $0)
        let connector = original.claudeConnector($0, $1)
        // Claude Code uses the person's own home; there is no app-only Claude folder.
        XCTAssertEqual((connector as? ClaudeSubscriptionConnector)?.userHome.path, paths.userHome.path)
        return connector
      }
      factories.logs = { receive("logs", $0); return original.logs($0, $1, $2) }
      factories.conversation = { receive("conversation", $0); return original.conversation($0, $1, $2) }
      factories.queryStorage = { receive("query", $0); return try original.queryStorage($0) }
      let composition = AppComposition(paths: paths, factories: factories)
      let executable = AgentExecutable.fixed(root.appendingPathComponent("absent-cli"))
      let connections = try composition.recorder(processes: NoProcesses(), fileVault: NoVault(),
        from: 0, dayStart: { $0 }, locale: { "en" })
      XCTAssertFalse(connections.recorder === connections.client)
      XCTAssertEqual(connections.securityTask.health.backupExclusionFailure, .backupExclusionSkippedOverride)
      XCTAssertEqual(connections.logTasks.count, 2)
      let firstSummary = connections.summaryTask
      XCTAssertThrowsError(try connections.configureSummary(caller: NoSummary(), from: 0, dayStart: { $0 }, locale: { "en" }))
      XCTAssertTrue(firstSummary === connections.summaryTask)
      let settings = try composition.settings(claude: executable)
      XCTAssertFalse(settings.settings.subscriptionConnected)
      let configuration = composition.conversation(command: executable, skipApprovals: false)
      XCTAssertEqual(configuration.codexHome.path, appData.appendingPathComponent("codex").path)
      XCTAssertEqual(configuration.userHome.path, paths.userHome.path)
      XCTAssertEqual(configuration.agentHome, appData.appendingPathComponent("agent-home"))
      XCTAssertEqual(configuration.database, paths.database)
      XCTAssertEqual(configuration.toolServer, paths.queryHelper)
      _ = try composition.queryStorage()
      XCTAssertEqual(seen, ["storage": 3, "summaryClaude": 1, "summary": 1, "connectors": 1, "logs": 1, "conversation": 1, "query": 1])
      XCTAssertFalse(FileManager.default.fileExists(atPath: paths.userHome.path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: appData.appendingPathComponent("claude").path))
    }
  }
  // Ideal: consent never lets isolated composition inspect outside default or discovered homes.
  func testIsolatedConsentDoesNotListOrReadOutsideHomes() throws {
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ACTIVITYPROBE_TEST_ROOT"] ?? "/tmp")
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let isolated = root.appendingPathComponent("isolated")
    try FileManager.default.createDirectory(at: isolated, withIntermediateDirectories: true)
    let outside = root.appendingPathComponent("outside")
    let discovered = outside.appendingPathComponent("discovered")
    for home in [outside.appendingPathComponent(".claude"), discovered] {
      let folder = home.appendingPathComponent("projects")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let line = #"{"type":"user","timestamp":"1970-01-01T02:46:40Z","uuid":""# + UUID().uuidString +
        #"","origin":{"kind":"human"},"message":{"role":"user","content":"Invented outside request"}}"#
      try (line + "\n").write(to: folder.appendingPathComponent("invented.jsonl"), atomically: true, encoding: .utf8)
    }
    let paths = AppPaths(userHome: outside, appData: isolated.appendingPathComponent("data"),
      database: isolated.appendingPathComponent("invented.sqlite"), appBinary: isolated.appendingPathComponent("ActivityProbe"),
      queryHelper: isolated.appendingPathComponent("ActivityQueryServer"))
    let processes = OutsideProcesses(home: discovered.path)
    let configuration = try ActivityProbeEntry.isolatedConfiguration(
      arguments: ["collect", "--isolated-root", isolated.path, "--app-data", paths.appData.path],
      environment: ["ACTIVITYPROBE_DB": paths.database.path], excludedUserHome: outside, appBinary: paths.appBinary)
    var factories = AppFactories()
    factories.logs = { _, _, _ in XCTFail("Isolated mode must not construct readers"); return [] }
    factories.chatGPTTokens = { _ in XCTFail("Isolated mode must not read the Keychain"); return SignedInTokens() }
    let connections = try configuration.composition(factories: factories).recorder(processes: processes, fileVault: NoVault(),
      from: 0, dayStart: { $0 }, locale: { "en" })
    try connections.client.saveFixtureSettings(StorageSettings(subscriptionConnected: true), at: 0)
    for task in connections.logTasks { try task.scan(at: 10001) }
    XCTAssertEqual(processes.listings, 0)
    XCTAssertTrue(try connections.client.evidence(in: TimeRange(0, 20000)).isEmpty)
    XCTAssertTrue(connections.logTasks.isEmpty)
  }
  // Ideal: the excluded app home and the invented source home are independent inputs.
  func testIsolatedValidationAcceptsInventedHomeAndRejectsEscapes() throws {
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ACTIVITYPROBE_TEST_ROOT"] ?? "/tmp")
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("user")
    let data = root.appendingPathComponent("data")
    let database = root.appendingPathComponent("database/invented.sqlite")
    let binary = root.appendingPathComponent("bin/ActivityProbe")
    func validate(data: URL = data, database: URL? = database) throws -> IsolatedRecorderConfiguration {
      try ActivityProbeEntry.isolatedConfiguration(
        arguments: ["collect", "--isolated-root", root.path, "--app-data", data.path],
        environment: database.map { ["ACTIVITYPROBE_DB": $0.path] } ?? [:], excludedUserHome: home, appBinary: binary)
    }
    let configuration = try validate()
    // The physical macOS alias spelling stays the same for existing and missing descendants.
    XCTAssertEqual(configuration.paths.appData.path, OperationalDirectory.systemURL(data).path)
    XCTAssertEqual(configuration.paths.database.path, OperationalDirectory.systemURL(database).path)
    XCTAssertEqual(configuration.paths.userHome.path, OperationalDirectory.systemURL(root.appendingPathComponent("source-home")).path)
    XCTAssertNotEqual(configuration.paths.userHome, home)
    XCTAssertThrowsError(try validate(database: nil))
    XCTAssertThrowsError(try validate(data: AppDataPaths.directory(in: home)))
    XCTAssertThrowsError(try validate(database: AppDataPaths.directory(in: home).appendingPathComponent("other.sqlite")))
    XCTAssertThrowsError(try validate(data: root.deletingLastPathComponent()))
    let alias = root.appendingPathComponent("escape")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root.deletingLastPathComponent())
    XCTAssertThrowsError(try validate(data: alias.appendingPathComponent("outside-data")))
    XCTAssertThrowsError(try validate(database: alias.appendingPathComponent("outside.sqlite")))
    let dangling = root.appendingPathComponent("dangling")
    try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: root.deletingLastPathComponent().appendingPathComponent("absent"))
    XCTAssertThrowsError(try validate(data: dangling.appendingPathComponent("data")))
    XCTAssertThrowsError(try validate(database: dangling.appendingPathComponent("invented.sqlite")))
    XCTAssertFalse(FileManager.default.fileExists(atPath: data.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: database.path))
  }
  func testEntryResolutionKeepsDataIndependentOfDatabase() throws {
    let user = URL(fileURLWithPath: "/invented/user")
    let binary = URL(fileURLWithPath: "/invented/bundle/ActivityProbe")
    let paths = try AppPaths.resolve(userHome: user, environment: ["ACTIVITYPROBE_DB": "/invented/override.sqlite"], appBinary: binary)
    XCTAssertEqual(paths.appData, AppDataPaths.directory(in: user))
    XCTAssertEqual(paths.database.path, "/invented/override.sqlite")
    XCTAssertEqual(paths.queryHelper.path, "/invented/bundle/ActivityQueryServer")
    XCTAssertEqual(try? ActivityProbeEntry.command(arguments: [], environment: [:], userHome: user, appBinary: binary).paths.appData, paths.appData)
  }
}

private final class OutsideProcesses: AgentLogProcessSource {
  let home: String
  var listings = 0
  init(home: String) { self.home = home }
  func processes() throws -> [AgentLogProcess] {
    listings += 1
    return [AgentLogProcess(pid: 123, tool: .claude)]
  }
  func homeVariable(_ name: String, processID: Int32) throws -> String? { home }
}
