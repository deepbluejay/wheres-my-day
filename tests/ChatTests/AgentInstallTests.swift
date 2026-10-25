import Core
import Darwin
import Foundation
@testable import Outbound
@testable import Shell
import XCTest

/// Invented shells, folders and CLIs only. The person's shell, start-up files and real CLIs are never touched.
final class AgentInstallTests: XCTestCase {
  var root: URL!
  let cliName = "invented-agent-cli"
  override func setUpWithError() throws {
    root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ACTIVITYPROBE_TEST_ROOT"] ?? NSTemporaryDirectory())
      .appendingPathComponent("install-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    AgentInstall.homebrew = root.appendingPathComponent("brew-a").path + ":" + root.appendingPathComponent("brew-b").path
    AgentInstall.desktopApps = { [] }
    AgentInstall.forget(); UserShell.forget()
  }
  override func tearDownWithError() throws {
    AgentInstall.homebrew = "/opt/homebrew/bin:/usr/local/bin"
    AgentInstall.desktopApps = { [] }
    AgentInstall.signedByVendor = { AgentInstall.validSignature($0, team: AgentInstall.desktopAppTeam) }
    AgentInstall.forget()
    UserShell.shellOverride = nil; UserShell.answer = nil; UserShell.claudeAnswer = nil; UserShell.claudeKnown = nil; UserShell.limit = 8; UserShell.forget()
    try? FileManager.default.removeItem(at: root)
  }

  @discardableResult func script(_ path: String, _ body: String) throws -> URL {
    let url = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    return url
  }
  func folder(_ path: String) -> String { root.appendingPathComponent(path).path }
  func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 || errno == EPERM }
  func pid(in file: URL) throws -> pid_t {
    let deadline = ProcessInfo.processInfo.systemUptime + 5
    while ProcessInfo.processInfo.systemUptime < deadline {
      if let text = try? String(contentsOf: file), let value = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) { return value }
      usleep(10_000)
    }
    throw CocoaError(.fileReadNoSuchFile)
  }
  let bare = ["PATH": "/usr/bin:/bin"]

  // Ideal: start-up noise is ignored and the last marker line is the answer.
  func testShellAnswerIsTheLastMarkerLine() throws {
    let shell = try script("shell/noisy", """
      echo "Welcome, invented person"
      printf '\(UserShell.marker)/invented/early\\n'
      echo "more noise"
      printf '\(UserShell.marker)/invented/late:/usr/bin\\n'
      echo "trailing noise"
      """)
    XCTAssertEqual(UserShell.ask(shell: shell.path, environment: bare, limit: 5), "/invented/late:/usr/bin")
    XCTAssertNil(UserShell.ask(shell: try script("shell/silent", "echo nothing to see").path, environment: bare, limit: 5))
    XCTAssertNil(UserShell.ask(shell: folder("shell/absent"), environment: bare, limit: 5))
    XCTAssertNil(UserShell.parse(Data("\(UserShell.marker)\n".utf8)))
  }

  // Ideal: the same answer carries the login shell's absolute CLAUDE_CONFIG_DIR, and nothing when it sets none.
  func testShellAnswerCarriesTheClaudeFolder() throws {
    let shell = try script("shell/claude-folder", """
      export CLAUDE_CONFIG_DIR=/invented/claude-folder
      eval "$4"
      """)
    XCTAssertEqual(UserShell.lookup(shell: shell.path, environment: bare, limit: 5),
      UserShell.Answer(path: "/usr/bin:/bin", claudeConfigDirectory: "/invented/claude-folder"))
    let unset = try script("shell/no-claude-folder", "unset CLAUDE_CONFIG_DIR; eval \"$4\"")
    XCTAssertEqual(UserShell.lookup(shell: unset.path, environment: ["PATH": "/usr/bin:/bin", "CLAUDE_CONFIG_DIR": "/invented/inherited"], limit: 5),
      UserShell.Answer(path: "/usr/bin:/bin", claudeConfigDirectory: nil))
    let relative = try script("shell/relative-claude-folder", "export CLAUDE_CONFIG_DIR=invented; eval \"$4\"")
    XCTAssertNil(UserShell.lookup(shell: relative.path, environment: bare, limit: 5)?.claudeConfigDirectory)
    XCTAssertNil(UserShell.parseAnswer(Data("\(UserShell.claudeMarker)/invented\n".utf8)), "no PATH, no answer")
    // installed() reads it from the shell; an explicitly named CLI has none.
    UserShell.answer = { "/usr/bin:/bin" }; UserShell.claudeAnswer = { "/invented/claude-folder" }
    XCTAssertEqual(AgentExecutable.installed(cliName, environment: bare, home: nil).claudeConfigDirectory(), "/invented/claude-folder")
    XCTAssertNil(AgentExecutable.fixed(URL(fileURLWithPath: folder("x"))).claudeConfigDirectory())
    UserShell.claudeAnswer = nil
    XCTAssertNil(AgentExecutable.installed(cliName, environment: bare, home: nil).claudeConfigDirectory())
  }

  // Ideal: the app says when it cannot know the terminal's Claude folder: a relative value, or no answer.
  func testClaudeFolderIsUnknownWithoutAnAbsoluteAnswer() throws {
    let relative = try script("shell/relative", "export CLAUDE_CONFIG_DIR=invented; eval \"$4\"")
    XCTAssertEqual(UserShell.lookup(shell: relative.path, environment: bare, limit: 5)?.claudeConfigRelative, true)
    XCTAssertEqual(UserShell.lookup(shell: try script("shell/none", "unset CLAUDE_CONFIG_DIR; eval \"$4\"").path,
      environment: bare, limit: 5)?.claudeConfigRelative, false)
    for (shell, known) in [(relative.path, false), (try script("shell/silent-folder", "echo nothing").path, false),
      (try script("shell/absolute", "export CLAUDE_CONFIG_DIR=/invented/folder; eval \"$4\"").path, true),
      (try script("shell/unset", "eval \"$4\"").path, true)] {
      UserShell.forget(); UserShell.shellOverride = shell
      XCTAssertEqual(AgentExecutable.installed(cliName, environment: bare, home: nil).claudeConfigKnown(), known, shell)
    }
    XCTAssertTrue(AgentExecutable.fixed(URL(fileURLWithPath: folder("x"))).claudeConfigKnown())
    let connector = ClaudeSubscriptionConnector(command: AgentExecutable(name: "claude", claudeConfigKnown: { false }) { nil },
      userHome: root)
    XCTAssertFalse(connector.loginFolderKnown())
  }

  // Ideal: every login shell on macOS answers PATH, and the folder only when it is exported. Real system
  // shells, started in an empty invented home with nothing of this process's environment.
  func testSystemShellsAnswerPathAndExportedFolder() throws {
    let home = root.appendingPathComponent("empty-home")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
    for shell in ["/bin/zsh", "/bin/bash", "/bin/sh", "/bin/tcsh", "/bin/csh"] where FileManager.default.isExecutableFile(atPath: shell) {
      let plain = try XCTUnwrap(UserShell.lookup(shell: shell, environment: environment, limit: 20), shell)
      XCTAssertNotNil(plain.path, shell); XCTAssertNil(plain.claudeConfigDirectory, shell)
      let exported = UserShell.lookup(shell: shell, environment: environment.merging(["CLAUDE_CONFIG_DIR": "/invented/claude-folder"]) { $1 },
        limit: 20)
      XCTAssertNotNil(exported?.path, shell); XCTAssertEqual(exported?.claudeConfigDirectory, "/invented/claude-folder", shell)
    }
    XCTAssertEqual(UserShell.arguments(shell: "/bin/tcsh", command: "x"), ["-tcsh", "-i", "-c", "x"])
    XCTAssertEqual(UserShell.arguments(shell: "/bin/csh", command: "x"), ["-csh", "-i", "-c", "x"])
    XCTAssertEqual(UserShell.arguments(shell: "/bin/zsh", command: "x"), ["/bin/zsh", "-l", "-i", "-c", "x"])
    // A shell variable that is not exported is not what the CLI would get.
    let unexported = try script("shell/unexported", "CLAUDE_CONFIG_DIR=/invented/shell-only; eval \"$4\"")
    XCTAssertNil(UserShell.lookup(shell: unexported.path, environment: bare, limit: 5)?.claudeConfigDirectory)
  }

  // Ideal: the shell gets the login, interactive command and no stdin; nothing else of this process.
  func testShellIsAskedAsATerminalStartsIt() throws {
    let record = root.appendingPathComponent("arguments")
    let shell = try script("shell/recording", """
      printf '%s\\n' "$@" > '\(record.path)'
      if read -r line; then echo stdin-had-data >> '\(record.path)'; fi
      printf '\(UserShell.marker)%s\\n' "$INVENTED_PATH"
      """)
    XCTAssertEqual(UserShell.ask(shell: shell.path, environment: ["PATH": "/usr/bin:/bin", "INVENTED_PATH": "/invented/x"], limit: 5), "/invented/x")
    let lines = try String(contentsOf: record).split(separator: "\n").map(String.init)
    XCTAssertEqual(Array(lines.prefix(3)), ["-l", "-i", "-c"])
    XCTAssertTrue(lines[3].hasPrefix("printf '\(UserShell.marker)"))
    XCTAssertFalse(lines.contains("stdin-had-data"))
  }

  // Ideal: a shell that never answers, and ignores SIGTERM, ends with its group at the limit.
  func testHangingShellIsEndedWithItsGroupAtTheLimit() throws {
    let pidFile = root.appendingPathComponent("hang-pid"), childFile = root.appendingPathComponent("hang-child")
    let shell = try script("shell/hanging", """
      /bin/sleep 0.7
      trap '' TERM
      echo $$ > '\(pidFile.path)'
      /bin/sleep 60 &
      echo $! > '\(childFile.path)'
      while :; do /bin/sleep 0.1; done
      """)
    var started = ProcessInfo.processInfo.systemUptime
    XCTAssertNil(UserShell.ask(shell: shell.path, environment: bare, limit: 0.5, beforeLimit: {
      // Give fixture startup its own bound, so suite load cannot consume the tested 0.5-second limit.
      let readyBy = ProcessInfo.processInfo.systemUptime + 10
      while ProcessInfo.processInfo.systemUptime < readyBy {
        if let a = try? String(contentsOf: pidFile), Int32(a.trimmingCharacters(in: .whitespacesAndNewlines)) != nil,
          let b = try? String(contentsOf: childFile), Int32(b.trimmingCharacters(in: .whitespacesAndNewlines)) != nil { break }
        usleep(10_000)
      }
      started = ProcessInfo.processInfo.systemUptime
    }))
    XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 4)
    let shellPID = try pid(in: pidFile), child = try pid(in: childFile)
    let deadline = ProcessInfo.processInfo.systemUptime + 3
    while (alive(shellPID) || alive(child)), ProcessInfo.processInfo.systemUptime < deadline { usleep(20_000) }
    XCTAssertFalse(alive(shellPID)); XCTAssertFalse(alive(child))
  }

  // Ideal: a finished shell's background child holding the pipe neither delays the answer nor is ended.
  func testBackgroundChildHoldingThePipeStillReturns() throws {
    let childFile = root.appendingPathComponent("background-child")
    let shell = try script("shell/background", """
      /bin/sleep 30 &
      echo $! > '\(childFile.path)'
      printf '\(UserShell.marker)/invented/answer\\n'
      exit 0
      """)
    let started = ProcessInfo.processInfo.systemUptime
    XCTAssertEqual(UserShell.ask(shell: shell.path, environment: bare, limit: 6), "/invented/answer")
    XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 3)
    let child = try pid(in: childFile)
    XCTAssertTrue(alive(child))
    kill(child, SIGKILL)
  }

  // Ideal: a recorder that ignores stop signals does not pass that on to what the shell leaves running.
  func testShellHelpersCanBeStoppedWhenTheCallerIgnoresStopSignals() throws {
    let childFile = root.appendingPathComponent("helper-child")
    let shell = try script("shell/helper", """
      /bin/sleep 30 > /dev/null 2>&1 &
      echo $! > '\(childFile.path)'
      printf '\(UserShell.marker)/invented/answer\\n'
      """)
    let previous = signal(SIGTERM, SIG_IGN)
    let answer = UserShell.ask(shell: shell.path, environment: bare, limit: 5)
    signal(SIGTERM, previous)
    XCTAssertEqual(answer, "/invented/answer")
    let child = try pid(in: childFile)
    XCTAssertTrue(alive(child))
    kill(child, SIGTERM)
    let deadline = ProcessInfo.processInfo.systemUptime + 3
    while alive(child), ProcessInfo.processInfo.systemUptime < deadline { usleep(20_000) }
    XCTAssertFalse(alive(child), "the helper still ignores SIGTERM")
    if alive(child) { kill(child, SIGKILL) }
  }

  // Ideal: a shell that closed its output but has not exited yet is waited for, not ended with its group.
  func testShellThatClosedItsOutputIsNotEndedWithItsHelpers() throws {
    let childFile = root.appendingPathComponent("closing-child")
    let shell = try script("shell/closing", """
      /bin/sleep 30 > /dev/null 2>&1 &
      echo $! > '\(childFile.path)'
      printf '\(UserShell.marker)/invented/answer\\n'
      exec 1>&-
      /bin/sleep 0.05
      exit 0
      """)
    XCTAssertEqual(UserShell.ask(shell: shell.path, environment: bare, limit: 5), "/invented/answer")
    let child = try pid(in: childFile)
    XCTAssertTrue(alive(child), "the finished shell's helper was ended")
    kill(child, SIGKILL)
  }

  // Ideal: past 1 MiB the shell is not read further, and a marker beyond the bound does not count.
  func testShellOutputIsBounded() throws {
    let shell = try script("shell/flood", """
      /usr/bin/head -c 1100000 /dev/zero | /usr/bin/tr '\\0' 'x'
      printf '\\n\(UserShell.marker)/invented/too-late\\n'
      """)
    XCTAssertNil(UserShell.ask(shell: shell.path, environment: bare, limit: 5))
  }

  // Ideal: the shell is asked once per process; concurrent callers wait for that one answer.
  func testShellIsAskedOnceAndConcurrentCallersShareTheAnswer() throws {
    let count = root.appendingPathComponent("asked")
    UserShell.shellOverride = try script("shell/slow", """
      echo asked >> '\(count.path)'
      /bin/sleep 0.3
      printf '\(UserShell.marker)/invented/shared\\n'
      """).path
    UserShell.limit = 5
    let lock = NSLock(); var answers: [String?] = []
    DispatchQueue.concurrentPerform(iterations: 4) { _ in
      let answer = UserShell.path(environment: bare)
      lock.lock(); answers.append(answer); lock.unlock()
    }
    XCTAssertEqual(answers, Array(repeating: "/invented/shared", count: 4))
    XCTAssertEqual(UserShell.path(environment: bare), "/invented/shared")
    XCTAssertEqual(try String(contentsOf: count), "asked\n")
  }

  // Ideal: shell path, then this process's PATH, then ~/.local/bin, then Homebrew's prefixes.
  func testLookupOrderAcrossInventedFolders() throws {
    let home = folder("home")
    let environment = ["PATH": folder("process")]
    func find(shell: String?) -> AgentInstall? {
      AgentInstall.forget(); return AgentInstall.find(cliName, shellPath: shell, environment: environment, home: home)
    }
    XCTAssertNil(find(shell: folder("shell")), "Not installed anywhere is nil, never an invented /usr/bin path")
    try script("brew-b/" + cliName, "exit 0")
    XCTAssertEqual(find(shell: folder("shell"))?.origin, .homebrew)
    try script("brew-a/" + cliName, "exit 0")
    XCTAssertEqual(find(shell: folder("shell"))?.executable.path, folder("brew-a/" + cliName))
    try script("home/.local/bin/" + cliName, "exit 0")
    XCTAssertEqual(find(shell: folder("shell"))?.origin, .native)
    try script("process/" + cliName, "exit 0")
    XCTAssertEqual(find(shell: nil)?.executable.path, folder("process/" + cliName), "Without a shell answer this process's PATH is used")
    XCTAssertEqual(find(shell: folder("shell"))?.origin, .native, "A shell answer replaces this process's PATH")
    try script("shell/" + cliName, "exit 0")
    let found = try XCTUnwrap(find(shell: folder("other") + ":" + folder("shell")))
    XCTAssertEqual(found.executable.path, folder("shell/" + cliName)); XCTAssertEqual(found.origin, .path)
    XCTAssertEqual(found.childPath, [folder("other"), folder("shell"), folder("home/.local/bin"), folder("brew-a"), folder("brew-b")].joined(separator: ":"))
    AgentInstall.forget()
    XCTAssertEqual(AgentInstall.find(cliName, shellPath: nil, environment: [:], home: nil)?.origin, .homebrew, "No PATH at all falls back to /usr/bin:/bin")
  }

  // Ideal: relative or empty entries and a directory named like the CLI are never used.
  func testRelativeEntriesAndDirectoriesAreIgnored() throws {
    try script("work/relative/" + cliName, "exit 0")
    let previous = FileManager.default.currentDirectoryPath
    XCTAssertTrue(FileManager.default.changeCurrentDirectoryPath(folder("work")))
    defer { FileManager.default.changeCurrentDirectoryPath(previous) }
    XCTAssertNil(AgentInstall.find(cliName, shellPath: "relative::.", environment: [:], home: nil))
    XCTAssertEqual(AgentInstall.childPath(base: "relative::./x:" + folder("abs"), home: nil),
      [folder("abs"), folder("brew-a"), folder("brew-b")].joined(separator: ":"))
    try FileManager.default.createDirectory(atPath: folder("dir/" + cliName), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o755])
    try script("later/" + cliName, "exit 0")
    AgentInstall.forget()
    XCTAssertEqual(AgentInstall.find(cliName, shellPath: folder("dir") + ":" + folder("later"), environment: [:], home: nil)?.executable.path,
      folder("later/" + cliName))
    try FileManager.default.createDirectory(atPath: folder("plain"), withIntermediateDirectories: true)
    try Data("not runnable".utf8).write(to: URL(fileURLWithPath: folder("plain/" + cliName)))
    AgentInstall.forget()
    XCTAssertNil(AgentInstall.find(cliName, shellPath: folder("plain"), environment: [:], home: nil), "A file without execute permission is not a CLI")
  }

  // Ideal: a found CLI stays the answer for its search path while it exists; once gone, the next is found.
  func testFoundExecutableIsPinnedWhileItExists() throws {
    try script("brew-b/" + cliName, "exit 0")
    let first = AgentInstall.find(cliName, shellPath: folder("shell"), environment: [:], home: nil)
    XCTAssertEqual(first?.origin, .homebrew)
    try script("shell/" + cliName, "exit 0")
    XCTAssertEqual(AgentInstall.find(cliName, shellPath: folder("shell"), environment: [:], home: nil), first)
    try FileManager.default.removeItem(atPath: folder("brew-b/" + cliName))
    XCTAssertEqual(AgentInstall.find(cliName, shellPath: folder("shell"), environment: [:], home: nil)?.origin, .path)
  }

  // Ideal: only codex looks in the desktop app, and only inside a bundle validly signed by the vendor.
  func testDesktopAppCLIRequiresTheVendorSignature() throws {
    let app = root.appendingPathComponent("Invented.app")
    try script("Invented.app/Contents/Resources/codex-cli/bin/codex", "exit 0")
    try Data("<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>CFBundleIdentifier</key><string>com.openai.codex</string></dict></plist>".utf8)
      .write(to: app.appendingPathComponent("Contents/Info.plist"))
    AgentInstall.desktopApps = { [app] }
    XCTAssertFalse(AgentInstall.validSignature(app, team: AgentInstall.desktopAppTeam))
    XCTAssertFalse(AgentInstall.validSignature(app, team: ""))
    XCTAssertNil(AgentInstall.find("codex", shellPath: folder("none"), environment: [:], home: nil), "An unsigned bundle has no CLI")
    AgentInstall.signedByVendor = { $0 == app }
    let found = AgentInstall.find("codex", shellPath: folder("none"), environment: [:], home: nil)
    XCTAssertEqual(found?.origin, .desktopApp)
    XCTAssertEqual(found?.executable.path, app.appendingPathComponent("Contents/Resources/codex-cli/bin/codex").path)
    XCTAssertNil(AgentInstall.find("claude", shellPath: folder("none"), environment: [:], home: nil))
    AgentInstall.desktopApps = { [self.root.appendingPathComponent("Other.app")] }
    AgentInstall.forget()
    XCTAssertNil(AgentInstall.find("codex", shellPath: folder("none"), environment: [:], home: nil))
  }

  // Ideal: installed() searches from the shell's answer, or this process's PATH when it gave none.
  func testInstalledUsesTheShellAnswer() throws {
    try script("shell/" + cliName, "exit 0"); try script("process/" + cliName, "exit 0")
    UserShell.answer = { self.folder("shell") }
    let command = AgentExecutable.installed(cliName, environment: ["PATH": folder("process")], home: nil)
    XCTAssertEqual(command.resolve()?.executable.path, folder("shell/" + cliName))
    UserShell.answer = { nil }
    XCTAssertEqual(command.resolve()?.executable.path, folder("process/" + cliName))
    XCTAssertEqual(command.resolve()?.childPath?.hasPrefix(folder("process") + ":"), true)
    XCTAssertNil(AgentExecutable.fixed(URL(fileURLWithPath: folder("x"))).resolve()?.childPath)
  }

  // Ideal: every CLI child gets the lookup's PATH so a version manager's script finds its interpreter.
  func testChildrenReceiveTheComputedPath() throws {
    let record = root.appendingPathComponent("child-paths")
    try script("manager/bin/invented-interpreter", "printf '%s\\n' \"$PATH\" >> '\(record.path)'; exit 0")
    // A script whose interpreter is found through PATH, as an installed Node CLI's is.
    let cli = root.appendingPathComponent("manager/bin/" + cliName)
    try Data("#!/usr/bin/env invented-interpreter\n".utf8).write(to: cli)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
    UserShell.answer = { self.folder("manager/bin") }
    let command = AgentExecutable.installed(cliName, environment: ["PATH": "/usr/bin:/bin"], home: folder("home"))
    let expected = [folder("manager/bin"), folder("home/.local/bin"), folder("brew-a"), folder("brew-b")].joined(separator: ":")
    let app = root.appendingPathComponent("app")
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    try ClaudeSubscriptionConnector(command: command, userHome: root,
      environment: ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]).connect()
    XCTAssertEqual(try String(contentsOf: record).split(separator: "\n").map(String.init), [expected])
    let launch = try ConversationConfiguration(command: command, userHome: root, toolServer: cli, database: root.appendingPathComponent("invented.sqlite"),
      environment: ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"], appDataDirectory: app, appBinary: cli).launch()
    XCTAssertEqual(launch.environment["PATH"], expected); XCTAssertEqual(launch.environment["LANG"], "en_US.UTF-8")
    XCTAssertEqual(launch.executable, cli)
  }

  // Ideal: a missing CLI starts nothing and reads as not installed or not connected everywhere.
  func testMissingCLIIsNotInstalled() async throws {
    let missing = AgentExecutable(name: "codex") { nil }
    let app = root.appendingPathComponent("app")
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    XCTAssertThrowsError(try ClaudeSubscriptionConnector(command: missing, userHome: app).connect()) {
      XCTAssertEqual($0 as? SubscriptionConnectionError, .notInstalled)
    }
    let configuration = ConversationConfiguration(command: missing, userHome: root, toolServer: root.appendingPathComponent("tool"),
      database: root.appendingPathComponent("invented.sqlite"), environment: bare, appDataDirectory: app, appBinary: root.appendingPathComponent("app-binary"))
    XCTAssertThrowsError(try CodexConversationAgent(configuration: configuration, tokens: FakeConversationTokens(), accountModels: FakeAccountModels()).models()) {
      XCTAssertEqual($0 as? ConversationError, .notInstalled)
    }
    var failure: Error?
    do {
      for try await _ in ClaudeConversationAgent(configuration: configuration).converse(messages: [.init(role: .user, text: "Invented")],
        selection: ChatSelection(provider: .claude, model: "sonnet", reasoning: "low")) {}
    } catch { failure = error }
    XCTAssertEqual(failure as? ConversationError, .notInstalled)
    XCTAssertEqual(SettingsMessage(error: SubscriptionConnectionError.notInstalled), .notInstalled)
  }

  // Ideal: the lookup runs in background modes without the application object or AppKit.
  func testLookupSourcesStayOutOfPresentation() throws {
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    for file in ["Sources/Outbound/AgentInstall.swift", "Sources/Outbound/UserShell.swift"] {
      let source = try String(contentsOf: repo.appendingPathComponent(file), encoding: .utf8)
      for name in ["AppKit", "NSApplication", "NSApp", "NSWorkspace", "SwiftUI"] {
        XCTAssertFalse(source.contains(name), "\(file) mentions \(name)")
      }
    }
  }
}
