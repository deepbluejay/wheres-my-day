import Core
import CryptoKit
import Foundation
import Security

/// Fixed values of the open-source "Sign in with ChatGPT" flow with ChatGPT plan usage.
public struct ChatGPTOAuthConfiguration {
  public static let registrationClientID = "dynamic_agent_client"
  public static let planScope = "chatgpt.tokens.use.direct"
  public static let scopes = ["openid", "profile", "email", "offline_access", "resource.invoke", planScope]
  public static let resource = "https://api.openai.com/v1"
  public static let agentName = AgentWindowIdentity.codexPlanOriginator
  public static let callbackPath = "/auth/callback"
  /// The Codex CLI's own login listens on 1455; this app never takes that port.
  public static let codexLoginPort: UInt16 = 1455
  public static let preferredPort: UInt16 = 1457
  public let issuer: String
  public let authorize: URL
  public let token: URL
  public let discovery: URL
  public let preferredPort: UInt16
  public let signInTimeout: TimeInterval
  public let requestTimeout: TimeInterval
  /// Only test servers on 127.0.0.1 may use plain HTTP; production endpoints are HTTPS.
  let permitsLoopbackHTTP: Bool
  public static let production = ChatGPTOAuthConfiguration(issuer: "https://auth.openai.com",
    authorize: URL(string: "https://auth.openai.com/api/accounts/authorize")!,
    token: URL(string: "https://auth.openai.com/api/accounts/oauth/token")!,
    discovery: URL(string: "https://auth.openai.com/.well-known/openid-configuration")!,
    preferredPort: preferredPort, signInTimeout: 600, requestTimeout: 30, permitsLoopbackHTTP: false)
  init(issuer: String, authorize: URL, token: URL, discovery: URL, preferredPort: UInt16,
    signInTimeout: TimeInterval, requestTimeout: TimeInterval, permitsLoopbackHTTP: Bool) {
    precondition(preferredPort != Self.codexLoginPort, "The Codex CLI login port is reserved")
    self.issuer = issuer; self.authorize = authorize; self.token = token; self.discovery = discovery
    self.preferredPort = preferredPort; self.signInTimeout = signInTimeout; self.requestTimeout = requestTimeout
    self.permitsLoopbackHTTP = permitsLoopbackHTTP
  }
  /// For tests against an invented local server only.
  public static func loopbackTest(server: URL, issuer: String, preferredPort: UInt16 = 0,
    signInTimeout: TimeInterval = 10, requestTimeout: TimeInterval = 5) -> ChatGPTOAuthConfiguration {
    ChatGPTOAuthConfiguration(issuer: issuer, authorize: server.appendingPathComponent("api/accounts/authorize"),
      token: server.appendingPathComponent("api/accounts/oauth/token"),
      discovery: server.appendingPathComponent(".well-known/openid-configuration"),
      preferredPort: preferredPort, signInTimeout: signInTimeout, requestTimeout: requestTimeout, permitsLoopbackHTTP: true)
  }
  func permits(_ url: URL) -> Bool {
    if url.scheme == "https", url.host?.isEmpty == false { return true }
    return permitsLoopbackHTTP && url.scheme == "http" && url.host == "127.0.0.1"
  }
}

/// One attempt's secrets. Fresh for every attempt, never stored, and printed as redacted.
struct ChatGPTAttempt: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
  let state: String
  let nonce: String
  let verifier: String
  var challenge: String { Self.challenge(for: verifier) }
  var description: String { "ChatGPTAttempt(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:]) }
  static func fresh() throws -> ChatGPTAttempt {
    ChatGPTAttempt(state: try random(32), nonce: try random(32), verifier: try random(32))
  }
  /// The base64url SHA-256 of the verifier without padding (PKCE S256).
  static func challenge(for verifier: String) -> String { base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }
  static func random(_ count: Int) throws -> String {
    var bytes = [UInt8](repeating: 0, count: count)
    guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else { throw ChatGPTSignInError.exchangeFailed }
    return base64URL(Data(bytes))
  }
  static func base64URL(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
  static func decodeBase64URL(_ text: String) -> Data? {
    var value = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while value.count % 4 != 0 { value += "=" }
    return Data(base64Encoded: value)
  }
}

enum ChatGPTAuthorizeRequest {
  /// The parameters the docs list, in their order. Hints are sent only for a returning account.
  static func url(configuration: ChatGPTOAuthConfiguration, clientID: String?, hostID: String, redirect: String,
    attempt: ChatGPTAttempt, idTokenHint: String?, reconsent: Bool) -> URL {
    var items: [(String, String)] = [("client_id", clientID ?? ChatGPTOAuthConfiguration.registrationClientID)]
    if clientID == nil { items.append(("agent_name_hint", ChatGPTOAuthConfiguration.agentName)) }
    items.append(("ext_agent_host_id", hostID))
    if clientID != nil, let idTokenHint { items.append(("id_token_hint", idTokenHint)) }
    items += [("response_type", "code"), ("redirect_uri", redirect),
      ("scope", ChatGPTOAuthConfiguration.scopes.joined(separator: " ")), ("resource", ChatGPTOAuthConfiguration.resource),
      ("state", attempt.state), ("nonce", attempt.nonce),
      ("code_challenge_method", "S256"), ("code_challenge", attempt.challenge)]
    // Asking for consent again is only for enabling plan usage after it was not granted.
    if reconsent && clientID != nil { items.append(("prompt", "consent")) }
    return URL(string: configuration.authorize.absoluteString + "?" + ChatGPTForm.encode(items))!
  }
}

enum ChatGPTForm {
  private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
  static func escape(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: unreserved)! }
  static func encode(_ items: [(String, String)]) -> String { items.map { escape($0.0) + "=" + escape($0.1) }.joined(separator: "&") }
  static func decode(_ query: String) -> [String: String] {
    var values: [String: String] = [:]
    for pair in query.split(separator: "&", omittingEmptySubsequences: true) {
      let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      func value(_ part: Substring) -> String? { part.replacingOccurrences(of: "+", with: " ").removingPercentEncoding }
      guard let key = value(parts[0]) else { continue }
      // A repeated parameter is ambiguous; the first value wins and the attempt still validates state.
      if values[key] == nil { values[key] = parts.count > 1 ? value(parts[1]) ?? "" : "" }
    }
    return values
  }
}

/// HTTP for the token, discovery, key and revocation endpoints. Bodies are never logged.
public protocol ChatGPTHTTP: AnyObject {
  func send(_ request: URLRequest) throws -> (status: Int, body: Data)
  func cancel()
}

/// One instance per sign-in, refresh or sign-out, so cancelling an attempt never affects another.
public final class URLSessionChatGPTHTTP: ChatGPTHTTP {
  private let lock = NSLock()
  private var tasks: [URLSessionTask] = []
  private var cancelled = false
  private let session: URLSession
  public init() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
    configuration.urlCredentialStorage = nil; configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
  }
  deinit { session.invalidateAndCancel() }
  public func send(_ request: URLRequest) throws -> (status: Int, body: Data) {
    let done = DispatchSemaphore(value: 0)
    var result: (Int, Data)?
    let task = session.dataTask(with: request) { data, response, _ in
      if let response = response as? HTTPURLResponse { result = (response.statusCode, data ?? Data()) }
      done.signal()
    }
    lock.lock()
    guard !cancelled else { lock.unlock(); throw ChatGPTSignInError.cancelled }
    tasks.append(task); lock.unlock()
    task.resume()
    done.wait()
    lock.lock(); tasks.removeAll { $0 === task }; let wasCancelled = cancelled; lock.unlock()
    if wasCancelled { throw ChatGPTSignInError.cancelled }
    guard let result else { throw ChatGPTSignInError.network }
    return result
  }
  public func cancel() {
    lock.lock(); cancelled = true; let running = tasks; lock.unlock()
    running.forEach { $0.cancel() }
  }
}

/// Credentials never follow a redirect to another endpoint.
private final class NoRedirects: NSObject, URLSessionTaskDelegate {
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

extension ChatGPTHTTP {
  func postForm(_ url: URL, _ items: [(String, String)], timeout: TimeInterval) throws -> (status: Int, body: Data) {
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpBody = Data(ChatGPTForm.encode(items).utf8)
    return try send(request)
  }
  func getJSON(_ url: URL, timeout: TimeInterval) throws -> [String: Any] {
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let (status, body) = try send(request)
    guard status == 200, let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { throw ChatGPTSignInError.network }
    return object
  }
}

/// The token endpoint's answer. The OAuth error code is kept only as a code, never with its description.
struct ChatGPTTokenResponse: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
  let accessToken: String
  let refreshToken: String?
  let idToken: String?
  let tokenType: String
  let expiresIn: Int
  let scopes: [String]?
  let earliestRefreshAt: Int?
  var description: String { "ChatGPTTokenResponse(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:]) }
  var planGranted: Bool { scopes?.contains(ChatGPTOAuthConfiguration.planScope) ?? false }
  static func parse(_ body: Data) -> ChatGPTTokenResponse? {
    guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
      let access = object["access_token"] as? String, !access.isEmpty else { return nil }
    let expires = (object["expires_in"] as? NSNumber)?.intValue ?? 3600
    let scope = (object["scope"] as? String).map { $0.split(separator: " ").map(String.init) }
    return ChatGPTTokenResponse(accessToken: access, refreshToken: (object["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 },
      idToken: object["id_token"] as? String, tokenType: object["token_type"] as? String ?? "Bearer",
      expiresIn: max(0, expires), scopes: scope, earliestRefreshAt: (object["earliest_refresh_at"] as? NSNumber)?.intValue)
  }
  /// Both the OAuth form `{"error":"code"}` and a nested `{"error":{"code":"..."}}` are recognized.
  static func errorCode(_ body: Data) -> String? {
    guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
    if let code = object["error"] as? String { return code }
    if let nested = object["error"] as? [String: Any] { return nested["code"] as? String ?? nested["type"] as? String }
    return object["code"] as? String
  }
}
