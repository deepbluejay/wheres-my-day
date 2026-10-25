import Core
import Foundation

/// "Sign in with ChatGPT" for the open-source flow: one ChatGPT account per Mac, the app's own
/// Keychain items, and refresh owned by the app. No value from this type is logged or shown.
public final class ChatGPTSession: ChatGPTAccount, ChatGPTAccessTokens {
  /// Refresh this long before expiry so a summary or turn never starts with a nearly expired token.
  public static let refreshMargin = 300
  /// Refresh failures that mean the token set is unusable (docs: Errors and recovery, Refresh errors).
  static let unusableRefreshCodes: Set<String> = ["invalid_grant", "invalid_refresh_token", "token_expired",
    "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused"]
  public static let revocationAttempts = 3
  /// How long new plan requests wait after a usage-limit or not-accepted refusal. A chosen value, not a
  /// reset time: the docs say not to infer one. One request per pause, so a refusal never becomes a loop.
  public static let pauseSeconds = 1800
  private let configuration: ChatGPTOAuthConfiguration
  private let store: ChatGPTCredentialStore
  private let lock: ChatGPTCredentialLock
  private let openBrowser: (URL) -> Bool
  private let makeHTTP: () -> ChatGPTHTTP
  private let clock: () -> Int
  private let backoff: (Int) -> Void
  private let callbackPage: () -> String
  private let attemptLock = NSLock()
  private var attemptHTTP: ChatGPTHTTP?
  private var cancelled = false
  private var attempting = false
  private var revoking = false
  /// This build's request fingerprint; a refusal of the request itself holds only for the build that sent it.
  private let requestShape: String
  public init(configuration: ChatGPTOAuthConfiguration = .production, store: ChatGPTCredentialStore,
    lock: ChatGPTCredentialLock, openBrowser: @escaping (URL) -> Bool,
    makeHTTP: @escaping () -> ChatGPTHTTP = { URLSessionChatGPTHTTP() },
    clock: @escaping () -> Int = { Int(Date().timeIntervalSince1970) },
    backoff: @escaping (Int) -> Void = { Thread.sleep(forTimeInterval: Double(1 << $0)) },
    callbackPage: @escaping () -> String = { "" }, requestShape: String = ChatGPTRequestShape.current) {
    self.configuration = configuration; self.store = store; self.lock = lock; self.openBrowser = openBrowser
    self.makeHTTP = makeHTTP; self.clock = clock; self.backoff = backoff; self.callbackPage = callbackPage
    self.requestShape = requestShape
  }

  public func overview() -> ChatGPTAccountOverview {
    guard let record = (try? store.load()) ?? nil else { return ChatGPTAccountOverview() }
    return ChatGPTAccountOverview(status: record.status(at: clock(), requestShape: requestShape),
      registered: record.registration != nil, planWelcomePending: record.status == .connected && !record.planWelcomeShown,
      revocationPending: !record.unusedGrants.isEmpty,
      conversationRequestRefused: record.refusedConversationRequests.contains {
        $0.hasPrefix("codex-responses-v1|") && $0.hasSuffix("|" + ChatGPTRequestShape.buildID)
      })
  }
  public var signedInForPlanUse: Bool {
    guard let record = (try? store.load()) ?? nil else { return false }
    return record.status(at: clock(), requestShape: requestShape).signedInForPlanUse
  }
  public func acknowledgePlanWelcome() {
    _ = try? lock.withLock {
      guard var record = try store.load(), !record.planWelcomeShown else { return }
      record.planWelcomeShown = true; try store.save(record)
    }
  }

  // MARK: Sign-in

  public func cancel() {
    attemptLock.lock(); cancelled = true; let http = attemptHTTP; attemptLock.unlock()
    http?.cancel()
  }
  /// The person's own click. Throws ChatGPTSignInError; stores tokens only after every check passes.
  public func connect() throws { try attempt(newAccount: false) }
  /// The person's own click on "use a different ChatGPT account": a fresh dynamic registration kept
  /// apart from the saved account until the new identity validates and grants plan use, then it replaces
  /// the saved account. The unused grant is revoked later by `revokeUnusedGrants`, not inside the attempt.
  public func connectDifferentAccount() throws { try attempt(newAccount: true) }
  public func revokeUnusedGrants() -> Bool {
    attemptLock.lock()
    guard !revoking else { attemptLock.unlock(); return true }
    revoking = true; attemptLock.unlock()
    defer { attemptLock.lock(); revoking = false; attemptLock.unlock() }
    guard let grants = ((try? store.load()) ?? nil)?.unusedGrants, !grants.isEmpty else { return true }
    var confirmed = true
    for grant in grants {
      if !revoke(grant.refreshToken, clientID: grant.clientID, http: makeHTTP()) { confirmed = false }
      // Tried once, then dropped: an unconfirmed revocation is reported, not retried on every later call.
      _ = try? lock.withLock {
        guard var record = try store.load() else { return }
        record.unusedGrants.removeAll { $0 == grant }; try store.save(record)
      }
    }
    return confirmed
  }
  private func attempt(newAccount: Bool) throws {
    attemptLock.lock()
    guard !attempting else { attemptLock.unlock(); throw ChatGPTSignInError.cancelled }
    attempting = true; cancelled = false
    let http = makeHTTP(); attemptHTTP = http
    attemptLock.unlock()
    defer { attemptLock.lock(); attempting = false; cancelled = false; attemptHTTP = nil; attemptLock.unlock() }
    do { try signIn(http: http, newAccount: newAccount) }
    catch let error as ChatGPTSignInError { throw isCancelled ? ChatGPTSignInError.cancelled : error }
    catch { throw isCancelled ? ChatGPTSignInError.cancelled : ChatGPTSignInError.storage }
  }
  private var isCancelled: Bool { attemptLock.lock(); defer { attemptLock.unlock() }; return cancelled }

  private func signIn(http: ChatGPTHTTP, newAccount: Bool) throws {
    let deadline = ProcessInfo.processInfo.systemUptime + configuration.signInTimeout
    let host: String
    let saved: ChatGPTCredentialRecord
    do { host = try store.hostID(); saved = try store.load() ?? ChatGPTCredentialRecord() }
    catch { throw ChatGPTSignInError.storage }
    // A different account registers again, or reuses the client an unfinished switch was issued;
    // nothing of the saved account is sent.
    let pending = newAccount && saved.pendingRegistration?.subject == nil ? saved.pendingRegistration : nil
    let registered = newAccount ? pending?.clientID : saved.registration?.clientID
    do {
      try authorize(http: http, newAccount: newAccount, saved: saved, host: host, registered: registered,
        pendingSubject: pending?.subject, deadline: deadline)
    } catch let error as ChatGPTSignInError where newAccount && Self.endsPending.contains(error) {
      // The pending client is for retrying the exchange of the account it was issued to, nothing else:
      // after a refusal, a different client or a different identity, the next switch registers afresh.
      // Attempts never overlap, so without a reused client any pending one was issued to this attempt.
      try? save { record in
        if registered == nil || record.pendingRegistration?.clientID == registered { record.pendingRegistration = nil }
      }
      throw error
    }
  }
  static let endsPending: Set<ChatGPTSignInError> = [.declined, .clientMismatch, .invalidIDToken]
  private func authorize(http: ChatGPTHTTP, newAccount: Bool, saved: ChatGPTCredentialRecord, host: String,
    registered: String?, pendingSubject: String?, deadline: TimeInterval) throws {
    let attempt = try ChatGPTAttempt.fresh()
    // The listener is up before the browser opens; its exact URI is reused for the exchange.
    let listener = try ChatGPTLoopbackListener(preferredPort: configuration.preferredPort)
    defer { listener.close() }
    let redirect = listener.redirectURI
    let reconsent = !newAccount && (saved.planDeclined || saved.tokens.map { !$0.planGranted } ?? false)
    let url = ChatGPTAuthorizeRequest.url(configuration: configuration, clientID: registered, hostID: host,
      redirect: redirect, attempt: attempt, idTokenHint: newAccount ? nil : saved.idToken, reconsent: reconsent)
    guard !isCancelled else { throw ChatGPTSignInError.cancelled }
    guard openBrowser(url) else { throw ChatGPTSignInError.browser }
    let page = callbackPage()
    // State first: a callback of another attempt, a stale tab or a forged request is answered and
    // ignored, including its error, and the wait goes on until this attempt's callback or the deadline.
    let query = try listener.waitForCallback(until: deadline, cancelled: { isCancelled }) { query in
      let matches = query["state"].map { ChatGPTIDTokenValidator.equal($0, attempt.state) } ?? false
      return (matches && query["error"] == nil && query["code"] != nil ? 200 : 400, page, matches)
    }
    if let error = query["error"] { throw error == "access_denied" ? ChatGPTSignInError.declined : ChatGPTSignInError.exchangeFailed }
    guard let code = query["code"], !code.isEmpty else { throw ChatGPTSignInError.exchangeFailed }
    let clientID: String
    if let registered {
      // A returning callback may omit client_id; a different one never replaces the registration.
      if let returned = query["client_id"], returned != registered { throw ChatGPTSignInError.clientMismatch }
      clientID = registered
    } else {
      guard let issued = query["client_id"], !issued.isEmpty, issued != ChatGPTOAuthConfiguration.registrationClientID
      else { throw ChatGPTSignInError.registrationIncomplete }
      clientID = issued
      // Keep the issued client so a failed exchange is retried with it, not with a fresh registration.
      // A different-account attempt keeps it as the pending client, apart from the saved account.
      try save { record in
        if newAccount { record.pendingRegistration = ChatGPTRegistration(clientID: issued, subject: nil) }
        else if record.registration == nil { record.registration = ChatGPTRegistration(clientID: issued, subject: nil) }
      }
    }
    let (status, body) = try request {
      try http.postForm(configuration.token, [("grant_type", "authorization_code"), ("client_id", clientID), ("code", code),
        ("code_verifier", attempt.verifier), ("redirect_uri", redirect), ("resource", ChatGPTOAuthConfiguration.resource)],
        timeout: configuration.requestTimeout)
    }
    guard status == 200, let response = ChatGPTTokenResponse.parse(body), let idToken = response.idToken
    else { throw ChatGPTSignInError.exchangeFailed }
    // The ID token and the granted scopes decide what the result is before anything else is required:
    // without plan permission there may be no refresh token, and the sign-in is still kept.
    let subject = try ChatGPTIDTokenValidator(configuration: configuration, http: http)
      .subject(of: idToken, clientID: clientID, nonce: attempt.nonce, now: clock())
    let now = clock()
    // Without plan permission a returned refresh token is kept only so sign-out can revoke it.
    let tokens = response.refreshToken.map { ChatGPTTokenSet(accessToken: response.accessToken, refreshToken: $0,
      tokenType: response.tokenType, expiresAt: now + response.expiresIn, scopes: response.scopes ?? [],
      earliestRefreshAt: response.earliestRefreshAt, savedAt: now) }
    if newAccount {
      // The pending client is bound to the identity first validated under it; another identity never uses it.
      if let pendingSubject, pendingSubject != subject {
        if let tokens { try save { $0.unusedGrants.append(ChatGPTUnusedGrant(refreshToken: tokens.refreshToken, clientID: clientID)) } }
        throw ChatGPTSignInError.clientMismatch
      }
      if !response.planGranted || response.refreshToken == nil {
        // Replacing a working account with one that cannot use its plan would leave the person with
        // neither. The saved account stays; the new grant is not used, so it is queued for revocation.
        // Identity validated: a later generic switch must register afresh.
        try save { record in
          record.pendingRegistration = nil
          if let tokens { record.unusedGrants.append(ChatGPTUnusedGrant(refreshToken: tokens.refreshToken, clientID: clientID)) }
        }
        throw response.planGranted ? ChatGPTSignInError.exchangeFailed : ChatGPTSignInError.differentAccountWithoutPlan
      }
    }
    if response.planGranted && response.refreshToken == nil { throw ChatGPTSignInError.exchangeFailed }
    try save { record in
      if newAccount {
        // The validated new account replaces the saved one as a whole; no value of the old one is combined with it.
        // The replaced account is forgotten on this Mac, so its grant is queued for revocation in the same save.
        var fresh = ChatGPTCredentialRecord()
        fresh.planWelcomeShown = record.planWelcomeShown
        fresh.unusedGrants = record.unusedGrants
        if let oldTokens = record.tokens, let oldClient = record.registration?.clientID {
          fresh.unusedGrants.append(ChatGPTUnusedGrant(refreshToken: oldTokens.refreshToken, clientID: oldClient))
        }
        record = fresh
      } else {
        // The returning account must be the one this client was registered for.
        if let known = record.registration?.subject, known != subject { throw ChatGPTSignInError.differentAccount }
        if let current = record.registration?.clientID, current != clientID { throw ChatGPTSignInError.clientMismatch }
      }
      record.registration = ChatGPTRegistration(clientID: clientID, subject: subject)
      record.idToken = idToken; record.tokens = tokens
      record.planDeclined = !response.planGranted; record.signInRequired = false
      record.pause = nil; record.pausedUntil = nil; record.refusedRequest = nil; record.refusedConversationRequests = []
    }
    // A valid ID token alone does not authorize plan usage; the sign-in is kept, usage stays off.
    guard response.planGranted else { throw ChatGPTSignInError.planRequired }
  }
  private func request(_ body: () throws -> (status: Int, body: Data)) throws -> (status: Int, body: Data) {
    do { return try body() }
    catch let error as ChatGPTSignInError where error == .cancelled { throw error }
    catch { throw ChatGPTSignInError.network }
  }
  private func save(_ change: (inout ChatGPTCredentialRecord) throws -> Void) throws {
    do {
      try lock.withLock {
        var record = try store.load() ?? ChatGPTCredentialRecord()
        try change(&record)
        try store.save(record)
      }
    } catch let error as ChatGPTSignInError { throw error } catch { throw ChatGPTSignInError.storage }
  }

  // MARK: Token port

  public func currentAccessToken() throws -> ChatGPTAccessToken { try currentAccessToken(requestShape: requestShape) }
  public func reportRejected(_ token: ChatGPTAccessToken) throws -> ChatGPTAccessToken { try reportRejected(token, requestShape: requestShape) }
  public func currentAccessToken(requestShape: String) throws -> ChatGPTAccessToken { try token(rejected: nil, requestShape: requestShape) }
  public func reportRejected(_ token: ChatGPTAccessToken, requestShape: String) throws -> ChatGPTAccessToken {
    try self.token(rejected: token.value, requestShape: requestShape)
  }
  private func token(rejected: String?, requestShape: String) throws -> ChatGPTAccessToken {
    do {
      return try lock.withLock {
        // Read under the lock: another process may have just rotated the token set.
        guard var record = try store.load() else { throw ChatGPTTokenError.notSignedIn }
        guard let tokens = record.tokens else {
          throw record.signInRequired ? ChatGPTTokenError.signInAgain : record.planDeclined ? ChatGPTTokenError.planRequired : ChatGPTTokenError.notSignedIn
        }
        guard tokens.planGranted else { throw ChatGPTTokenError.planRequired }
        guard !record.notEligible else { throw ChatGPTTokenError.notAvailable }
        guard !record.requestRefused(requestShape) else { throw ChatGPTTokenError.requestRefused }
        let now = clock()
        switch record.activePause(at: now) {
        case .usageLimited?: throw ChatGPTTokenError.usageLimited
        case .notAccepted?: throw ChatGPTTokenError.notAccepted
        case nil: break
        }
        let fresh = now < tokens.expiresAt - Self.refreshMargin
        if let rejected {
          // Another caller already replaced the rejected token: hand out the replacement, no second refresh.
          if fresh && !ChatGPTIDTokenValidator.equal(rejected, tokens.accessToken) { return Self.token(tokens) }
        } else {
          let early = tokens.earliestRefreshAt.map { now < $0 } ?? false
          if fresh || (early && now < tokens.expiresAt) { return Self.token(tokens) }
        }
        return try refresh(&record, tokens, now: now)
      }
    } catch let error as ChatGPTTokenError { throw error } catch { throw ChatGPTTokenError.storage }
  }
  private static func token(_ tokens: ChatGPTTokenSet) -> ChatGPTAccessToken {
    ChatGPTAccessToken(tokens.accessToken, validUntil: tokens.expiresAt)
  }
  /// Runs under the credential lock.
  private func refresh(_ record: inout ChatGPTCredentialRecord, _ tokens: ChatGPTTokenSet, now: Int) throws -> ChatGPTAccessToken {
    guard let clientID = record.registration?.clientID else { throw ChatGPTTokenError.signInAgain }
    let http = makeHTTP()
    let response: (status: Int, body: Data)
    do {
      response = try http.postForm(configuration.token, [("grant_type", "refresh_token"), ("client_id", clientID),
        ("refresh_token", tokens.refreshToken), ("resource", ChatGPTOAuthConfiguration.resource)], timeout: configuration.requestTimeout)
    } catch { throw ChatGPTTokenError.temporarilyUnavailable }
    if response.status == 200, let renewed = ChatGPTTokenResponse.parse(response.body) {
      // Access token, expiry, granted scopes and the rotating refresh token are replaced together.
      var next = tokens
      next.accessToken = renewed.accessToken; next.expiresAt = now + renewed.expiresIn
      next.scopes = renewed.scopes ?? tokens.scopes
      next.refreshToken = renewed.refreshToken ?? tokens.refreshToken
      next.earliestRefreshAt = renewed.earliestRefreshAt; next.savedAt = now
      record.tokens = next
      try store.save(record)
      guard next.planGranted else { throw ChatGPTTokenError.planRequired }
      return Self.token(next)
    }
    let code = ChatGPTTokenResponse.errorCode(response.body)
    if let code, Self.unusableRefreshCodes.contains(code) || code == "invalid_client" {
      // Terminal: the token set is unusable. The registration and the ID token stay for the next
      // sign-in's hint; an invalid client is a configuration problem, not a reason to register again.
      record.tokens = nil; record.signInRequired = true
      try store.save(record)
      throw ChatGPTTokenError.signInAgain
    }
    // Network and server failures keep the credentials.
    throw ChatGPTTokenError.temporarilyUnavailable
  }
  public func reportNotEligible(_ token: ChatGPTAccessToken) {
    report(token) { record in
      guard !record.notEligible else { return false }
      record.notEligible = true; return true
    }
  }
  public func reportUsageLimited(_ token: ChatGPTAccessToken) { pause(.usageLimited, token) }
  public func reportNotAccepted(_ token: ChatGPTAccessToken) { pause(.notAccepted, token) }
  public func reportRequestRefused(_ token: ChatGPTAccessToken) {
    reportRequestRefused(token, requestShape: requestShape)
  }
  public func reportRequestRefused(_ token: ChatGPTAccessToken, requestShape: String) {
    let shape = requestShape
    report(token) { record in
      if shape == self.requestShape { record.refusedRequest = shape }
      else {
        record.refusedConversationRequests.removeAll {
          $0.hasPrefix("codex-responses-v1|") && !$0.hasSuffix("|" + ChatGPTRequestShape.buildID)
        }
        if !record.refusedConversationRequests.contains(shape) { record.refusedConversationRequests.append(shape) }
      }
      return true
    }
  }
  private func pause(_ reason: ChatGPTPause, _ token: ChatGPTAccessToken) {
    let until = clock() + Self.pauseSeconds
    report(token) { record in record.pause = reason; record.pausedUntil = until; return true }
  }
  /// Applies a refusal under the lock, only while the refused token is still the saved one: a refusal that
  /// lands after a switch or a new sign-in is about an account or token set that is gone.
  private func report(_ token: ChatGPTAccessToken, _ change: (inout ChatGPTCredentialRecord) -> Bool) {
    _ = try? lock.withLock {
      guard var record = try store.load(), let tokens = record.tokens,
        ChatGPTIDTokenValidator.equal(tokens.accessToken, token.value), change(&record) else { return }
      try store.save(record)
    }
  }
  public func reportSignInRequired() {
    _ = try? lock.withLock {
      guard var record = try store.load(), record.tokens != nil else { return }
      record.tokens = nil; record.signInRequired = true; try store.save(record)
    }
  }

  // MARK: Sign-out

  /// Revokes the refresh token, retrying network and server failures, then clears every token and the
  /// ID token. The registration and host ID stay for a later sign-in, as the docs direct.
  public func signOut() -> Bool {
    cancel()
    guard let record = (try? store.load()) ?? nil, let tokens = record.tokens else {
      clearSignIn(); return true
    }
    var confirmed = false
    if let clientID = record.registration?.clientID { confirmed = revoke(tokens.refreshToken, clientID: clientID, http: makeHTTP()) }
    clearSignIn()
    return confirmed
  }
  /// Discovery and revocation are each retried on failure with the same backoff. True only for a confirmed revocation.
  private func revoke(_ refreshToken: String, clientID: String, http: ChatGPTHTTP) -> Bool {
    var discovery: ChatGPTDiscovery?
    for attempt in 0..<Self.revocationAttempts where discovery == nil {
      if attempt > 0 { backoff(attempt - 1) }
      discovery = try? ChatGPTDiscovery.load(configuration, http: http)
    }
    guard let revocation = discovery?.revocation else { return false }
    for attempt in 0..<Self.revocationAttempts {
      if attempt > 0 { backoff(attempt - 1) }
      guard let response = try? http.postForm(revocation, [("token", refreshToken), ("token_type_hint", "refresh_token"),
        ("client_id", clientID)], timeout: configuration.requestTimeout) else { continue }
      if response.status == 200 { return true }
      if response.status < 500 { return false }
    }
    return false
  }
  private func clearSignIn() {
    _ = try? lock.withLock {
      guard var record = try store.load() else { return }
      record.tokens = nil; record.idToken = nil
      record.signInRequired = false; record.planDeclined = false; record.notEligible = false
      record.pause = nil; record.pausedUntil = nil; record.refusedRequest = nil; record.refusedConversationRequests = []
      // A pending client belongs to a switch of this sign-in; after sign-out the next switch registers afresh.
      record.pendingRegistration = nil
      try store.save(record)
    }
  }
}
