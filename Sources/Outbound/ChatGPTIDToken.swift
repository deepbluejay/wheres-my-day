import Core
import Foundation
import Security

/// The discovery document's endpoints this flow uses. Fetched per operation, never stored.
struct ChatGPTDiscovery {
  let jwks: URL
  let revocation: URL?
  static func load(_ configuration: ChatGPTOAuthConfiguration, http: ChatGPTHTTP) throws -> ChatGPTDiscovery {
    let object = try http.getJSON(configuration.discovery, timeout: configuration.requestTimeout)
    // The ID token's issuer must exactly match the issuer the discovery document names.
    guard object["issuer"] as? String == configuration.issuer,
      let jwks = (object["jwks_uri"] as? String).flatMap(URL.init(string:)), configuration.permits(jwks)
    else { throw ChatGPTSignInError.invalidIDToken }
    let revocation = (object["revocation_endpoint"] as? String).flatMap(URL.init(string:)).flatMap { configuration.permits($0) ? $0 : nil }
    return ChatGPTDiscovery(jwks: jwks, revocation: revocation)
  }
}

/// Verifies an OpenAI ID token: RS256 signature against the published keys, then issuer,
/// audience, expiry, issued-at, nonce and subject. Returns only the validated subject.
struct ChatGPTIDTokenValidator {
  static let clockSkew = 5
  let configuration: ChatGPTOAuthConfiguration
  let http: ChatGPTHTTP
  func subject(of token: String, clientID: String, nonce: String, now: Int) throws -> String {
    let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 3,
      let headerData = ChatGPTAttempt.decodeBase64URL(parts[0]), let payloadData = ChatGPTAttempt.decodeBase64URL(parts[1]),
      let signature = ChatGPTAttempt.decodeBase64URL(parts[2]),
      let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
      let claims = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
      header["alg"] as? String == "RS256" else { throw ChatGPTSignInError.invalidIDToken }
    let discovery = try ChatGPTDiscovery.load(configuration, http: http)
    let keys = try http.getJSON(discovery.jwks, timeout: configuration.requestTimeout)["keys"] as? [[String: Any]] ?? []
    let kid = header["kid"] as? String
    let candidates = keys.filter { key in
      key["kty"] as? String == "RSA" && (key["use"] == nil || key["use"] as? String == "sig")
        && (key["alg"] == nil || key["alg"] as? String == "RS256") && (kid == nil || key["kid"] as? String == kid)
    }
    let signed = Data((parts[0] + "." + parts[1]).utf8)
    guard candidates.contains(where: { key in
      guard let publicKey = Self.publicKey(key) else { return false }
      return SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256, signed as CFData, signature as CFData, nil)
    }) else { throw ChatGPTSignInError.invalidIDToken }
    guard claims["iss"] as? String == configuration.issuer, Self.audience(claims, contains: clientID),
      let exp = (claims["exp"] as? NSNumber)?.intValue, exp + Self.clockSkew > now,
      let iat = (claims["iat"] as? NSNumber)?.intValue, iat - Self.clockSkew <= now,
      let tokenNonce = claims["nonce"] as? String, Self.equal(tokenNonce, nonce),
      let subject = claims["sub"] as? String, !subject.isEmpty else { throw ChatGPTSignInError.invalidIDToken }
    return subject
  }
  private static func audience(_ claims: [String: Any], contains clientID: String) -> Bool {
    if let audience = claims["aud"] as? String { return audience == clientID }
    guard let audiences = claims["aud"] as? [String], audiences.contains(clientID) else { return false }
    // With several audiences, OpenID Connect requires the authorized party to be this client.
    return audiences.count == 1 || claims["azp"] as? String == clientID
  }
  static func equal(_ a: String, _ b: String) -> Bool {
    let left = Array(a.utf8), right = Array(b.utf8)
    guard left.count == right.count else { return false }
    return zip(left, right).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
  }
  /// A JWK's modulus and exponent as a PKCS#1 RSAPublicKey, the form SecKey accepts. At least 2048 bits.
  static func publicKey(_ jwk: [String: Any]) -> SecKey? {
    guard let n = (jwk["n"] as? String).flatMap(ChatGPTAttempt.decodeBase64URL),
      let e = (jwk["e"] as? String).flatMap(ChatGPTAttempt.decodeBase64URL) else { return nil }
    let modulus = Array(n.drop { $0 == 0 })
    guard modulus.count >= 256, !e.isEmpty else { return nil }
    let der = DER.sequence(DER.integer(modulus) + DER.integer(Array(e)))
    let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic]
    return SecKeyCreateWithData(Data(der) as CFData, attributes as CFDictionary, nil)
  }
}

enum DER {
  static func length(_ count: Int) -> [UInt8] {
    if count < 0x80 { return [UInt8(count)] }
    var bytes: [UInt8] = []; var value = count
    while value > 0 { bytes.insert(UInt8(value & 0xff), at: 0); value >>= 8 }
    return [0x80 | UInt8(bytes.count)] + bytes
  }
  static func integer(_ magnitude: [UInt8]) -> [UInt8] {
    var value = Array(magnitude.drop { $0 == 0 })
    if value.isEmpty { value = [0] }
    if value[0] & 0x80 != 0 { value.insert(0, at: 0) }
    return [0x02] + length(value.count) + value
  }
  static func sequence(_ content: [UInt8]) -> [UInt8] { [0x30] + length(content.count) + content }
}
