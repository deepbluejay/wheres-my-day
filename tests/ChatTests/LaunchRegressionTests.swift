import Core
import Darwin
import Foundation
@testable import Outbound
import Storage
import XCTest

final class LaunchRegressionTests: XCTestCase {
  var root: URL!
  override func setUpWithError() throws {
    root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ACTIVITYPROBE_TEST_ROOT"] ?? NSTemporaryDirectory())
      .appendingPathComponent("launch-regression-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }
  override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
  func executable(_ text: String, name: String = "invented-cli") throws -> URL {
    let url = root.appendingPathComponent(name)
    try Data(text.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    return url
  }
  // Ideal: no launch may follow any link below the platform root, even outside userHome.
  func testEveryLaunchRefusesIntermediateParentAndFinalLinksBeforeMutation() throws {
    for provider in ChatProvider.allCases {
      for linked in ["alias", "alias/app-data", "alias/app-data/" + provider.rawValue, "alias/app-data/agent-home/tmp"] {
        let base = root.appendingPathComponent(UUID().uuidString)
        let destination = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        let link = base.appendingPathComponent(linked)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
        let appData = base.appendingPathComponent("alias/app-data")
        let home = appData.appendingPathComponent(provider.rawValue)
        let originalModes = [appData, home.deletingLastPathComponent().appendingPathComponent("agent-home")].compactMap { url -> (URL, Int)? in
          var info = stat()
          guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
          return (url, Int(info.st_mode & 0o777))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? Int, 0o755)
        let config = ConversationConfiguration(executable: root.appendingPathComponent("invented-cli"), userHome: root.appendingPathComponent("unrelated-user"),
          toolServer: root.appendingPathComponent("server"), database: root.appendingPathComponent("db"),
          environment: [:], appDataDirectory: appData, appBinary: root.appendingPathComponent("app"))
        // Nothing uses the app's earlier Claude folder any more, so a link there is never reached.
        if linked == "alias/app-data/claude" { XCTAssertNoThrow(try config.prepare()) } else { XCTAssertThrowsError(try config.prepare()) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? Int, 0o755)
        if linked == "alias/app-data/claude" { continue }
        for (url, mode) in originalModes {
          XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, mode)
        }
      }
    }
  }
  func testClaudeStatusKeepsPersonalTemporaryDirectoryWithoutPreparingAppData() throws {
    let temporary = root.appendingPathComponent("personal-tmp"), user = root.appendingPathComponent("invented-user")
    for folder in [temporary, user] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    let cli = try executable("""
    #!/bin/sh
    printf canary > "$TMPDIR/status-canary"
    """)
    try ClaudeSubscriptionConnector(executable: cli, userHome: user,
      environment: ["PATH": "/usr/bin:/bin", "TMPDIR": temporary.path]).connect()
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temporary.path), ["status-canary"])
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: user.path), [])
  }

  func testWholeSettingsSavesCannotChangeEitherConnectionConsent() throws {
    let url = root.appendingPathComponent("invented.sqlite")
    let a = try ActivityStorage(url: url, appDataDirectory: root, databaseScope: .directory(root))
    let b = try ActivityStorage(url: url, appDataDirectory: root, databaseScope: .directory(root))
    try a.saveSettings(StorageSettings(subscriptionConnected: true,
      general: ["chat.claude.connected": "1", "chat.claude.generation": "invented"]))
    XCTAssertFalse(try b.settings().subscriptionConnected)
    XCTAssertFalse(try b.settings().claudeConnected)
    XCTAssertEqual(try b.settings().claudeConnectionGeneration, "")
    for provider in ChatProvider.allCases {
      let pending = try a.patchSettings(provider == .codex ? .beginConnection : .beginClaudeConnection)
      let connected = try a.patchSettings(provider == .codex
        ? .completeConnection(generation: pending.connectionGeneration)
        : .completeClaudeConnection(generation: pending.claudeConnectionGeneration))
      var staleOff = pending
      staleOff.general["dayStartHour"] = "7"
      try b.saveSettings(staleOff)
      XCTAssertTrue(provider == .codex ? try a.settings().subscriptionConnected : try a.settings().claudeConnected)
      let revoked = try b.patchSettings(provider == .codex ? .disconnect : .disconnectClaude)
      var staleOn = connected
      staleOn.general["dayStartHour"] = "9"
      try a.saveSettings(staleOn)
      let latest = try b.settings()
      XCTAssertFalse(provider == .codex ? latest.subscriptionConnected : latest.claudeConnected)
      XCTAssertEqual(latest.connectionGeneration, revoked.connectionGeneration)
      XCTAssertEqual(latest.claudeConnectionGeneration, revoked.claudeConnectionGeneration)
      XCTAssertEqual(latest.general["dayStartHour"], "9")
    }
  }
  func testGuidedPreviewAndConfirmationUseQueryDatabaseDespiteInheritedOverrides() throws {
    let app = try executable("#!/bin/sh\nprintf '%s|%s\\n' \"$ACTIVITYPROBE_DB\" \"$*\" >> '\(root.path)/deletions'\n", name: "app's binary")
    let database = root.appendingPathComponent("query's db.sqlite")
    for inherited in [nil, root.appendingPathComponent("wrong.sqlite").path] {
      var environment = ["PATH": "/usr/bin:/bin"]
      environment["ACTIVITYPROBE_DB"] = inherited
      let config = ConversationConfiguration(executable: app, userHome: root, toolServer: app, database: database,
        environment: environment, appBinary: app)
      XCTAssertEqual(config.environment["ACTIVITYPROBE_DB"], database.path)
      let runtime = try ConversationRuntime(config)
      XCTAssertEqual(runtime.toolEnvironment[QueryToolContract.databaseVariable], database.path)
      let command = try XCTUnwrap(config.guidance.components(separatedBy: "To delete records use ").last?.components(separatedBy: ", show its preview").first)
      for suffix in ["", " --confirm INVENTED"] {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command.replacingOccurrences(of: "<from> <to>", with: "100 200") + suffix]
        // The printed command must also work when a native shell filters its parent's environment.
        process.environment = environment
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
      }
    }
    let lines = try String(contentsOf: root.appendingPathComponent("deletions")).split(separator: "\n")
    XCTAssertEqual(lines.map(String.init), ["\(database.path)|privacy forget 100 200", "\(database.path)|privacy forget 100 200 --confirm INVENTED",
      "\(database.path)|privacy forget 100 200", "\(database.path)|privacy forget 100 200 --confirm INVENTED"])
  }
  func testApprovalStatusReportsClampedDeadline() {
    for (input, expected): (TimeInterval, String) in [(0.1, "0.1"), (0, "0.01"), (90, "60")] {
      let config = ConversationConfiguration(executable: root, userHome: root, toolServer: root, database: root,
        environment: [:], appBinary: root, approvalTimeout: input)
      XCTAssertTrue(config.approvalStatus.contains("after \(expected) seconds"))
    }
  }
}
