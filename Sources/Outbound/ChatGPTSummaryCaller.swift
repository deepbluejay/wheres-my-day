import Core
import Darwin
import Foundation
import MachO

/// The running build's summary request: model, effort and the build's own identifier. A request refused
/// as such (a 400) stays refused for this fingerprint only, so a different build tries again.
public enum ChatGPTRequestShape {
  public static let current = "\(SummaryPolicy.model)|\(ChatGPTSummaryCaller.effort)|\(buildID)"
  /// The main executable's LC_UUID, which the linker sets anew for each build.
  static var buildID: String {
    guard let header = _dyld_get_image_header(0) else { return "unknown" }
    var command = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
    for _ in 0..<header.pointee.ncmds {
      let load = command.load(as: load_command.self)
      if load.cmd == LC_UUID { return UUID(uuid: command.load(as: uuid_command.self).uuid).uuidString }
      command = command.advanced(by: Int(load.cmdsize))
    }
    return "unknown"
  }
}

/// The Responses endpoint for ChatGPT plan usage (docs: Models and inference).
public struct ChatGPTResponsesConfiguration {
  public let url: URL
  /// The whole request, from sending to the end of the stream.
  public let timeout: TimeInterval
  /// Only test servers on 127.0.0.1 may use plain HTTP; the token is otherwise sent only over HTTPS.
  let permitsLoopbackHTTP: Bool
  public static let production = ChatGPTResponsesConfiguration(url: URL(string: "https://api.openai.com/v1/responses")!,
    timeout: 600, permitsLoopbackHTTP: false)
  /// For tests against an invented local server only.
  public static func loopbackTest(url: URL, timeout: TimeInterval = 10) -> ChatGPTResponsesConfiguration {
    ChatGPTResponsesConfiguration(url: url, timeout: timeout, permitsLoopbackHTTP: true)
  }
  var permitted: Bool {
    if url.scheme == "https", url.host?.isEmpty == false { return true }
    return permitsLoopbackHTTP && url.scheme == "http" && url.host == "127.0.0.1"
  }
}

/// What a streamed request returned. The body is the event stream or an error object, never logged.
public struct ChatGPTStreamedResponse {
  public let status: Int
  public let requestID: String?
  public let body: Data
  public init(status: Int, requestID: String?, body: Data) { self.status = status; self.requestID = requestID; self.body = body }
}
public enum ChatGPTStreamError: Error { case network, deadline, tooLarge }

/// Sends one request and reads its response through to the end of the stream, within a deadline and a size cap.
public protocol ChatGPTStreamingHTTP: AnyObject {
  func stream(_ request: URLRequest, deadline: TimeInterval, limit: Int) throws -> ChatGPTStreamedResponse
}

/// One instance per request. Ephemeral, no cache, cookies or credential storage, and no redirects,
/// so the bearer token is never sent to another endpoint.
public final class URLSessionChatGPTStreamingHTTP: NSObject, ChatGPTStreamingHTTP, URLSessionDataDelegate {
  private let lock = NSLock()
  private let done = DispatchSemaphore(value: 0)
  private var body = Data()
  private var status: Int?
  private var requestID: String?
  private var failed = false
  private var overLimit = false
  private var limit = 0
  public override init() { super.init() }
  public func stream(_ request: URLRequest, deadline: TimeInterval, limit: Int) throws -> ChatGPTStreamedResponse {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
    configuration.urlCredentialStorage = nil; configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    configuration.timeoutIntervalForResource = max(1, deadline)
    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    lock.lock(); self.limit = limit; lock.unlock()
    let task = session.dataTask(with: request)
    task.resume()
    guard done.wait(timeout: .now() + max(0, deadline)) == .success else { task.cancel(); throw ChatGPTStreamError.deadline }
    lock.lock(); defer { lock.unlock() }
    if overLimit { throw ChatGPTStreamError.tooLarge }
    guard !failed, let status else { throw ChatGPTStreamError.network }
    return ChatGPTStreamedResponse(status: status, requestID: requestID, body: body)
  }
  public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
    if let response = response as? HTTPURLResponse {
      lock.lock(); status = response.statusCode; requestID = response.value(forHTTPHeaderField: "x-request-id"); lock.unlock()
    }
    completionHandler(.allow)
  }
  public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    lock.lock()
    if body.count + data.count > limit { overLimit = true; lock.unlock(); dataTask.cancel(); return }
    body.append(data); lock.unlock()
  }
  public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    lock.lock(); if error != nil { failed = true }; lock.unlock()
    done.signal()
  }
  public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// Summaries on the person's ChatGPT plan: one streamed Responses request per call, with the access
/// token from the token port. The token stays in this process: it is sent only in the Authorization
/// header and never reaches arguments, logs, files or the database. No prompt file is written.
public final class ChatGPTSummaryCaller: SummaryCaller {
  /// The whole body of one response is capped like the earlier CLI output.
  public static let responseLimit = 64 * 1024 * 1024
  /// Chosen, not measured: the request carries only the message framing around the prompt.
  public static let fixedEnvelopeTokens = 64
  public static let inputMarginTokens = SummaryMaintenance.inputMarginTokens
  public static let effort = "low"
  /// After ChatGPT reports usage or user information unavailable (503), requests wait this long, doubling
  /// for each further one up to `unavailableLongest`. Chosen values; the docs ask only for bounded backoff.
  public static let unavailableShortest: TimeInterval = 300
  public static let unavailableLongest: TimeInterval = 1800
  static let unavailableCodes: Set<String> = ["subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable"]
  private let tokens: ChatGPTAccessTokens
  private let configuration: ChatGPTResponsesConfiguration
  private let makeHTTP: () -> ChatGPTStreamingHTTP
  private let attemptLog: URL
  private let legacyPrompts: URL?
  private let clock: () -> TimeInterval
  /// The backoff after unavailable answers. Kept in memory: it is short, and the recorder is one long process.
  private var unavailableUntil: TimeInterval?
  public var serviceUnavailableUntil: TimeInterval? {
    unavailableUntil.flatMap { clock() < $0 ? $0 : nil }
  }
  private var unavailableStreak = 0
  public init(tokens: ChatGPTAccessTokens, attemptLog: URL, configuration: ChatGPTResponsesConfiguration = .production,
    legacyPrompts: URL? = nil, makeHTTP: @escaping () -> ChatGPTStreamingHTTP = { URLSessionChatGPTStreamingHTTP() },
    clock: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 }) {
    self.tokens = tokens; self.attemptLog = attemptLog; self.configuration = configuration
    self.legacyPrompts = legacyPrompts; self.makeHTTP = makeHTTP; self.clock = clock
  }

  /// The request body: only fields the preview accepts (docs: Preview limitations). No tools.
  public static func body(prompt: String) throws -> Data {
    let object: [String: Any] = ["model": SummaryPolicy.model, "input": [["role": "user", "content": prompt]],
      "reasoning": ["effort": effort], "store": false, "stream": true]
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }

  /// One stream's result. Only types and counts reach the attempt log.
  struct Stream {
    var answer = SummaryAnswer(text: "invalid")
    var completed = false
    var failureCode: String?
    var events: [String: Int] = [:]
    var items: [String: Int] = [:]
  }
  static let eventTypes: Set<String> = ["response.created", "response.in_progress", "response.output_item.added",
    "response.output_item.done", "response.content_part.added", "response.content_part.done",
    "response.output_text.delta", "response.output_text.done", "response.reasoning_summary_text.delta",
    "response.completed", "response.failed", "response.incomplete", "error"]
  static let itemTypes: Set<String> = ["message", "reasoning", "function_call", "web_search_call"]

  /// Reads the event stream through its terminal event. Success only with `response.completed`.
  static func parse(_ data: Data) -> Stream {
    var stream = Stream()
    var deltas = ""
    for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) where line.hasPrefix("data:") {
      let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
      guard let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
        let type = object["type"] as? String else { continue }
      stream.events[eventTypes.contains(type) ? type : "other", default: 0] += 1
      let response = object["response"] as? [String: Any]
      switch type {
      case "response.output_text.delta": deltas += object["delta"] as? String ?? ""
      case "response.output_item.done":
        if let item = object["item"] as? [String: Any], let kind = item["type"] as? String {
          stream.items[itemTypes.contains(kind) ? kind : "other", default: 0] += 1
        }
      case "response.completed":
        stream.completed = true
        stream.answer.text = response.flatMap(outputText) ?? deltas
      case "response.failed", "response.incomplete":
        stream.failureCode = ((response?["error"] as? [String: Any])?["code"] as? String) ?? type
      case "error":
        stream.failureCode = (object["code"] as? String) ?? ((object["error"] as? [String: Any])?["code"] as? String) ?? "error"
      default: break
      }
      if let usage = response?["usage"] as? [String: Any] {
        stream.answer.inputTokens = usage["input_tokens"] as? Int ?? 0
        stream.answer.cachedTokens = (usage["input_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int ?? 0
        stream.answer.outputTokens = usage["output_tokens"] as? Int ?? 0
      }
    }
    if !stream.completed && stream.failureCode == nil { stream.answer.text = "invalid" }
    return stream
  }
  /// The assistant message text of a completed response, joined across its text parts.
  private static func outputText(_ response: [String: Any]) -> String? {
    guard let output = response["output"] as? [[String: Any]] else { return nil }
    let parts = output.filter { $0["type"] as? String == "message" }.flatMap { $0["content"] as? [[String: Any]] ?? [] }
      .filter { $0["type"] as? String == "output_text" }.compactMap { $0["text"] as? String }
    return parts.isEmpty ? nil : parts.joined()
  }
  /// The error code of a refused request: `error.code`, or nothing for an admission body like `{"detail":…}`.
  static func errorCode(_ body: Data) -> String? {
    guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
    return (object["error"] as? [String: Any])?["code"] as? String
  }

  /// Only a named incompatibility with this build's fixed request can disable every future request.
  static func invariantRequestRefusal(_ body: Data) -> Bool {
    guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
      let error = object["error"] as? [String: Any] else { return false }
    let code = error["code"] as? String ?? ""
    if ["unsupported_model", "model_not_found", "unsupported_reasoning_effort"].contains(code) { return true }
    let param = error["param"] as? String ?? ""
    let field = param.split(whereSeparator: { $0 == "." || $0 == "[" }).first.map(String.init) ?? ""
    let requestFields: Set<String> = ["model", "reasoning", "reasoning_effort", "stream", "store", "input"]
    if field == "input" {
      // A context limit or content refusal depends on this prompt, rather than the build's input shape.
      let shapeCodes: Set<String> = ["subscription_sharing_unsupported_capability", "invalid_parameter", "invalid_value",
        "unsupported_parameter", "unsupported_value", "invalid_request_error"]
      return shapeCodes.contains(code) || (code.isEmpty && error["type"] as? String == "invalid_request_error")
    }
    return requestFields.contains(field)
  }

  public func beginPass() throws {
    // Earlier builds wrote prompts and work folders for the CLI; anything a crash left behind goes.
    if let legacyPrompts { Self.sweepLegacy(legacyPrompts) }
    _ = try perform(nil)
  }
  public func call(_ prompt: String) throws -> SummaryAnswer { try perform(prompt) }

  private struct Attempt {
    var status = -1
    var requests = 0
    var requestID: String?
    var stream = Stream()
    var reason: String?
  }

  private func perform(_ prompt: String?) throws -> SummaryAnswer {
    let start = Date().timeIntervalSince1970
    var attempt = Attempt()
    var failure: Error?
    do {
      guard configuration.permitted else { attempt.reason = "local_preparation"; throw SummaryError.localPreparation }
      if let until = unavailableUntil, clock() < until { attempt.reason = "service_unavailable"; throw SummaryError.paused }
      var token = try access(&attempt) { try tokens.currentAccessToken() }
      // Successful preflight is not a model attempt and needs no attempt row.
      guard let prompt else { return SummaryAnswer(text: "invalid") }
      let body = try Self.body(prompt: prompt)
      var response = try send(body, token: token, &attempt)
      if response.status == 401 {
        resetUnavailable()
        // Renew once, then send the same request once more; a second refusal stops plan requests for a while.
        token = try access(&attempt) { try tokens.reportRejected(token) }
        response = try send(body, token: token, &attempt)
        if response.status == 401 { tokens.reportNotAccepted(token); attempt.reason = "not_accepted"; throw SummaryError.paused }
      }
      try check(response, token: token, &attempt)
      attempt.stream = Self.parse(response.body)
      let code = attempt.stream.failureCode
      if !(code.map(Self.unavailableCodes.contains) ?? false) { resetUnavailable() }
      if code == "subscription_sharing_usage_limit_exceeded" {
        tokens.reportUsageLimited(token); attempt.reason = "usage_limited"; throw pause(attempt.stream.answer)
      }
      if let code, Self.unavailableCodes.contains(code) {
        backOff(); attempt.reason = "service_unavailable"; throw pause(attempt.stream.answer)
      }
      guard attempt.stream.completed else {
        attempt.reason = "stream_failed"
        // A failure before any billed input says nothing about the account; the next pass tries again.
        if attempt.stream.answer.inputTokens == 0 { throw SummaryError.unbilledExecFailure }
        throw SummaryTransportFailure(usage: attempt.stream.answer)
      }
    } catch { failure = error }
    do { try log(start: start, prompt: prompt ?? "", attempt) }
    catch {
      // An unavailable diagnostic file must never erase usage already returned by the model.
      if attempt.stream.answer.inputTokens == 0 && attempt.stream.answer.outputTokens == 0 { throw error }
    }
    if let failure { throw failure }
    return attempt.stream.answer
  }
  /// Maps the token port's refusals to what the summary service does with them.
  private func access(_ attempt: inout Attempt, _ read: () throws -> ChatGPTAccessToken) throws -> ChatGPTAccessToken {
    do { return try read() } catch let error as ChatGPTTokenError {
      switch error {
      case .notSignedIn, .planRequired, .signInAgain: attempt.reason = "not_connected"; throw SummaryError.notConnected
      case .notAvailable: attempt.reason = "not_eligible"; throw SummaryError.notConnected
      case .storage: attempt.reason = "credential_storage"; throw SummaryError.notConnected
      case .usageLimited: attempt.reason = "usage_limited"; throw SummaryError.paused
      case .notAccepted: attempt.reason = "not_accepted"; throw SummaryError.paused
      case .requestRefused: attempt.reason = "request_refused"; throw SummaryError.paused
      // A refresh that could not reach ChatGPT is the same as a network failure of the request.
      case .temporarilyUnavailable: attempt.reason = "network"; throw SummaryError.unbilledExecFailure
      }
    }
  }
  private func send(_ body: Data, token: ChatGPTAccessToken, _ attempt: inout Attempt) throws -> ChatGPTStreamedResponse {
    var request = URLRequest(url: configuration.url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
      timeoutInterval: configuration.timeout)
    request.httpMethod = "POST"
    request.setValue("Bearer " + token.value, forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    request.httpBody = body
    attempt.requests += 1
    do {
      let response = try makeHTTP().stream(request, deadline: configuration.timeout, limit: Self.responseLimit)
      attempt.status = response.status
      attempt.requestID = response.requestID.flatMap { $0.range(of: "^[A-Za-z0-9_.:-]{1,128}$", options: .regularExpression) != nil ? $0 : nil }
      return response
    } catch ChatGPTStreamError.network {
      attempt.reason = "network"; throw SummaryError.unbilledExecFailure
    } catch {
      // A deadline or an oversized stream is a failed attempt, like a CLI that had to be stopped.
      attempt.reason = "transport"; throw SummaryTransportFailure(usage: SummaryAnswer(text: ""))
    }
  }
  /// A paused attempt that was billed still carries its usage, so the service can account for it.
  private func pause(_ usage: SummaryAnswer) -> Error {
    usage.inputTokens > 0 || usage.outputTokens > 0 ? SummaryPausedAfterBilling(usage: usage) : SummaryError.paused
  }
  private func resetUnavailable() { unavailableStreak = 0; unavailableUntil = nil }
  private func backOff() {
    unavailableStreak += 1
    let wait = min(Self.unavailableLongest, Self.unavailableShortest * pow(2, Double(min(unavailableStreak - 1, 8))))
    unavailableUntil = clock() + wait
  }
  /// Errors and recovery: each refusal maps to one action, and none of them retries in a loop.
  /// Every report names the token the refused request carried.
  private func check(_ response: ChatGPTStreamedResponse, token: ChatGPTAccessToken, _ attempt: inout Attempt) throws {
    let code = Self.errorCode(response.body)
    // Any other answer from ChatGPT ends the backoff; a stream (200) is judged after it is read.
    let unavailable = response.status == 503 || ((500...599).contains(response.status) && (code.map(Self.unavailableCodes.contains) ?? false))
    if response.status != 200 && !unavailable {
      resetUnavailable()
    }
    switch response.status {
    case 200: return
    case 403 where code == "subscription_sharing_user_not_eligible":
      tokens.reportNotEligible(token); attempt.reason = "not_eligible"; throw SummaryError.notConnected
    case 429:
      tokens.reportUsageLimited(token); attempt.reason = "usage_limited"; throw SummaryError.paused
    case 500...599 where unavailable:
      // Usage or user information is unavailable for now: credentials stay and requests wait a short,
      // growing while. A pause, so an outage does not use up the minutes' failure passes.
      backOff(); attempt.reason = "service_unavailable"; throw SummaryError.paused
    case 500...599:
      // Routing or the server is down: credentials stay, a later pass retries.
      attempt.reason = "server_unavailable"; throw SummaryError.unbilledExecFailure
    case 403:
      // A refused permission: the account may need to sign in again; requests pause for a while.
      tokens.reportNotAccepted(token); attempt.reason = "not_accepted"; throw SummaryError.paused
    case 408, 409, 425:
      attempt.reason = "server_unavailable"; throw SummaryError.unbilledExecFailure
    case 400 where Self.invariantRequestRefusal(response.body):
      tokens.reportRequestRefused(token); attempt.reason = "request_refused"; throw SummaryError.paused
    case 400...499:
      tokens.reportNotAccepted(token); attempt.reason = "not_accepted"; throw SummaryError.paused
    default:
      // A refused redirect or another answer that is not the API's: pause for a while.
      tokens.reportNotAccepted(token); attempt.reason = "not_accepted"; throw SummaryError.paused
    }
  }
  private func log(start: Double, prompt: String, _ attempt: Attempt) throws {
    let answer = attempt.stream.answer
    let estimate = SummaryMaintenance.estimatedTokens(prompt)
    var record: [String: Any] = ["startedAt": start, "endedAt": Date().timeIntervalSince1970,
      "transport": "responses", "httpStatus": attempt.status, "requests": attempt.requests,
      "events": attempt.stream.events, "items": attempt.stream.items,
      "inputTokens": answer.inputTokens, "cachedTokens": answer.cachedTokens, "outputTokens": answer.outputTokens,
      "promptEstimatedTokens": estimate, "fixedEnvelopeTokens": Self.fixedEnvelopeTokens,
      "marginTokens": Self.inputMarginTokens,
      "excessInput": answer.inputTokens > estimate + Self.fixedEnvelopeTokens + Self.inputMarginTokens]
    if let reason = attempt.reason { record["failureReason"] = reason }
    if let requestID = attempt.requestID { record["requestID"] = requestID }
    var encoded = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
    encoded.append(10)
    let descriptor = Darwin.open(attemptLog.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { throw SummaryError.transport }
    let log = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? log.close() }
    try log.write(contentsOf: encoded)
  }
  static func sweepLegacy(_ prompts: URL, files: FileManager = .default) {
    var isDirectory: ObjCBool = false
    if files.fileExists(atPath: prompts.path, isDirectory: &isDirectory), isDirectory.boolValue {
      try? SummaryMaintenance.sweepStalePromptFiles(in: prompts, timeout: SummaryMaintenance.callTimeoutSeconds)
    }
    try? SummaryMaintenance.sweepStaleWorkFolders(in: prompts.deletingLastPathComponent(), timeout: SummaryMaintenance.callTimeoutSeconds)
  }
}
