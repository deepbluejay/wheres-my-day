import Core
import Foundation
@testable import Inbound
@testable import Outbound
import XCTest

/// Every run uses an invented `claude` script; the person's own CLI and login are never started.
final class ClaudeSummaryCallerTests: XCTestCase {
  var root: URL!
  var home: URL { root.appendingPathComponent("invented-user") }
  var appData: URL { root.appendingPathComponent("app-data") }
  var temporary: URL { root.appendingPathComponent("tmp") }
  var log: URL { root.appendingPathComponent("summary-attempts.jsonl") }
  var now: TimeInterval = 1_800_000_000
  static let answer = #"00:00\t00:10\twork\tInvented\tInvented"#
  static let laterAnswer = #"02:00\t02:10\twork\tInvented\tInvented"#
  static let usage = #"{"input_tokens":100,"cache_creation_input_tokens":10,"cache_read_input_tokens":20,"output_tokens":30}"#
  static let initLine = #"{"type":"system","subtype":"init","tools":[],"mcp_servers":[],"model":"claude-haiku-5-5","session_id":"invented"}"#

  override func setUpWithError() throws {
    root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ACTIVITYPROBE_TEST_ROOT"] ?? NSTemporaryDirectory())
      .appendingPathComponent("claude-summary-" + UUID().uuidString)
    for folder in [home, appData, temporary] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    try login("in")
  }
  override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

  func login(_ state: String) throws { try Data(state.utf8).write(to: root.appendingPathComponent("login")) }
  func read(_ name: String) -> String? { try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8) }

  /// `mode` picks what the invented CLI prints after the init line. `effortRejected` refuses `--effort` itself.
  func cli(_ mode: String) throws -> URL {
    let executable = root.appendingPathComponent("claude")
    let r = root.path
    let script = """
    #!/bin/sh
    # printf, not echo: this sh's echo would turn the JSON's \\t into a raw tab.
    r='\(r)'
    [ "$HOME" = '\(home.path)' ] || exit 9
    if [ "$1" = auth ]; then
      printf '%s\\n' "$*" >> "$r/status-commands"
      pwd -P > "$r/status-cwd"
      ls -A | wc -l | tr -d ' ' > "$r/status-cwd-entries"; : > status-child-file
      case "$(cat "$r/login")" in
        in) printf '%s\\n' '{"loggedIn":true,"authMethod":"claude.ai","email":"person@example.com"}'; exit 0;;
        key) printf '%s\\n' '{"loggedIn":true,"authMethod":"api_key"}'; exit 0;;
        *) printf '%s\\n' '{"loggedIn":false}'; exit 1;;
      esac
    fi
    : > "$r/args"; for a in "$@"; do printf '[%s]\\n' "$a" >> "$r/args"; done
    pwd -P > "$r/cwd"
    ls -A | wc -l | tr -d ' ' > "$r/cwd-entries"; : > child-file
    printf '%s|%s|%s\\n' "${CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC-}" "${ANTHROPIC_API_KEY-unset}" "${CLAUDE_CODE_EFFORT_LEVEL-unset}" > "$r/env"
    effort=no; for a in "$@"; do [ "$a" = --effort ] && effort=yes; done
    echo "$effort" >> "$r/efforts"
    mode='\(mode)'
    if [ "$mode" = effortRejected ] && [ "$effort" = yes ]; then exit 1; fi
    if [ "$mode" = effortResult ] && [ "$effort" = yes ]; then
      printf '%s\\n' '\(Self.initLine)'
      printf '%s\\n' '{"type":"result","subtype":"error_during_execution","is_error":true,"result":"API Error: 400 effort is not supported for this model","usage":{"input_tokens":0,"output_tokens":0}}'
      sleep 30; exit 0
    fi
    if [ "$mode" = flakyStart ] && [ "$effort" = yes ] && [ ! -e "$r/crashed" ]; then : > "$r/crashed"; exit 1; fi
    [ "$mode" = exit ] && exit 3
    [ "$mode" = stall ] && sleep 30
    IFS= read -r line; printf '%s\\n' "$line" > "$r/stdin"
    case "$mode" in
      tools) printf '%s\\n' '{"type":"system","subtype":"init","tools":["Bash"],"mcp_servers":[],"model":"claude-haiku-5-5"}';;
      mcp) printf '%s\\n' '{"type":"system","subtype":"init","tools":[],"mcp_servers":[{"name":"invented","status":"connected"}]}';;
      *) printf '%s\\n' '\(Self.initLine)';;
    esac
    case "$mode" in
      success|effortRejected|effortResult|flakyStart)
        printf '%s\\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"\(Self.answer)"}]}}'
        printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"result":"\(Self.answer)","usage":\(Self.usage)}';;
      shape) printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"result":"invented prose, not minute lines","usage":\(Self.usage)}';;
      limit)
        printf '%s\\n' '{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":1800003600,"rateLimitType":"five_hour"}}'
        printf '%s\\n' '{"type":"result","subtype":"success","is_error":true,"result":"Invented limit reached","usage":{"input_tokens":0,"output_tokens":0}}';;
      limitBilled) printf '%s\\n' '{"type":"result","subtype":"error_during_execution","is_error":true,"api_error_status":429,"result":"Invented","usage":\(Self.usage)}';;
      refuseFirst)
        # Refuses every prompt except the one for the later minutes from 02:00.
        case "$line" in
          *02:00*)
            printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"result":"\(Self.laterAnswer)","usage":\(Self.usage)}';;
          *)
            printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"stop_reason":"refusal","result":"","usage":\(Self.usage)}';;
        esac;;
      refusal)
        printf '%s\\n' '{"type":"assistant","message":{"role":"assistant","stop_reason":"refusal","content":[]}}'
        printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"stop_reason":"refusal","result":"","usage":\(Self.usage)}';;
      overloaded) printf '%s\\n' '{"type":"result","subtype":"error_during_execution","is_error":true,"api_error_status":529,"result":"Overloaded","usage":{"input_tokens":0,"output_tokens":0}}';;
      loggedOut) printf '%s\\n' '{"type":"result","subtype":"success","is_error":true,"result":"Not logged in · Please run /login","usage":{"input_tokens":0,"output_tokens":0}}';;
      ended) exit 2;;
      timeout) sleep 30;;
    esac
    sleep 30
    """
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    return executable
  }
  func caller(_ mode: String, timeout: TimeInterval = 20) throws -> ClaudeSummaryCaller {
    ClaudeSummaryCaller(command: .fixed(try cli(mode)), appDataDirectory: appData, attemptLog: log,
      environment: ["HOME": home.path, "PATH": "/usr/bin:/bin", "ANTHROPIC_API_KEY": "invented-key",
        "CLAUDE_CODE_EFFORT_LEVEL": "high", "CLAUDE_CONFIG_DIR": root.appendingPathComponent("app-owned").path],
      temporaryRoot: temporary, timeout: timeout, clock: { [unowned self] in now })
  }
  func records() throws -> [[String: Any]] {
    try (read("summary-attempts.jsonl") ?? "").split(separator: "\n").map {
      try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
    }
  }
  func arguments() -> [String] {
    (read("args") ?? "").split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.isEmpty }
      .map { String($0.dropFirst().dropLast()) }
  }
  func service(_ caller: SummaryCaller) -> (SummaryService, SummaryMemory) {
    let memory = SummaryMemory()
    memory.rows = (0..<600).map { TimeSample(ts: $0, app: "Invented", keys: 1, keepingAwake: true) }
    return (SummaryService(storage: memory, caller: caller, format: SummaryFormat(timeZone: TimeZone(secondsFromGMT: 0)!)), memory)
  }

  // MARK: Argument contract and isolation

  func testArgumentContractHasModelEffortNoToolsNoPersistenceAndAPrivateFolder() throws {
    let caller = try caller("success")
    try caller.beginPass()
    let answer = try caller.call("Invented prompt canary")
    XCTAssertEqual(answer.text, "00:00\t00:10\twork\tInvented\tInvented")
    let arguments = arguments()
    func value(_ flag: String) -> String? { arguments.firstIndex(of: flag).map { arguments[$0 + 1] } }
    XCTAssertEqual(arguments.first, "-p")
    XCTAssertEqual(value("--model"), "claude-haiku-5-5")
    XCTAssertEqual(value("--effort"), "low")
    XCTAssertEqual(value("--output-format"), "stream-json"); XCTAssertEqual(value("--input-format"), "stream-json")
    // No tools, no MCP server, no setting source, no hooks, no slash commands, no saved session.
    XCTAssertEqual(value("--tools"), "")
    XCTAssertTrue(arguments.contains("--strict-mcp-config")); XCTAssertEqual(value("--mcp-config"), #"{"mcpServers":{}}"#)
    XCTAssertEqual(value("--setting-sources"), "")
    XCTAssertTrue(arguments.contains("--safe-mode")); XCTAssertTrue(arguments.contains("--disable-slash-commands"))
    XCTAssertTrue(arguments.contains("--no-session-persistence"))
    XCTAssertEqual(value("--permission-mode"), "dontAsk"); XCTAssertEqual(value("--permission-prompts"), "none")
    XCTAssertEqual(value("--system-prompt"), ClaudeSummaryCaller.systemPrompt)
    let settings = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(value("--settings")).utf8)) as? [String: Any])
    XCTAssertEqual(settings["disableAllHooks"] as? Bool, true); XCTAssertEqual(settings["autoMemoryEnabled"] as? Bool, false)
    XCTAssertEqual(settings["includeGitInstructions"] as? Bool, false); XCTAssertEqual(settings["disableClaudeAiConnectors"] as? Bool, true)
    XCTAssertFalse(arguments.contains { ["--allowedTools", "--add-dir", "--resume", "--continue", "--dangerously-skip-permissions"].contains($0) })
    // The prompt reaches stdin only.
    XCTAssertFalse(arguments.contains { $0.contains("canary") })
    let input = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(read("stdin")).utf8)) as? [String: Any])
    XCTAssertEqual((input["message"] as? [String: Any])?["content"] as? String, "Invented prompt canary")
    // One stable private folder under the temporary root for the status check and the call, empty after.
    let resolved = try XCTUnwrap(realpath(temporary.path, nil)); defer { free(resolved) }
    let work = String(cString: resolved) + "/activityprobe-summary-work"
    for name in ["cwd", "status-cwd"] { XCTAssertEqual(try XCTUnwrap(read(name)).trimmingCharacters(in: .newlines), work, name) }
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temporary.path), ["activityprobe-summary-work"])
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work), [])
    XCTAssertEqual(read("status-commands"), "auth status --json\n")
    // The app's API key, effort override and config folder never reach the child; optional traffic is off.
    XCTAssertEqual(read("env"), "1|unset|unset\n")
    // The session is the app's own before the child starts.
    let session = try XCTUnwrap(value("--session-id"))
    let registry = AgentLogFiles.ownSources(appDataDirectory: appData)
    XCTAssertTrue(try registry.containsSession(AgentLogIdentity.decoded(session), tool: .claude))
    let record = try XCTUnwrap(try records().first)
    XCTAssertEqual(record["model"] as? String, "claude-haiku-5-5"); XCTAssertEqual(record["effort"] as? String, "low")
    XCTAssertEqual(record["reportedModelMatches"] as? Bool, true)
    XCTAssertEqual(record["inputTokens"] as? Int, 130); XCTAssertEqual(record["cachedTokens"] as? Int, 20)
    XCTAssertFalse(try String(contentsOf: log).contains("canary")); XCTAssertFalse(try String(contentsOf: log).contains("Invented\\t"))
  }

  /// Own-source exclusion: had the CLI saved a transcript of this session anyway, the reader refuses it.
  func testATranscriptOfTheSummarySessionIsRefusedAsOwnSource() throws {
    let caller = try caller("success")
    _ = try caller.call("Invented prompt")
    let session = try XCTUnwrap(arguments().firstIndex(of: "--session-id").map { arguments()[$0 + 1] })
    let projects = home.appendingPathComponent(".claude/projects/-invented-summary")
    try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    func transcript(_ id: String) throws -> URL {
      let url = projects.appendingPathComponent(id + ".jsonl")
      let line: [String: Any] = ["type": "user", "timestamp": "2027-01-15T08:00:00Z", "uuid": UUID().uuidString, "sessionId": id,
        "cwd": "/invented/tmp/activityprobe-summary-x", "origin": ["kind": "human"], "message": ["role": "user", "content": "Invented summary prompt"]]
      try (JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) + Data([10])).write(to: url)
      return url
    }
    let own = try transcript(session), foreign = try transcript(UUID().uuidString.lowercased())
    let reader = ClaudeAgentLogReader(userHome: home.path, processes: NoAgentLogProcessHomes(), appDataDirectory: appData)
    let files = try reader.files()
    let ownFile = try XCTUnwrap(files.first { $0.path == own.path }), foreignFile = try XCTUnwrap(files.first { $0.path == foreign.path })
    XCTAssertTrue(try reader.read(ownFile, position: nil, at: 1_800_000_000).events.isEmpty)
    XCTAssertEqual(try reader.read(foreignFile, position: nil, at: 1_800_000_000).events.count, 1)
  }

  func testInitReportingAToolOrAnMCPServerIsRefusedBeforeAnyAnswer() throws {
    for mode in ["tools", "mcp"] {
      XCTAssertThrowsError(try caller(mode).call("Invented")) { XCTAssertEqual($0 as? SummaryError, .localPreparation, mode) }
    }
    XCTAssertEqual(try records().map { $0["failureReason"] as? String }, ["not_isolated", "not_isolated"])
  }

  // MARK: Outcomes through the summary service

  func testSuccessRecordsClaudeUsageAndModel() throws {
    let (service, memory) = service(try caller("success"))
    try service.summarize(from: 0, through: 10000, dayStart: 0, locale: "en-US")
    XCTAssertEqual(memory.calls.map(\.model), ["claude-haiku-5-5"])
    XCTAssertEqual(memory.calls.map(\.succeeded), [true])
    XCTAssertEqual(memory.calls.map(\.inputTokens), [130]); XCTAssertEqual(memory.calls.map(\.cachedTokens), [20])
    XCTAssertEqual(memory.calls.map(\.outputTokens), [30]); XCTAssertEqual(memory.named.count, 1)
  }

  func testShapeFailureIsRecordedAsTwoBilledAttempts() throws {
    let (service, memory) = service(try caller("shape"))
    try service.summarize(from: 0, through: 10000, dayStart: 0, locale: "en-US")
    XCTAssertEqual(memory.calls.map(\.succeeded), [false, false]); XCTAssertEqual(memory.calls.map(\.inputTokens), [130, 130])
    XCTAssertEqual(service.health.firstAttemptShapeFailures, 1); XCTAssertEqual(service.health.failedRanges, [TimeRange(0, 900)])
    XCTAssertTrue(memory.named.isEmpty)
  }

  func testUsageLimitPausesUntilTheReportedResetWithoutAnAttempt() throws {
    let caller = try caller("limit")
    let (service, memory) = service(caller)
    try service.summarize(from: 0, through: 10000, dayStart: 0, locale: "en-US")
    XCTAssertTrue(service.health.planUsePaused); XCTAssertTrue(memory.calls.isEmpty)
    XCTAssertEqual(service.health.serviceUnavailableUntil, 1_800_003_600)
    // Until the reset no CLI starts, not even the status check.
    try FileManager.default.removeItem(at: root.appendingPathComponent("status-commands"))
    try service.summarize(from: 0, through: 10000, dayStart: 0, locale: "en-US")
    XCTAssertNil(read("status-commands")); XCTAssertTrue(service.health.planUsePaused)
    XCTAssertEqual(try records().last?["failureReason"] as? String, "service_unavailable")
  }

  /// A billed usage limit pauses and keeps its usage; a refusal is two failed billed attempts for these
  /// minutes, with no pause and no "unavailable or reported a limit" notice.
  func testBilledUsageLimitPausesAndARefusalFailsTheRange() throws {
    let (limited, limitedMemory) = service(try caller("limitBilled"))
    try limited.summarize(from: 0, through: 10000, dayStart: 0, locale: "en-US")
    XCTAssertTrue(limited.health.planUsePaused)
    XCTAssertEqual(limitedMemory.calls.map(\.inputTokens), [130]); XCTAssertEqual(limitedMemory.calls.map(\.pending), [true])
    XCTAssertEqual(limited.health.serviceUnavailableUntil, now + ClaudeSummaryCaller.unavailableShortest)
    XCTAssertTrue(limitedMemory.named.isEmpty)

    let (refused, refusedMemory) = service(try caller("refusal"))
    try refused.summarize(from: 0, through: 10000, dayStart: 0, locale: "en-US")
    XCTAssertFalse(refused.health.planUsePaused); XCTAssertNil(refused.health.serviceUnavailableUntil)
    XCTAssertEqual(refusedMemory.calls.map(\.inputTokens), [130, 130])
    XCTAssertEqual(refusedMemory.calls.map(\.pending), [false, false]); XCTAssertEqual(refusedMemory.calls.map(\.succeeded), [false, false])
    XCTAssertEqual(refused.health.failedRanges, [TimeRange(0, 900)]); XCTAssertTrue(refusedMemory.named.isEmpty)
    // A second pass does not send the same minutes again.
    try refused.summarize(from: 0, through: 10000, dayStart: 0, locale: "en-US")
    XCTAssertEqual(refusedMemory.calls.count, 2)
    XCTAssertEqual(try records().map { $0["failureReason"] as? String }, ["usage_limited", "refused", "refused"])
  }

  /// Many passes with a CLI that always refuses: the calls stop at the attempt limit, the range is failed,
  /// and a later piece is still summarized.
  func testRepeatedRefusalsStopAtTheAttemptLimitAndLaterPiecesGoOn() throws {
    let caller = try caller("refuseFirst")
    let (service, memory) = service(caller)
    memory.rows += (7200..<7800).map { TimeSample(ts: $0, app: "Invented", keys: 1, keepingAwake: true) }
    for _ in 0..<6 {
      try service.summarize(from: 0, through: 20000, dayStart: 0, locale: "en-US")
      XCTAssertFalse(service.health.planUsePaused); XCTAssertNil(caller.serviceUnavailableUntil)
      now += 3600
    }
    // Two refused attempts for the first minutes, one answered call for the later ones, then nothing more.
    XCTAssertEqual(read("efforts"), "yes\nyes\nyes\n"); XCTAssertEqual(memory.calls.count, 3)
    XCTAssertEqual(memory.calls.map(\.succeeded), [false, false, true]); XCTAssertTrue(memory.calls.allSatisfy { !$0.pending })
    XCTAssertEqual(memory.calls.map(\.range.start), [0, 0, 7200])
    XCTAssertEqual(service.health.failedRanges, [TimeRange(0, 900)])
    XCTAssertEqual(memory.named.map(\.range.start), [7200])
    XCTAssertTrue(try service.plan(from: 0, through: 20000).pieces.isEmpty)
  }

  func testOverloadedServiceBacksOffWithoutAnAttempt() throws {
    let (service, memory) = service(try caller("overloaded"))
    try service.summarize(from: 0, through: 10000, dayStart: 0, locale: "en-US")
    XCTAssertTrue(service.health.planUsePaused); XCTAssertTrue(memory.calls.isEmpty)
    XCTAssertEqual(service.health.serviceUnavailableUntil, now + ClaudeSummaryCaller.unavailableShortest)
  }

  /// Logged out or not a subscription login: not connected, no `-p` child, no attempt row, no billed call.
  func testNotLoggedInReportsNotConnectedWithoutStartingASummary() throws {
    for state in ["out", "key"] {
      try login(state)
      let (service, memory) = service(try caller("success"))
      try service.summarize(from: 0, through: 10000, dayStart: 0, locale: "en-US")
      XCTAssertFalse(service.health.subscriptionConnected, state); XCTAssertTrue(memory.calls.isEmpty, state)
      XCTAssertNil(read("args"), state); XCTAssertEqual(service.health.transportFailures, 0, state)
    }
    XCTAssertEqual(try records().map { $0["failureReason"] as? String }, ["not_connected", "not_subscription"])
    // A login lost between the status check and the call is the same.
    try login("in")
    let (service, memory) = service(try caller("loggedOut"))
    try service.summarize(from: 0, through: 10000, dayStart: 0, locale: "en-US")
    XCTAssertFalse(service.health.subscriptionConnected); XCTAssertTrue(memory.calls.isEmpty)
  }

  func testMissingCLIIsNotConnected() throws {
    let caller = ClaudeSummaryCaller(command: .absent("claude"), appDataDirectory: appData, attemptLog: log, temporaryRoot: temporary)
    XCTAssertThrowsError(try caller.beginPass()) { XCTAssertEqual($0 as? SummaryError, .notConnected) }
    XCTAssertThrowsError(try caller.call("Invented")) { XCTAssertEqual($0 as? SummaryError, .notConnected) }
  }

  func testTimeoutIsAFailedAttemptAndTheChildIsGone() throws {
    let (service, memory) = service(try caller("timeout", timeout: 1))
    try service.summarize(from: 0, through: 10000, dayStart: 0, locale: "en-US")
    XCTAssertEqual(memory.calls.map(\.succeeded), [false, false]); XCTAssertEqual(service.health.transportFailures, 2)
    XCTAssertEqual(try records().compactMap { $0["exit"] as? String }, ["timeout", "timeout"])
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temporary.appendingPathComponent("activityprobe-summary-work").path), [])
  }

  /// A child stopped before its init line sent nothing to the model: an unbilled failure, retried next pass.
  func testTimeoutBeforeInitIsUnbilledAndRetryable() throws {
    let (service, memory) = service(try caller("stall", timeout: 1))
    try service.summarize(from: 0, through: 10000, dayStart: 0, locale: "en-US")
    XCTAssertTrue(memory.calls.isEmpty); XCTAssertEqual(service.health.unbilledExecFailures, 1)
    XCTAssertEqual(service.health.transportFailures, 0); XCTAssertTrue(service.health.failedRanges.isEmpty)
    XCTAssertFalse(try service.plan(from: 0, through: 10000).pieces.isEmpty)
    let record = try XCTUnwrap(try records().last)
    XCTAssertEqual(record["exit"] as? String, "timeout"); XCTAssertEqual(record["failureReason"] as? String, "timeout_before_start")
  }

  // MARK: Work folder

  /// The status check and the call share one stable folder; it starts empty for each child and is emptied after.
  func testWorkFolderIsOneStablePrivateFolderEmptiedAroundEachChild() throws {
    let work = temporary.appendingPathComponent("activityprobe-summary-work")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    try Data("invented".utf8).write(to: work.appendingPathComponent("left-over"))
    try FileManager.default.createSymbolicLink(at: work.appendingPathComponent("link"), withDestinationURL: home)
    let caller = try caller("success")
    try caller.beginPass(); _ = try caller.call("Invented")
    XCTAssertEqual(read("status-cwd-entries"), "0\n"); XCTAssertEqual(read("cwd-entries"), "0\n")
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.path), [])
    XCTAssertTrue(FileManager.default.fileExists(atPath: home.path))
    let mode = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: work.path)[.posixPermissions] as? Int)
    XCTAssertEqual(mode, 0o700)
    // A second call uses the same folder.
    let first = read("cwd"); _ = try caller.call("Invented"); XCTAssertEqual(read("cwd"), first)
  }

  /// A link, a file or a folder open to others in its place stops the call before any child starts.
  func testUnsafeWorkFolderIsRefused() throws {
    let work = temporary.appendingPathComponent("activityprobe-summary-work")
    let elsewhere = root.appendingPathComponent("elsewhere")
    try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let setups: [(String, () throws -> Void)] = [
      ("link", { try FileManager.default.createSymbolicLink(at: work, withDestinationURL: elsewhere) }),
      ("file", { try Data().write(to: work) }),
      ("mode", { try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755]) }),
    ]
    for (name, setup) in setups {
      try? FileManager.default.removeItem(at: work)
      try setup()
      let caller = try caller("success")
      XCTAssertThrowsError(try caller.beginPass(), name) { XCTAssertEqual($0 as? SummaryError, .localPreparation, name) }
      XCTAssertThrowsError(try caller.call("Invented"), name) { XCTAssertEqual($0 as? SummaryError, .localPreparation, name) }
      XCTAssertNil(read("args"), name); XCTAssertNil(read("status-commands"), name)
    }
  }

  /// Per-child folders from the previous build are swept once stale; the stable folder is kept.
  func testLegacyWorkFoldersAreSweptAndTheStableOneKept() throws {
    let legacy = temporary.appendingPathComponent("activityprobe-summary-AbCdEf12")
    let work = temporary.appendingPathComponent("activityprobe-summary-work")
    for folder in [legacy, work] {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -86_400)], ofItemAtPath: folder.path)
    }
    try caller("success").beginPass()
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temporary.path), ["activityprobe-summary-work"])
  }

  /// An exit before any result is an unbilled failure: the minutes stay pending for the next pass.
  func testNonZeroExitIsUnbilledAndRetryable() throws {
    for mode in ["exit", "ended"] {
      let (service, memory) = service(try caller(mode))
      try service.summarize(from: 0, through: 10000, dayStart: 0, locale: "en-US")
      XCTAssertTrue(memory.calls.isEmpty, mode); XCTAssertEqual(service.health.unbilledExecFailures, 1, mode)
      XCTAssertTrue(service.health.failedRanges.isEmpty, mode)
      XCTAssertFalse(try service.plan(from: 0, through: 10000).pieces.isEmpty, mode)
    }
  }

  // MARK: Effort fallback

  /// A CLI that refuses `--effort` is run once more without it. An error naming effort drops the flag for
  /// the rest of the process at once; a stop before init drops it only after the second call in a row.
  func testRefusedEffortIsOmittedAndSaidSo() throws {
    let expected = ["effortResult": "yes\nno\nno\n", "effortRejected": "yes\nno\nyes\nno\nno\n"]
    for mode in ["effortResult", "effortRejected"] {
      try? FileManager.default.removeItem(at: root.appendingPathComponent("efforts"))
      let caller = try caller(mode)
      XCTAssertEqual(try caller.call("Invented").text, "00:00\t00:10\twork\tInvented\tInvented", mode)
      if mode == "effortRejected" {
        XCTAssertTrue(caller.effortAccepted, mode)
        _ = try caller.call("Invented")
      }
      XCTAssertFalse(caller.effortAccepted, mode)
      _ = try caller.call("Invented")
      XCTAssertEqual(read("efforts"), expected[mode], mode)
      XCTAssertFalse(arguments().contains("--effort"), mode)
    }
    let fallback = try records().filter { $0["effortFallback"] as? Bool == true }
    XCTAssertEqual(fallback.count, 3); XCTAssertTrue(fallback.allSatisfy { $0["effort"] as? String == "omitted" })
  }

  /// One transient startup crash with `--effort` falls back for that call only; the next call keeps it, and a
  /// later single crash after a good start does not add up to two.
  func testOneStartupCrashKeepsEffort() throws {
    let caller = try caller("flakyStart")
    XCTAssertEqual(try caller.call("Invented").text, "00:00\t00:10\twork\tInvented\tInvented")
    XCTAssertTrue(caller.effortAccepted)
    _ = try caller.call("Invented")
    XCTAssertEqual(arguments().firstIndex(of: "--effort").map { arguments()[$0 + 1] }, "low")
    try FileManager.default.removeItem(at: root.appendingPathComponent("crashed"))
    _ = try caller.call("Invented")
    XCTAssertTrue(caller.effortAccepted); XCTAssertEqual(read("efforts"), "yes\nno\nyes\nyes\nno\n")
  }

  /// A plain startup failure is not mistaken for a refused effort.
  func testStartupFailureKeepsEffort() throws {
    let caller = try caller("exit")
    XCTAssertThrowsError(try caller.call("Invented")) { XCTAssertEqual($0 as? SummaryError, .unbilledExecFailure) }
    XCTAssertTrue(caller.effortAccepted); XCTAssertEqual(read("efforts"), "yes\nno\n")
  }
}

private struct NoAgentLogProcessHomes: AgentLogProcessSource {
  func processes() throws -> [AgentLogProcess] { [] }
  func homeVariable(_ name: String, processID: Int32) throws -> String? { nil }
}
