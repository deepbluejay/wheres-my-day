import Foundation

/// What the settings row shows. Never carries an email, subject or token.
/// `planRequired` means plan permission was not granted at sign-in; `unavailable` means a request was
/// refused because plan use is not available for this account, workspace or policy. `usageLimited` and
/// `notAccepted` are pauses of a signed-in account after a refused request; they end on their own.
/// `requestRefused` means ChatGPT refused the request this build sends; it ends with a different build.
public enum ChatGPTConnectionStatus: String, CaseIterable, Equatable {
  case notConnected, connected, planRequired, unavailable, signInAgain, usageLimited, notAccepted, requestRefused
  /// Signed in with plan permission. A pause still counts: the account is kept and requests resume later.
  public var signedInForPlanUse: Bool { [.connected, .usageLimited, .notAccepted, .requestRefused].contains(self) }
}

/// Sign-in failures. Cases carry no server text, so a description can never leak a value.
public enum ChatGPTSignInError: Error, Equatable, CaseIterable {
  case cancelled, timedOut, declined, registrationIncomplete, clientMismatch
  case differentAccount, invalidIDToken, planRequired, exchangeFailed, network, listener, browser, storage
  /// A different account signed in without plan permission; the saved account was kept.
  case differentAccountWithoutPlan
}

/// Failures of the token port. Callers stop requests on every case.
/// `usageLimited` and `notAccepted` are pauses after a refused request; requests are allowed again later.
/// `requestRefused` lasts until a different build, a new sign-in or sign-out.
public enum ChatGPTTokenError: Error, Equatable {
  case notSignedIn, planRequired, notAvailable, signInAgain, temporarilyUnavailable, storage, usageLimited, notAccepted
  case requestRefused
}

/// An access token that prints as redacted, so interpolation or a dump never writes the value.
public struct ChatGPTAccessToken: Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
  public let value: String
  /// Unix seconds after which the token is expired. A caller that holds the token (for example a
  /// long-running app-server) asks for a renewed one before this time.
  public let validUntil: Int
  public init(_ value: String, validUntil: Int) { self.value = value; self.validUntil = validUntil }
  public var description: String { "ChatGPTAccessToken(redacted)" }
  public var debugDescription: String { description }
  public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// The port summaries and conversations use. Implementations refresh near expiry and serialize refreshes.
///
/// Every call can block: it takes a cross-process lock and may make one refresh request under it,
/// for up to the request timeout. Call it off the main thread.
public protocol ChatGPTAccessTokens: AnyObject {
  /// Signed in with plan permission, without a refresh or a request. Paused accounts count as signed in.
  /// Reads the saved record, so it can block on the Keychain; call it off the main thread.
  var signedInForPlanUse: Bool { get }
  /// Returns a token valid for at least a few minutes, refreshing first when needed.
  /// Never returns a token without ChatGPT plan permission, and none while plan use is paused.
  func currentAccessToken() throws -> ChatGPTAccessToken
  /// A request with `token` was rejected as unauthorized (for example a 401). Refreshes once and returns
  /// the renewed token; when another caller already replaced it, returns the replacement without a
  /// second request. Signs out only on a terminal refresh error; a temporary failure keeps the
  /// credentials and throws `temporarilyUnavailable`. If the renewed token is rejected too, stop
  /// the request and show the error instead of calling this again.
  func reportRejected(_ token: ChatGPTAccessToken) throws -> ChatGPTAccessToken
  /// The refusal reports below name the token the refused request carried. Each is applied only while that
  /// token is still the saved one, so a refusal of an account that was switched away from meanwhile is ignored.
  ///
  /// A request was refused because plan use is not available for this account, workspace or policy
  /// (`subscription_sharing_user_not_eligible`). Requests stop; signing in again does not clear it.
  func reportNotEligible(_ token: ChatGPTAccessToken)
  /// A request was refused for a usage limit (`subscription_sharing_usage_limit_exceeded` or another 429).
  /// New requests pause for a while; the docs give no reset time, so the pause is not one.
  func reportUsageLimited(_ token: ChatGPTAccessToken)
  /// A request was refused as unauthorized again after `reportRejected` already renewed the token, or for
  /// another permission reason. New requests pause for a while; the credentials are kept, because the docs
  /// ask for a new sign-in only after a confirmed revocation.
  func reportNotAccepted(_ token: ChatGPTAccessToken)
  /// The request itself was refused (a 400 or another request error), so sending the same request again
  /// cannot help (docs: do not retry the same invalid body). Requests stop until a different build,
  /// a new sign-in, a switch or sign-out.
  func reportRequestRefused(_ token: ChatGPTAccessToken)
  /// Only for a confirmed terminal case: revocation was confirmed, or the server confirmed the session
  /// is gone after `reportRejected` already refreshed. Never for a single rejected request or a
  /// temporary failure. Clears the token set; the person must sign in again.
  func reportSignInRequired()
  /// Invalid-request refusals are scoped to the caller's request shape, not every use of the account.
  func currentAccessToken(requestShape: String) throws -> ChatGPTAccessToken
  func reportRejected(_ token: ChatGPTAccessToken, requestShape: String) throws -> ChatGPTAccessToken
  func reportRequestRefused(_ token: ChatGPTAccessToken, requestShape: String)
}

public extension ChatGPTAccessTokens {
  func currentAccessToken(requestShape: String) throws -> ChatGPTAccessToken { try currentAccessToken() }
  func reportRejected(_ token: ChatGPTAccessToken, requestShape: String) throws -> ChatGPTAccessToken { try reportRejected(token) }
  func reportRequestRefused(_ token: ChatGPTAccessToken, requestShape: String) { reportRequestRefused(token) }
}

/// What the settings row needs about the account. Holds no email, subject or token.
public struct ChatGPTAccountOverview: Equatable {
  public var status: ChatGPTConnectionStatus
  /// A ChatGPT account registration exists on this Mac, so "use a different account" applies.
  public var registered: Bool
  /// Plan use was just enabled for the first time and the one-time confirmation has not been dismissed.
  public var planWelcomePending: Bool
  /// A switch left grants that are not revoked yet, for example after a quit during the revocation.
  public var revocationPending: Bool
  /// A conversation request from this build was refused. Summaries can still be available.
  public var conversationRequestRefused: Bool
  public init(status: ChatGPTConnectionStatus = .notConnected, registered: Bool = false, planWelcomePending: Bool = false,
    revocationPending: Bool = false, conversationRequestRefused: Bool = false) {
    self.status = status; self.registered = registered; self.planWelcomePending = planWelcomePending
    self.revocationPending = revocationPending
    self.conversationRequestRefused = conversationRequestRefused
  }
}

/// The settings row's account: sign-in is the connector's connect(), the person's own click.
public protocol ChatGPTAccount: SubscriptionConnector {
  func overview() -> ChatGPTAccountOverview
  /// Signs in to another ChatGPT account with a fresh registration. The saved account is replaced only
  /// after the new account's identity is validated and it grants plan use. Every thrown error means the
  /// saved account is unchanged; a normal return means it was replaced.
  func connectDifferentAccount() throws
  /// Revokes the grants a switch left unused: the replaced account's, or a new account's that was not kept.
  /// They are queued in the saved record, so a grant left by a quit or crash is revoked by a later call.
  /// Blocks on the network with retries, so run it in the background after the switch returns.
  /// Each grant is tried once per call and then dropped. Returns false when a revocation could not be confirmed.
  func revokeUnusedGrants() -> Bool
  /// The person dismissed the one-time "using your ChatGPT plan" confirmation.
  func acknowledgePlanWelcome()
  /// Stops use, attempts remote revocation, then clears tokens. Returns whether revocation was confirmed.
  func signOut() -> Bool
}

public extension ChatGPTAccount {
  func status() -> ChatGPTConnectionStatus { overview().status }
}
