import Core
import Darwin
import Foundation
@testable import Outbound
import XCTest

/// An invented Responses endpoint on 127.0.0.1. Each request gets the next scripted reply; nothing leaves the Mac.
final class FakeResponsesServer {
  struct Request { let path: String; let headers: [String: String]; let body: Data }
  struct Reply { var status = 200; var contentType = "text/event-stream"; var headers: [String: String] = [:]; var body = Data() }
  let port: UInt16
  var url: URL { URL(string: "http://127.0.0.1:\(port)/v1/responses")! }
  private let socket: Int32
  private let lock = NSLock()
  private var recorded: [Request] = []
  private var stopped = false
  var replies: [Reply] = []
  init() throws {
    let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET); address.sin_port = 0; address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard bound == 0, listen(descriptor, 8) == 0 else { close(descriptor); throw POSIXError(.EADDRINUSE) }
    var actual = sockaddr_in(); var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &actual) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) } }
    socket = descriptor; port = UInt16(bigEndian: actual.sin_port)
    Thread.detachNewThread { [self] in serve() }
  }
  func stop() { lock.lock(); stopped = true; lock.unlock(); shutdown(socket, SHUT_RDWR); close(socket) }
  var requests: [Request] { lock.lock(); defer { lock.unlock() }; return recorded }
  private func serve() {
    while true {
      let client = accept(socket, nil, nil)
      if client < 0 { lock.lock(); let done = stopped; lock.unlock(); if done { return }; continue }
      var noSignal: Int32 = 1
      setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
      handle(client); close(client)
    }
  }
  private func handle(_ client: Int32) {
    var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
    var expected: Int?
    while true {
      if let end = data.range(of: Data("\r\n\r\n".utf8)) {
        if expected == nil {
          let head = String(decoding: data[..<end.lowerBound], as: UTF8.self)
          expected = head.split(separator: "\r\n").compactMap { line -> Int? in
            let parts = line.split(separator: ":", maxSplits: 1)
            return parts.count == 2 && parts[0].lowercased() == "content-length" ? Int(parts[1].trimmingCharacters(in: .whitespaces)) : nil
          }.first ?? 0
        }
        if data.count - end.upperBound >= expected! { break }
      }
      let count = read(client, &buffer, buffer.count)
      if count <= 0 { return }
      data.append(contentsOf: buffer.prefix(count))
    }
    guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return }
    let lines = String(decoding: data[..<end.lowerBound], as: UTF8.self).split(separator: "\r\n")
    let path = String(lines.first?.split(separator: " ").dropFirst().first ?? "")
    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      let parts = line.split(separator: ":", maxSplits: 1)
      if parts.count == 2 { headers[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces) }
    }
    lock.lock()
    recorded.append(Request(path: path, headers: headers, body: Data(data[end.upperBound...])))
    let reply = replies.isEmpty ? Reply(status: 500) : replies.removeFirst()
    lock.unlock()
    var head = "HTTP/1.1 \(reply.status) X\r\nContent-Type: \(reply.contentType)\r\nContent-Length: \(reply.body.count)\r\nConnection: close\r\n"
    for (name, value) in reply.headers { head += "\(name): \(value)\r\n" }
    let bytes = [UInt8](Data((head + "\r\n").utf8) + reply.body)
    _ = bytes.withUnsafeBufferPointer { write(client, $0.baseAddress, $0.count) }
  }
}

/// A token port with scripted answers that counts every report.
final class FakePlanTokens: ChatGPTAccessTokens {
  var current: Result<String, ChatGPTTokenError> = .success("invented-access-1")
  var renewed: Result<String, ChatGPTTokenError> = .success("invented-access-2")
  var rejected: [String] = []
  var notEligible = 0, usageLimited = 0, notAccepted = 0, requestRefused = 0, signInRequired = 0
  /// The token each refusal report named.
  var reported: [String] = []
  var signedInForPlanUse = true
  func currentAccessToken() throws -> ChatGPTAccessToken { ChatGPTAccessToken(try current.get(), validUntil: Int.max) }
  func reportRejected(_ token: ChatGPTAccessToken) throws -> ChatGPTAccessToken {
    rejected.append(token.value); return ChatGPTAccessToken(try renewed.get(), validUntil: Int.max)
  }
  func reportNotEligible(_ token: ChatGPTAccessToken) { notEligible += 1; reported.append(token.value) }
  func reportUsageLimited(_ token: ChatGPTAccessToken) { usageLimited += 1; reported.append(token.value) }
  func reportNotAccepted(_ token: ChatGPTAccessToken) { notAccepted += 1; reported.append(token.value) }
  func reportRequestRefused(_ token: ChatGPTAccessToken) { requestRefused += 1; reported.append(token.value) }
  func reportSignInRequired() { signInRequired += 1 }
}

final class ChatGPTSummaryCallerTests: XCTestCase {
  var root: URL!
  var server: FakeResponsesServer!
  var tokens: FakePlanTokens!
  var log: URL { root.appendingPathComponent("summary-attempts.jsonl") }
  override func setUpWithError() throws {
    root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ACTIVITYPROBE_TEST_ROOT"] ?? NSTemporaryDirectory())
      .appendingPathComponent("responses-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    server = try FakeResponsesServer(); tokens = FakePlanTokens()
  }
  override func tearDownWithError() throws { server.stop(); try? FileManager.default.removeItem(at: root) }

  var now: TimeInterval = 1_800_000_000
  func caller(timeout: TimeInterval = 10) -> ChatGPTSummaryCaller {
    ChatGPTSummaryCaller(tokens: tokens, attemptLog: log, configuration: .loopbackTest(url: server.url, timeout: timeout),
      clock: { [unowned self] in now })
  }
  /// Invented server-sent events, as the docs describe them, ending with `terminal`.
  static func events(_ text: String, terminal: String = "response.completed", usage: [String: Any]? = nil,
    error: [String: Any]? = nil) -> Data {
    let message: [String: Any] = ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": text]]]
    var response: [String: Any] = ["id": "resp_invented", "status": "completed", "output": [message]]
    if let usage { response["usage"] = usage }
    if let error { response["error"] = error }
    let half = text.index(text.startIndex, offsetBy: text.count / 2)
    let list: [[String: Any]] = [
      ["type": "response.created", "response": ["id": "resp_invented", "status": "in_progress", "output": []]],
      ["type": "response.output_text.delta", "delta": String(text[..<half])],
      ["type": "response.output_text.delta", "delta": String(text[half...])],
      ["type": "response.output_item.done", "item": message],
      ["type": terminal, "response": response]]
    return Data(list.map { event in
      "event: \(event["type"]!)\ndata: " + String(decoding: try! JSONSerialization.data(withJSONObject: event), as: UTF8.self) + "\n\n"
    }.joined().utf8)
  }
  static let usage: [String: Any] = ["input_tokens": 120, "input_tokens_details": ["cached_tokens": 20], "output_tokens": 30]
  static func refusal(_ status: Int, code: String?, param: String? = nil) -> FakeResponsesServer.Reply {
    let body: [String: Any] = code != nil || param != nil
      ? ["error": ["code": code.map { $0 as Any } ?? NSNull(), "message": "Invented refusal", "param": param.map { $0 as Any } ?? NSNull()]]
      : ["detail": "Invented admission refusal"]
    return FakeResponsesServer.Reply(status: status, contentType: "application/json", body: try! JSONSerialization.data(withJSONObject: body))
  }
  func records() throws -> [[String: Any]] {
    try String(contentsOf: log).split(separator: "\n").map {
      try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
    }
  }
  func expect(_ error: Error, _ expected: SummaryError, file: StaticString = #filePath, line: UInt = #line) {
    guard let error = error as? SummaryError, error == expected else { return XCTFail("\(error) is not \(expected)", file: file, line: line) }
  }

  // MARK: Request and answer

  func testStreamedRequestSendsOnlyAllowedFieldsAndReadsTheCompletedAnswer() throws {
    let answerText = "09:00\t09:30\twork\tInvented task\tInvented description"
    server.replies = [.init(headers: ["x-request-id": "req_invented1"], body: Self.events(answerText, usage: Self.usage))]
    let answer = try caller().call("Invented prompt.")
    XCTAssertEqual(answer.text, answerText)
    XCTAssertEqual([answer.inputTokens, answer.cachedTokens, answer.outputTokens], [120, 20, 30])
    let request = try XCTUnwrap(server.requests.first)
    XCTAssertEqual(server.requests.count, 1); XCTAssertEqual(request.path, "/v1/responses")
    XCTAssertEqual(request.headers["authorization"], "Bearer invented-access-1")
    XCTAssertEqual(request.headers["accept"], "text/event-stream")
    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
    // Preview limitations: store false, stream true, the context in `input`, no unsupported field and no tools.
    XCTAssertEqual(Set(body.keys), ["model", "input", "reasoning", "store", "stream"])
    XCTAssertEqual(body["model"] as? String, "gpt-5.6-luna"); XCTAssertEqual(body["model"] as? String, ChatGPTSummaryCaller.model)
    XCTAssertEqual(body["store"] as? Bool, false); XCTAssertEqual(body["stream"] as? Bool, true)
    XCTAssertEqual((body["reasoning"] as? [String: String]) ?? [:], ["effort": "low"])
    let input = try XCTUnwrap(body["input"] as? [[String: String]])
    XCTAssertEqual(input, [["role": "user", "content": "Invented prompt."]])
    // The attempt log keeps its meaning: one line per attempt with counts and token use, never a value.
    let record = try XCTUnwrap(try records().first)
    XCTAssertEqual(try records().count, 1)
    XCTAssertEqual(record["inputTokens"] as? Int, 120); XCTAssertEqual(record["cachedTokens"] as? Int, 20)
    XCTAssertEqual(record["outputTokens"] as? Int, 30); XCTAssertEqual(record["httpStatus"] as? Int, 200)
    XCTAssertEqual(record["transport"] as? String, "responses"); XCTAssertEqual(record["requestID"] as? String, "req_invented1")
    XCTAssertEqual((record["events"] as? [String: Int])?["response.completed"], 1)
    XCTAssertEqual((record["events"] as? [String: Int])?["response.output_text.delta"], 2)
    XCTAssertEqual((record["items"] as? [String: Int]) ?? [:], ["message": 1])
    XCTAssertNil(record["failureReason"]); XCTAssertEqual(record["excessInput"] as? Bool, false)
    XCTAssertEqual(record["promptEstimatedTokens"] as? Int, SummaryMaintenance.estimatedTokens("Invented prompt."))
  }

  func testPreflightNeedsOnlyTheTokenAndWritesNothing() throws {
    try caller().beginPass()
    XCTAssertTrue(server.requests.isEmpty); XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))
    tokens.current = .failure(.notSignedIn)
    XCTAssertThrowsError(try caller().beginPass()) { expect($0, .notConnected) }
    XCTAssertEqual(try records().first?["failureReason"] as? String, "not_connected")
    XCTAssertTrue(server.requests.isEmpty)
  }

  func testTokenStaysOutOfLogsFilesAndErrors() throws {
    tokens.current = .success("invented-secret-access-token")
    server.replies = [Self.refusal(401, code: "subscription_sharing_invalid_user"), Self.refusal(401, code: "subscription_sharing_invalid_user")]
    tokens.renewed = .success("invented-secret-renewed-token")
    var thrown: Error?
    XCTAssertThrowsError(try caller().call("Invented prompt.")) { thrown = $0 }
    server.replies = [.init(body: Self.events("invalid", usage: Self.usage))]
    _ = try caller().call("Invented prompt.")
    for secret in ["invented-secret-access-token", "invented-secret-renewed-token"] {
      XCTAssertFalse(String(describing: thrown as Any).contains(secret))
      let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!.compactMap { $0 as? URL }
      XCTAssertFalse(files.isEmpty)
      for file in files { XCTAssertFalse((try? String(contentsOf: file))?.contains(secret) ?? false, file.lastPathComponent) }
    }
    XCTAssertEqual(server.requests.map { $0.headers["authorization"] },
      ["Bearer invented-secret-access-token", "Bearer invented-secret-renewed-token", "Bearer invented-secret-access-token"])
  }

  // MARK: Errors and recovery

  func testUnauthorizedRenewsOnceThenRetriesOnce() throws {
    server.replies = [Self.refusal(401, code: "subscription_sharing_invalid_user"), .init(body: Self.events("invalid", usage: Self.usage))]
    _ = try caller().call("Invented prompt.")
    XCTAssertEqual(tokens.rejected, ["invented-access-1"])
    XCTAssertEqual(server.requests.map { $0.headers["authorization"] }, ["Bearer invented-access-1", "Bearer invented-access-2"])
    XCTAssertEqual(tokens.notAccepted, 0); XCTAssertEqual(tokens.signInRequired, 0)
    XCTAssertEqual(try records().last?["requests"] as? Int, 2)
  }

  func testSecondUnauthorizedStopsWithoutSigningOut() throws {
    server.replies = [Self.refusal(401, code: "subscription_sharing_invalid_user"), Self.refusal(401, code: nil)]
    XCTAssertThrowsError(try caller().call("Invented prompt.")) { expect($0, .paused) }
    XCTAssertEqual(server.requests.count, 2); XCTAssertEqual(tokens.rejected.count, 1)
    XCTAssertEqual(tokens.notAccepted, 1); XCTAssertEqual(tokens.signInRequired, 0)
    // The pause names the renewed token, the one the second refusal was about.
    XCTAssertEqual(tokens.reported, ["invented-access-2"])
    XCTAssertEqual(try records().last?["failureReason"] as? String, "not_accepted")
    // A renewal that ends the sign-in, or cannot reach ChatGPT, stops at once.
    for (failure, expected) in [(ChatGPTTokenError.signInAgain, SummaryError.notConnected), (.temporarilyUnavailable, .unbilledExecFailure)] {
      tokens.renewed = .failure(failure)
      server.replies = [Self.refusal(401, code: "subscription_sharing_invalid_user")]
      let before = server.requests.count
      XCTAssertThrowsError(try caller().call("Invented prompt.")) { expect($0, expected) }
      XCTAssertEqual(server.requests.count, before + 1)
    }
  }

  func testRefusalsMapToOneActionEach() throws {
    let cases: [(FakeResponsesServer.Reply, SummaryError, String)] = [
      (Self.refusal(403, code: "subscription_sharing_user_not_eligible"), .notConnected, "not_eligible"),
      (Self.refusal(403, code: nil), .paused, "not_accepted"),
      (Self.refusal(403, code: "chatpass_v2_scope_not_authorized"), .paused, "not_accepted"),
      // The request itself was refused: the same body is not sent again by this build.
      (Self.refusal(400, code: "subscription_sharing_unsupported_capability", param: "model"), .paused, "request_refused"),
      (Self.refusal(404, code: nil), .paused, "not_accepted"),
      (Self.refusal(422, code: "invalid_request_error"), .paused, "not_accepted"),
      (Self.refusal(429, code: "subscription_sharing_usage_limit_exceeded"), .paused, "usage_limited"),
      (Self.refusal(429, code: "rate_limit_exceeded"), .paused, "usage_limited"),
      // Unavailable for now: a short backoff pause, not a failed pass.
      (Self.refusal(503, code: "subscription_sharing_usage_unavailable"), .paused, "service_unavailable"),
      (Self.refusal(503, code: "subscription_sharing_user_unavailable"), .paused, "service_unavailable"),
      (Self.refusal(503, code: nil), .paused, "service_unavailable"),
      (Self.refusal(500, code: "subscription_sharing_usage_unavailable"), .paused, "service_unavailable"),
      (Self.refusal(502, code: nil), .unbilledExecFailure, "server_unavailable"),
      (Self.refusal(500, code: "server_error"), .unbilledExecFailure, "server_unavailable"),
    ]
    for (reply, expected, reason) in cases {
      server.replies = [reply]
      let before = server.requests.count
      XCTAssertThrowsError(try caller().call("Invented prompt.")) { expect($0, expected) }
      // One request: none of these is retried inside the call.
      XCTAssertEqual(server.requests.count, before + 1, reason)
      XCTAssertEqual(try records().last?["failureReason"] as? String, reason)
    }
    XCTAssertEqual(tokens.notEligible, 1); XCTAssertEqual(tokens.notAccepted, 4); XCTAssertEqual(tokens.usageLimited, 2)
    XCTAssertEqual(tokens.requestRefused, 1)
    XCTAssertTrue(tokens.rejected.isEmpty); XCTAssertEqual(tokens.signInRequired, 0)
    // Every report names the token the refused request carried.
    XCTAssertEqual(Set(tokens.reported), ["invented-access-1"]); XCTAssertEqual(tokens.reported.count, 8)
  }

  func testRedirectIsNotFollowedAndPauses() throws {
    let elsewhere = "http://127.0.0.1:\(server.port)/elsewhere"
    server.replies = [.init(status: 307, contentType: "text/plain", headers: ["Location": elsewhere]),
      .init(body: Self.events("invalid", usage: Self.usage))]
    XCTAssertThrowsError(try caller().call("Invented prompt.")) { expect($0, .paused) }
    // The bearer token never reaches the redirect's target: nothing but the one request arrived.
    XCTAssertEqual(server.requests.map(\.path), ["/v1/responses"])
    XCTAssertEqual(tokens.notAccepted, 1); XCTAssertEqual(tokens.requestRefused, 0)
    XCTAssertEqual(try records().last?["failureReason"] as? String, "not_accepted")
    XCTAssertEqual(try records().last?["httpStatus"] as? Int, 307)
  }

  func testUnavailableBacksOffBrieflyAndGrows() throws {
    let caller = caller()
    server.replies = [Self.refusal(503, code: "subscription_sharing_usage_unavailable")]
    XCTAssertThrowsError(try caller.call("Invented prompt.")) { expect($0, .paused) }
    // Within the backoff nothing is sent, and the pass preflight stops too.
    now += ChatGPTSummaryCaller.unavailableShortest - 1
    XCTAssertThrowsError(try caller.beginPass()) { expect($0, .paused) }
    XCTAssertThrowsError(try caller.call("Invented prompt.")) { expect($0, .paused) }
    XCTAssertEqual(server.requests.count, 1)
    XCTAssertEqual(try records().last?["failureReason"] as? String, "service_unavailable")
    // After it one request goes; a second unavailable answer doubles the wait, up to the longest.
    now += 1
    server.replies = [Self.refusal(503, code: nil)]
    XCTAssertThrowsError(try caller.call("Invented prompt.")) { expect($0, .paused) }
    XCTAssertEqual(server.requests.count, 2)
    now += ChatGPTSummaryCaller.unavailableShortest
    XCTAssertThrowsError(try caller.call("Invented prompt.")) { expect($0, .paused) }
    XCTAssertEqual(server.requests.count, 2)
    now += ChatGPTSummaryCaller.unavailableShortest
    for _ in 0..<6 {
      server.replies = [.init(body: Self.events("", terminal: "response.failed", error: ["code": "subscription_sharing_user_unavailable"]))]
      XCTAssertThrowsError(try caller.call("Invented prompt.")) { expect($0, .paused) }
      now += ChatGPTSummaryCaller.unavailableLongest
    }
    XCTAssertEqual(server.requests.count, 8)
    // An answer ends the backoff at once.
    server.replies = [.init(body: Self.events("invalid", usage: Self.usage)), Self.refusal(503, code: nil)]
    _ = try caller.call("Invented prompt.")
    XCTAssertThrowsError(try caller.call("Invented prompt.")) { expect($0, .paused) }
    now += ChatGPTSummaryCaller.unavailableShortest
    server.replies = [.init(body: Self.events("invalid", usage: Self.usage))]
    _ = try caller.call("Invented prompt.")
    XCTAssertEqual(server.requests.count, 11)
    XCTAssertEqual(tokens.notAccepted + tokens.usageLimited + tokens.requestRefused, 0)
  }

  func testUsageLimitAfterTheStreamBeganPauses() throws {
    server.replies = [.init(body: Self.events("", terminal: "response.failed",
      error: ["code": "subscription_sharing_usage_limit_exceeded"]))]
    XCTAssertThrowsError(try caller().call("Invented prompt.")) { expect($0, .paused) }
    XCTAssertEqual(tokens.usageLimited, 1)
    // A stream that was billed before the limit carries its usage with the pause.
    server.replies = [.init(body: Self.events("", terminal: "response.failed", usage: Self.usage,
      error: ["code": "subscription_sharing_usage_limit_exceeded"]))]
    XCTAssertThrowsError(try caller().call("Invented prompt.")) { error in
      let paused = error as? SummaryPausedAfterBilling
      XCTAssertEqual(paused?.usage.inputTokens, 120); XCTAssertEqual(paused?.usage.outputTokens, 30)
    }
  }

  func testIncompleteOrInterruptedStreamsAreNotAnswers() throws {
    // Billed but incomplete: a counted failure with its usage, like a CLI that failed after billing.
    server.replies = [.init(body: Self.events("09:00", terminal: "response.incomplete", usage: Self.usage))]
    XCTAssertThrowsError(try caller().call("Invented prompt.")) { error in
      let failure = error as? SummaryTransportFailure
      XCTAssertEqual(failure?.inputTokens, 120); XCTAssertEqual(failure?.outputTokens, 30)
    }
    // Ended without a terminal event and nothing billed: the next pass retries.
    var cut = Self.events("09:00", usage: Self.usage)
    cut = cut.prefix(upTo: cut.range(of: Data("event: response.completed".utf8))!.lowerBound)
    server.replies = [.init(body: cut), .init(body: Self.events("", terminal: "response.failed", error: ["code": "server_error"]))]
    XCTAssertThrowsError(try caller().call("Invented prompt.")) { expect($0, .unbilledExecFailure) }
    XCTAssertThrowsError(try caller().call("Invented prompt.")) { expect($0, .unbilledExecFailure) }
    XCTAssertEqual(try records().map { $0["failureReason"] as? String }, ["stream_failed", "stream_failed", "stream_failed"])
  }

  func testNetworkAndTokenPortFailuresSendNothingMore() throws {
    let port = server.port; server.stop()
    let closed = ChatGPTSummaryCaller(tokens: tokens, attemptLog: log,
      configuration: .loopbackTest(url: URL(string: "http://127.0.0.1:\(port)/v1/responses")!, timeout: 5))
    XCTAssertThrowsError(try closed.call("Invented prompt.")) { expect($0, .unbilledExecFailure) }
    XCTAssertEqual(try records().last?["failureReason"] as? String, "network")
    server = try FakeResponsesServer()
    let mapping: [(ChatGPTTokenError, SummaryError)] = [(.notSignedIn, .notConnected), (.planRequired, .notConnected),
      (.signInAgain, .notConnected), (.notAvailable, .notConnected), (.storage, .notConnected),
      (.usageLimited, .paused), (.notAccepted, .paused), (.requestRefused, .paused), (.temporarilyUnavailable, .unbilledExecFailure)]
    for (failure, expected) in mapping {
      tokens.current = .failure(failure)
      XCTAssertThrowsError(try caller().call("Invented prompt.")) { expect($0, expected) }
    }
    XCTAssertTrue(server.requests.isEmpty)
  }

  func testTheTokenIsSentOnlyOverHTTPSOrToTheLoopbackTestServer() throws {
    XCTAssertEqual(ChatGPTResponsesConfiguration.production.url.absoluteString, "https://api.openai.com/v1/responses")
    XCTAssertTrue(ChatGPTResponsesConfiguration.production.permitted)
    let plain = ChatGPTResponsesConfiguration(url: URL(string: "http://example.invalid/v1/responses")!, timeout: 5, permitsLoopbackHTTP: true)
    let caller = ChatGPTSummaryCaller(tokens: tokens, attemptLog: log, configuration: plain)
    XCTAssertThrowsError(try caller.call("Invented prompt.")) { expect($0, .localPreparation) }
    let production = ChatGPTSummaryCaller(tokens: tokens, attemptLog: log,
      configuration: ChatGPTResponsesConfiguration(url: server.url, timeout: 5, permitsLoopbackHTTP: false))
    XCTAssertThrowsError(try production.call("Invented prompt.")) { expect($0, .localPreparation) }
    XCTAssertTrue(server.requests.isEmpty)
  }

  func testLeftoverPromptFilesFromTheCLIPathAreRemoved() throws {
    let prompts = root.appendingPathComponent("summary-prompts")
    try FileManager.default.createDirectory(at: prompts, withIntermediateDirectories: true)
    let stale = prompts.appendingPathComponent("prompt-invented"), work = root.appendingPathComponent("summary-work-invented")
    try Data("Invented evidence".utf8).write(to: stale)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let old = Date(timeIntervalSinceNow: -10 * SummaryMaintenance.callTimeoutSeconds)
    for url in [stale, work] { try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path) }
    try ChatGPTSummaryCaller(tokens: tokens, attemptLog: log, configuration: .loopbackTest(url: server.url), legacyPrompts: prompts).beginPass()
    XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path)); XCTAssertFalse(FileManager.default.fileExists(atPath: work.path))
  }

  // MARK: The summary service

  func testBilledIncompleteStreamsRetryAndPreserveFailedAttemptUsage() throws {
    let memory = SummaryMemory()
    memory.rows = (0..<600).map { TimeSample(ts: $0, app: "Invented", keys: 1, keepingAwake: true) }
    let reply = FakeResponsesServer.Reply(body: Self.events("invalid", terminal: "response.incomplete", usage: Self.usage))
    server.replies = [reply, reply]
    let service = SummaryService(storage: memory, caller: caller(), format: SummaryFormat(timeZone: TimeZone(secondsFromGMT: 0)!))

    try service.summarize(from: 0, through: 10000, dayStart: 0, locale: "en-US")

    XCTAssertEqual(server.requests.count, 2)
    XCTAssertEqual(service.health.calls, 2)
    XCTAssertEqual(service.health.transportFailures, 2)
    XCTAssertEqual(service.health.unbilledExecFailures, 0)
    XCTAssertEqual(service.health.firstAttemptShapeFailures, 0)
    XCTAssertTrue(service.health.shapeFailures.isEmpty)
    XCTAssertEqual(service.health.failedRanges, [TimeRange(0, 900)])
    XCTAssertEqual(memory.calls.map(\.range), [TimeRange(0, 900), TimeRange(0, 900)])
    XCTAssertEqual(memory.calls.map(\.succeeded), [false, false])
    XCTAssertEqual(memory.calls.map(\.inputTokens), [120, 120])
    XCTAssertEqual(memory.calls.map(\.cachedTokens), [20, 20])
    XCTAssertEqual(memory.calls.map(\.outputTokens), [30, 30])
    XCTAssertTrue(memory.named.isEmpty)
  }

  func testUnbilledFailuresLeaveMinutesRetryableAndRecover() throws {
    let memory = SummaryMemory()
    memory.rows = (0..<600).map { TimeSample(ts: $0, app: "Invented", keys: 1, keepingAwake: true) }
    let service = SummaryService(storage: memory, caller: caller(), format: SummaryFormat(timeZone: TimeZone(secondsFromGMT: 0)!))
    for pass in 1...2 {
      server.replies = [Self.refusal(500, code: "server_error")]
      try service.summarize(from: 0, through: 10000, dayStart: 0, locale: "en-US")
      XCTAssertTrue(memory.calls.isEmpty); XCTAssertTrue(memory.named.isEmpty)
      XCTAssertTrue(service.health.failedRanges.isEmpty); XCTAssertTrue(service.health.subscriptionConnected)
      XCTAssertEqual(service.health.unbilledExecFailures, pass)
      XCTAssertEqual(server.requests.count, pass)
      XCTAssertFalse(try service.plan(from: 0, through: 10000).pieces.isEmpty)
    }
    server.replies = [.init(body: Self.events("00:00\t00:10\twork\tInvented\tInvented", usage: Self.usage))]
    try service.summarize(from: 0, through: 10000, dayStart: 0, locale: "en-US")
    XCTAssertEqual(memory.calls.map(\.succeeded), [true]); XCTAssertEqual(memory.named.count, 1)
  }

  func testThreeUnbilledPassesFailFirstPieceAndReleaseSecond() throws {
    let memory = SummaryMemory()
    memory.rows = (0..<7200).map { TimeSample(ts: $0, app: "Invented", keepingAwake: true) }
    let service = SummaryService(storage: memory, caller: caller(), format: SummaryFormat(timeZone: TimeZone(secondsFromGMT: 0)!))
    for pass in 1...3 {
      server.replies = [Self.refusal(500, code: "server_error")]
      if pass == 3 {
        server.replies.append(.init(body: Self.events("01:00\t02:00\twork\tInvented\tInvented", usage: Self.usage)))
      }
      try service.summarize(from: 0, through: 10000, dayStart: 0, locale: "en-US", at: 10000 + pass)
      XCTAssertEqual(service.health.unbilledExecFailures, pass)
      if pass < 3 { XCTAssertTrue(memory.calls.isEmpty) }
    }
    XCTAssertEqual(service.health.failedRanges, [TimeRange(0, 3600)])
    XCTAssertEqual(memory.calls.filter { !$0.succeeded }.count, 2)
    XCTAssertTrue(memory.calls.contains { $0.range == TimeRange(3600, 7200) && $0.succeeded })
    XCTAssertTrue(memory.named.contains { $0.range == TimeRange(3600, 7200) })
  }

  func testAttemptPreparationFailureHasSeparateHealth() throws {
    final class PreparationFailure: SummaryCaller {
      func call(_ prompt: String) throws -> SummaryAnswer { throw SummaryError.localPreparation }
    }
    let memory = SummaryMemory()
    memory.rows = (0..<600).map { TimeSample(ts: $0, app: "Invented", keys: 1) }
    let service = SummaryService(storage: memory, caller: PreparationFailure())
    try service.summarize(from: 0, through: 10000, dayStart: 0, locale: "en-US")
    XCTAssertTrue(service.health.localPreparationFailed); XCTAssertTrue(service.health.subscriptionConnected)
    XCTAssertTrue(memory.calls.isEmpty); XCTAssertTrue(service.health.failedRanges.isEmpty)
  }

  func testPausedPlanLeavesTheRangeForLaterAndRecordsNoAttempt() throws {
    let memory = SummaryMemory()
    memory.rows = (0..<600).map { TimeSample(ts: $0, app: "Invented", keys: 1, keepingAwake: true) }
    let service = SummaryService(storage: memory, caller: caller())
    server.replies = [Self.refusal(429, code: "subscription_sharing_usage_limit_exceeded")]
    try service.summarize(from: 0, through: 10000, dayStart: 0, locale: "en-US")
    XCTAssertTrue(service.health.planUsePaused); XCTAssertTrue(memory.calls.isEmpty)
    XCTAssertTrue(service.health.failedRanges.isEmpty)
    XCTAssertFalse(try service.plan(from: 0, through: 10000).pieces.isEmpty)
    // While paused the port refuses, so the next pass sends nothing.
    tokens.current = .failure(.usageLimited)
    try service.summarize(from: 0, through: 10000, dayStart: 0, locale: "en-US")
    XCTAssertEqual(server.requests.count, 1); XCTAssertTrue(service.health.planUsePaused)
    // After the pause the same minutes are sent again, with the shape retry, and both attempts are accounted.
    tokens.current = .success("invented-access-1")
    server.replies = [.init(body: Self.events("invalid", usage: Self.usage)), .init(body: Self.events("invalid", usage: Self.usage))]
    try service.summarize(from: 0, through: 10000, dayStart: 0, locale: "en-US")
    XCTAssertFalse(service.health.planUsePaused); XCTAssertEqual(server.requests.count, 3)
    XCTAssertEqual(memory.calls.map(\.inputTokens), [120, 120]); XCTAssertEqual(memory.calls.map(\.outputTokens), [30, 30])
    XCTAssertEqual(memory.calls.map(\.model), ["gpt-5.6-luna", "gpt-5.6-luna"])
  }

  func testBilledAttemptBeforeAPauseIsAccountedWithoutFailingTheRange() throws {
    let memory = SummaryMemory()
    memory.rows = (0..<600).map { TimeSample(ts: $0, app: "Invented", keys: 1, keepingAwake: true) }
    let service = SummaryService(storage: memory, caller: caller(), format: SummaryFormat(timeZone: TimeZone(identifier: "UTC")!))
    // The first attempt is billed but its answer has the wrong shape; the retry meets a usage limit.
    server.replies = [.init(body: Self.events("invalid", usage: Self.usage)), Self.refusal(429, code: "subscription_sharing_usage_limit_exceeded")]
    try service.summarize(from: 0, through: 10000, dayStart: 0, locale: "en-US")
    XCTAssertTrue(service.health.planUsePaused); XCTAssertEqual(server.requests.count, 2)
    // Accounting is durable immediately, with no terminal scheduling or failure state.
    XCTAssertEqual(memory.calls.map(\.inputTokens), [120]); XCTAssertTrue(memory.calls.allSatisfy(\.pending)); XCTAssertTrue(service.health.failedRanges.isEmpty)
    XCTAssertFalse(try service.plan(from: 0, through: 10000).pieces.isEmpty)
    // A stream billed before its own usage limit is kept the same way.
    server.replies = [.init(body: Self.events("", terminal: "response.failed", usage: ["input_tokens": 50, "output_tokens": 5],
      error: ["code": "subscription_sharing_usage_limit_exceeded"]))]
    try service.summarize(from: 0, through: 10000, dayStart: 0, locale: "en-US")
    XCTAssertEqual(memory.calls.map(\.inputTokens), [120, 50]); XCTAssertEqual(server.requests.count, 3)
    // The piece's next outcome writes the billed attempts first, then its own.
    let answer = "00:00\t00:01\twork\tInvented task\tInvented description"
    server.replies = [.init(body: Self.events(answer, usage: Self.usage))]
    try service.summarize(from: 0, through: 10000, dayStart: 0, locale: "en-US")
    XCTAssertFalse(service.health.planUsePaused)
    XCTAssertEqual(memory.calls.map(\.inputTokens), [120, 50, 120]); XCTAssertEqual(memory.calls.map(\.outputTokens), [30, 5, 30])
    XCTAssertEqual(memory.calls.map(\.succeeded), [false, false, true])
    XCTAssertTrue(SummaryHealth.unresolvedFailedRanges(in: memory.calls).isEmpty)
    XCTAssertTrue(try service.plan(from: 0, through: 10000).pieces.isEmpty)
  }

  func testBilledAttemptBeforeALostConnectionOrAnUnbilledRetryIsKept() throws {
    let memory = SummaryMemory()
    memory.rows = (0..<600).map { TimeSample(ts: $0, app: "Invented", keys: 1, keepingAwake: true) }
    let service = SummaryService(storage: memory, caller: caller())
    // Billed shape failure, then a server failure that bills nothing: the next pass tries again.
    server.replies = [.init(body: Self.events("invalid", usage: Self.usage)), Self.refusal(502, code: nil)]
    try service.summarize(from: 0, through: 10000, dayStart: 0, locale: "en-US")
    XCTAssertEqual(memory.calls.map(\.inputTokens), [120])
    // Then a lost sign-in on the first attempt of the next pass.
    tokens.current = .failure(.signInAgain)
    try service.summarize(from: 0, through: 10000, dayStart: 0, locale: "en-US")
    XCTAssertEqual(memory.calls.map(\.inputTokens), [120]); XCTAssertFalse(service.health.subscriptionConnected)
    tokens.current = .success("invented-access-1")
    server.replies = [.init(body: Self.events("invalid", usage: Self.usage)), .init(body: Self.events("invalid", usage: Self.usage))]
    try service.summarize(from: 0, through: 10000, dayStart: 0, locale: "en-US")
    // Two failed attempts in this pass end the piece; the billed one from before is written with them.
    XCTAssertEqual(memory.calls.map(\.inputTokens), [120, 120, 120]); XCTAssertEqual(memory.calls.map(\.succeeded), [false, false, false])
    XCTAssertFalse(SummaryHealth.unresolvedFailedRanges(in: memory.calls).isEmpty)
  }
}

extension ChatGPTSummaryCallerTests {
  func testOnlyNamedInvariant400ErrorsRefuseTheBuild() throws {
    let cases: [(Int, String?, String?, Bool, SummaryError)] = [
      (400, "unsupported_model", nil, true, .paused),
      (400, "model_not_found", nil, true, .paused),
      (400, "subscription_sharing_unsupported_capability", "model", true, .paused),
      (400, "subscription_sharing_unsupported_capability", "input[0].role", true, .paused),
      (400, "invalid_parameter", "reasoning.effort", true, .paused),
      (400, "invalid_value", "stream", true, .paused),
      (400, "unsupported_value", "store", true, .paused),
      (400, "invalid_request_error", "input", true, .paused),
      (400, nil, "model", true, .paused),
      (400, "context_length_exceeded", "input", false, .paused),
      (400, "invalid_prompt", "input[0].content", false, .paused),
      (400, nil, "input", false, .paused),
      (400, nil, nil, false, .paused),
      (400, "invalid_request_error", nil, false, .paused),
      (400, "subscription_sharing_unsupported_capability", "service_tier", false, .paused),
      (400, "invented_error", "model", true, .paused),
      (404, "model_not_found", "model", false, .paused),
      (422, "invalid_parameter", "input", false, .paused),
      (408, nil, nil, false, .unbilledExecFailure),
      (409, nil, nil, false, .unbilledExecFailure),
      (425, nil, nil, false, .unbilledExecFailure),
    ]
    for (status, code, param, sticky, expected) in cases {
      let caller = caller(), refused = tokens.requestRefused, accepted = tokens.notAccepted
      server.replies = [Self.refusal(status, code: code, param: param), .init(body: Self.events("", usage: Self.usage))]
      XCTAssertThrowsError(try caller.call("Invented prompt")) { expect($0, expected) }
      XCTAssertEqual(tokens.requestRefused - refused, sticky ? 1 : 0)
      XCTAssertEqual(tokens.notAccepted - accepted, !sticky && ![408, 409, 425].contains(status) ? 1 : 0)
      now += 1800
      _ = try caller.call("Another invented prompt")
    }
  }

  func testUsageStreamAndSecond401ResetUnavailableBackoff() throws {
    for usageStream in [true, false] {
      let caller = caller()
      server.replies = [Self.refusal(503, code: nil)]
      XCTAssertThrowsError(try caller.call("Invented prompt"))
      XCTAssertNotNil(caller.serviceUnavailableUntil)
      now += 300
      server.replies = usageStream
        ? [.init(body: Self.events("", terminal: "response.failed", error: ["code": "subscription_sharing_usage_limit_exceeded"]))]
        : [Self.refusal(401, code: nil), Self.refusal(401, code: nil)]
      XCTAssertThrowsError(try caller.call("Invented prompt")) { expect($0, .paused) }
      XCTAssertNil(caller.serviceUnavailableUntil)
      server.replies = [Self.refusal(503, code: nil)]
      XCTAssertThrowsError(try caller.call("Invented prompt"))
      XCTAssertEqual(caller.serviceUnavailableUntil, now + 300)
      now += 300
      server.replies = [.init(body: Self.events("", usage: Self.usage))]
      _ = try caller.call("Invented prompt")
    }
  }
}


extension ChatGPTSummaryCallerTests {
  func testDiagnosticWriteFailureDoesNotEraseBilledUsage() throws {
    // A directory where the log file belongs forces a local write error after the billed response.
    try FileManager.default.createDirectory(at: log, withIntermediateDirectories: true)
    let memory = SummaryMemory()
    memory.rows = (0..<600).map { TimeSample(ts: $0, keys: 1) }
    let service = SummaryService(storage: memory, caller: caller())
    server.replies = [.init(body: Self.events("", usage: Self.usage))]
    try service.summarize(from: 0, through: 600, dayStart: 0, locale: "en", requested: true)
    XCTAssertEqual(memory.calls.map(\.inputTokens), [120])
    XCTAssertEqual(memory.calls.map(\.succeeded), [true])
    XCTAssertEqual(server.requests.count, 1)
  }
}
