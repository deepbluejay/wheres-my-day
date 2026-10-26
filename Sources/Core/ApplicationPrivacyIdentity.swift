import Foundation

/// Privacy matching survives case folding and lossy presentation masking.
public enum ApplicationPrivacyIdentity {
  private static let digests: NSCache<NSString, NSString> = {
    let cache = NSCache<NSString, NSString>()
    cache.countLimit = 256; cache.totalCostLimit = 64 * 1024
    return cache
  }()
  /// A presentation mask cannot establish the identity that it replaced.
  public static func originalDigest(_ bundleID: String) -> String? {
    HistoricalApplicationPrivacy.masked(bundleID) ? nil : digest(bundleID)
  }
  public static func digest(_ bundleID: String) -> String {
    let normalized = bundleID.lowercased()
    if let cached = digests.object(forKey: normalized as NSString) { return cached as String }
    let value = sha256(Array(normalized.utf8)).map { String(format: "%08x", $0) }.joined()
    let cost = normalized.utf8.count + 64
    if cost <= 1024 { digests.setObject(value as NSString, forKey: normalized as NSString, cost: cost) }
    return value
  }

  // Core deliberately depends only on Foundation. SHA-256 makes the durable
  // matching key opaque without retaining a reversible encoding of a secret.
  private static func sha256(_ input: [UInt8]) -> [UInt32] {
    let constants: [UInt32] = [
      0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
      0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
      0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
      0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
      0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
      0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
      0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
      0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]
    func rotate(_ value: UInt32, _ amount: UInt32) -> UInt32 { (value >> amount) | (value << (32 - amount)) }
    var bytes = input
    let bits = UInt64(bytes.count) * 8
    bytes.append(0x80)
    while bytes.count % 64 != 56 { bytes.append(0) }
    for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8(truncatingIfNeeded: bits >> shift)) }
    var hash: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
    for offset in stride(from: 0, to: bytes.count, by: 64) {
      var words = [UInt32](repeating: 0, count: 64)
      for index in 0..<16 {
        for byte in 0..<4 { words[index] = (words[index] << 8) | UInt32(bytes[offset + index * 4 + byte]) }
      }
      for index in 16..<64 {
        let x = words[index - 15], y = words[index - 2]
        let s0 = rotate(x, 7) ^ rotate(x, 18) ^ (x >> 3)
        let s1 = rotate(y, 17) ^ rotate(y, 19) ^ (y >> 10)
        words[index] = words[index - 16] &+ s0 &+ words[index - 7] &+ s1
      }
      var a = hash[0], b = hash[1], c = hash[2], d = hash[3]
      var e = hash[4], f = hash[5], g = hash[6], h = hash[7]
      for index in 0..<64 {
        let sum1 = rotate(e, 6) ^ rotate(e, 11) ^ rotate(e, 25)
        let choice = (e & f) ^ (~e & g)
        let t1 = h &+ sum1 &+ choice &+ constants[index] &+ words[index]
        let sum0 = rotate(a, 2) ^ rotate(a, 13) ^ rotate(a, 22)
        let majority = (a & b) ^ (a & c) ^ (b & c)
        let t2 = sum0 &+ majority
        h = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
      }
      let values = [a, b, c, d, e, f, g, h]
      for index in 0..<8 { hash[index] = hash[index] &+ values[index] }
    }
    return hash
  }
}

public extension StorageSettings {
  func excludesApplication(_ bundleID: String, identity: String? = nil) -> Bool {
    let identity = identity ?? ApplicationPrivacyIdentity.digest(bundleID)
    return excludedApps.contains { excluded in
      let label = excluded.lowercased()
      if (excludedAppPrivacyIdentities[label] ?? [ApplicationPrivacyIdentity.digest(excluded)]).contains(identity) { return true }
      // Older settings retained only the masked label. Keep that conservative
      // exclusion effective until the person removes it or supplies an identity.
      return excludedAppPrivacyIdentities[label] == nil && label.contains("[")
        && HistoricalApplicationPrivacy(applications: [label]).contains(bundleID)
    }
  }

  /// Ordinary identities retain their existing settings representation. Only
  /// lossy names need an extra opaque identity alongside their masked label.
  var persistedAppExclusions: [(label: String, identity: String)] {
    var result: [(label: String, identity: String)] = []
    for raw in excludedApps {
      let normalized = raw.lowercased()
      let label = Redaction.applyKnownSecrets(normalized).text
      let identities = excludedAppPrivacyIdentities[normalized] ?? [ApplicationPrivacyIdentity.digest(raw)]
      result += identities.map { (label, $0) }
    }
    return result.sorted { $0.label == $1.label ? $0.identity < $1.identity : $0.label < $1.label }
  }
}

/// Read policy for historical labels whose original spelling was discarded.
/// Masks are wildcards here only; collection still uses the opaque identity.
public struct HistoricalApplicationPrivacy {
  private let spellings: Set<String>
  private let maskedPatterns: [NSRegularExpression]
  public init(applications: [String]) {
    spellings = Set(applications.flatMap { raw in
      [raw.lowercased(), Redaction.applyKnownSecrets(raw).text.lowercased(),
        Redaction.applyKnownSecrets(raw.lowercased()).text.lowercased(),
        Redaction.applyKnownSecrets(raw.uppercased()).text.lowercased()]
    })
    maskedPatterns = spellings.filter(Self.masked).map(Self.pattern)
  }
  public static func masked(_ label: String) -> Bool {
    let normalized = label.lowercased()
    return normalized.contains(Redaction.secretMark) || normalized.contains(Redaction.emailMark)
  }
  private static func pattern(_ label: String) -> NSRegularExpression {
    var pattern = NSRegularExpression.escapedPattern(for: label)
    for mark in [Redaction.secretMark, Redaction.emailMark] {
      pattern = pattern.replacingOccurrences(of: NSRegularExpression.escapedPattern(for: mark), with: ".*")
    }
    return try! NSRegularExpression(pattern: "^" + pattern + "$", options: [.caseInsensitive, .dotMatchesLineSeparators])
  }
  public func contains(_ label: String) -> Bool {
    let label = label.lowercased()
    if spellings.contains(label) { return true }
    let range = NSRange(location: 0, length: (label as NSString).length)
    if maskedPatterns.contains(where: { $0.firstMatch(in: label, range: range) != nil }) { return true }
    guard Self.masked(label) else { return false }
    // Two lossy labels cannot disprove a shared identity. Historical privacy
    // deliberately prefers hiding an extra row to exposing an excluded one.
    if !maskedPatterns.isEmpty { return true }
    let pattern = Self.pattern(label)
    return spellings.contains { pattern.firstMatch(in: $0, range: NSRange(location: 0, length: ($0 as NSString).length)) != nil }
  }
}
