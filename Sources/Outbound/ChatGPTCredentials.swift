import Core
import Darwin
import Foundation
import Security

/// The account's issued client and its validated subject. Kept after sign-out for a later sign-in.
public struct ChatGPTRegistration: Codable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
  public var clientID: String
  public var subject: String?
  public var description: String { "ChatGPTRegistration(redacted)" }
  public var debugDescription: String { description }
  public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// One usable token set. Replaced as a whole after an exchange or a refresh.
/// Prints as redacted: a dump, interpolation or failed assertion never writes a token.
public struct ChatGPTTokenSet: Codable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
  public var accessToken: String
  public var refreshToken: String
  public var tokenType: String
  public var expiresAt: Int
  public var scopes: [String]
  public var earliestRefreshAt: Int?
  public var savedAt: Int
  public var planGranted: Bool { scopes.contains(ChatGPTOAuthConfiguration.planScope) }
  public var description: String { "ChatGPTTokenSet(redacted)" }
  public var debugDescription: String { description }
  public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// A grant a switch left unused, waiting for revocation. Kept in the record, so a quit or crash between the
/// replacing save and the revocation still revokes it later.
public struct ChatGPTUnusedGrant: Codable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
  public var refreshToken: String
  public var clientID: String
  public var description: String { "ChatGPTUnusedGrant(redacted)" }
  public var debugDescription: String { description }
  public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// No email is kept: the row says only "connected", and the docs make `login_hint` optional.
public struct ChatGPTCredentialRecord: Codable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
  public var registration: ChatGPTRegistration?
  /// Kept apart from the token set so a later sign-in can send `id_token_hint` even after a terminal
  /// refresh failure (the hint may be expired; it identifies the account). Cleared on sign-out.
  public var idToken: String?
  public var tokens: ChatGPTTokenSet?
  /// A validated sign-in without plan permission. The sign-in is kept; plan use stays off.
  public var planDeclined = false
  /// A request was refused as not eligible. Survives a new sign-in of the same account, so the app
  /// never loops through OAuth on the same refusal; cleared on sign-out or switching accounts.
  public var notEligible = false
  public var signInRequired = false
  /// The one-time "using your ChatGPT plan" confirmation was dismissed on this Mac.
  public var planWelcomeShown = false
  /// The client issued to a different-account attempt whose exchange did not finish. Kept apart from the
  /// saved account so a retry of that account reuses it instead of registering the app again; it never signs
  /// anything in. Its subject is known once an identity was validated under it.
  public var pendingRegistration: ChatGPTRegistration?
  /// Grants a switch left unused; see `ChatGPTUnusedGrant`.
  public var unusedGrants: [ChatGPTUnusedGrant] = []
  /// ChatGPT refused this build's request itself (a 400 or another request error), so sending it again cannot
  /// help. Holds the build's request fingerprint: a different build, a sign-in, a switch or sign-out ends it.
  public var refusedRequest: String?
  /// Conversation refusals are independent of the summary request and of other model/effort choices.
  public var refusedConversationRequests: [String] = []
  /// New plan requests wait until this Unix time after a refused request; see `pause`.
  public var pausedUntil: Int?
  public var pause: ChatGPTPause?
  public init() {}
  enum CodingKeys: String, CodingKey {
    case registration, idToken, tokens, planDeclined, notEligible, signInRequired, planWelcomeShown
    case pendingRegistration, pausedUntil, pause, unusedGrants, refusedRequest, refusedConversationRequests
  }
  /// Missing fields take their defaults, so an item saved by an earlier build still loads.
  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    registration = try values.decodeIfPresent(ChatGPTRegistration.self, forKey: .registration)
    idToken = try values.decodeIfPresent(String.self, forKey: .idToken)
    tokens = try values.decodeIfPresent(ChatGPTTokenSet.self, forKey: .tokens)
    planDeclined = try values.decodeIfPresent(Bool.self, forKey: .planDeclined) ?? false
    notEligible = try values.decodeIfPresent(Bool.self, forKey: .notEligible) ?? false
    signInRequired = try values.decodeIfPresent(Bool.self, forKey: .signInRequired) ?? false
    planWelcomeShown = try values.decodeIfPresent(Bool.self, forKey: .planWelcomeShown) ?? false
    pendingRegistration = try values.decodeIfPresent(ChatGPTRegistration.self, forKey: .pendingRegistration)
    pausedUntil = try values.decodeIfPresent(Int.self, forKey: .pausedUntil)
    pause = try values.decodeIfPresent(ChatGPTPause.self, forKey: .pause)
    unusedGrants = try values.decodeIfPresent([ChatGPTUnusedGrant].self, forKey: .unusedGrants) ?? []
    refusedRequest = try values.decodeIfPresent(String.self, forKey: .refusedRequest)
    refusedConversationRequests = try values.decodeIfPresent([String].self, forKey: .refusedConversationRequests) ?? []
  }
  /// The status without a pause.
  public var status: ChatGPTConnectionStatus {
    if let tokens { return !tokens.planGranted ? .planRequired : notEligible ? .unavailable : .connected }
    if planDeclined { return .planRequired }
    return signInRequired ? .signInAgain : .notConnected
  }
  /// The pause that is still running at `now`, if any.
  public func activePause(at now: Int) -> ChatGPTPause? {
    guard let pause, let pausedUntil, now < pausedUntil else { return nil }
    return pause
  }
  /// Whether this build's request was refused; `requestShape` is the running build's fingerprint.
  public func requestRefused(_ requestShape: String) -> Bool {
    refusedRequest == requestShape || refusedConversationRequests.contains(requestShape)
  }
  public func status(at now: Int, requestShape: String) -> ChatGPTConnectionStatus {
    let base = status
    guard base == .connected else { return base }
    if requestRefused(requestShape) { return .requestRefused }
    guard let pause = activePause(at: now) else { return base }
    return pause == .usageLimited ? .usageLimited : .notAccepted
  }
  public var description: String { "ChatGPTCredentialRecord(redacted)" }
  public var debugDescription: String { description }
  public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Why new plan requests are paused. Neither reason clears the credentials.
public enum ChatGPTPause: String, Codable, Equatable { case usageLimited, notAccepted }

public protocol ChatGPTCredentialStore: AnyObject {
  func load() throws -> ChatGPTCredentialRecord?
  func save(_ record: ChatGPTCredentialRecord) throws
  /// This host's opaque identifier, created once before the first sign-in and kept for the host's life.
  func hostID() throws -> String
}

public final class InMemoryChatGPTCredentialStore: ChatGPTCredentialStore {
  private let lock = NSLock()
  private var record: ChatGPTCredentialRecord?
  private var host: String?
  public private(set) var saves = 0
  public var failSaves = false
  public init(record: ChatGPTCredentialRecord? = nil, hostID: String? = nil) { self.record = record; host = hostID }
  public func load() throws -> ChatGPTCredentialRecord? { lock.lock(); defer { lock.unlock() }; return record }
  public func save(_ record: ChatGPTCredentialRecord) throws {
    lock.lock(); defer { lock.unlock() }
    if failSaves { throw ChatGPTTokenError.storage }
    self.record = record; saves += 1
  }
  public func hostID() throws -> String {
    lock.lock(); defer { lock.unlock() }
    if let host { return host }
    let created = ChatGPTHostID.make(); host = created; return created
  }
}

enum ChatGPTHostID {
  /// A UUIDv4 URN, one of the docs' accepted formats. Opaque: derived from nothing about the person.
  static func make() -> String { "urn:uuid:" + UUID().uuidString.lowercased() }
}

/// The Security calls the Keychain store makes. Tests inject recorders; the real calls refuse to run under XCTest.
public struct KeychainCalls {
  public var copy: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
  public var add: (CFDictionary) -> OSStatus
  public var update: (CFDictionary, CFDictionary) -> OSStatus
  public var delete: (CFDictionary) -> OSStatus
  public init(copy: @escaping (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus, add: @escaping (CFDictionary) -> OSStatus,
    update: @escaping (CFDictionary, CFDictionary) -> OSStatus, delete: @escaping (CFDictionary) -> OSStatus) {
    self.copy = copy; self.add = add; self.update = update; self.delete = delete
  }
  /// The test runner never reaches the person's real Keychain.
  public static let system = KeychainCalls(
    copy: { TestPathGuard.active ? errSecNotAvailable : SecItemCopyMatching($0, $1) },
    add: { TestPathGuard.active ? errSecNotAvailable : SecItemAdd($0, nil) },
    update: { TestPathGuard.active ? errSecNotAvailable : SecItemUpdate($0, $1) },
    delete: { TestPathGuard.active ? errSecNotAvailable : SecItemDelete($0) })
}

/// Generic-password items under the app's own service, on this Mac only (never synchronized).
public final class KeychainChatGPTCredentialStore: ChatGPTCredentialStore {
  static let credentialAccount = "chatgpt-credential"
  static let hostAccount = "chatgpt-host-id"
  public let service: String
  private let calls: KeychainCalls
  public init(service: String, calls: KeychainCalls = .system) { self.service = service; self.calls = calls }
  public func load() throws -> ChatGPTCredentialRecord? {
    guard let data = try read(Self.credentialAccount) else { return nil }
    guard let record = try? JSONDecoder().decode(ChatGPTCredentialRecord.self, from: data) else { throw ChatGPTTokenError.storage }
    return record
  }
  public func save(_ record: ChatGPTCredentialRecord) throws {
    try write(Self.credentialAccount, try JSONEncoder().encode(record))
  }
  public func hostID() throws -> String {
    if let data = try read(Self.hostAccount), let value = String(data: data, encoding: .utf8), !value.isEmpty { return value }
    let created = ChatGPTHostID.make()
    try write(Self.hostAccount, Data(created.utf8))
    return created
  }
  func base(_ account: String) -> [CFString: Any] {
    [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
      kSecAttrSynchronizable: kCFBooleanFalse as Any]
  }
  private func read(_ account: String) throws -> Data? {
    var query = base(account)
    query[kSecReturnData] = kCFBooleanTrue; query[kSecMatchLimit] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = calls.copy(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else { throw ChatGPTTokenError.storage }
    return data
  }
  private func write(_ account: String, _ data: Data) throws {
    let update: [CFString: Any] = [kSecValueData: data]
    var status = calls.update(base(account) as CFDictionary, update as CFDictionary)
    if status == errSecItemNotFound {
      var item = base(account)
      item[kSecValueData] = data
      item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      item[kSecAttrLabel] = "ActivityProbe ChatGPT sign-in"
      status = calls.add(item as CFDictionary)
    }
    guard status == errSecSuccess else { throw ChatGPTTokenError.storage }
  }
}

/// Serializes every credential write across processes (the window and the recorder are separate
/// processes), so two refreshes never race a rotating refresh token. The file holds no data.
public final class ChatGPTCredentialLock {
  private let path: String?
  private let local = NSLock()
  public init(file: URL?) { path = file?.path }
  func withLock<T>(_ body: () throws -> T) throws -> T {
    local.lock(); defer { local.unlock() }
    guard let path else { return try body() }
    let descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { throw ChatGPTTokenError.storage }
    defer { close(descriptor) }
    guard flock(descriptor, LOCK_EX) == 0 else { throw ChatGPTTokenError.storage }
    defer { flock(descriptor, LOCK_UN) }
    return try body()
  }
}
