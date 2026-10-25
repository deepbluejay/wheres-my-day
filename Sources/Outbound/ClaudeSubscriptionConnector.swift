import Core
import Darwin
import Foundation

/// The person logs in to Claude Code themselves, in Terminal; the app never runs `auth login`.
/// Consent checks discard stdout. Only the visible Settings section reads display-only status JSON.
public final class ClaudeSubscriptionConnector: SubscriptionConnector, ClaudeLoginSource {
  public static let statusTimeoutSeconds: TimeInterval = 15
  public let userHome: URL
  private let command: AgentExecutable
  private let environment: [String: String]
  private let statusTimeout: TimeInterval
  private let loginScript: ClaudeLoginScript?
  private let openTerminal: (URL) async throws -> Void
  private let lock = NSLock()
  /// Each status run keeps its own child and cancel flag; cancel() reaches only the connection's run,
  /// so a display check running at the same time neither takes nor clears it.
  private final class StatusRun {
    var child: Process?
    var cancelled = false
  }
  private var connection: StatusRun?
  public convenience init(executable: URL, userHome: URL, environment: [String: String] = ProcessInfo.processInfo.environment,
    statusTimeout: TimeInterval = ClaudeSubscriptionConnector.statusTimeoutSeconds,
    loginScript: ClaudeLoginScript? = nil, openTerminal: @escaping (URL) async throws -> Void = { _ in throw SubscriptionConnectionError.failed }) {
    self.init(command: .fixed(executable), userHome: userHome, environment: environment, statusTimeout: statusTimeout,
      loginScript: loginScript, openTerminal: openTerminal)
  }
  /// `openTerminal` hands the written script to Terminal; the Shell supplies it.
  public init(command: AgentExecutable, userHome: URL, environment: [String: String] = ProcessInfo.processInfo.environment,
    statusTimeout: TimeInterval = ClaudeSubscriptionConnector.statusTimeoutSeconds,
    loginScript: ClaudeLoginScript? = nil, openTerminal: @escaping (URL) async throws -> Void = { _ in throw SubscriptionConnectionError.failed }) {
    self.command = command; self.userHome = userHome; self.environment = environment; self.statusTimeout = statusTimeout
    self.loginScript = loginScript; self.openTerminal = openTerminal
  }
  public func connect() throws {
    let run = StatusRun()
    lock.lock(); connection = run; lock.unlock()
    defer { lock.lock(); if connection === run { connection = nil }; lock.unlock() }
    switch try status(run).code {
    case 0: return
    case 1: throw SubscriptionConnectionError.notLoggedIn
    default: throw SubscriptionConnectionError.failed
    }
  }
  public func cancel() {
    lock.lock(); defer { lock.unlock() }
    guard let connection else { return }
    connection.cancelled = true
    if let child = connection.child, child.isRunning { kill(child.processIdentifier, SIGKILL) }
  }
  /// `auth status` rejects any option it does not list, `--settings` included, and exits 1, so the
  /// telemetry-off values reach it through the environment.
  private func status(_ run: StatusRun, display: Bool = false) throws -> (code: Int32, output: Data) {
    guard let install = command.resolve() else { throw SubscriptionConnectionError.notInstalled }
    let deadline = ProcessInfo.processInfo.systemUptime + statusTimeout
    let process = Process()
    process.executableURL = install.executable; process.currentDirectoryURL = userHome
    process.environment = install.environment(ClaudePersonalHome.environment(environment, configOverride: command.claudeConfigDirectory()))
    process.arguments = ["auth", "status", "--json"]
    process.standardInput = FileHandle.nullDevice
    let pipe = Pipe()
    let output = StatusOutput()
    defer { try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
    if display, fcntl(pipe.fileHandleForReading.fileDescriptor, F_SETFL, O_NONBLOCK) < 0 {
      throw SubscriptionConnectionError.failed
    }
    process.standardOutput = display ? pipe : FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    lock.lock()
    guard !run.cancelled else { lock.unlock(); throw SubscriptionConnectionError.cancelled }
    do { try process.run(); run.child = process; lock.unlock() }
    catch { lock.unlock(); throw SubscriptionConnectionError.failed }
    if display {
      try? pipe.fileHandleForWriting.close()
    }
    var timedOut = false
    while process.isRunning {
      if display { output.drain(pipe.fileHandleForReading) }
      if ProcessInfo.processInfo.systemUptime >= deadline { timedOut = true; kill(process.processIdentifier, SIGKILL) }
      Thread.sleep(forTimeInterval: 0.01)
    }
    process.waitUntilExit()
    lock.lock(); run.child = nil; let wasCancelled = run.cancelled; lock.unlock()
    if wasCancelled { throw SubscriptionConnectionError.cancelled }
    if timedOut { throw SubscriptionConnectionError.statusTimeout }
    guard process.terminationReason == .exit else { throw SubscriptionConnectionError.failed }
    if display { output.drain(pipe.fileHandleForReading) }
    return (process.terminationStatus, output.data)
  }

  /// Drain while the child runs so an oversized response cannot block it. Keep at most 64 KiB.
  private final class StatusOutput {
    var data = Data()
    private var oversized = false
    func drain(_ handle: FileHandle) {
      var bytes = [UInt8](repeating: 0, count: 4096)
      // A descendant can retain the pipe after the CLI exits. Nonblocking, bounded reads keep the deadline real.
      for _ in 0..<16 {
        let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
        guard count > 0 else { return }
        if !oversized && data.count + count <= 65_536 { data.append(contentsOf: bytes.prefix(count)) }
        else { oversized = true; data.removeAll() }
      }
    }
  }
}

extension ClaudeSubscriptionConnector {
  /// For display only; connecting still checks again.
  public func loginState() -> ClaudeLoginState {
    loginSnapshot().state
  }
  public func loginSnapshot() -> ClaudeLoginSnapshot {
    do {
      let result = try status(StatusRun(), display: true)
      return Self.parseLoginStatus(result.output, exitCode: result.code)
    }
    catch SubscriptionConnectionError.notInstalled { return ClaudeLoginSnapshot(state: .notInstalled) }
    catch { return ClaudeLoginSnapshot(state: .unknown) }
  }
  static func parseLoginStatus(_ data: Data, exitCode: Int32) -> ClaudeLoginSnapshot {
    guard exitCode == 0 else { return ClaudeLoginSnapshot(state: exitCode == 1 ? .loggedOut : .unknown) }
    guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let loggedIn = json["loggedIn"] as? Bool else { return ClaudeLoginSnapshot(state: .unknown) }
    guard loggedIn else { return ClaudeLoginSnapshot(state: .loggedOut) }
    func nonempty(_ key: String) -> String? {
      guard let value = json[key] as? String else { return nil }
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    let plan = nonempty("subscriptionType").map { ["max": "Max", "pro": "Pro", "team": "Team", "enterprise": "Enterprise"][$0] ?? $0 }
    return ClaudeLoginSnapshot(state: .loggedIn, email: nonempty("email"), plan: plan)
  }
  public func loginFolderKnown() -> Bool { command.claudeConfigKnown() }
  public func openLogin() async throws {
    guard let loginScript else { throw SubscriptionConnectionError.failed }
    guard let install = command.resolve() else { throw SubscriptionConnectionError.notInstalled }
    try await openTerminal(try loginScript.write(executable: install.executable))
  }
}

/// The one script Terminal runs for the person's own login: the resolved CLI with `auth login`, nothing
/// added, in the environment the person's terminal gives it. Terminal opens it as a document, so no
/// automation permission is needed, and the app never sees the login.
public struct ClaudeLoginScript {
  public let appData: URL
  public init(appData: URL) { self.appData = appData }
  public var folder: URL { appData.appendingPathComponent("claude-login", isDirectory: true) }
  public var script: URL { folder.appendingPathComponent("claude-login.command") }
  static func contents(executable: URL) -> String {
    let quoted = "'" + executable.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    return "#!/bin/sh\nexec " + quoted + " auth login\n"
  }
  /// Replaces the script in the app's own 0700 folder; a link or another owner there refuses.
  public func write(executable: URL) throws -> URL {
    do { try AgentDirectories.prepare(appData: appData, ownedDirectories: [folder]) }
    catch { throw SubscriptionConnectionError.localPreparation }
    let staged = folder.appendingPathComponent(".claude-login-" + UUID().uuidString)
    let descriptor = Darwin.open(staged.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o700)
    guard descriptor >= 0 else { throw SubscriptionConnectionError.localPreparation }
    let data = Array(Self.contents(executable: executable).utf8)
    let written = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
    let modeSet = fchmod(descriptor, 0o700) == 0
    Darwin.close(descriptor)
    guard written == data.count, modeSet, rename(staged.path, script.path) == 0 else {
      unlink(staged.path); throw SubscriptionConnectionError.localPreparation
    }
    return script
  }
}
