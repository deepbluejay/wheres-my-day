import CryptoKit
import Darwin
import Foundation
@testable import Outbound
import Security

/// An invented OAuth server on 127.0.0.1. Serves discovery, keys, token and revocation with invented values.
final class FakeOAuthServer {
  struct Request { let method: String; let path: String; let form: [String: String]; let authorization: String? }
  let port: UInt16
  var url: URL { URL(string: "http://127.0.0.1:\(port)")! }
  var issuer: String { "https://issuer.invalid" }
  private let socket: Int32
  private let lock = NSLock()
  private var recorded: [Request] = []
  private var stopped = false
  /// The handler for token-endpoint POSTs; the default refuses.
  var token: ([String: String]) -> (Int, Any) = { _ in (400, ["error": "invalid_request"]) }
  var revoke: ([String: String]) -> Int = { _ in 200 }
  var models: (String?) -> (Int, Any) = { _ in (200, ["models": []]) }
  var keys: [[String: Any]] = []
  var discoveryIssuer: String?
  /// Discovery answers 503 this many times before it succeeds.
  var discoveryFailures = 0
  init() throws {
    let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0; address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard bound == 0, listen(descriptor, 16) == 0 else { throw POSIXError(.EADDRINUSE) }
    var actual = sockaddr_in(); var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &actual) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) } }
    socket = descriptor
    port = UInt16(bigEndian: actual.sin_port)
    Thread.detachNewThread { [self] in serve() }
  }
  func stop() { lock.lock(); stopped = true; lock.unlock(); shutdown(socket, SHUT_RDWR); close(socket) }
  var requests: [Request] { lock.lock(); defer { lock.unlock() }; return recorded }
  func requests(_ path: String) -> [Request] { requests.filter { $0.path == path } }
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
    while true {
      if let end = data.range(of: Data("\r\n\r\n".utf8)) {
        let head = String(decoding: data[..<end.lowerBound], as: UTF8.self)
        let length = head.split(separator: "\r\n").compactMap { line -> Int? in
          let parts = line.split(separator: ":", maxSplits: 1)
          return parts.count == 2 && parts[0].lowercased() == "content-length" ? Int(parts[1].trimmingCharacters(in: .whitespaces)) : nil
        }.first ?? 0
        if data.count - end.upperBound >= length { break }
      }
      let count = read(client, &buffer, buffer.count)
      if count <= 0 { break }
      data.append(buffer, count: count)
    }
    guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return }
    let head = String(decoding: data[..<end.lowerBound], as: UTF8.self)
    let line = head.split(separator: "\r\n").first.map(String.init) ?? ""
    let fields = line.split(separator: " ")
    guard fields.count == 3 else { return }
    let path = String(fields[1].split(separator: "?").first ?? "")
    let form = ChatGPTForm.decode(String(decoding: data[end.upperBound...], as: UTF8.self))
    lock.lock(); recorded.append(Request(method: String(fields[0]), path: path, form: form, authorization: head.split(separator: "\r\n").first { $0.lowercased().hasPrefix("authorization:") }.map { $0.dropFirst(14).trimmingCharacters(in: .whitespaces) })); lock.unlock()
    var status = 404; var body: Any = [String: Any]()
    switch path {
    case "/.well-known/openid-configuration" where discoveryFailures > 0:
      lock.lock(); discoveryFailures -= 1; lock.unlock(); status = 503
    case "/.well-known/openid-configuration":
      status = 200
      body = ["issuer": discoveryIssuer ?? issuer, "jwks_uri": url.appendingPathComponent("jwks").absoluteString,
        "revocation_endpoint": url.appendingPathComponent("revoke").absoluteString]
    case "/v1/models": (status, body) = models(requests.last?.authorization)
    case "/jwks": status = 200; body = ["keys": keys]
    case "/api/accounts/oauth/token": (status, body) = token(form)
    case "/revoke": status = revoke(form); body = [String: Any]()
    default: break
    }
    let payload = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    let reply = "HTTP/1.1 \(status) X\r\nContent-Type: application/json\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
    let bytes = [UInt8](Data(reply.utf8) + payload)
    _ = bytes.withUnsafeBufferPointer { write(client, $0.baseAddress, $0.count) }
  }
}

/// An invented RSA signing key and the JWK the fake server publishes for it. Never stored in a keychain.
struct FakeSigner {
  let privateKey: SecKey
  let kid: String
  init(kid: String = "invented-key") {
    let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
    privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, nil)!
    self.kid = kid
  }
  var jwk: [String: Any] {
    let der = [UInt8](SecKeyCopyExternalRepresentation(SecKeyCopyPublicKey(privateKey)!, nil)! as Data)
    // PKCS#1 RSAPublicKey: SEQUENCE { INTEGER n, INTEGER e }.
    var index = 0
    func length() -> Int {
      let first = Int(der[index]); index += 1
      guard first & 0x80 != 0 else { return first }
      var value = 0
      for _ in 0..<(first & 0x7f) { value = value << 8 | Int(der[index]); index += 1 }
      return value
    }
    index += 1; _ = length()
    index += 1; let nLength = length(); let n = Array(der[index..<index + nLength]); index += nLength
    index += 1; let eLength = length(); let e = Array(der[index..<index + eLength])
    return ["kty": "RSA", "kid": kid, "use": "sig", "alg": "RS256",
      "n": ChatGPTAttempt.base64URL(Data(n.drop { $0 == 0 })), "e": ChatGPTAttempt.base64URL(Data(e))]
  }
  func token(_ claims: [String: Any], alg: String = "RS256") -> String {
    let header = ChatGPTAttempt.base64URL(try! JSONSerialization.data(withJSONObject: ["alg": alg, "kid": kid, "typ": "JWT"]))
    let payload = ChatGPTAttempt.base64URL(try! JSONSerialization.data(withJSONObject: claims))
    let input = Data((header + "." + payload).utf8)
    let signature = SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, input as CFData, nil)! as Data
    return header + "." + payload + "." + ChatGPTAttempt.base64URL(signature)
  }
}

/// Stands in for the person's browser: reads the authorize URL and calls the loopback callback.
final class FakeBrowser {
  private let lock = NSLock()
  private(set) var opened: [URL] = []
  /// Returns the callback query for an authorize URL's parameters, or nil to never call back.
  var answer: ([String: String]) -> [(String, String)]? = { _ in nil }
  /// Callbacks sent, one after another, before the answer: other attempts, stale tabs, forged requests.
  var decoys: ([String: String]) -> [[(String, String)]] = { _ in [] }
  var opens: Bool = true
  private let session = URLSession(configuration: .ephemeral)
  private var answered: [(status: Int, page: String)] = []
  /// Status and page of every callback the listener answered, in order.
  var replies: [(status: Int, page: String)] { lock.lock(); defer { lock.unlock() }; return answered }
  var lastOpened: [String: String] { lock.lock(); defer { lock.unlock() }; return opened.last.map(Self.query) ?? [:] }
  static func query(_ url: URL) -> [String: String] { ChatGPTForm.decode(url.query ?? "") }
  func open(_ url: URL) -> Bool {
    lock.lock(); opened.append(url); lock.unlock()
    guard opens else { return false }
    let parameters = Self.query(url)
    guard let redirect = parameters["redirect_uri"] else { return true }
    let callbacks = decoys(parameters) + [answer(parameters)].compactMap { $0 }
    // The listener reads only after this returns, so the callbacks go out from another thread, in order.
    Thread.detachNewThread { [self] in
      for items in callbacks {
        let done = DispatchSemaphore(value: 0)
        session.dataTask(with: URL(string: redirect + "?" + ChatGPTForm.encode(items))!) { [self] data, response, _ in
          let status = (response as? HTTPURLResponse)?.statusCode ?? 0
          lock.lock(); answered.append((status, String(decoding: data ?? Data(), as: UTF8.self))); lock.unlock()
          done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 5)
      }
    }
    return true
  }
}

/// Invented values for one account.
enum FakeAccount {
  static let clientID = "oaiapp_invented"
  static let subject = "invented-subject"
  static let now = 1_800_000_000
  static let allScopes = ChatGPTOAuthConfiguration.scopes.sorted().joined(separator: " ")
  static func claims(issuer: String, nonce: String, audience: Any = clientID, subject: String = subject,
    exp: Int = now + 3600, iat: Int = now) -> [String: Any] {
    ["iss": issuer, "aud": audience, "sub": subject, "exp": exp, "iat": iat, "nonce": nonce, "email": "person@example.invalid"]
  }
}
