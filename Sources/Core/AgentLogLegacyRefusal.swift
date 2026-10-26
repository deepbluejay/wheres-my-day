import Foundation

/// Exact main-format proofs are digests, never reversible key spellings or ownership edges.
public struct AgentLogLegacyRefusal: Equatable {
  public var digests: [AgentLogLegacyProof] = []
  public var nativeDigests: [AgentLogLegacyProof] = []
  public var codexThread: AgentLogLegacyProof?
  public var codexSuffixBytes = 0
  public var codexSuffixDigest: AgentLogLegacyProof?
  public init() {}
  public var retainedByteEstimate: Int {
    128 + (digests + nativeDigests).reduce(0) { $0 + 64 + $1.utf8.count }
      + (codexThread?.utf8.count ?? 0) + (codexSuffixDigest?.utf8.count ?? 0)
  }
  public static func digest(_ joined: String) -> AgentLogLegacyProof {
    AgentLogIdentityCodec.legacy(hash(Redaction.applyKnownSecrets(joined).text.utf8, domain: "activityprobe.legacy.joined.v1"))
  }
  private static func hash<S: Sequence>(_ bytes: S, domain: String) -> String where S.Element == UInt8 {
    var digest = AgentLogDigest()
    for byte in (domain + "\0").utf8 { digest.consume(byte) }
    for byte in bytes { digest.consume(byte) }
    return digest.hex()
  }
  public static func marker(_ digest: AgentLogLegacyProof) -> AgentLogLegacyProof { AgentLogIdentityCodec.legacy("legacy:key:sha256:" + digest.storedKey) }
  mutating func claude(_ raw: String) { add("claude:" + raw) }
  mutating func fallbackIdentity(tool: AgentLogTool, at time: Int, hash: AgentLogLegacyProof) -> AgentLogInstructionIdentity {
    let key = "\(tool.rawValue):legacy:\(time):\(hash)"
    add(key, native: false)
    return AgentLogIdentityCodec.instruction(key)
  }
  static func discardQueued(body: String, at time: Int, state: inout AgentLogState, fingerprint: (String) -> String) {
    let hash = AgentLogIdentityCodec.legacy(fingerprint(body))
    state.legacyRefusalQueue.removeAll { $0.hash == hash && !$0.delivered && $0.ts <= time }
  }
  static func observeQueue(_ line: [String: Any], body: String, at time: Int, state: inout AgentLogState, fingerprint: (String) -> String) {
    let hash = AgentLogIdentityCodec.legacy(fingerprint(body))
    let digest = (line["commandUuid"] as? String).map { Self.digest("claude:" + $0) }
    if line["operation"] as? String == "enqueue" {
      state.legacyRefusalQueue.removeAll { $0.hash == hash && !$0.delivered }
      state.legacyRefusalQueue.append(.init(hash: hash, keyDigest: digest, ts: time, delivered: false))
    } else if line["operation"] as? String == "remove" {
      if line["reason"] as? String == "absorbed_mid_turn" {
        if let index = state.legacyRefusalQueue.lastIndex(where: { $0.hash == hash && !$0.delivered }), let digest {
          state.legacyRefusalQueue[index].keyDigest = digest
        }
      } else { state.legacyRefusalQueue.removeAll { $0.hash == hash && !$0.delivered } }
    }
    state.legacyRefusalQueue = Array(state.legacyRefusalQueue.suffix(AgentLogState.queueLimit))
  }
  mutating func pairQueue(_ line: [String: Any], attachment: [String: Any], queuedAttachment: Bool,
    hash: AgentLogLegacyProof, at time: Int, state: inout AgentLogState) {
    let legacyTime = queuedAttachment ? legacyEpoch(attachment["timestamp"] ?? line["timestamp"]) ?? time : time
    let rawID = queuedAttachment ? attachment["source_uuid"] as? String ?? line["uuid"] as? String : line["uuid"] as? String
    var digest = rawID.map { AgentLogLegacyRefusal.digest("claude:" + $0) }
    if queuedAttachment {
      let sourceDigest = (attachment["source_uuid"] as? String).map { AgentLogLegacyRefusal.digest("claude:" + $0) }
      let pending = state.legacyRefusalQueue.lastIndex { !$0.delivered && sourceDigest != nil && $0.keyDigest == sourceDigest }
        ?? state.legacyRefusalQueue.lastIndex { !$0.delivered && $0.hash == hash && $0.ts <= legacyTime }
      let pairedTime = pending.map { state.legacyRefusalQueue.remove(at: $0).ts } ?? legacyTime
      digest = digest ?? AgentLogLegacyRefusal.digest("claude:legacy:\(pairedTime):\(hash.storedKey)")
      state.legacyRefusalQueue.append(.init(hash: hash, keyDigest: digest, ts: pairedTime, delivered: true))
    } else if line["promptSource"] as? String == "queued" {
      let index = state.legacyRefusalQueue.lastIndex { $0.hash == hash && !$0.delivered && $0.ts <= time }
        ?? state.legacyRefusalQueue.firstIndex { $0.hash == hash && $0.delivered }
      if let index {
        let pair = state.legacyRefusalQueue.remove(at: index)
        digest = (pair.delivered ? pair.keyDigest : pair.keyDigest ?? digest)
          ?? AgentLogLegacyRefusal.digest("claude:legacy:\(pair.ts):\(hash.storedKey)")
      }
    }
    if let digest, !digests.contains(digest) { digests.append(digest) }
    state.legacyRefusalQueue = Array(state.legacyRefusalQueue.suffix(AgentLogState.queueLimit))
  }
  private func legacyEpoch(_ value: Any?) -> Int? {
    guard let string = value as? String else { return nil }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return (fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)).map { Int($0.timeIntervalSince1970) }
  }
  mutating func add(_ joined: String, native: Bool = true) {
    let digest = Self.digest(joined)
    if !digests.contains(digest) { digests.append(digest) }
    if native && !nativeDigests.contains(digest) { nativeDigests.append(digest) }
  }
  static func legacyThread(_ raw: String) -> AgentLogLegacyProof {
    // Main redacted a tool-prefixed joined key, so a JSON-shaped header must
    // take the same text-redaction path rather than the standalone JSON path.
    let prefix = Redaction.applyKnownSecrets("codex:" + raw).text
    if prefix.hasPrefix("codex:") {
      return legacySubject(String(prefix.dropFirst(6)))
    }
    return AgentLogIdentityCodec.legacy("legacy-prefix:sha256:" + hash(prefix.utf8, domain: "activityprobe.legacy.prefix.v1"))
  }
  // Main-era compatibility must not inherit modern byte-predicate key corrections.
  // These original grapheme checks name proof classes only, never modern subjects.
  private static func legacySubject(_ text: String) -> AgentLogLegacyProof {
    if text.utf8.count > AgentLogMetadata.tokenLimit {
      return AgentLogIdentityCodec.legacy(text.unicodeScalars.contains(where: { !CharacterSet.whitespacesAndNewlines.contains($0) })
        ? AgentLogIdentity.longKey(AgentLogIdentity.hash(text)) : "")
    }
    let safe = AgentLogEventParser.sanitizedIdentity(text)
    if safe != text {
      return AgentLogIdentityCodec.legacy("activityprobe:decoded-identity:sha256:" + AgentLogIdentity.hash("decoded-subject-v1\0" + text))
    }
    if safe.utf8.count > AgentLogMetadata.tokenLimit { return AgentLogIdentityCodec.legacy(AgentLogIdentity.longKey(AgentLogIdentity.hash(safe))) }
    if safe == "activityprobe" || safe.hasPrefix("activityprobe:") {
      return AgentLogIdentityCodec.legacy("activityprobe:literal-identity:sha256:" + AgentLogIdentity.hash(safe))
    }
    return AgentLogIdentityCodec.legacy(safe)
  }
  mutating func codex(thread: AgentLogNativeComponent, explicitThread: String?, state: AgentLogState,
    fallbackSource: String, turn: String, item: String) {
    codex(thread: thread, rawThread: explicitThread
      ?? (state.sessionExact == true ? state.session?.storedKey : nil)
      ?? (state.session == nil && state.legacySession == nil ? fallbackSource : nil),
      legacyThread: state.legacySession, turn: turn, item: item)
  }
  private mutating func codex(thread: AgentLogNativeComponent, rawThread: String?, legacyThread: AgentLogLegacyProof? = nil, turn: String, item: String) {
    if let rawThread {
      add("codex:" + rawThread + ":" + turn + ":" + item)
      return
    }
    add("codex:" + thread.storedKey + ":" + turn + ":" + item)
    codexThread = legacyThread ?? AgentLogIdentityCodec.legacy(thread.storedKey)
    let suffix = Redaction.applyKnownSecrets(":" + turn + ":" + item).text
    codexSuffixBytes = suffix.utf8.count
    codexSuffixDigest = AgentLogIdentityCodec.legacy(Self.hash(suffix.utf8.reversed(), domain: "activityprobe.legacy.suffix.v1"))
  }
  public var ambiguousCodexThread: Bool {
    guard let thread = codexThread else { return false }
    return thread.storedKey.contains(Redaction.secretMark)
      || ["activityprobe:", "legacy-prefix:", "\"", "{", "["].contains(where: { thread.storedKey.hasPrefix($0) })
  }
  /// Index every possible thread boundary, without guessing where main's colon-joined
  /// components ended. Forward and reverse incremental hashes make this linear in bytes.
  public static func compatibilityKeys(_ legacy: String, visit: (AgentLogLegacyProof, AgentLogLegacyProof) throws -> Void) rethrows {
    let codexPrefix = legacy.hasPrefix("codex:")
    // Only a masked-away prefix is ambiguous. Explicit Claude/other tool keys
    // must never become an inherited Codex wildcard refusal.
    guard codexPrefix || legacy.hasPrefix(Redaction.secretMark) else { return }
    if legacy.contains(Redaction.secretMark) { try visit(AgentLogIdentityCodec.legacy("*"), AgentLogIdentityCodec.legacy("*")) }
    let subject = codexPrefix ? String(legacy.dropFirst(6)) : legacy
    let bytes = Array(subject.utf8)
    var suffix = AgentLogDigest()
    for byte in "activityprobe.legacy.suffix.v1\0".utf8 { suffix.consume(byte) }
    var boundaries: [Int: String] = [:]
    var colons = 0
    for i in bytes.indices.reversed() {
      suffix.consume(bytes[i])
      if bytes[i] == 58 {
        if colons > 0 { boundaries[i] = suffix.hex() }
        colons += 1
      }
    }
    var prefix = AgentLogDigest()
    if !codexPrefix {
      for byte in "activityprobe.legacy.prefix.v1\0".utf8 { prefix.consume(byte) }
    }
    var firstNonWhitespace: Int?
    var scalarOffset = 0
    for scalar in subject.unicodeScalars {
      if !CharacterSet.whitespacesAndNewlines.contains(scalar) { firstNonWhitespace = scalarOffset; break }
      scalarOffset += String(scalar).utf8.count
    }
    for i in bytes.indices {
      if let suffix = boundaries[i] {
        let thread: String
        if !codexPrefix { thread = "legacy-prefix:sha256:" + prefix.hex() }
        else {
          thread = i > AgentLogMetadata.tokenLimit
            ? (firstNonWhitespace.map { $0 < i } == true ? AgentLogIdentity.longKey(prefix.hex()) : "")
            : legacySubject(String(decoding: bytes[..<i], as: UTF8.self)).storedKey
        }
        try visit(AgentLogIdentityCodec.legacy(thread), AgentLogIdentityCodec.legacy(suffix))
      }
      prefix.consume(bytes[i])
    }
  }
}

/// Main's old content pairing is retained only to consult adopted refusals.
/// It never supplies a source ID, timestamp, lineage edge or ownership marker.
struct AgentLogLegacyQueueReceipt: Codable, Equatable {
  let hash: AgentLogLegacyProof
  var keyDigest: AgentLogLegacyProof?
  let ts: Int
  let delivered: Bool
}

/// Decode-only historical state. The projection parser never interprets an old queue format.
struct AgentLogLegacyQueueState: Decodable {
  var queued: [AgentLogState.QueuedInstruction] = []
  var receipts: [AgentLogLegacyQueueReceipt] = []
  private enum CodingKeys: String, CodingKey { case metadataVersion, metadataRead, queued, receipts = "legacyRefusalQueue" }
  // Decode main-era proof input before the bounded stored-key codec can change its spelling.
  private struct LegacyQueuedInstruction: Decodable {
    let hash: String
    let id: String?
    let ts: Int
    let delivered: Bool
  }
  private struct OldQueuedInstruction: Decodable {
    let hash: String
    let id: String?
    let ts: Int
    let delivered: Bool?
    let sourceID: String?
  }
  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    // Old receipts are decoded for migration only; they cannot establish content-based identity.
    let metadataVersion = try values.decodeIfPresent(Int.self, forKey: .metadataVersion) ?? 0
    if values.contains(.metadataRead) {
      if metadataVersion == 0 {
        let original = Array((try values.decodeIfPresent([LegacyQueuedInstruction].self, forKey: .queued) ?? []).suffix(AgentLogState.queueLimit))
        receipts = original.map { receipt in
          AgentLogLegacyQueueReceipt(hash: AgentLogIdentityCodec.legacy(receipt.hash),
            keyDigest: receipt.id.map { AgentLogLegacyRefusal.digest(receipt.delivered ? $0 : "claude:" + $0) },
            ts: receipt.ts, delivered: receipt.delivered)
        }
        queued = original.map { AgentLogState.QueuedInstruction(hash: AgentLogIdentityCodec.legacy($0.hash),
          id: $0.id.map(AgentLogIdentityCodec.legacy), ts: $0.ts, delivered: $0.delivered) }
      } else {
        queued = Array((try values.decodeIfPresent([AgentLogState.QueuedInstruction].self, forKey: .queued) ?? []).suffix(AgentLogState.queueLimit))
      }
    } else {
      let old = try values.decodeIfPresent([OldQueuedInstruction].self, forKey: .queued) ?? []
      receipts = old.suffix(AgentLogState.queueLimit).map {
        let id = $0.delivered == true ? $0.sourceID ?? $0.id.map { "claude:" + $0 } : $0.id.map { "claude:" + $0 }
        return AgentLogLegacyQueueReceipt(hash: AgentLogIdentityCodec.legacy($0.hash),
          keyDigest: id.map(AgentLogLegacyRefusal.digest), ts: $0.ts, delivered: $0.delivered ?? false)
      }
      queued = old.suffix(AgentLogState.queueLimit).map {
        AgentLogState.QueuedInstruction(hash: AgentLogIdentityCodec.legacy($0.hash), id: ($0.delivered == true
          ? $0.sourceID ?? $0.id.map { AgentLogIdentity.claude($0).storedKey } : $0.id).map(AgentLogIdentityCodec.legacy), ts: $0.ts, delivered: $0.delivered ?? false)
      }
    }
    if let receipts = try values.decodeIfPresent([AgentLogLegacyQueueReceipt].self, forKey: .receipts) {
      self.receipts = Array(receipts.suffix(AgentLogState.queueLimit)).map {
        AgentLogLegacyQueueReceipt(hash: $0.hash,
          keyDigest: $0.keyDigest.flatMap { $0.utf8.count == 64 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } ? $0 : nil },
          ts: $0.ts, delivered: $0.delivered)
      }
    }
  }
}
