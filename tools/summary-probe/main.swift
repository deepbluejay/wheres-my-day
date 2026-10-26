import Core
import Foundation
import Darwin
import Outbound
import Shell
import Storage

// Evidence comes from the converted copy; each measurement has fresh output and context.
final class MeasurementStorage: SummaryStorage {
  let source: ActivityStorage
  let output: ActivityStorage
  init(source: ActivityStorage, output: ActivityStorage) { self.source = source; self.output = output }
  func samples(in range: TimeRange) throws -> [TimeSample] { try source.samples(in: range) }
  func evidence(in range: TimeRange) throws -> [EvidenceText] { try source.novelEvidence(in: range) }
  func recentScreenLineKeys(at now: Int) throws -> [String: Int] { try source.recentScreenLineKeys(at: now) }
  func forgottenRanges(in range: TimeRange) throws -> [TimeRange] { try source.forgottenRanges(in: range) }
  func intervals(in range: TimeRange) throws -> [NamedInterval] { try output.intervals(in: range) }
  func appendIntervals(_ intervals: [NamedInterval]) throws -> AppendResult {
    var result = AppendResult()
    for interval in intervals {
      if try !source.forgottenRanges(in: interval.range).isEmpty { result.refused += 1 }
      else { let saved = try output.appendIntervals([interval]); result.stored += saved.stored; result.refused += saved.refused }
    }
    return result
  }
  func modelCalls(in range: TimeRange) throws -> [ModelCall] { try output.modelCalls(in: range) }
  func modelCalls(overlapping range: TimeRange) throws -> [ModelCall] { try output.modelCalls(overlapping: range) }
  func appendModelCall(_ call: ModelCall) throws -> AppendResult { try output.appendModelCall(call) }
  func settings() throws -> StorageSettings { try output.settings() }
  func saveSettings(_ settings: StorageSettings) throws { try output.saveSettings(settings) }
}
final class CountedCaller: SummaryCaller {
  let transport: SummaryCaller
  var count = 0
  var maximumCalls = 0
  private var connected = false
  init(transport: SummaryCaller) { self.transport = transport }
  func beginPass() throws {
    guard !connected else { return }
    try transport.beginPass(); connected = true
  }
  func endPass() { transport.endPass(); connected = false }
  func call(_ prompt: String) throws -> SummaryAnswer {
    guard count < maximumCalls else { print("stopped_call_limit=\(maximumCalls)"); fflush(stdout); exit(3) }
    count += 1
    let answer = try transport.call(prompt)
    print("call=\(count) input_tokens=\(answer.inputTokens) cached_tokens=\(answer.cachedTokens) output_tokens=\(answer.outputTokens)")
    fflush(stdout)
    return answer
  }
}
// Only the invented test port or the explicitly selected production account can supply a token.
final class InventedTokens: ChatGPTAccessTokens {
  let signedInForPlanUse: Bool
  init(signedIn: Bool) { signedInForPlanUse = signedIn }
  func currentAccessToken() throws -> ChatGPTAccessToken {
    guard signedInForPlanUse else { throw ChatGPTTokenError.notSignedIn }
    return ChatGPTAccessToken("invented-summary-token", validUntil: Int.max)
  }
  func reportRejected(_ token: ChatGPTAccessToken) throws -> ChatGPTAccessToken { throw ChatGPTTokenError.notAccepted }
  func reportNotEligible(_ token: ChatGPTAccessToken) {}
  func reportUsageLimited(_ token: ChatGPTAccessToken) {}
  func reportNotAccepted(_ token: ChatGPTAccessToken) {}
  func reportRequestRefused(_ token: ChatGPTAccessToken) {}
  func reportSignInRequired() {}
}
var arguments = Array(CommandLine.arguments.dropFirst())
var testEndpoint: URL?
if let index = arguments.firstIndex(of: "--responses-url") {
  guard index + 1 < arguments.count, let url = URL(string: arguments[index + 1]),
    url.scheme == "http", url.host == "127.0.0.1", url.user == nil, url.password == nil else {
    print("loopback_responses_url_required"); exit(2)
  }
  testEndpoint = url; arguments.removeSubrange(index...index + 1)
}
let signedOut = arguments.contains("--signed-out")
arguments.removeAll { $0 == "--signed-out" }
let productAccount = arguments.contains("--product-account")
arguments.removeAll { $0 == "--product-account" }
func measurementCaller() -> ChatGPTSummaryCaller {
  let tokens: ChatGPTAccessTokens
  let configuration: ChatGPTResponsesConfiguration
  if let testEndpoint {
    tokens = InventedTokens(signedIn: !signedOut)
    configuration = .loopbackTest(url: testEndpoint)
  } else {
    guard let user = getpwuid(getuid()) else { print("user_home_unavailable"); exit(2) }
    let userHome = URL(fileURLWithPath: String(cString: user.pointee.pw_dir))
    guard let paths = try? AppPaths.resolve(userHome: userHome, environment: [:], appBinary: URL(fileURLWithPath: CommandLine.arguments[0])) else {
      print("summary_local_preparation"); exit(2)
    }
    tokens = ChatGPTSignInHost.tokens(paths: paths)
    configuration = .production
  }
  return ChatGPTSummaryCaller(tokens: tokens, attemptLog: root.appendingPathComponent("summary-attempts.jsonl"), configuration: configuration)
}
func allowMeasurement(_ storage: ActivityStorage) throws {
  let pending = try storage.patchSettings(.beginConnection)
  _ = try storage.patchSettings(.completeConnection(generation: pending.connectionGeneration))
}
func requireConnection(_ service: SummaryService) {
  if service.health.localPreparationFailed { print("summary_local_preparation"); exit(2) }
  if service.health.unbilledExecFailures > 0 { print("summary_unbilled_exec_failure"); exit(2) }
  if service.health.planUsePaused { print("summary_plan_paused"); exit(2) }
  guard service.health.subscriptionConnected else { print("summary_not_connected"); exit(2) }
}
guard let rootPath = ProcessInfo.processInfo.environment["ACTIVITYPROBE_TEST_ROOT"],
  ["/tmp/", "/private/tmp/"].contains(where: { URL(fileURLWithPath: rootPath).resolvingSymlinksInPath().path.hasPrefix($0) }) else {
  fatalError("Isolated temporary root required")
}
let root = URL(fileURLWithPath: rootPath)
let format = SummaryFormat()
// The evaluation day is the owner's midnight day, independent of isolated app defaults.
func requireMeasurementBounds(_ start: Int, _ end: Int) {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = .current
  let date = Date(timeIntervalSince1970: Double(start))
  guard calendar.startOfDay(for: date) == date,
    calendar.date(byAdding: .day, value: 1, to: date) == Date(timeIntervalSince1970: Double(end)) else {
    print("measurement_requires_midnight_day_bounds"); exit(2)
  }
}
guard let command = arguments.first else { fatalError("Mode required") }
if ["measure", "invented", "envelope"].contains(command) {
  guard (testEndpoint != nil) != productAccount, !signedOut || testEndpoint != nil else {
    print("measurement_account_required"); exit(2)
  }
  print("account_kind=\(testEndpoint == nil ? "app" : "invented")")
}

if command == "dry-run" {
  guard arguments.count == 4, let start = Int(arguments[2]), let end = Int(arguments[3]) else { fatalError("Bounds required") }
  requireMeasurementBounds(start, end)
  let storage = try ActivityStorage(url: root.appendingPathComponent("converted.sqlite"), appDataDirectory: root, databaseScope: .directory(root))
  let result = try storage.convertOldDatabase(at: URL(fileURLWithPath: arguments[1]))
  let range = TimeRange(start, end)
  let samples = try storage.samples(in: range), evidence = try storage.novelEvidence(in: range)
  let planningSamples = try storage.samples(in: TimeRange(start - RestPolicy.inputAgeSeconds - 1, end))
  let plan = SummaryPolicy.plan(samples: planningSamples, forgotten: try storage.forgottenRanges(in: range),
    through: end, requested: true, from: start)
  print("conversion samples=\(result.samples) evidence=\(result.evidence) intervals=\(result.intervals) finished=\(result.finished)")
  print("day samples=\(samples.count) evidence=\(evidence.count)")
  print("calls=\(plan.pieces.filter { !$0.isPrivate }.count) private=\(plan.pieces.filter(\.isPrivate).count) carried=\(plan.pieces.reduce(0) { $0 + $1.carriedCount }) waiting=\(plan.waiting.count)")
  for (index, piece) in plan.pieces.filter({ !$0.isPrivate }).enumerated() {
    let table = format.table(range: piece.range, samples: samples, evidence: evidence, sentRanges: piece.sentRanges, endsAtRest: piece.endsAtRest)
    print("call=\(index + 1) minutes=\(piece.minutes) clock_minutes=\((piece.range.end-piece.range.start)/60) table_characters=\(table.unicodeScalars.count) estimated_table_tokens=\((table.utf8.count+3)/4)")
  }
} else if command == "tables" {
  guard arguments.count == 3, let start = Int(arguments[1]), let end = Int(arguments[2]) else { fatalError("Bounds required") }
  requireMeasurementBounds(start, end)
  let source = try ActivityStorage(url: root.appendingPathComponent("converted.sqlite"), appDataDirectory: root, databaseScope: .directory(root))
  let output = try ActivityStorage(url: root.appendingPathComponent("sample-1.sqlite"), appDataDirectory: root, databaseScope: .directory(root))
  let range = TimeRange(start, end)
  let samples = try source.samples(in: TimeRange(start - RestPolicy.inputAgeSeconds - 1, end))
  let evidence = try source.novelEvidence(in: range)
  let plan = SummaryPolicy.plan(samples: samples, forgotten: try source.forgottenRanges(in: range),
    through: end, requested: true, from: start)
  let rows = try plan.pieces.filter { !$0.isPrivate }.map { piece -> [String: Any] in
    let prior = try output.modelCalls(in: TimeRange(Int.min + 1, Int.max)).filter { !$0.pending && $0.range.end <= piece.range.start }.max { $0.range.end < $1.range.end }
    let previous = try prior.map { call in try output.intervals(in: call.range).filter {
      $0.range.start >= call.range.start && $0.range.end <= call.range.end
    } } ?? []
    let names = try Set(output.intervals(in: TimeRange(start, piece.range.start)).filter { $0.state == .named }.map(\.name)).sorted()
    let table = format.table(range: piece.range, samples: samples, evidence: evidence, sentRanges: piece.sentRanges, endsAtRest: piece.endsAtRest)
    let prompt = format.prompt(range: piece.range, table: table, previous: previous, names: names, locale: "ko-KR", sentRanges: piece.sentRanges)
    return ["table": table, "prompt": prompt, "instructions": SummaryFormat.instructions,
      "context": format.prompt(range: piece.range, table: "", previous: previous, names: names, locale: "ko-KR", sentRanges: piece.sentRanges)]
  }
  let file = root.appendingPathComponent("table-analysis.json")
  try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys]).write(to: file, options: [.atomic])
  try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
  print("tables=\(rows.count)")
} else if command == "measure" {
  guard arguments.count == 4, let sample = Int(arguments[1]), (1...3).contains(sample),
    let start = Int(arguments[2]), let end = Int(arguments[3]) else { fatalError("Sample and bounds required") }
  requireMeasurementBounds(start, end)
  let source = try ActivityStorage(url: root.appendingPathComponent("converted.sqlite"), appDataDirectory: root, databaseScope: .directory(root))
  let output = try ActivityStorage(url: root.appendingPathComponent("sample-\(sample).sqlite"), appDataDirectory: root, databaseScope: .directory(root))
  guard try output.modelCalls(in: TimeRange(Int.min + 1, Int.max)).isEmpty,
    try output.intervals(in: TimeRange(start, end)).isEmpty else { fatalError("Fresh sample required") }
  try allowMeasurement(output)
  // Output writes and each attempt consult deletion barriers in the frozen source.
  let storage = MeasurementStorage(source: source, output: output)
  let caller = CountedCaller(transport: measurementCaller())
  // Validate login even when an empty day has no pieces to send.
  do { try caller.beginPass() }
  catch SummaryError.notConnected { print("summary_not_connected"); exit(2) }
  catch SummaryError.localPreparation { print("summary_local_preparation"); exit(2) }
  catch { print("summary_transport_failure"); exit(2) }
  let service = SummaryService(storage: storage, caller: caller, format: format)
  let planned = try service.plan(from: start, through: end, requested: true)
  // Exactly one run, with at most the service's one retry per planned call.
  caller.maximumCalls = planned.pieces.filter { !$0.isPrivate }.count * 2
  try service.summarize(from: start, through: end, dayStart: start, locale: "ko-KR", requested: true)
  requireConnection(service)
  print("sample=\(sample) calls=\(service.health.calls) intervals=\(service.health.storedIntervals) failed_ranges=\(service.health.failedRanges.count) first_shape_failures=\(service.health.firstAttemptShapeFailures) transport_failures=\(service.health.transportFailures)")
  for reason in SummaryShapeReason.allCases {
    print("shape_reason=\(reason.rawValue) first_attempts=\(service.health.firstAttemptShapeReasons[reason, default: 0]) all_attempts=\(service.health.shapeFailures[reason, default: 0])")
  }
  for reason in SummaryUnknownKindReason.allCases {
    print("unknown_kind_reason=\(reason.rawValue) first_attempts=\(service.health.firstAttemptUnknownKindReasons[reason, default: 0]) all_attempts=\(service.health.unknownKindReasons[reason, default: 0])")
  }
} else if command == "kinds" {
  guard arguments.count == 4, let sample = Int(arguments[1]), (1...3).contains(sample),
    let start = Int(arguments[2]), let end = Int(arguments[3]) else { fatalError("Sample and bounds required") }
  requireMeasurementBounds(start, end)
  let storage = MeasurementStorage(source: try ActivityStorage(url: root.appendingPathComponent("converted.sqlite"), appDataDirectory: root, databaseScope: .directory(root)),
    output: try ActivityStorage(url: root.appendingPathComponent("sample-\(sample).sqlite"), appDataDirectory: root, databaseScope: .directory(root)))
  let kinds = try SummaryTimeline.minutes(in: TimeRange(start, end), storage: storage)
  let minutes = Dictionary(uniqueKeysWithValues: kinds.map { (String($0.key), $0.value.rawValue) })
  let file = root.appendingPathComponent("minute-kinds.json")
  try JSONSerialization.data(withJSONObject: minutes, options: [.sortedKeys]).write(to: file, options: [.atomic])
  try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
  print("minute_kinds=\(minutes.count)")
  print("unnamed_middle_quiet_minutes=\(try SummaryTimeline.unnamedMiddleQuietMinuteCount(in: TimeRange(start, end), storage: storage))")
  print("breaks_301_419_seconds=\(SummaryTimeline.shortBreakCount(in: TimeRange(start, end), samples: try storage.samples(in: TimeRange(start, end)), forgotten: try storage.forgottenRanges(in: TimeRange(start, end))))")
} else if command == "judge-data" {
  guard arguments.count == 3, let start = Int(arguments[1]), let end = Int(arguments[2]) else { fatalError("Bounds required") }
  let source = try ActivityStorage(url: root.appendingPathComponent("converted.sqlite"), appDataDirectory: root, databaseScope: .directory(root))
  let range = TimeRange(start, end)
  let samples = try source.samples(in: range), evidence = try source.novelEvidence(in: range)
  let minutes = stride(from: start, to: end, by: 60).map { minute -> [String: Any] in
    ["ts": minute, "table": format.table(range: TimeRange(minute, minute + 60), samples: samples, evidence: evidence)]
  }
  func mask(_ value: Any) -> Any {
    if let text = value as? String { return Redaction.apply(text).text }
    if let array = value as? [Any] { return array.map(mask) }
    if let dictionary = value as? [String: Any] { return dictionary.mapValues(mask) }
    return value
  }
  let labels = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("dispute-labels.json")))
  let data = try JSONSerialization.data(withJSONObject: ["minutes": minutes, "labels": mask(labels)], options: [.sortedKeys])
  let file = root.appendingPathComponent("judge-data.json")
  try data.write(to: file, options: [.atomic])
  try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
  print("judge_data_minutes=\(minutes.count)")
 } else if command == "envelope" {
  guard arguments.count == 1 else { fatalError("Unexpected argument") }
  let caller = measurementCaller()
  let prompt = "Invented."
  let answer: SummaryAnswer
  do { answer = try caller.call(prompt) }
  catch SummaryError.notConnected { print("summary_not_connected"); exit(2) }
  catch SummaryError.localPreparation { print("summary_local_preparation"); exit(2) }
  catch { print("summary_transport_failure"); exit(2) }
  print("envelope_input=\(answer.inputTokens) prompt_estimate=\(SummaryMaintenance.estimatedTokens(prompt)) cached=\(answer.cachedTokens) output=\(answer.outputTokens)")
} else if command == "invented" {
  guard arguments.count == 1 else { fatalError("Unexpected argument") }
  let storage = try ActivityStorage(url: root.appendingPathComponent("invented-model.sqlite"), appDataDirectory: root, databaseScope: .directory(root))
  try allowMeasurement(storage)
  let start = 1_800_000_000 / 60 * 60
  let range = TimeRange(start, start + 1800)
  let samples = (range.start..<range.end).map { TimeSample(ts: $0, app: "Invented editor", window: "Invented exercise",
    documentKey: "/invented/exercise/item", keys: $0 % 10 == 0 ? 1 : 0) }
  try storage.appendSamples(samples)
  try storage.appendEvidence([EvidenceText(ts: start, kind: .prompt, source: "invented", project: "exercise",
    text: "Review the invented arithmetic exercise."), EvidenceText(ts: start + 60, kind: .screen, source: "invented",
    text: "Invented arithmetic exercise: add two numbers and check the answer.")])
  let caller = measurementCaller()
  let service = SummaryService(storage: storage, caller: caller, format: format)
  try service.summarize(from: start, through: range.end + 600, dayStart: start, locale: "en-US", requested: true)
  requireConnection(service)
  let calls = try storage.modelCalls(in: TimeRange(start, range.end + 1000))
  for (index, call) in calls.enumerated() {
    print("invented_call=\(index+1) input_tokens=\(call.inputTokens) cached_tokens=\(call.cachedTokens) output_tokens=\(call.outputTokens) parsed=\(call.succeeded)")
  }
  print("intervals=\(try storage.intervals(in: range).count) failed_ranges=\(service.health.failedRanges.count)")
  for reason in SummaryUnknownKindReason.allCases {
    print("unknown_kind_reason=\(reason.rawValue) first_attempts=\(service.health.firstAttemptUnknownKindReasons[reason, default: 0]) all_attempts=\(service.health.unknownKindReasons[reason, default: 0])")
  }
  if calls.isEmpty || !calls.last!.succeeded { exit(2) }
} else { fatalError("Unknown mode") }
