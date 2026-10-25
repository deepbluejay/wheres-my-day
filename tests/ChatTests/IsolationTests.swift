import Core
import Darwin
import Foundation
import Inbound
@testable import Outbound
import XCTest

final class IsolationTests: XCTestCase {
  var root: URL!
  override func setUpWithError() throws {
    root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ACTIVITYPROBE_TEST_ROOT"] ?? NSTemporaryDirectory())
      .appendingPathComponent("isolation-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }
  override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
  func testAppPreparationDoesNotChangeSharedAncestorsOrTrustInheritedPaths() throws {
    let support = root.appendingPathComponent("Library/Application Support")
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    let library = root.appendingPathComponent("Library")
    for folder in [root!, library, support] { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
    let config = ConversationConfiguration(executable: root.appendingPathComponent("invented"), userHome: root,
      toolServer: root.appendingPathComponent("server"), database: root.appendingPathComponent("invented.sqlite"),
      environment: ["CODEX_SQLITE_HOME": root.appendingPathComponent("personal").path, "BASH_ENV": "invented", "ZDOTDIR": "invented", "CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD": "1", "ANTHROPIC_AUTH_TOKEN": "invented"],
      appBinary: root.appendingPathComponent("ActivityProbe"))
    try config.prepare()
    for folder in [root!, library, support] {
      XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? NSNumber)?.intValue, 0o755)
    }
    XCTAssertEqual(config.codexHome, AppDataPaths.summaryCodexHome(in: AppDataPaths.directory(in: root)))
    XCTAssertEqual(config.environment["CODEX_SQLITE_HOME"], config.codexHome.path)
    XCTAssertNil(config.environment["BASH_ENV"])
    XCTAssertNil(config.environment["ANTHROPIC_AUTH_TOKEN"])
    XCTAssertNil(config.environment["CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD"])
    XCTAssertEqual(config.environment["ZDOTDIR"], config.agentHome.path)
    for folder in [config.codexHome, config.agentHome] {
      XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }
    // Claude runs in the person's own home; the app's earlier Claude folder is no longer made.
    XCTAssertFalse(FileManager.default.fileExists(atPath: config.appDataDirectory.appendingPathComponent("claude").path))
    XCTAssertNil(config.environment["CLAUDE_CONFIG_DIR"])
  }
  // Ideal: the summary's Codex home and its aliases stay out of log discovery; Claude has no app home to
  // exclude, so the person's own Claude folder and every Claude folder a running process names are read.
  func testSummaryHomeAndItsAliasesAreExcludedFromLogDiscovery() throws {
    let appData = root.appendingPathComponent("app-data")
    let codex = AppDataPaths.summaryCodexHome(in: appData), claude = appData.appendingPathComponent("claude")
    let alias = root.appendingPathComponent("alias")
    try FileManager.default.createDirectory(at: appData, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: appData)
    for folder in [codex.appendingPathComponent("sessions"), claude.appendingPathComponent("projects"),
      root.appendingPathComponent(".codex/sessions"), root.appendingPathComponent(".claude/projects")] {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try Data("{}\n".utf8).write(to: folder.appendingPathComponent("invented.jsonl"))
    }
    let processes = IsolatedProcessHomes(codex: alias.appendingPathComponent("codex"), claude: alias.appendingPathComponent("claude"))
    let readers: [AgentLogReader] = [ClaudeAgentLogReader(userHome: root.path, processes: processes, appDataDirectory: appData),
      CodexAgentLogReader(userHome: root.path, processes: processes, appDataDirectory: appData)]
    let codexFiles = try readers[1].files()
    XCTAssertEqual(codexFiles.count, 1)
    XCTAssertFalse(codexFiles.contains { $0.path.contains("app-data") || $0.path.contains("alias") })
    let claudeFiles = try readers[0].files().map(\.path)
    XCTAssertEqual(claudeFiles.count, 2)
    XCTAssertTrue(claudeFiles.contains { $0.hasPrefix(root.appendingPathComponent(".claude/projects").path) })
  }
}
private struct IsolatedProcessHomes: AgentLogProcessSource {
  let codex: URL
  let claude: URL
  func processes() throws -> [AgentLogProcess] { [.init(pid: 1, tool: .codex), .init(pid: 2, tool: .claude)] }
  func homeVariable(_ name: String, processID: Int32) throws -> String? { processID == 1 ? codex.path : claude.path }
}
