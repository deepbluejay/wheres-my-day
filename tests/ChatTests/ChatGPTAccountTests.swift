import Core
import Darwin
import Foundation
@testable import Outbound
@testable import Shell
import Storage
import XCTest

/// Plan scope before the refresh token, switching accounts, the rejected-token path, the listener under
/// decoys and idle connections, and the Codex row's states. Invented server, browser and keys only.
extension ChatGPTSignInTests {
  /// The token endpoint answers a code exchange with `fields` and an ID token for the request's client and nonce.
  func issue(_ fields: [String: Any], subject: String = FakeAccount.subject) {
    let browser = self.browser!, issuer = server.issuer, signer = self.signer!
    server.token = { form in
      guard form["grant_type"] == "authorization_code" else { return (400, ["error": "unsupported_grant_type"]) }
      let id = signer.token(FakeAccount.claims(issuer: issuer, nonce: browser.lastOpened["nonce"] ?? "",
        audience: form["client_id"] ?? "", subject: subject))
      return (200, fields.merging(["id_token": id, "token_type": "Bearer", "expires_in": 3600]) { kept, _ in kept })
    }
  }
  func planTokens(_ name: String) -> [String: Any] {
    ["access_token": "invented-access-" + name, "refresh_token": "invented-refresh-" + name, "scope": FakeAccount.allScopes]
  }

  // MARK: Plan scope before the refresh token

  func testPlanDeclinedWithoutRefreshTokenKeepsTheSignIn() throws {
    approve(); issue(["access_token": "invented-access-1", "scope": "openid profile email"])
    let session = session()
    XCTAssertThrowsError(try session.connect()) { XCTAssertEqual($0 as? ChatGPTSignInError, .planRequired) }
    let record = try XCTUnwrap(try store.load())
    XCTAssertEqual(record.registration, ChatGPTRegistration(clientID: FakeAccount.clientID, subject: FakeAccount.subject))
    XCTAssertNotNil(record.idToken); XCTAssertNil(record.tokens); XCTAssertTrue(record.planDeclined)
    XCTAssertEqual(session.status(), .planRequired)
    XCTAssertThrowsError(try session.currentAccessToken()) { XCTAssertEqual($0 as? ChatGPTTokenError, .planRequired) }
    // Enabling plan use later repeats OAuth with the saved client, the account hint and consent.
    approve(clientID: nil); issueTokens()
    try session.connect()
    XCTAssertEqual(browser.lastOpened["client_id"], FakeAccount.clientID)
    XCTAssertEqual(browser.lastOpened["prompt"], "consent")
    XCTAssertEqual(browser.lastOpened["id_token_hint"], record.idToken)
    XCTAssertEqual(session.status(), .connected)
    XCTAssertFalse(try XCTUnwrap(try store.load()).planDeclined)
  }

  func testIDTokenIsCheckedBeforeTheRefreshTokenIsRequired() throws {
    approve(); issue(["access_token": "invented-access-1", "scope": "openid profile email"], subject: "")
    XCTAssertThrowsError(try session().connect()) { XCTAssertEqual($0 as? ChatGPTSignInError, .invalidIDToken) }
    XCTAssertNil(try store.load()?.registration?.subject); XCTAssertNil(try store.load()?.idToken)
    // Plan permission without a refresh token cannot be kept usable.
    issue(["access_token": "invented-access-1", "scope": FakeAccount.allScopes])
    XCTAssertThrowsError(try session().connect()) { XCTAssertEqual($0 as? ChatGPTSignInError, .exchangeFailed) }
    assertNothingStored()
  }

  // MARK: A different account

  func testDifferentAccountRegistersAgainAndReplacesOnlyAfterValidation() throws {
    let session = try signedIn()
    session.acknowledgePlanWelcome()
    let host = try store.hostID()
    let before = try XCTUnwrap(try store.load())
    func assertSavedAccountUnchanged(pending: ChatGPTRegistration?, file: StaticString = #filePath, line: UInt = #line) throws {
      var kept = try XCTUnwrap(try store.load(), file: file, line: line)
      XCTAssertEqual(kept.pendingRegistration, pending, file: file, line: line)
      kept.pendingRegistration = nil
      XCTAssertEqual(kept, before, file: file, line: line)
    }
    func assertFreshRegistration(file: StaticString = #filePath, line: UInt = #line) {
      let opened = browser.lastOpened
      XCTAssertEqual(opened["client_id"], "dynamic_agent_client", file: file, line: line)
      XCTAssertEqual(opened["agent_name_hint"], "ActivityProbe", file: file, line: line)
      XCTAssertEqual(opened["ext_agent_host_id"], host, file: file, line: line)
      XCTAssertNil(opened["id_token_hint"], file: file, line: line); XCTAssertNil(opened["prompt"], file: file, line: line)
    }
    // An exchange that fails before any identity is validated keeps the issued client, apart, as pending.
    approve(clientID: "oaiapp_second"); server.token = { _ in (400, ["error": "invalid_grant"]) }
    XCTAssertThrowsError(try session.connectDifferentAccount()) { XCTAssertEqual($0 as? ChatGPTSignInError, .exchangeFailed) }
    assertFreshRegistration()
    try assertSavedAccountUnchanged(pending: ChatGPTRegistration(clientID: "oaiapp_second", subject: nil))
    // The retry reuses it instead of registering the app again (docs: keep the issued client for this attempt).
    approve(clientID: nil)
    XCTAssertThrowsError(try session.connectDifferentAccount()) { XCTAssertEqual($0 as? ChatGPTSignInError, .exchangeFailed) }
    XCTAssertEqual(browser.lastOpened["client_id"], "oaiapp_second"); XCTAssertNil(browser.lastOpened["agent_name_hint"])
    XCTAssertNil(browser.lastOpened["id_token_hint"])
    XCTAssertEqual(server.requests("/api/accounts/oauth/token").last?.form["client_id"], "oaiapp_second")
    try assertSavedAccountUnchanged(pending: ChatGPTRegistration(clientID: "oaiapp_second", subject: nil))
    // A callback carrying another client is refused, and the pending client is dropped with it.
    approve(clientID: "oaiapp_third")
    XCTAssertThrowsError(try session.connectDifferentAccount()) { XCTAssertEqual($0 as? ChatGPTSignInError, .clientMismatch) }
    try assertSavedAccountUnchanged(pending: nil)
    // So the third switch registers afresh.
    approve(clientID: "oaiapp_fourth"); issue(planTokens("b"), subject: "")
    XCTAssertThrowsError(try session.connectDifferentAccount()) { XCTAssertEqual($0 as? ChatGPTSignInError, .invalidIDToken) }
    assertFreshRegistration()
    // An identity that does not validate ends the pending client too.
    try assertSavedAccountUnchanged(pending: nil)
    // So does a refusal in the browser.
    approve(clientID: "oaiapp_fifth"); server.token = { _ in (400, ["error": "invalid_grant"]) }
    XCTAssertThrowsError(try session.connectDifferentAccount())
    try assertSavedAccountUnchanged(pending: ChatGPTRegistration(clientID: "oaiapp_fifth", subject: nil))
    browser.answer = { query in [("state", query["state"]!), ("error", "access_denied")] }
    XCTAssertThrowsError(try session.connectDifferentAccount()) { XCTAssertEqual($0 as? ChatGPTSignInError, .declined) }
    XCTAssertEqual(browser.lastOpened["client_id"], "oaiapp_fifth")
    try assertSavedAccountUnchanged(pending: nil)
    XCTAssertTrue(session.revokeUnusedGrants()); XCTAssertTrue(server.requests("/revoke").isEmpty)
    // A validated new account with plan use replaces the saved one as a whole.
    approve(clientID: "oaiapp_sixth"); issue(planTokens("b"), subject: "invented-other-subject")
    try session.connectDifferentAccount()
    assertFreshRegistration()
    let record = try XCTUnwrap(try store.load())
    XCTAssertEqual(record.registration, ChatGPTRegistration(clientID: "oaiapp_sixth", subject: "invented-other-subject"))
    XCTAssertNil(record.pendingRegistration)
    XCTAssertEqual(record.tokens?.accessToken, "invented-access-b"); XCTAssertEqual(record.tokens?.refreshToken, "invented-refresh-b")
    XCTAssertTrue(record.planWelcomeShown)
    // The old grant is queued in the same save and revoked only afterwards, outside the attempt, once.
    XCTAssertEqual(record.unusedGrants, [ChatGPTUnusedGrant(refreshToken: "invented-refresh-1", clientID: FakeAccount.clientID)])
    XCTAssertTrue(session.overview().revocationPending)
    XCTAssertTrue(server.requests("/revoke").isEmpty)
    XCTAssertTrue(session.revokeUnusedGrants())
    XCTAssertEqual(server.requests("/revoke").map(\.form), [["token": "invented-refresh-1", "token_type_hint": "refresh_token",
      "client_id": FakeAccount.clientID]])
    XCTAssertTrue(session.revokeUnusedGrants()); XCTAssertEqual(server.requests("/revoke").count, 1)
    XCTAssertFalse(session.overview().revocationPending); XCTAssertEqual(try store.load()?.unusedGrants, [])
    XCTAssertEqual(try store.hostID(), host)
    // The new account is now the returning one.
    approve(clientID: nil); issue(planTokens("c"), subject: "invented-other-subject")
    try session.connect()
    XCTAssertEqual(browser.lastOpened["client_id"], "oaiapp_sixth")
    XCTAssertEqual(try store.load()?.tokens?.accessToken, "invented-access-c")
  }

  func testValidatedPlanlessSwitchRegistersAfreshWithoutSignOut() throws {
    let session = try signedIn()
    for client in ["oaiapp_second", "oaiapp_third", "oaiapp_fourth"] {
      approve(clientID: client)
      issue(["access_token": "invented-access-np", "refresh_token": "invented-refresh-np",
        "scope": "openid profile email"], subject: "invented-bound-planless-subject")
      XCTAssertThrowsError(try session.connectDifferentAccount()) { XCTAssertEqual($0 as? ChatGPTSignInError, .differentAccountWithoutPlan) }
      XCTAssertEqual(browser.lastOpened["client_id"], "dynamic_agent_client")
      XCTAssertNil(try store.load()?.pendingRegistration)
      XCTAssertEqual(try store.load()?.tokens?.accessToken, "invented-access-1")
    }
    XCTAssertEqual(try store.load()?.unusedGrants.map(\.clientID), ["oaiapp_second", "oaiapp_third", "oaiapp_fourth"])
    // A validated identity without a refresh token also ends reuse.
    approve(clientID: "oaiapp_fifth"); issue(["access_token": "invented-access-nr", "scope": FakeAccount.allScopes])
    XCTAssertThrowsError(try session.connectDifferentAccount())
    XCTAssertNil(try store.load()?.pendingRegistration)
    approve(clientID: "oaiapp_sixth"); server.token = { _ in (400, ["error": "invalid_grant"]) }
    XCTAssertThrowsError(try session.connectDifferentAccount())
    XCTAssertEqual(browser.lastOpened["client_id"], "dynamic_agent_client")
    XCTAssertEqual(try store.load()?.pendingRegistration?.clientID, "oaiapp_sixth")
    XCTAssertTrue(session.signOut()); XCTAssertNil(try store.load()?.pendingRegistration)
  }

  func testUnusedGrantsSurviveAQuitAndAreRevokedLater() throws {
    let session = try signedIn()
    // A grant an earlier switch left queued stays queued through the replacing save.
    let earlier = ChatGPTUnusedGrant(refreshToken: "invented-refresh-earlier", clientID: "oaiapp_earlier")
    var seeded = try XCTUnwrap(try store.load()); seeded.unusedGrants = [earlier]; try store.save(seeded)
    approve(clientID: "oaiapp_second"); issue(planTokens("b"), subject: "invented-other-subject")
    try session.connectDifferentAccount()
    XCTAssertEqual(try store.load()?.unusedGrants,
      [earlier, ChatGPTUnusedGrant(refreshToken: "invented-refresh-1", clientID: FakeAccount.clientID)])
    // The app quits before the revocation: a new session (a new process) still finds both grants.
    let later = self.session()
    XCTAssertTrue(later.overview().revocationPending)
    server.revoke = { _ in 503 }
    XCTAssertFalse(later.revokeUnusedGrants())
    XCTAssertEqual(server.requests("/revoke").map { $0.form["token"] },
      Array(repeating: "invented-refresh-earlier", count: ChatGPTSession.revocationAttempts)
        + Array(repeating: "invented-refresh-1", count: ChatGPTSession.revocationAttempts))
    // Tried and reported once; it is not retried on every later call.
    XCTAssertFalse(later.overview().revocationPending)
    XCTAssertTrue(later.revokeUnusedGrants()); XCTAssertEqual(server.requests("/revoke").count, 2 * ChatGPTSession.revocationAttempts)
    // The queue never leaks a value through a description.
    let grant = ChatGPTUnusedGrant(refreshToken: "invented-refresh-1", clientID: FakeAccount.clientID)
    XCTAssertFalse(String(describing: grant).contains("invented")); XCTAssertFalse(String(reflecting: grant).contains("invented"))
  }

  func testRefusalsApplyOnlyToTheTokenTheyAreAbout() throws {
    let session = try signedIn()
    let old = try savedToken()
    approve(clientID: "oaiapp_second"); issue(planTokens("b"), subject: "invented-other-subject")
    try session.connectDifferentAccount()
    // Refusals of the account switched away from land after the switch: none applies to the new account.
    session.reportNotEligible(old); session.reportUsageLimited(old); session.reportNotAccepted(old); session.reportRequestRefused(old)
    let record = try XCTUnwrap(try store.load())
    XCTAssertFalse(record.notEligible); XCTAssertNil(record.pause); XCTAssertNil(record.refusedRequest)
    XCTAssertEqual(session.status(), .connected)
    // A refusal of the saved token applies.
    session.reportUsageLimited(try savedToken())
    XCTAssertEqual(session.status(), .usageLimited)
  }

  func testRefusedRequestStopsUntilAnotherBuildOrASignIn() throws {
    var now = FakeAccount.now
    approve(); issueTokens()
    let session = session(clock: { now })
    try session.connect()
    session.reportRequestRefused(try savedToken())
    XCTAssertEqual(session.status(), .requestRefused); XCTAssertTrue(session.signedInForPlanUse)
    XCTAssertThrowsError(try session.currentAccessToken()) { XCTAssertEqual($0 as? ChatGPTTokenError, .requestRefused) }
    // Sticky: no time ends it, unlike a pause.
    now += 30 * 24 * 3600
    XCTAssertEqual(session.status(), .requestRefused)
    XCTAssertThrowsError(try session.currentAccessToken())
    // A different build asks again.
    now = FakeAccount.now
    let rebuilt = self.session(clock: { now }, requestShape: "invented-build-2")
    XCTAssertEqual(rebuilt.status(), .connected)
    XCTAssertEqual(try rebuilt.currentAccessToken().value, "invented-access-1")
    // A new sign-in ends it as well.
    approve(clientID: nil); issueTokens(access: "invented-access-2", refresh: "invented-refresh-2")
    try session.connect()
    XCTAssertEqual(session.status(), .connected); XCTAssertNil(try store.load()?.refusedRequest)
    session.reportRequestRefused(try savedToken())
    XCTAssertTrue(session.signOut())
    XCTAssertNil(try store.load()?.refusedRequest)
  }

  func testSummaryRefusalDoesNotBlockADifferentConversationShape() throws {
    let session = try signedIn()
    let token = try savedToken()
    session.reportRequestRefused(token)
    XCTAssertThrowsError(try session.currentAccessToken())
    XCTAssertEqual(try session.currentAccessToken(requestShape: "invented-conversation-low").value, token.value)
    session.reportRequestRefused(token, requestShape: "invented-conversation-low")
    XCTAssertThrowsError(try session.currentAccessToken(requestShape: "invented-conversation-low")) {
      XCTAssertEqual($0 as? ChatGPTTokenError, .requestRefused)
    }
    XCTAssertEqual(try session.currentAccessToken(requestShape: "invented-conversation-medium").value, token.value)
    XCTAssertThrowsError(try session.currentAccessToken())
    let roundTrip = try JSONDecoder().decode(ChatGPTCredentialRecord.self, from: JSONEncoder().encode(try XCTUnwrap(store.load())))
    XCTAssertTrue(roundTrip.requestRefused("invented-conversation-low"))
    XCTAssertTrue(roundTrip.requestRefused("invented-build-1"))
  }

  @MainActor func testConversationRefusalIsShownWithoutPausingSummaries() async throws {
    let account = try signedIn()
    let shape = CodexConversationAgent.requestShape(.init(provider: .codex, model: "gpt-invented", reasoning: "low"))
    account.reportRequestRefused(try savedToken(), requestShape: shape)
    XCTAssertEqual(account.overview().status, .connected)
    XCTAssertTrue(account.overview().conversationRequestRefused)
    XCTAssertNoThrow(try account.currentAccessToken())
    XCTAssertThrowsError(try account.currentAccessToken(requestShape: shape))
    let storage = try ActivityStorage(url: root.appendingPathComponent("conversation-refused.sqlite"), appDataDirectory: root, databaseScope: .directory(root))
    let controller = try SettingsController(store: storage, connector: account, ownBundleID: "org.example.self", chatGPT: account)
    await controller.refreshChatGPTStatus()
    XCTAssertEqual(controller.chatGPT.status, .requestRefused)
    let rebuilt = session(requestShape: "invented-build-2")
    XCTAssertNoThrow(try rebuilt.currentAccessToken())
    XCTAssertNoThrow(try account.currentAccessToken(requestShape: shape + "-different"))
  }

  func testDifferentAccountWithoutPlanKeepsTheSavedAccount() throws {
    let session = try signedIn()
    let before = try XCTUnwrap(try store.load())
    approve(clientID: "oaiapp_second")
    issue(["access_token": "invented-access-np", "refresh_token": "invented-refresh-np", "scope": "openid profile email"],
      subject: "invented-other-subject")
    XCTAssertThrowsError(try session.connectDifferentAccount()) {
      XCTAssertEqual($0 as? ChatGPTSignInError, .differentAccountWithoutPlan)
    }
    var kept = try XCTUnwrap(try store.load())
    XCTAssertNil(kept.pendingRegistration)
    XCTAssertEqual(kept.unusedGrants, [ChatGPTUnusedGrant(refreshToken: "invented-refresh-np", clientID: "oaiapp_second")])
    kept.pendingRegistration = nil; kept.unusedGrants = []
    XCTAssertEqual(kept, before)
    XCTAssertEqual(session.status(), .connected)
    XCTAssertEqual(try session.currentAccessToken().value, "invented-access-1")
    // The new account's grant is not used, so it is revoked afterwards with its own client.
    XCTAssertTrue(server.requests("/revoke").isEmpty)
    XCTAssertTrue(session.revokeUnusedGrants())
    XCTAssertEqual(server.requests("/revoke").map(\.form), [["token": "invented-refresh-np", "token_type_hint": "refresh_token",
      "client_id": "oaiapp_second"]])
    // An unconfirmed revocation is reported, after the retries.
    server.revoke = { _ in 503 }
    approve(clientID: "oaiapp_third")
    XCTAssertThrowsError(try session.connectDifferentAccount())
    XCTAssertFalse(session.revokeUnusedGrants())
    XCTAssertEqual(server.requests("/revoke").count, 1 + ChatGPTSession.revocationAttempts)
  }

  func testDifferentAccountErrorAndAnAbandonedRegistrationLeadToTheSwitch() throws {
    // An abandoned first registration is bound to whichever account was picked in it.
    approve(); server.token = { _ in (400, ["error": "invalid_grant"]) }
    let session = session()
    XCTAssertThrowsError(try session.connect()) { XCTAssertEqual($0 as? ChatGPTSignInError, .exchangeFailed) }
    XCTAssertEqual(session.overview(), ChatGPTAccountOverview(status: .notConnected, registered: true))
    approve(clientID: nil); issue(planTokens("a"))
    try session.connect()
    approve(clientID: nil); issue(planTokens("x"), subject: "invented-other-subject")
    XCTAssertThrowsError(try session.connect()) { XCTAssertEqual($0 as? ChatGPTSignInError, .differentAccount) }
    approve(clientID: "oaiapp_second")
    try session.connectDifferentAccount()
    XCTAssertEqual(try store.load()?.registration, ChatGPTRegistration(clientID: "oaiapp_second", subject: "invented-other-subject"))
    XCTAssertEqual(session.status(), .connected)
  }

  // MARK: Rejected tokens, eligibility and the one-time confirmation

  func testRejectedTokenRefreshesOnceAndSignsOutOnlyOnATerminalError() throws {
    var saved = refreshable(expiresAt: FakeAccount.now + 3600)
    saved.tokens?.earliestRefreshAt = FakeAccount.now + 1800
    try store.save(saved)
    var rotation = 0
    server.token = { _ in
      rotation += 1
      return (200, ["access_token": "invented-access-r\(rotation)", "refresh_token": "invented-refresh-r\(rotation)",
        "expires_in": 3600, "scope": FakeAccount.allScopes])
    }
    let session = session()
    let first = try session.currentAccessToken()
    XCTAssertEqual(first, ChatGPTAccessToken("invented-old-access", validUntil: FakeAccount.now + 3600))
    XCTAssertTrue(server.requests("/api/accounts/oauth/token").isEmpty)
    // A rejected token is refreshed even before earliest_refresh_at.
    let renewed = try session.reportRejected(first)
    XCTAssertEqual(renewed, ChatGPTAccessToken("invented-access-r1", validUntil: FakeAccount.now + 3600))
    // Another caller holding the same rejected token gets the replacement without a second request.
    XCTAssertEqual(try self.session().reportRejected(first), renewed)
    XCTAssertEqual(server.requests("/api/accounts/oauth/token").count, 1)
    // A temporary failure keeps the credentials.
    server.token = { _ in (503, ["error": "temporarily_unavailable"]) }
    XCTAssertThrowsError(try session.reportRejected(renewed)) { XCTAssertEqual($0 as? ChatGPTTokenError, .temporarilyUnavailable) }
    XCTAssertEqual(try store.load()?.tokens?.refreshToken, "invented-refresh-r1")
    XCTAssertEqual(session.status(), .connected)
    // Only a terminal refresh error signs out, and the ID token stays for the next sign-in's hint.
    server.token = { _ in (400, ["error": "invalid_grant"]) }
    XCTAssertThrowsError(try session.reportRejected(renewed)) { XCTAssertEqual($0 as? ChatGPTTokenError, .signInAgain) }
    XCTAssertEqual(session.status(), .signInAgain)
    approve(clientID: nil); issueTokens()
    try session.connect()
    XCTAssertEqual(browser.lastOpened["id_token_hint"], "invented-id")
    XCTAssertNil(browser.lastOpened["prompt"])
  }

  func testNotEligibleSurvivesSignInButNotSignOut() throws {
    let session = try signedIn()
    session.reportNotEligible(try savedToken())
    XCTAssertEqual(session.status(), .unavailable)
    // Signing in again does not clear the refusal, so the app never loops through OAuth on it.
    approve(clientID: nil); issueTokens(access: "invented-access-2", refresh: "invented-refresh-2")
    try session.connect()
    XCTAssertNil(browser.lastOpened["prompt"])
    XCTAssertEqual(session.status(), .unavailable)
    XCTAssertThrowsError(try session.currentAccessToken()) { XCTAssertEqual($0 as? ChatGPTTokenError, .notAvailable) }
    XCTAssertTrue(session.signOut())
    approve(clientID: nil); issueTokens()
    try session.connect()
    XCTAssertEqual(session.status(), .connected)
  }

  func testUsageLimitAndRefusalPauseRequestsWithoutSigningOut() throws {
    var now = FakeAccount.now
    approve(); issueTokens()
    let session = session(clock: { now })
    try session.connect()
    XCTAssertTrue(session.signedInForPlanUse)
    session.reportUsageLimited(try savedToken())
    XCTAssertEqual(session.status(), .usageLimited); XCTAssertTrue(session.signedInForPlanUse)
    XCTAssertThrowsError(try session.currentAccessToken()) { XCTAssertEqual($0 as? ChatGPTTokenError, .usageLimited) }
    XCTAssertNotNil(try store.load()?.tokens)
    // The pause ends on its own; no reset time is inferred, the next request simply asks again.
    now += ChatGPTSession.pauseSeconds
    XCTAssertEqual(session.status(), .connected)
    XCTAssertEqual(try session.currentAccessToken().value, "invented-access-1")
    session.reportNotAccepted(try savedToken())
    XCTAssertEqual(session.status(), .notAccepted)
    XCTAssertThrowsError(try session.currentAccessToken()) { XCTAssertEqual($0 as? ChatGPTTokenError, .notAccepted) }
    XCTAssertEqual(server.requests("/api/accounts/oauth/token").count, 1)
    // Signing in again ends a refusal pause at once.
    approve(clientID: nil); issueTokens(access: "invented-access-2", refresh: "invented-refresh-2")
    try session.connect()
    XCTAssertEqual(session.status(), .connected)
    XCTAssertEqual(try session.currentAccessToken().value, "invented-access-2")
    // Without a sign-in nothing is paused, and sign-out clears a pause.
    let last = try savedToken()
    session.reportUsageLimited(last)
    XCTAssertTrue(session.signOut())
    XCTAssertNil(try store.load()?.pause); XCTAssertFalse(session.signedInForPlanUse)
    session.reportUsageLimited(last)
    XCTAssertNil(try store.load()?.pause)
  }

  func testPlanConfirmationIsPendingOnlyUntilDismissedOnce() throws {
    approve(); issue(["access_token": "invented-access-1", "scope": "openid profile email"])
    let session = session()
    XCTAssertThrowsError(try session.connect())
    XCTAssertEqual(session.overview(), ChatGPTAccountOverview(status: .planRequired, registered: true))
    approve(clientID: nil); issueTokens()
    try session.connect()
    XCTAssertEqual(session.overview(), ChatGPTAccountOverview(status: .connected, registered: true, planWelcomePending: true))
    session.acknowledgePlanWelcome()
    XCTAssertFalse(session.overview().planWelcomePending)
    XCTAssertTrue(session.signOut())
    XCTAssertEqual(session.overview(), ChatGPTAccountOverview(status: .notConnected, registered: true))
    approve(clientID: nil); issueTokens()
    try session.connect()
    XCTAssertEqual(session.overview(), ChatGPTAccountOverview(status: .connected, registered: true))
    XCTAssertEqual(ChatGPTSession(store: store, lock: ChatGPTCredentialLock(file: nil), openBrowser: { _ in false }).overview().status, .connected)
  }

  // MARK: Sign-out and the listener

  func testSignOutRetriesDiscoveryWithTheSameBackoff() throws {
    let session = try signedIn()
    server.discoveryFailures = 2
    XCTAssertTrue(session.signOut())
    XCTAssertEqual(backoffs, [0, 1])
    XCTAssertEqual(server.requests("/revoke").count, 1)
    XCTAssertNil(try store.load()?.tokens); XCTAssertNil(try store.load()?.idToken)
    approve(clientID: nil); issueTokens()
    try session.connect()
    backoffs = []; server.discoveryFailures = 5
    let discoveries = server.requests("/.well-known/openid-configuration").count
    XCTAssertFalse(session.signOut())
    XCTAssertEqual(server.requests("/.well-known/openid-configuration").count - discoveries, ChatGPTSession.revocationAttempts)
    XCTAssertEqual(backoffs, [0, 1])
    XCTAssertNil(try store.load()?.tokens)
  }

  func testIdleConnectionsDoNotHoldUpTheCallback() throws {
    let listener = try ChatGPTLoopbackListener(preferredPort: 0)
    // Connections that never send a request, like a browser's preconnect, are already queued.
    let idle = (0..<3).map { _ in Self.connect(port: listener.port) }
    defer { idle.forEach { Darwin.close($0) } }
    XCTAssertTrue(idle.allSatisfy { $0 >= 0 })
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
      URLSession(configuration: .ephemeral).dataTask(with: URL(string: listener.redirectURI + "?state=s&code=c")!).resume()
    }
    let started = Date()
    let query = try listener.waitForCallback(until: ProcessInfo.processInfo.systemUptime + 15, cancelled: { false }) { _ in (200, "", true) }
    XCTAssertEqual(query["code"], "c")
    XCTAssertLessThan(Date().timeIntervalSince(started), 3)
  }
  static func connect(port: UInt16) -> Int32 {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    if result != 0 { Darwin.close(descriptor); return -1 }
    return descriptor
  }

  // MARK: Codex row

  @MainActor func testCodexRowSaysSummariesArePausedUntilChatGPTSignIn() throws {
    func row(consented: Bool, _ status: ChatGPTConnectionStatus, registered: Bool = false, problem: Bool = false,
      connecting: Bool = false) -> ChatGPTRow {
      var summary = SummaryHealth(); summary.subscriptionConnected = consented; summary.localPreparationFailed = problem
      let model = SettingsViewModel(settings: StorageSettings(subscriptionConnected: consented), health: TimelineHealth(summary: summary),
        ownBundleID: "org.example.self", now: 100)
      return ChatGPTRow(model: model, overview: ChatGPTAccountOverview(status: status, registered: registered), isConnecting: connecting)
    }
    // Consent is on but ChatGPT is not signed in: summaries no longer have an earlier connection to run on.
    let paused = row(consented: true, .notConnected)
    XCTAssertEqual(paused.headline, .notConnected); XCTAssertEqual(paused.notes, [.pausedUntilSignIn])
    XCTAssertTrue(paused.offersContinue); XCTAssertTrue(paused.offersSignOut); XCTAssertFalse(paused.showsProblem)
    for status in [ChatGPTConnectionStatus.notConnected, .planRequired, .signInAgain] {
      let state = row(consented: true, status, registered: true)
      XCTAssertEqual(state.headline, ChatGPTRow.label(status)); XCTAssertEqual(state.notes, [.pausedUntilSignIn])
      XCTAssertTrue(state.offersContinue)
    }
    let problem = row(consented: true, .signInAgain, registered: true, problem: true)
    XCTAssertEqual(problem.headline, .signInAgain)
    XCTAssertTrue(problem.showsProblem); XCTAssertTrue(problem.offersContinue); XCTAssertTrue(problem.offersDifferentAccount)
    XCTAssertTrue(row(consented: true, .connected, problem: true).showsProblem)
    // A usage limit pauses summaries; signing in again cannot change it, usage settings can.
    let limited = row(consented: true, .usageLimited, registered: true)
    XCTAssertEqual(limited.headline, .usageLimited); XCTAssertEqual(limited.notes, [.usageLimitedNote])
    XCTAssertFalse(limited.offersContinue); XCTAssertTrue(limited.offersManageUsage); XCTAssertTrue(limited.offersSignOut)
    // Requests not accepted: summaries pause and retry later; signing in again is offered.
    let refused = row(consented: true, .notAccepted, registered: true)
    XCTAssertEqual(refused.headline, .notAccepted); XCTAssertEqual(refused.notes, [.notAcceptedNote])
    XCTAssertTrue(refused.offersContinue); XCTAssertFalse(refused.offersManageUsage)
    XCTAssertEqual(row(consented: false, .usageLimited).notes, [.usageLimitedNote, .summariesOff])
    // ChatGPT refused the request this build sends: it says so, and neither signing in nor usage settings is offered.
    for consented in [true, false] {
      let rejected = row(consented: consented, .requestRefused, registered: true)
      XCTAssertEqual(rejected.headline, .requestRefused)
      XCTAssertEqual(rejected.notes, consented ? [.requestRefusedNote] : [.requestRefusedNote, .summariesOff])
      XCTAssertFalse(rejected.notes.contains(.pausedUntilSignIn)); XCTAssertFalse(rejected.notes.contains(.notAcceptedNote))
      XCTAssertFalse(rejected.offersContinue); XCTAssertFalse(rejected.offersManageUsage)
      XCTAssertTrue(rejected.offersSignOut); XCTAssertTrue(rejected.offersDifferentAccount)
    }
    // Signed in but summaries off (a cancel after the last request, or a superseded completion).
    let off = row(consented: false, .connected, registered: true)
    XCTAssertEqual(off.headline, .connected); XCTAssertEqual(off.notes, [.summariesOff])
    XCTAssertTrue(off.offersContinue); XCTAssertTrue(off.offersManageUsage); XCTAssertTrue(off.offersSignOut)
    let on = row(consented: true, .connected, registered: true)
    XCTAssertEqual(on.headline, .connected); XCTAssertEqual(on.notes, [])
    XCTAssertFalse(on.offersContinue); XCTAssertTrue(on.offersManageUsage); XCTAssertTrue(on.offersDifferentAccount)
    // Not available: signing in again cannot help, so it is not offered; switching or signing out is.
    let unavailable = row(consented: false, .unavailable, registered: true)
    XCTAssertEqual(unavailable.headline, .unavailable); XCTAssertEqual(unavailable.notes, [.unavailableNote])
    XCTAssertFalse(unavailable.offersContinue); XCTAssertTrue(unavailable.offersDifferentAccount)
    XCTAssertTrue(unavailable.offersSignOut); XCTAssertFalse(unavailable.offersManageUsage)
    let fresh = row(consented: false, .notConnected)
    XCTAssertEqual(fresh.headline, .notConnected); XCTAssertTrue(fresh.offersContinue)
    XCTAssertFalse(fresh.offersDifferentAccount); XCTAssertFalse(fresh.offersSignOut)
    let waiting = row(consented: false, .planRequired, registered: true, connecting: true)
    XCTAssertFalse(waiting.offersContinue || waiting.offersDifferentAccount || waiting.offersSignOut)
    let strings = SettingsStrings(language: "en", resources: nil)
    XCTAssertGreaterThan(try XCTUnwrap(SettingsOffscreenRender.planWelcomePNG(strings: strings, dark: false)).count, 1000)
    XCTAssertEqual(AppPaths.chatGPTUsageSettings.absoluteString, "https://chatgpt.com/settings/usage")
  }

  @MainActor func testSettingsSwitchesAccountAndShowsThePlanConfirmationOnce() async throws {
    let account = FakeChatGPTAccount()
    let storage = try ActivityStorage(url: root.appendingPathComponent("settings.sqlite"), appDataDirectory: root, databaseScope: .directory(root))
    let controller = try SettingsController(store: storage, connector: account, ownBundleID: "org.example.self", chatGPT: account)
    account.result = .failure(ChatGPTSignInError.declined)
    await controller.connectDifferentAccount()
    XCTAssertEqual(controller.error, .chatGPTDeclined); XCTAssertFalse(controller.settings.subscriptionConnected)
    account.result = .success(()); account.current = .connected; account.registered = true; account.welcomePending = true
    await controller.connectDifferentAccount()
    XCTAssertEqual(account.differentAccountSignIns, 2)
    XCTAssertNil(controller.error); XCTAssertTrue(controller.settings.subscriptionConnected)
    await controller.refreshChatGPTStatus()
    XCTAssertTrue(controller.showsPlanWelcome)
    XCTAssertEqual(controller.chatGPT, ChatGPTAccountOverview(status: .connected, registered: true, planWelcomePending: true))
    await controller.acknowledgePlanWelcome()
    XCTAssertFalse(controller.showsPlanWelcome); XCTAssertEqual(account.acknowledged, 1)
    await controller.refreshChatGPTStatus()
    XCTAssertFalse(controller.showsPlanWelcome)
  }

  @MainActor func testFailedSwitchRestoresSummariesAndReportsUnconfirmedRevocation() async throws {
    let account = FakeChatGPTAccount(); account.current = .connected; account.registered = true
    let storage = try ActivityStorage(url: root.appendingPathComponent("switch.sqlite"), appDataDirectory: root, databaseScope: .directory(root))
    let controller = try SettingsController(store: storage, connector: account, ownBundleID: "org.example.self", chatGPT: account)
    await controller.connect()
    XCTAssertTrue(controller.settings.subscriptionConnected)
    // A failed switch leaves the saved account, so summaries come back on.
    account.result = .failure(ChatGPTSignInError.declined)
    await controller.connectDifferentAccount()
    XCTAssertEqual(controller.error, .chatGPTDeclined); XCTAssertTrue(controller.settings.subscriptionConnected)
    XCTAssertEqual(account.revocations, 1)
    // A cancelled switch too.
    account.during = { Task { @MainActor in controller.cancelConnection() } }
    account.result = .failure(ChatGPTSignInError.cancelled)
    await controller.connectDifferentAccount()
    XCTAssertEqual(controller.error, .cancelled); XCTAssertTrue(controller.settings.subscriptionConnected)
    // A new account without plan use: the saved one is kept; an unconfirmed revocation of the unused grant is said.
    account.during = nil; account.unusedConfirmed = false
    account.result = .failure(ChatGPTSignInError.differentAccountWithoutPlan)
    await controller.connectDifferentAccount()
    XCTAssertEqual(controller.error, .chatGPTDifferentAccountWithoutPlanUnconfirmed); XCTAssertTrue(controller.settings.subscriptionConnected)
    // A switch that returned replaced the account: a late Cancel is not reported, and the old grant's result is.
    account.result = .success(())
    account.during = { DispatchQueue.main.sync { MainActor.assumeIsolated { controller.cancelConnection() } } }
    await controller.connectDifferentAccount()
    XCTAssertEqual(controller.error, .chatGPTUnusedRevocationUnconfirmed); XCTAssertTrue(controller.settings.subscriptionConnected)
    account.during = nil; account.unusedConfirmed = true
    await controller.connectDifferentAccount()
    XCTAssertNil(controller.error); XCTAssertEqual(account.revocations, 5)
    // With summaries off before, a failed switch leaves them off; a disconnect during an attempt is not undone.
    controller.disconnect()
    account.result = .failure(ChatGPTSignInError.declined)
    await controller.connectDifferentAccount()
    XCTAssertFalse(controller.settings.subscriptionConnected)
    await controller.connect()
    account.during = { DispatchQueue.main.sync { MainActor.assumeIsolated { controller.disconnect() } } }
    await controller.connectDifferentAccount()
    XCTAssertFalse(controller.settings.subscriptionConnected)
  }

  @MainActor func testGrantsLeftByAQuitAreRevokedWhenTheStatusIsRead() async throws {
    let account = FakeChatGPTAccount(); account.current = .connected; account.registered = true
    account.revocationPending = true; account.unusedConfirmed = false
    let storage = try ActivityStorage(url: root.appendingPathComponent("later.sqlite"), appDataDirectory: root, databaseScope: .directory(root))
    let controller = try SettingsController(store: storage, connector: account, ownBundleID: "org.example.self", chatGPT: account)
    await controller.refreshChatGPTStatus()
    let deadline = Date().addingTimeInterval(5)
    while account.revocations == 0 || controller.error == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertEqual(account.revocations, 1)
    XCTAssertEqual(controller.error, .chatGPTUnusedRevocationUnconfirmed); XCTAssertEqual(controller.errorSection, .subscription)
    // Nothing queued: nothing is revoked.
    await controller.refreshChatGPTStatus()
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(account.revocations, 1)
  }

  func testTimelineStatusIsReadAtMostOncePerInterval() {
    let account = FakeChatGPTAccount(); account.current = .usageLimited
    var now: TimeInterval = 0
    final class Counting: ChatGPTAccount {
      let inner: FakeChatGPTAccount; var reads = 0
      init(_ inner: FakeChatGPTAccount) { self.inner = inner }
      func connect() throws {}
      func cancel() {}
      func connectDifferentAccount() throws {}
      func revokeUnusedGrants() -> Bool { true }
      func acknowledgePlanWelcome() {}
      func signOut() -> Bool { true }
      func overview() -> ChatGPTAccountOverview { reads += 1; return inner.overview() }
    }
    let counting = Counting(account)
    let reader = ChatGPTStatusReader(account: counting, clock: { now })
    XCTAssertEqual(reader.status(), .usageLimited)
    account.current = .connected
    now += ChatGPTStatusReader.interval - 1
    XCTAssertEqual(reader.status(), .usageLimited); XCTAssertEqual(counting.reads, 1)
    now += 1
    XCTAssertEqual(reader.status(), .connected); XCTAssertEqual(counting.reads, 2)
  }
}

extension ChatGPTSignInTests {
  func testUnclassifiedRequestRefusalsRetryAfterTimedPause() throws {
    final class HTTP: ChatGPTStreamingHTTP {
      var status = 400
      var calls = 0
      func stream(_ request: URLRequest, deadline: TimeInterval, limit: Int) throws -> ChatGPTStreamedResponse {
        calls += 1
        return ChatGPTStreamedResponse(status: status, requestID: "invented-request", body: Data("{\"detail\":\"invented\"}".utf8))
      }
    }
    var now = FakeAccount.now
    approve(); issueTokens()
    let session = session(clock: { now }); try session.connect()
    var record = try XCTUnwrap(try store.load()); record.tokens?.expiresAt = now + 100000; try store.save(record)
    let http = HTTP()
    let caller = ChatGPTSummaryCaller(tokens: session, attemptLog: root.appendingPathComponent("invented-attempts"),
      configuration: .loopbackTest(url: URL(string: "http://127.0.0.1:1/v1/responses")!), makeHTTP: { http }, clock: { TimeInterval(now) })
    for status in [400, 404, 422] {
      http.status = status
      XCTAssertThrowsError(try caller.call("Invented prompt"))
      XCTAssertEqual(session.status(), .notAccepted); XCTAssertNil(try store.load()?.refusedRequest)
      let before = http.calls
      XCTAssertThrowsError(try caller.call("Invented prompt")); XCTAssertEqual(http.calls, before)
      now += ChatGPTSession.pauseSeconds
      XCTAssertEqual(session.status(), .connected)
      XCTAssertThrowsError(try caller.call("Another invented prompt")); XCTAssertEqual(http.calls, before + 1)
      now += ChatGPTSession.pauseSeconds
    }
  }
}
