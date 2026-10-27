import Core
import CryptoKit
import Darwin
import Foundation
@testable import Outbound
@testable import Shell
import Storage
import XCTest

/// Invented server, browser, keys and accounts only. No OpenAI endpoint, real browser or Keychain is reached.
final class ChatGPTSignInTests: XCTestCase {
  var root: URL!
  var server: FakeOAuthServer!
  var signer: FakeSigner!
  var browser: FakeBrowser!
  var store: InMemoryChatGPTCredentialStore!
  var backoffs: [Int] = []
  override func setUpWithError() throws {
    root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ACTIVITYPROBE_TEST_ROOT"] ?? NSTemporaryDirectory())
      .appendingPathComponent("chatgpt-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    server = try FakeOAuthServer(); signer = FakeSigner(); server.keys = [signer.jwk]
    browser = FakeBrowser(); store = InMemoryChatGPTCredentialStore(); backoffs = []
  }
  override func tearDownWithError() throws { server.stop(); try? FileManager.default.removeItem(at: root) }

  func configuration(timeout: TimeInterval = 10, port: UInt16 = 0) -> ChatGPTOAuthConfiguration {
    .loopbackTest(server: server.url, issuer: server.issuer, preferredPort: port, signInTimeout: timeout)
  }
  func session(_ configuration: ChatGPTOAuthConfiguration? = nil, store: ChatGPTCredentialStore? = nil,
    clock: @escaping () -> Int = { FakeAccount.now }, requestShape: String = "invented-build-1") -> ChatGPTSession {
    ChatGPTSession(configuration: configuration ?? self.configuration(), store: store ?? self.store,
      lock: ChatGPTCredentialLock(file: root.appendingPathComponent("chatgpt.lock")),
      openBrowser: browser.open, clock: clock, backoff: { [weak self] in self?.backoffs.append($0) },
      callbackPage: { "invented-page" }, requestShape: requestShape)
  }
  /// The access token saved now, as a refused request would have carried it.
  func savedToken() throws -> ChatGPTAccessToken {
    ChatGPTAccessToken(try XCTUnwrap(try store.load()?.tokens?.accessToken), validUntil: Int.max)
  }
  /// The browser approves: code, the attempt's own state, and the issued client on a new registration.
  func approve(clientID: String? = FakeAccount.clientID, state: String? = nil, extra: [(String, String)] = []) {
    browser.answer = { query in
      var items = [("code", "invented-code"), ("state", state ?? query["state"]!), ("scope", FakeAccount.allScopes)]
      if let clientID { items.append(("client_id", clientID)) }
      return items + extra
    }
  }
  /// The token endpoint answers a code exchange with an ID token signed for the authorize request's nonce.
  func issueTokens(scope: String = FakeAccount.allScopes, claims: ((String) -> [String: Any])? = nil, alg: String = "RS256",
    signer: FakeSigner? = nil, access: String = "invented-access-1", refresh: String = "invented-refresh-1") {
    let browser = self.browser!, issuer = server.issuer, signer = signer ?? self.signer!
    server.token = { form in
      guard form["grant_type"] == "authorization_code" else { return (400, ["error": "unsupported_grant_type"]) }
      let nonce = browser.lastOpened["nonce"] ?? ""
      let id = signer.token(claims?(nonce) ?? FakeAccount.claims(issuer: issuer, nonce: nonce), alg: alg)
      return (200, ["access_token": access, "refresh_token": refresh, "id_token": id, "token_type": "Bearer",
        "expires_in": 3600, "scope": scope])
    }
  }
  func signedIn() throws -> ChatGPTSession {
    approve(); issueTokens()
    let session = session()
    try session.connect()
    return session
  }
  func assertNothingStored(file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertNil(((try? store.load()) ?? nil)?.tokens, file: file, line: line)
  }

  // MARK: Registration and exchange

  func testFirstSignInRegistersDynamicallyAndExchangesWithPKCE() throws {
    approve(); issueTokens()
    let session = session()
    try session.connect()
    let authorize = browser.lastOpened
    XCTAssertEqual(browser.opened.first?.path, "/api/accounts/authorize")
    XCTAssertEqual(authorize["client_id"], "dynamic_agent_client")
    XCTAssertEqual(authorize["agent_name_hint"], "ActivityProbe")
    XCTAssertEqual(authorize["response_type"], "code")
    XCTAssertEqual(authorize["scope"], "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct")
    XCTAssertEqual(authorize["resource"], "https://api.openai.com/v1")
    XCTAssertEqual(authorize["code_challenge_method"], "S256")
    XCTAssertNil(authorize["id_token_hint"]); XCTAssertNil(authorize["login_hint"]); XCTAssertNil(authorize["prompt"])
    let host = try XCTUnwrap(authorize["ext_agent_host_id"])
    XCTAssertTrue(host.hasPrefix("urn:uuid:")); XCTAssertNotNil(UUID(uuidString: String(host.dropFirst(9))))
    XCTAssertFalse(host.contains("example.invalid") || host.contains(FakeAccount.subject))
    let redirect = try XCTUnwrap(authorize["redirect_uri"])
    XCTAssertTrue(redirect.hasPrefix("http://127.0.0.1:")); XCTAssertTrue(redirect.hasSuffix("/auth/callback"))
    XCTAssertFalse(redirect.contains("localhost"))
    let exchange = try XCTUnwrap(server.requests("/api/accounts/oauth/token").first?.form)
    XCTAssertEqual(exchange["grant_type"], "authorization_code")
    XCTAssertEqual(exchange["client_id"], FakeAccount.clientID)
    XCTAssertEqual(exchange["code"], "invented-code")
    XCTAssertEqual(exchange["redirect_uri"], redirect)
    XCTAssertEqual(exchange["resource"], "https://api.openai.com/v1")
    XCTAssertNil(exchange["client_secret"])
    let verifier = try XCTUnwrap(exchange["code_verifier"])
    XCTAssertGreaterThanOrEqual(verifier.count, 43)
    XCTAssertEqual(authorize["code_challenge"], ChatGPTAttempt.base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))))
    XCTAssertFalse(authorize["code_challenge"]!.contains("="))
    let record = try XCTUnwrap(try store.load())
    XCTAssertEqual(record.registration, ChatGPTRegistration(clientID: FakeAccount.clientID, subject: FakeAccount.subject))
    XCTAssertEqual(record.tokens?.accessToken, "invented-access-1")
    XCTAssertEqual(record.tokens?.refreshToken, "invented-refresh-1")
    XCTAssertEqual(record.tokens?.expiresAt, FakeAccount.now + 3600)
    XCTAssertEqual(Set(record.tokens?.scopes ?? []), Set(ChatGPTOAuthConfiguration.scopes))
    XCTAssertEqual(session.status(), .connected)
    XCTAssertEqual(try session.currentAccessToken().value, "invented-access-1")
    XCTAssertEqual(try store.hostID(), host)
  }

  func testReturningSignInReusesClientAndHostWithFreshAttemptValues() throws {
    let session = try signedIn()
    let first = browser.lastOpened
    approve(clientID: nil); issueTokens(access: "invented-access-2", refresh: "invented-refresh-2")
    try session.connect()
    let second = browser.lastOpened
    XCTAssertEqual(second["client_id"], FakeAccount.clientID)
    XCTAssertNil(second["agent_name_hint"])
    XCTAssertEqual(second["ext_agent_host_id"], first["ext_agent_host_id"])
    XCTAssertNotNil(second["id_token_hint"])
    for key in ["state", "nonce", "code_challenge"] { XCTAssertNotEqual(first[key], second[key], key) }
    let verifiers = server.requests("/api/accounts/oauth/token").map { $0.form["code_verifier"] }
    XCTAssertEqual(verifiers.count, 2); XCTAssertNotEqual(verifiers[0], verifiers[1])
    XCTAssertEqual(server.requests("/api/accounts/oauth/token").last?.form["client_id"], FakeAccount.clientID)
    XCTAssertEqual(try store.load()?.tokens?.accessToken, "invented-access-2")
  }

  func testCallbacksOfAnotherAttemptAreAnsweredAndIgnoredUntilTheRealOne() throws {
    // Wrong state, no state and a forged error each get 400 and the same neutral page; the attempt goes on.
    browser.decoys = { _ in [[("code", "invented-code"), ("state", "invented-other-state"), ("client_id", "oaiapp_forged")],
      [("code", "invented-code"), ("client_id", "oaiapp_forged")], [("error", "access_denied"), ("state", "invented-other-state")]] }
    approve(); issueTokens()
    try session().connect()
    XCTAssertEqual(browser.replies.map(\.status), [400, 400, 400, 200])
    XCTAssertEqual(Set(browser.replies.map(\.page)), ["invented-page"])
    XCTAssertEqual(server.requests("/api/accounts/oauth/token").count, 1)
    XCTAssertEqual(try store.load()?.registration?.clientID, FakeAccount.clientID)
  }

  func testOnlyMismatchedCallbacksTimeOutWithoutExchange() throws {
    approve(state: "invented-other-state"); issueTokens()
    XCTAssertThrowsError(try session(configuration(timeout: 1)).connect()) { XCTAssertEqual($0 as? ChatGPTSignInError, .timedOut) }
    browser.answer = { _ in [("code", "invented-code"), ("client_id", FakeAccount.clientID)] }
    XCTAssertThrowsError(try session(configuration(timeout: 1)).connect()) { XCTAssertEqual($0 as? ChatGPTSignInError, .timedOut) }
    // A forged error with the wrong state is not a decline either.
    browser.answer = { _ in [("error", "access_denied"), ("state", "invented-other-state")] }
    XCTAssertThrowsError(try session(configuration(timeout: 1)).connect()) { XCTAssertEqual($0 as? ChatGPTSignInError, .timedOut) }
    browser.answer = { [("error", "access_denied"), ("state", $0["state"]!)] }
    XCTAssertThrowsError(try session().connect()) { XCTAssertEqual($0 as? ChatGPTSignInError, .declined) }
    XCTAssertTrue(server.requests("/api/accounts/oauth/token").isEmpty)
    assertNothingStored()
    XCTAssertNil(try store.load()?.registration)
  }

  func testNewRegistrationWithoutIssuedClientIsIncomplete() throws {
    issueTokens()
    for client: String? in [nil, "", "dynamic_agent_client"] {
      approve(clientID: client)
      XCTAssertThrowsError(try session().connect()) { XCTAssertEqual($0 as? ChatGPTSignInError, .registrationIncomplete) }
    }
    XCTAssertTrue(server.requests("/api/accounts/oauth/token").isEmpty)
    XCTAssertNil(try store.load()?.registration)
  }

  func testReturningCallbackWithAnotherClientIsRejected() throws {
    let session = try signedIn()
    approve(clientID: "oaiapp_other")
    XCTAssertThrowsError(try session.connect()) { XCTAssertEqual($0 as? ChatGPTSignInError, .clientMismatch) }
    XCTAssertEqual(server.requests("/api/accounts/oauth/token").count, 1)
    XCTAssertEqual(try store.load()?.registration?.clientID, FakeAccount.clientID)
  }

  func testFailedExchangeKeepsIssuedClientForTheNextAttempt() throws {
    approve()
    server.token = { _ in (400, ["error": "invalid_grant"]) }
    XCTAssertThrowsError(try session().connect()) { XCTAssertEqual($0 as? ChatGPTSignInError, .exchangeFailed) }
    XCTAssertEqual(try store.load()?.registration, ChatGPTRegistration(clientID: FakeAccount.clientID, subject: nil))
    assertNothingStored()
    approve(clientID: nil); issueTokens()
    try session().connect()
    XCTAssertEqual(browser.lastOpened["client_id"], FakeAccount.clientID)
    XCTAssertEqual(session().status(), .connected)
  }

  // MARK: ID token and scope validation

  func testInvalidIDTokensAreRejectedAndNothingIsStored() throws {
    let issuer = server.issuer, now = FakeAccount.now
    let cases: [(String, (String) -> [String: Any])] = [
      ("issuer", { FakeAccount.claims(issuer: "https://other.invalid", nonce: $0) }),
      ("audience", { FakeAccount.claims(issuer: issuer, nonce: $0, audience: "oaiapp_other") }),
      ("audiences without azp", { FakeAccount.claims(issuer: issuer, nonce: $0, audience: [FakeAccount.clientID, "other"]) }),
      ("expired", { FakeAccount.claims(issuer: issuer, nonce: $0, exp: now - 60) }),
      ("future", { FakeAccount.claims(issuer: issuer, nonce: $0, iat: now + 600) }),
      ("nonce", { _ in FakeAccount.claims(issuer: issuer, nonce: "invented-other-nonce") }),
      ("subject", { FakeAccount.claims(issuer: issuer, nonce: $0, subject: "") }),
    ]
    approve()
    for (name, claims) in cases {
      issueTokens(claims: claims)
      XCTAssertThrowsError(try session().connect(), name) { XCTAssertEqual($0 as? ChatGPTSignInError, .invalidIDToken, name) }
      assertNothingStored()
    }
    issueTokens(signer: FakeSigner())  // signed by a key the server does not publish
    XCTAssertThrowsError(try session().connect()) { XCTAssertEqual($0 as? ChatGPTSignInError, .invalidIDToken) }
    issueTokens(alg: "none")
    XCTAssertThrowsError(try session().connect()) { XCTAssertEqual($0 as? ChatGPTSignInError, .invalidIDToken) }
    server.discoveryIssuer = "https://other.invalid"; issueTokens()
    XCTAssertThrowsError(try session().connect()) { XCTAssertEqual($0 as? ChatGPTSignInError, .invalidIDToken) }
    assertNothingStored()
  }

  func testValidIDTokenWithoutPlanScopeKeepsSignInButNoToken() throws {
    approve(); issueTokens(scope: "openid profile email offline_access")
    let session = session()
    XCTAssertThrowsError(try session.connect()) { XCTAssertEqual($0 as? ChatGPTSignInError, .planRequired) }
    XCTAssertEqual(session.status(), .planRequired)
    XCTAssertThrowsError(try session.currentAccessToken()) { XCTAssertEqual($0 as? ChatGPTTokenError, .planRequired) }
    // Enabling it later asks for the complete scope set and consent again with the saved client.
    approve(clientID: nil); issueTokens()
    try session.connect()
    XCTAssertEqual(browser.lastOpened["prompt"], "consent")
    XCTAssertTrue(browser.lastOpened["scope"]!.contains("chatgpt.tokens.use.direct"))
    XCTAssertEqual(session.status(), .connected)
  }

  func testDifferentAccountNeverReplacesTheRegistration() throws {
    let session = try signedIn()
    approve(clientID: nil)
    let issuer = server.issuer
    issueTokens(claims: { FakeAccount.claims(issuer: issuer, nonce: $0, subject: "invented-other-subject") }, access: "invented-access-x")
    XCTAssertThrowsError(try session.connect()) { XCTAssertEqual($0 as? ChatGPTSignInError, .differentAccount) }
    XCTAssertEqual(try store.load()?.tokens?.accessToken, "invented-access-1")
    XCTAssertEqual(try store.load()?.registration?.subject, FakeAccount.subject)
  }

  // MARK: Timeout, cancel, listener

  func testTimeoutAndCancelStopTheAttemptAndFreeThePort() throws {
    let timed = session(configuration(timeout: 0.3))
    XCTAssertThrowsError(try timed.connect()) { XCTAssertEqual($0 as? ChatGPTSignInError, .timedOut) }
    let cancelled = session(configuration(timeout: 30))
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { cancelled.cancel() }
    let started = Date()
    XCTAssertThrowsError(try cancelled.connect()) { XCTAssertEqual($0 as? ChatGPTSignInError, .cancelled) }
    XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    let redirect = try XCTUnwrap(URL(string: browser.lastOpened["redirect_uri"] ?? ""))
    let listener = try ChatGPTLoopbackListener(preferredPort: UInt16(redirect.port!))
    XCTAssertEqual(Int(listener.port), redirect.port)
    browser.opens = false
    XCTAssertThrowsError(try session().connect()) { XCTAssertEqual($0 as? ChatGPTSignInError, .browser) }
    assertNothingStored()
  }

  func testListenerUsesLoopbackAndAvoidsTheCodexLoginPort() throws {
    XCTAssertNotEqual(ChatGPTOAuthConfiguration.production.preferredPort, ChatGPTOAuthConfiguration.codexLoginPort)
    XCTAssertEqual(ChatGPTOAuthConfiguration.production.authorize.absoluteString, "https://auth.openai.com/api/accounts/authorize")
    XCTAssertEqual(ChatGPTOAuthConfiguration.production.token.absoluteString, "https://auth.openai.com/api/accounts/oauth/token")
    let taken = try ChatGPTLoopbackListener(preferredPort: 0)
    let fallback = try ChatGPTLoopbackListener(preferredPort: taken.port)
    XCTAssertNotEqual(fallback.port, taken.port)
    XCTAssertEqual(fallback.redirectURI, "http://127.0.0.1:\(fallback.port)/auth/callback")
    // Other paths get 404 and the wait continues until the callback arrives.
    let other = URLSession(configuration: .ephemeral)
    var answered = false
    DispatchQueue.global().async {
      let done = DispatchSemaphore(value: 0)
      other.dataTask(with: URL(string: "http://127.0.0.1:\(fallback.port)/favicon.ico")!) { _, response, _ in
        answered = (response as? HTTPURLResponse)?.statusCode == 404; done.signal()
      }.resume()
      done.wait()
      other.dataTask(with: URL(string: fallback.redirectURI + "?state=s&code=c")!).resume()
    }
    let query = try fallback.waitForCallback(until: ProcessInfo.processInfo.systemUptime + 5, cancelled: { false }) { _ in (200, "", true) }
    XCTAssertTrue(answered); XCTAssertEqual(query["code"], "c")
  }

  // MARK: Refresh

  func refreshable(expiresAt: Int, scopes: [String] = ChatGPTOAuthConfiguration.scopes) -> ChatGPTCredentialRecord {
    var record = ChatGPTCredentialRecord()
    record.registration = ChatGPTRegistration(clientID: FakeAccount.clientID, subject: FakeAccount.subject)
    record.idToken = "invented-id"
    record.tokens = ChatGPTTokenSet(accessToken: "invented-old-access", refreshToken: "invented-old-refresh",
      tokenType: "Bearer", expiresAt: expiresAt, scopes: scopes, earliestRefreshAt: nil, savedAt: FakeAccount.now - 3000)
    return record
  }

  func testRefreshRotatesTheWholeTokenSetOnce() throws {
    try store.save(refreshable(expiresAt: FakeAccount.now + 60))
    server.token = { form in
      guard form["grant_type"] == "refresh_token" else { return (400, ["error": "invalid_request"]) }
      return (200, ["access_token": "invented-new-access", "refresh_token": "invented-new-refresh", "token_type": "Bearer",
        "expires_in": 3600, "scope": FakeAccount.allScopes])
    }
    let session = session()
    XCTAssertEqual(try session.currentAccessToken().value, "invented-new-access")
    let form = try XCTUnwrap(server.requests("/api/accounts/oauth/token").first?.form)
    XCTAssertEqual(form, ["grant_type": "refresh_token", "client_id": FakeAccount.clientID,
      "refresh_token": "invented-old-refresh", "resource": "https://api.openai.com/v1"])
    let tokens = try XCTUnwrap(try store.load()?.tokens)
    XCTAssertEqual(tokens.accessToken, "invented-new-access"); XCTAssertEqual(tokens.refreshToken, "invented-new-refresh")
    XCTAssertEqual(tokens.expiresAt, FakeAccount.now + 3600); XCTAssertEqual(try store.load()?.idToken, "invented-id")
    XCTAssertEqual(try session.currentAccessToken(), ChatGPTAccessToken("invented-new-access", validUntil: FakeAccount.now + 3600))
    XCTAssertEqual(server.requests("/api/accounts/oauth/token").count, 1)
  }

  func testConcurrentRefreshesFromTwoSessionsSendOneRequest() throws {
    try store.save(refreshable(expiresAt: FakeAccount.now + 60))
    var rotation = 0
    server.token = { _ in
      rotation += 1
      Thread.sleep(forTimeInterval: 0.2)
      return (200, ["access_token": "invented-access-r\(rotation)", "refresh_token": "invented-refresh-r\(rotation)",
        "expires_in": 3600, "scope": FakeAccount.allScopes])
    }
    let sessions = [session(), session()]
    var values = [String?](repeating: nil, count: 2)
    DispatchQueue.concurrentPerform(iterations: 2) { index in values[index] = try? sessions[index].currentAccessToken().value }
    XCTAssertEqual(values, ["invented-access-r1", "invented-access-r1"])
    XCTAssertEqual(server.requests("/api/accounts/oauth/token").count, 1)
  }

  func testRefreshErrorsClearOnlyWhenTheTokenIsUnusable() throws {
    let session = session()
    for code in ["invalid_grant", "refresh_token_reused", "refresh_token_expired"] {
      try store.save(refreshable(expiresAt: FakeAccount.now - 1))
      server.token = { _ in (400, ["error": code]) }
      XCTAssertThrowsError(try session.currentAccessToken()) { XCTAssertEqual($0 as? ChatGPTTokenError, .signInAgain, code) }
      XCTAssertNil(try store.load()?.tokens)
      XCTAssertEqual(try store.load()?.registration?.clientID, FakeAccount.clientID)
      XCTAssertEqual(try store.load()?.idToken, "invented-id")
      XCTAssertEqual(session.status(), .signInAgain)
    }
    try store.save(refreshable(expiresAt: FakeAccount.now - 1))
    server.token = { _ in (503, ["error": "temporarily_unavailable"]) }
    XCTAssertThrowsError(try session.currentAccessToken()) { XCTAssertEqual($0 as? ChatGPTTokenError, .temporarilyUnavailable) }
    XCTAssertEqual(try store.load()?.tokens?.refreshToken, "invented-old-refresh")
    // An invalid client is a configuration problem: tokens are unusable, but the registration and the
    // account mapping stay, so no new registration is made silently.
    server.token = { _ in (401, ["error": "invalid_client"]) }
    XCTAssertThrowsError(try session.currentAccessToken()) { XCTAssertEqual($0 as? ChatGPTTokenError, .signInAgain) }
    XCTAssertNil(try store.load()?.tokens)
    XCTAssertEqual(try store.load()?.registration, ChatGPTRegistration(clientID: FakeAccount.clientID, subject: FakeAccount.subject))
    XCTAssertEqual(try store.load()?.idToken, "invented-id")
    XCTAssertEqual(session.status(), .signInAgain)
  }

  func testNotEligibleAndConfirmedDisconnectionChangeStatus() throws {
    try store.save(refreshable(expiresAt: FakeAccount.now + 3600))
    let session = session()
    XCTAssertEqual(try session.currentAccessToken().value, "invented-old-access")
    session.reportNotEligible(try savedToken())
    XCTAssertEqual(session.status(), .unavailable)
    XCTAssertThrowsError(try session.currentAccessToken()) { XCTAssertEqual($0 as? ChatGPTTokenError, .notAvailable) }
    session.reportSignInRequired()
    XCTAssertEqual(session.status(), .signInAgain)
    XCTAssertNil(try store.load()?.tokens)
    XCTAssertEqual(try store.load()?.idToken, "invented-id")
    XCTAssertThrowsError(try session.currentAccessToken()) { XCTAssertEqual($0 as? ChatGPTTokenError, .signInAgain) }
    XCTAssertThrowsError(try self.session(store: InMemoryChatGPTCredentialStore()).currentAccessToken()) {
      XCTAssertEqual($0 as? ChatGPTTokenError, .notSignedIn)
    }
  }

  // MARK: Sign-out

  func testSignOutRevokesThenClearsTokensButKeepsRegistrationAndHost() throws {
    let session = try signedIn()
    let host = try store.hostID()
    XCTAssertTrue(session.signOut())
    XCTAssertEqual(server.requests("/revoke").first?.form, ["token": "invented-refresh-1", "token_type_hint": "refresh_token",
      "client_id": FakeAccount.clientID])
    let record = try XCTUnwrap(try store.load())
    XCTAssertNil(record.tokens); XCTAssertEqual(record.registration?.clientID, FakeAccount.clientID)
    XCTAssertEqual(try store.hostID(), host); XCTAssertEqual(session.status(), .notConnected)
    XCTAssertThrowsError(try session.currentAccessToken()) { XCTAssertEqual($0 as? ChatGPTTokenError, .notSignedIn) }
    approve(clientID: nil); issueTokens()
    try session.connect()
    XCTAssertNil(browser.lastOpened["id_token_hint"])
    server.revoke = { _ in 503 }
    XCTAssertFalse(session.signOut())
    XCTAssertEqual(server.requests("/revoke").count, 1 + ChatGPTSession.revocationAttempts)
    XCTAssertEqual(backoffs, [0, 1])
    XCTAssertNil(try store.load()?.tokens)
  }

  // MARK: Storage and leaks

  func testKeychainStoreUsesTheAppServiceOnThisMacOnly() throws {
    var items: [String: [String: Any]] = [:]
    var operations: [String] = []
    func key(_ query: CFDictionary) -> String {
      let q = query as NSDictionary
      return (q[kSecAttrService] as! String) + "/" + (q[kSecAttrAccount] as! String)
    }
    let calls = KeychainCalls(copy: { query, result in
      operations.append("copy")
      let q = query as NSDictionary
      XCTAssertEqual(q[kSecClass] as! CFString as String, kSecClassGenericPassword as String)
      XCTAssertEqual(q[kSecAttrSynchronizable] as? Bool, false)
      guard let item = items[key(query)] else { return errSecItemNotFound }
      result?.pointee = item[kSecValueData as String] as! Data as CFData
      return errSecSuccess
    }, add: { item in
      operations.append("add")
      let q = item as NSDictionary
      XCTAssertEqual(q[kSecAttrAccessible] as! CFString as String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
      XCTAssertEqual(q[kSecAttrSynchronizable] as? Bool, false)
      items[key(item)] = [kSecValueData as String: q[kSecValueData]!]
      return errSecSuccess
    }, update: { query, change in
      operations.append("update")
      guard items[key(query)] != nil else { return errSecItemNotFound }
      items[key(query)] = [kSecValueData as String: (change as NSDictionary)[kSecValueData]!]
      return errSecSuccess
    }, delete: { _ in errSecSuccess })
    let keychain = KeychainChatGPTCredentialStore(service: AppPaths.chatGPTKeychainService, calls: calls)
    XCTAssertEqual(AppPaths.chatGPTKeychainService, "dev.local.ActivityProbe.chatgpt")
    XCTAssertNil(try keychain.load())
    let host = try keychain.hostID()
    XCTAssertEqual(try keychain.hostID(), host)
    var record = refreshable(expiresAt: FakeAccount.now)
    try keychain.save(record)
    record.notEligible = true
    try keychain.save(record)
    XCTAssertEqual(try keychain.load(), record)
    XCTAssertEqual(Set(items.keys), ["dev.local.ActivityProbe.chatgpt/chatgpt-host-id", "dev.local.ActivityProbe.chatgpt/chatgpt-credential"])
    XCTAssertEqual(operations.filter { $0 == "add" }.count, 2)
    // The real Security calls refuse to run under the test runner.
    let real = KeychainChatGPTCredentialStore(service: "org.example.invented")
    XCTAssertThrowsError(try real.load()) { XCTAssertEqual($0 as? ChatGPTTokenError, .storage) }
    XCTAssertThrowsError(try real.hostID())
    XCTAssertEqual(ChatGPTSignInHost.session(paths: try invented()).status(), .notConnected)
  }
  func invented() throws -> AppPaths {
    AppPaths(userHome: root, appData: root.appendingPathComponent("app-data"), database: root.appendingPathComponent("db.sqlite"),
      appBinary: root.appendingPathComponent("ActivityProbe"), queryHelper: root.appendingPathComponent("ActivityQueryServer"))
  }

  func testNoTokenReachesOutputFilesOrDescriptions() throws {
    let capture = root.appendingPathComponent("captured-output")
    FileManager.default.createFile(atPath: capture.path, contents: nil)
    let out = dup(1), err = dup(2)
    let file = open(capture.path, O_WRONLY)
    dup2(file, 1); dup2(file, 2)
    var errors: [String] = []
    do {
      let session = try signedIn()
      try store.save({ var r = try store.load()!; r.tokens!.expiresAt = FakeAccount.now; return r }())
      server.token = { _ in (200, ["access_token": "invented-access-rotated", "refresh_token": "invented-refresh-rotated",
        "expires_in": 3600, "scope": FakeAccount.allScopes]) }
      let token = try session.currentAccessToken()
      errors.append(String(describing: token)); errors.append(String(reflecting: token)); errors.append("\(token)")
      var dumped = ""; dump(token, to: &dumped); errors.append(dumped)
      browser.answer = { [("error", "access_denied"), ("state", $0["state"]!)] }
      do { try session.connect() } catch { errors.append(String(describing: error)); errors.append(error.localizedDescription) }
      let record = try XCTUnwrap(try store.load())
      for value in [record as Any, record.tokens as Any, record.registration as Any] {
        errors.append(String(describing: value)); errors.append(String(reflecting: value))
        var dumped = ""; dump(value, to: &dumped); errors.append(dumped)
      }
      errors.append("\(record) \(String(describing: record.tokens))")
      server.token = { _ in (400, ["error": "invalid_grant", "error_description": "invented-refresh-rotated"]) }
      try store.save({ var r = try store.load()!; r.tokens!.expiresAt = FakeAccount.now; return r }())
      do { _ = try session.currentAccessToken() } catch { errors.append(String(describing: error)) }
      _ = session.signOut()
    }
    fflush(stdout); fflush(stderr)
    dup2(out, 1); dup2(err, 2); close(file); close(out); close(err)
    let secrets = ["invented-access-1", "invented-refresh-1", "invented-access-rotated", "invented-refresh-rotated", "invented-code",
      "person@example.invalid", FakeAccount.subject]
    var texts = errors
    let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!.compactMap { $0 as? URL }
    for url in files { if let data = FileManager.default.contents(atPath: url.path) { texts.append(String(decoding: data, as: UTF8.self)) } }
    XCTAssertTrue(files.contains { $0.lastPathComponent == "chatgpt.lock" })
    for secret in secrets { for text in texts { XCTAssertFalse(text.contains(secret), secret) } }
    XCTAssertTrue(errors.contains("ChatGPTAccessToken(redacted)"))
  }

  // MARK: Settings row

  @MainActor func testSettingsRowConnectsOnlyWithPlanAndReportsUnconfirmedSignOut() async throws {
    let account = FakeChatGPTAccount()
    let storage = try ActivityStorage(url: root.appendingPathComponent("settings.sqlite"), appDataDirectory: root, databaseScope: .directory(root))
    let controller = try SettingsController(store: storage, connector: account, ownBundleID: "org.example.self", chatGPT: account)
    account.result = .failure(ChatGPTSignInError.planRequired); account.current = .planRequired
    await controller.connect()
    XCTAssertEqual(controller.error, .chatGPTPlanRequired)
    XCTAssertFalse(controller.settings.subscriptionConnected)
    await controller.refreshChatGPTStatus()
    XCTAssertEqual(controller.chatGPTStatus, .planRequired)
    account.result = .success(()); account.current = .connected
    await controller.connect()
    XCTAssertNil(controller.error); XCTAssertTrue(controller.settings.subscriptionConnected)
    await controller.refreshChatGPTStatus()
    XCTAssertEqual(controller.chatGPTStatus, .connected)
    account.confirmed = false
    await controller.signOut()
    XCTAssertFalse(controller.settings.subscriptionConnected)
    XCTAssertEqual(controller.chatGPTStatus, .notConnected)
    XCTAssertEqual(controller.error, .chatGPTRevocationUnconfirmed)
    XCTAssertEqual(account.signOuts, 1)
    let messages = ChatGPTSignInError.allCases.map { SettingsMessage(error: $0) }
    XCTAssertEqual(Set(messages).count, ChatGPTSignInError.allCases.count)
    let strings = SettingsStrings(language: "en", resources: nil)
    XCTAssertEqual(ChatGPTConnectionStatus.allCases.map(strings.text),
      ["Not connected", "Connected", "ChatGPT Plus or Pro required", "Not available for this account", "Sign in again",
       "Usage limit reached", "ChatGPT did not accept requests", "ChatGPT refused a request"])
    let ko = SettingsStrings(language: "ko", resources: try compiledResources())
    XCTAssertEqual(ChatGPTConnectionStatus.allCases.map(ko.text), ["연결 안 됨", "연결됨", "Plus·Pro 필요", "이 계정에서는 사용할 수 없음", "다시 로그인 필요",
      "사용 한도 도달", "ChatGPT가 요청을 받지 않음", "ChatGPT가 요청을 거절했습니다"])
    XCTAssertEqual(ko.text(.continueWithChatGPT), "ChatGPT로 계속하기")
    XCTAssertEqual([ko.text(.differentAccount), ko.text(.manageUsage), ko.text(.planWelcomeTitle), ko.text(.gotIt), ko.text(.pausedUntilSignIn)],
      ["다른 ChatGPT 계정 사용", "사용량 관리", "ChatGPT 요금제를 사용 중", "확인", "ChatGPT로 계속하기 전까지 Codex 대화를 멈춥니다."])
    // The pause and switch texts have Korean translations in the catalog.
    let added: [String] = [SettingsMessage.chatGPTDifferentAccountWithoutPlan, .chatGPTDifferentAccountWithoutPlanUnconfirmed,
      .chatGPTUnusedRevocationUnconfirmed].map(\.rawValue)
      + [SettingsLabel.usageLimitedNote, .notAcceptedNote, .claudeSummaries, .claudeSummariesPaused, .serviceUnavailableNote].map(\.rawValue)
    for key in added { XCTAssertNotEqual(ko.text(key: key), key, key) }
    XCTAssertTrue(SettingsMessage.chatGPTDifferentAccount.rawValue.hasSuffix("choose " + SettingsLabel.differentAccount.rawValue + "."))
  }
  func compiledResources() throws -> URL {
    let output = root.appendingPathComponent("strings")
    let catalog = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Resources/Localizable.xcstrings")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["xcstringstool", "compile", catalog.path, "--output-directory", output.path]
    process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
    try process.run(); process.waitUntilExit()
    return output
  }
}

final class FakeChatGPTAccount: ChatGPTAccount {
  var result: Result<Void, Error> = .success(())
  var current: ChatGPTConnectionStatus = .notConnected
  var registered = false
  var welcomePending = false
  var confirmed = true
  var signOuts = 0
  var differentAccountSignIns = 0
  var acknowledged = 0
  var revocations = 0
  var unusedConfirmed = true
  var revocationPending = false
  /// Runs inside the attempt, like a person pressing Cancel while the browser is open.
  var during: (() -> Void)?
  func connect() throws { during?(); try result.get() }
  func connectDifferentAccount() throws { differentAccountSignIns += 1; during?(); try result.get() }
  func revokeUnusedGrants() -> Bool { revocations += 1; revocationPending = false; return unusedConfirmed }
  func cancel() {}
  func overview() -> ChatGPTAccountOverview {
    ChatGPTAccountOverview(status: current, registered: registered, planWelcomePending: welcomePending, revocationPending: revocationPending)
  }
  func acknowledgePlanWelcome() { acknowledged += 1; welcomePending = false }
  func signOut() -> Bool { signOuts += 1; current = .notConnected; return confirmed }
}
