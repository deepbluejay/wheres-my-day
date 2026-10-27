import Core
import Darwin
import Foundation

/// Summaries on the person's own Claude Code login: one `claude -p` child per call, with Claude Haiku at the
/// lowest effort. The prompt goes to the child's stdin only, never to arguments, files or logs.
///
/// The child has no tools, no MCP servers, no hooks, no setting sources, no saved session and a fixed
/// system prompt in place of Claude Code's own, which would add the working folder, the OS and git facts.
/// It runs in one stable private folder under the temporary directory, emptied around each child, never in
/// a project folder: one path, so the CLI cannot keep a new per-folder entry for every call. Its session
/// ID is registered as the app's own before it starts, so a transcript that appeared anyway is refused by
/// the agent-log readers.
public final class ClaudeSummaryCaller: SummaryCaller {
  public static let model = "claude-haiku-5-5"
  public static let effort = "low"
  /// Chosen, not measured: Claude Code's framing around the prompt with its own system prompt replaced.
  public static let fixedEnvelopeTokens = 4_096
  public static let inputMarginTokens = SummaryMaintenance.inputMarginTokens
  /// The one stdin line carrying the prompt.
  public static let inputLimit = 16 * 1024 * 1024
  /// After a usage limit without a reset time or an overloaded service, calls wait this long,
  /// doubling for each further one up to `unavailableLongest`. Chosen values.
  public static let unavailableShortest: TimeInterval = 300
  public static let unavailableLongest: TimeInterval = 1800
  /// A reported reset further away than this is not believed; the backoff applies instead.
  static let longestReset: TimeInterval = 7 * 24 * 3600
  static let workFolderName = "activityprobe-summary-work"
  /// Older builds made one `activityprobe-summary-XXXXXXXX` folder per child; swept for one release.
  static let legacyWorkPrefix = "activityprobe-summary-"
  static let systemPrompt = "Follow the instructions in the user message exactly. Answer only with the lines it asks for."
  /// Only the person's subscription login is used; an API key or another provider is not.
  static let subscriptionMethods: Set<String> = ["claude.ai", "oauth_token"]
  public var model: String { Self.model }

  private let command: AgentExecutable
  private let environment: [String: String]
  private let appDataDirectory: URL
  private let attemptLog: URL
  private let temporaryRoot: URL
  private let timeout: TimeInterval
  private let legacyPrompts: URL?
  private let clock: () -> TimeInterval
  private var unavailableUntil: TimeInterval?
  private var unavailableStreak = 0
  /// False once this CLI refused `--effort`; later calls in this process omit it.
  public private(set) var effortAccepted = true
  /// Calls in a row where the run with `--effort` stopped before init and the one without it started.
  /// One such call may be a transient crash; two in a row are taken as a refused flag.
  private var effortStartupMismatches = 0
  static let effortStartupMismatchLimit = 2
  public var serviceUnavailableUntil: TimeInterval? {
    unavailableUntil.flatMap { clock() < $0 ? $0 : nil }
  }
  public init(command: AgentExecutable, appDataDirectory: URL, attemptLog: URL,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    temporaryRoot: URL = FileManager.default.temporaryDirectory, timeout: TimeInterval = SummaryMaintenance.callTimeoutSeconds,
    legacyPrompts: URL? = nil, clock: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 }) {
    self.command = command; self.appDataDirectory = appDataDirectory; self.attemptLog = attemptLog
    self.environment = environment; self.temporaryRoot = temporaryRoot; self.timeout = timeout
    self.legacyPrompts = legacyPrompts; self.clock = clock
  }

  /// Hooks, memory, git instructions and instruction files off; telemetry content off as for conversations.
  static var settings: [String: Any] {
    ConversationDiagnostics.claudeSettings.merging(["disableAllHooks": true, "includeGitInstructions": false,
      "autoMemoryEnabled": false,
      "pluginConfigs": ["cc-plugin-agents-md@builtin": ["options": ["instructionFiles": "managed-only"]]]]) { _, fence in fence }
  }
  /// The whole command line. Nothing in it comes from the prompt or the person's activity.
  static func arguments(session: String, effort: Bool) throws -> [String] {
    var arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
      "--model", model]
    if effort { arguments += ["--effort", Self.effort] }
    arguments += ["--tools", "", "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#,
      "--setting-sources", "", "--settings", String(decoding: try ConversationEncoding.json(settings), as: UTF8.self),
      "--safe-mode", "--disable-slash-commands", "--no-session-persistence", "--session-id", session,
      "--system-prompt", systemPrompt, "--permission-mode", "dontAsk", "--permission-prompts", "none"]
    return arguments
  }
  /// The person's environment without the app's keys, tokens or config folder, plus no optional traffic.
  func childEnvironment(_ install: AgentInstall) -> [String: String] {
    var values = ClaudePersonalHome.environment(environment, configOverride: command.claudeConfigDirectory())
    values["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
    return install.environment(values)
  }

  public func beginPass() throws {
    if let legacyPrompts { ChatGPTSummaryCaller.sweepLegacy(legacyPrompts) }
    try? SummaryMaintenance.sweepStaleWorkFolders(in: temporaryRoot, timeout: timeout, prefix: Self.legacyWorkPrefix,
      keeping: [Self.workFolderName])
    var attempt = Attempt()
    let start = clock()
    do {
      if serviceUnavailableUntil != nil { attempt.reason = "service_unavailable"; throw SummaryError.paused }
      try checkLogin(&attempt)
      return
    } catch {
      try? log(start: start, prompt: "", attempt)
      throw error
    }
  }
  public func call(_ prompt: String) throws -> SummaryAnswer {
    let start = clock()
    var attempt = Attempt()
    var failure: Error?
    do {
      if serviceUnavailableUntil != nil { attempt.reason = "service_unavailable"; throw SummaryError.paused }
      try perform(prompt, &attempt)
    } catch { failure = error }
    do { try log(start: start, prompt: prompt, attempt) }
    catch {
      // An unavailable diagnostic file must never erase usage already returned by the model.
      if attempt.run.answer.inputTokens == 0 && attempt.run.answer.outputTokens == 0 { throw error }
    }
    if let failure { throw failure }
    return attempt.run.answer
  }

  /// One call's diagnostics. Only types, counts and reasons reach the attempt log.
  struct Attempt {
    var run = Run()
    var effort = ClaudeSummaryCaller.effort
    var effortFallback = false
    var exit: String?
    var reason: String?
  }
  /// What one child reported on stdout.
  struct Run {
    var started = false
    var answer = SummaryAnswer(text: "invalid")
    var finished = false
    var succeeded = false
    var events: [String: Int] = [:]
    var signals: Set<Signal> = []
    var resetsAt: TimeInterval?
    var reportedModel: String?
    var billed: Bool { answer.inputTokens > 0 || answer.outputTokens > 0 }
  }
  enum Signal: Hashable { case usageLimited, notLoggedIn, refused, effortRejected, unavailable }
  enum RunError: Error { case notIsolated, incompatible, ended }
  static let eventTypes: Set<String> = ["system", "assistant", "user", "stream_event", "rate_limit_event", "result"]

  /// `auth status --json` with the same environment; telemetry is off through the environment because
  /// `auth status` takes no `--settings`.
  private func checkLogin(_ attempt: inout Attempt) throws {
    guard let install = command.resolve() else { attempt.reason = "not_installed"; throw SummaryError.notConnected }
    let output: String
    do {
      output = try withWorkFolder { folder in
        try ConversationProcess.metadata(executable: install.executable, arguments: ["auth", "status", "--json"],
          environment: childEnvironment(install), cwd: folder, exitErrors: [1: .notLoggedIn])
      }
    } catch ConversationError.notLoggedIn { attempt.reason = "not_connected"; throw SummaryError.notConnected }
    catch SummaryError.localPreparation { attempt.reason = "local_preparation"; throw SummaryError.localPreparation }
    catch { attempt.reason = "status_failed"; throw SummaryError.unbilledExecFailure }
    guard let account = try? ConversationEncoding.object(Data(output.utf8)), account["loggedIn"] as? Bool == true else {
      attempt.reason = "not_connected"; throw SummaryError.notConnected
    }
    guard Self.subscriptionMethods.contains(account["authMethod"] as? String ?? "") else {
      attempt.reason = "not_subscription"; throw SummaryError.notConnected
    }
  }

  private func perform(_ prompt: String, _ attempt: inout Attempt) throws {
    guard let install = command.resolve() else { attempt.reason = "not_installed"; throw SummaryError.notConnected }
    let input = try ConversationEncoding.json(["type": "user", "message": ["role": "user", "content": prompt]])
    guard input.count <= Self.inputLimit else { attempt.reason = "local_preparation"; throw SummaryError.localPreparation }
    attempt.effort = effortAccepted ? Self.effort : "omitted"
    attempt.run = try launch(install, input: input, effort: effortAccepted, &attempt)
    // A CLI that refuses `--effort` either stops before its first line or reports it as the error. Once,
    // the same call runs again without the flag. The flag stays off for this process only when the error
    // names effort, or when a stop before init followed by a start without it happens on two calls in a
    // row; a single startup crash does not drop it.
    if effortAccepted, !attempt.run.billed, !attempt.run.succeeded,
      !attempt.run.started || attempt.run.signals.contains(.effortRejected) {
      let named = attempt.run.signals.contains(.effortRejected)
      let retry = try launch(install, input: input, effort: false, &attempt)
      if retry.started && !retry.signals.contains(.effortRejected) {
        attempt.effort = "omitted"; attempt.effortFallback = true; attempt.run = retry
        effortStartupMismatches = named ? 0 : effortStartupMismatches + 1
        if named || effortStartupMismatches >= Self.effortStartupMismatchLimit { effortAccepted = false }
      }
    } else if effortAccepted && attempt.run.started { effortStartupMismatches = 0 }
    try judge(attempt.run, &attempt)
  }

  private func launch(_ install: AgentInstall, input: Data, effort: Bool, _ attempt: inout Attempt) throws -> Run {
    let session = UUID().uuidString.lowercased()
    var run = Run()
    attempt.exit = nil
    do {
      try withWorkFolder { folder in
        // Registered before the child starts: a transcript it wrote anyway is the app's own, never activity.
        // Both spellings, since receipts compare exactly and the CLI may keep or fold the case it was given.
        do {
          let registry = OwnLogSources.registry(appDataDirectory: appDataDirectory)
          for spelling in [session, session.uppercased()] { try registry.registerSession(AgentLogIdentity.decoded(spelling), tool: .claude) }
        } catch { throw SummaryError.localPreparation }
        try ConversationProcess.exchange(executable: install.executable, arguments: Self.arguments(session: session, effort: effort),
          environment: childEnvironment(install), cwd: folder, timeout: timeout, cancellation: ConversationCancellation(),
          inputLineLimit: Self.inputLimit, isReady: { run.started }, initial: [input]) { line, _ in
          guard !line.isEmpty else { throw RunError.ended }
          return try Self.receive(line, into: &run)
        }
      }
      attempt.exit = "result"
    } catch RunError.ended { attempt.exit = "ended" }
    catch RunError.notIsolated { attempt.exit = "not_isolated"; attempt.reason = "not_isolated"; throw SummaryError.localPreparation }
    catch RunError.incompatible { attempt.exit = "incompatible" }
    catch ConversationError.timeout {
      attempt.exit = "timeout"; attempt.run = run
      // Before init nothing reached the model: the unbilled rule applies, not a spent attempt.
      if !run.started && !run.billed { attempt.reason = "timeout_before_start"; throw SummaryError.unbilledExecFailure }
      // A child that had to be stopped is a failed attempt, as with a stream past its deadline.
      attempt.reason = "transport"
      throw SummaryTransportFailure(usage: run.answer)
    } catch ConversationError.outputLimit {
      attempt.exit = "output_limit"; attempt.reason = "transport"
      attempt.run = run
      throw SummaryTransportFailure(usage: run.answer)
    } catch SummaryError.localPreparation { attempt.reason = "local_preparation"; throw SummaryError.localPreparation }
    catch { attempt.exit = "spawn" }
    return run
  }

  /// Reads one stdout line. Returns true at the final result.
  static func receive(_ line: Data, into run: inout Run) throws -> Bool {
    guard let value = try? ConversationEncoding.object(line), let type = value["type"] as? String else { throw RunError.incompatible }
    run.events[eventTypes.contains(type) ? type : "other", default: 0] += 1
    if type == "system", value["subtype"] as? String == "init" {
      // The child must itself report that it has no tool and no MCP server before anything is accepted.
      guard !run.started, let tools = value["tools"] as? [Any], tools.isEmpty,
        let servers = value["mcp_servers"] as? [Any], servers.isEmpty else { throw RunError.notIsolated }
      run.started = true
      run.reportedModel = value["model"] as? String
      return false
    }
    guard run.started else {
      if type == "system" { return false }
      throw RunError.incompatible
    }
    switch type {
    case "rate_limit_event":
      let info = value["rate_limit_info"] as? [String: Any] ?? [:]
      if info["status"] as? String == "rejected" {
        run.signals.insert(.usageLimited)
        if let reset = (info["resetsAt"] as? NSNumber)?.doubleValue { run.resetsAt = reset }
      }
    case "assistant":
      let message = value["message"] as? [String: Any] ?? [:]
      if message["stop_reason"] as? String == "refusal" { run.signals.insert(.refused) }
      switch value["error"] as? String {
      case "rate_limit"?, "billing_error"?: run.signals.insert(.usageLimited)
      case "authentication_failed"?: run.signals.insert(.notLoggedIn)
      case "server_error"?: run.signals.insert(.unavailable)
      default: break
      }
    case "result":
      let usage = value["usage"] as? [String: Any] ?? [:]
      func count(_ key: String) -> Int { (usage[key] as? NSNumber)?.intValue ?? 0 }
      // Like the Responses usage: input counts every prompt token, cached the ones read from cache.
      let cached = count("cache_read_input_tokens")
      run.answer = SummaryAnswer(text: "invalid", inputTokens: count("input_tokens") + count("cache_creation_input_tokens") + cached,
        cachedTokens: cached, outputTokens: count("output_tokens"))
      if value["stop_reason"] as? String == "refusal" { run.signals.insert(.refused) }
      let failed = value["is_error"] as? Bool != false || value["subtype"] as? String != "success"
      if failed { run.signals.formUnion(errorSignals(value)) }
      else if let text = value["result"] as? String { run.answer.text = text; run.succeeded = !run.signals.contains(.refused) }
      run.finished = true
      return true
    default: break
    }
    return false
  }
  /// The CLI's own error result names the cause in its status or its message. The message is matched,
  /// never stored.
  static func errorSignals(_ result: [String: Any]) -> Set<Signal> {
    var signals: Set<Signal> = []
    let status = (result["api_error_status"] as? NSNumber)?.intValue
    let text = ((result["result"] as? String) ?? "").lowercased()
    if status == 429 || ["usage limit", "limit reached", "hit your limit", "rate limit", "rate_limit"].contains(where: text.contains) {
      signals.insert(.usageLimited)
    }
    if status == 401 || status == 403 || ["not logged in", "/login", "invalid api key", "authentication", "oauth token"].contains(where: text.contains) {
      signals.insert(.notLoggedIn)
    }
    if text.contains("effort") { signals.insert(.effortRejected) }
    if [500, 502, 503, 504, 529].contains(status ?? 0) || text.contains("overloaded") { signals.insert(.unavailable) }
    return signals
  }

  /// Errors and recovery: each outcome maps to one action, and none of them retries in a loop.
  private func judge(_ run: Run, _ attempt: inout Attempt) throws {
    if run.signals.contains(.notLoggedIn) && !run.billed {
      attempt.reason = "not_connected"; throw SummaryError.notConnected
    }
    if run.signals.contains(.usageLimited) {
      if let reset = run.resetsAt, reset > clock(), reset - clock() <= Self.longestReset {
        unavailableStreak += 1; unavailableUntil = reset
      } else { backOff() }
      attempt.reason = "usage_limited"; throw pause(run.answer)
    }
    if run.signals.contains(.refused) {
      // A refusal depends on these minutes, not on the account: a failed attempt, so the two-attempt
      // rule closes the range and later pieces go on. Pausing would resend the same minutes forever.
      resetUnavailable(); attempt.reason = "refused"
      if !run.billed { throw SummaryError.unbilledExecFailure }
      throw SummaryTransportFailure(usage: run.answer)
    }
    if run.signals.contains(.unavailable) {
      backOff(); attempt.reason = "service_unavailable"; throw pause(run.answer)
    }
    resetUnavailable()
    guard run.succeeded else {
      attempt.reason = run.signals.contains(.effortRejected) ? "effort_rejected" : run.finished ? "result_failed" : "ended"
      // A failure before any billed input says nothing about the account; the next pass tries again.
      if !run.billed { throw SummaryError.unbilledExecFailure }
      throw SummaryTransportFailure(usage: run.answer)
    }
  }
  private func pause(_ usage: SummaryAnswer) -> Error {
    usage.inputTokens > 0 || usage.outputTokens > 0 ? SummaryPausedAfterBilling(usage: usage) : SummaryError.paused
  }
  private func resetUnavailable() { unavailableStreak = 0; unavailableUntil = nil }
  private func backOff() {
    unavailableStreak += 1
    let wait = min(Self.unavailableLongest, Self.unavailableShortest * pow(2, Double(min(unavailableStreak - 1, 8))))
    unavailableUntil = clock() + wait
  }

  /// The one work folder, checked and emptied before the child and emptied again after it.
  private func withWorkFolder<T>(_ body: (URL) throws -> T) throws -> T {
    let folder = try Self.workFolder(in: temporaryRoot)
    defer { try? Self.empty(folder) }
    return try body(folder)
  }
  /// Made 0700 if missing, then refused unless it is a real directory of this user with mode 0700.
  static func workFolder(in root: URL) throws -> URL {
    let folder = root.appendingPathComponent(workFolderName, isDirectory: true)
    guard mkdir(folder.path, 0o700) == 0 || errno == EEXIST else { throw SummaryError.localPreparation }
    var info = stat()
    guard lstat(folder.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
      info.st_mode & 0o7777 == 0o700 else { throw SummaryError.localPreparation }
    try empty(folder)
    return folder
  }
  /// Removes each entry itself; a link inside is removed, never followed.
  static func empty(_ folder: URL) throws {
    do {
      for entry in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
        try FileManager.default.removeItem(atPath: folder.appendingPathComponent(entry).path)
      }
    } catch { throw SummaryError.localPreparation }
  }

  private func log(start: TimeInterval, prompt: String, _ attempt: Attempt) throws {
    let answer = attempt.run.answer
    let estimate = SummaryMaintenance.estimatedTokens(prompt)
    var record: [String: Any] = ["startedAt": start, "endedAt": clock(), "transport": "claude-cli", "model": Self.model,
      "effort": attempt.effort, "effortFallback": attempt.effortFallback, "events": attempt.run.events,
      "inputTokens": answer.inputTokens, "cachedTokens": answer.cachedTokens, "outputTokens": answer.outputTokens,
      "promptEstimatedTokens": estimate, "fixedEnvelopeTokens": Self.fixedEnvelopeTokens, "marginTokens": Self.inputMarginTokens,
      "excessInput": answer.inputTokens > estimate + Self.fixedEnvelopeTokens + Self.inputMarginTokens]
    if let reported = attempt.run.reportedModel { record["reportedModelMatches"] = reported == Self.model }
    if let exit = attempt.exit { record["exit"] = exit }
    if let reason = attempt.reason { record["failureReason"] = reason }
    var encoded = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
    encoded.append(10)
    let descriptor = Darwin.open(attemptLog.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { throw SummaryError.transport }
    let log = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? log.close() }
    try log.write(contentsOf: encoded)
  }
}
