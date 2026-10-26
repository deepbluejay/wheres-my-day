import Foundation

/// Agent-log identity contract.
///
/// PhysicalSource names an exact resolved filesystem subject; SessionSubject names a decoded
/// session; NativeComponent names one decoded instruction component; InstructionIdentity names
/// its tool-framed tuple (or a physical fallback); PayloadDigest shares masked bytes only;
/// LegacyProof preserves main-era refusal meaning without establishing ownership or lineage.
/// Equality and hashing compare UTF-8 bytes, never Unicode canonical equivalence. Filesystem URL
/// resolution precedes construction; display sanitation is a separate operation.
///
/// `AgentLogIdentity.decoded` is the only untrusted-input constructor. Its incremental input
/// accepts once-decoded valid UTF-8, with a 4096-byte prefix and streaming digest. Full decoding,
/// selective scanning and launch registration therefore produce the same bounded key.
/// `AgentLogIdentityCodec` is the trusted storage boundary for keys already encoded by this
/// module, not a raw/canonical Boolean option on input APIs.
///
/// The shared transition reducer interprets missing metadata with schema-specific inheritance;
/// present whitespace-only or non-string metadata is an unusable transition. Unusability never becomes
/// an empty native instruction component. Native IDs, including blank/oversized values, remain
/// exact subjects. Stored key formats/domains stay unchanged and no rows are rewritten. New
/// native keys correct oversized-blank collisions and use byte predicates for delimiter/reserved
/// checks. Legacy proof derivation keeps its original semantics. Display-masked event columns
/// remain display data; exact session receipts are authoritative for identity decisions.
///
/// New app-created sessions register ownership before launch. Unregistered historical own
/// sources retain collect-first acquisition with late transactional revocation. Before discovery,
/// collection inventories known app-owned homes/folders and hash-only launch receipts per database.
/// This baseline does not assert completeness for unregistered historical sources. Positive path
/// ownership keeps whole-source exclusion. Identity/lineage sharing alone never proves session ownership.
/// A prepared batch submitted after off/pause writes safe refusal-only identity/alias proofs, never
/// content, events, prompts, cursor advancement, content correspondences or ownership receipts.
public enum AgentLogIdentity {
  public enum PhysicalSourceKind {}
  public enum SessionSubjectKind {}
  public enum NativeComponentKind {}
  public enum InstructionKind {}
  public enum PayloadDigestKind {}
  public enum LegacyProofKind {}
  public enum InputDomain: Equatable {
    case component, physicalSource, legacyPhysicalSource, payload
  }

  public static func decoded<S: Sequence>(_ bytes: S, domain: InputDomain = .component)
    -> DecodedInput where S.Element == UInt8
  {
    var input = DecodedInput(domain: domain)
    for byte in bytes { input.consume(byte) }
    return input
  }
  public static func decoded(_ text: String, domain: InputDomain = .component) -> DecodedInput {
    decoded(text.utf8, domain: domain)
  }

  public struct DecodedInput: Equatable {
    private var prefix: [UInt8]? = []
    fileprivate var digest = AgentLogDigest()
    private var nonWhitespace = false
    private var scalar: UInt32 = 0
    private var minimum: UInt32 = 0
    private var remaining = 0
    private var invalidUTF8 = false
    private var domain: InputDomain = .component
    fileprivate init(domain: InputDomain) {
      self.domain = domain
      let prefix =
        domain == .physicalSource
        ? "physical-log-path-v1\0"
        : domain == .legacyPhysicalSource ? "physical-log-legacy-key-v1\0" : ""
      for byte in prefix.utf8 { digest.consume(byte) }
    }
    public mutating func consume(_ byte: UInt8) {
      digest.consume(byte)
      if prefix != nil {
        if prefix!.count < AgentLogMetadata.tokenLimit {
          prefix!.append(byte)
        } else {
          prefix = nil
        }
      }
      guard !invalidUTF8 else { return }
      if remaining > 0 {
        guard (128...191).contains(byte) else {
          invalidUTF8 = true
          return
        }
        scalar = (scalar << 6) | UInt32(byte & 63)
        remaining -= 1
      } else {
        switch byte {
        case 0...127:
          scalar = UInt32(byte)
          minimum = 0
        case 194...223:
          scalar = UInt32(byte & 31)
          minimum = 0x80
          remaining = 1
        case 224...239:
          scalar = UInt32(byte & 15)
          minimum = 0x800
          remaining = 2
        case 240...244:
          scalar = UInt32(byte & 7)
          minimum = 0x10000
          remaining = 3
        default:
          invalidUTF8 = true
          return
        }
      }
      if remaining == 0 {
        guard scalar >= minimum, let value = UnicodeScalar(scalar) else {
          invalidUTF8 = true
          return
        }
        if !CharacterSet.whitespacesAndNewlines.contains(value) { nonWhitespace = true }
      }
    }
    public var isValidUTF8: Bool { !invalidUTF8 && remaining == 0 }
    public var checkpointSafe: Bool { isValidUTF8 && digest.checkpointSafe }
    public var component: AgentLogNativeComponent {
      precondition(
        domain == .component && isValidUTF8, "Identity input must be once-decoded valid UTF-8")
      return AgentLogNativeComponent(
        key: prefix.map { encodeDecoded(String(decoding: $0, as: UTF8.self)) }
          ?? longKey(digest.hex()))
    }
    public var session: AgentLogSessionTransition {
      precondition(isValidUTF8)
      return nonWhitespace ? .subject(AgentLogSessionSubject(key: component.storedKey)) : .unusable
    }
    public var physicalSource: AgentLogPhysicalSource {
      precondition(isValidUTF8 && (domain == .physicalSource || domain == .legacyPhysicalSource))
      return AgentLogPhysicalSource(
        key: (domain == .physicalSource
          ? "activityprobe:path:sha256:" : "activityprobe:legacy-path:sha256:") + digest.hex())
    }
    public var payloadDigest: AgentLogPayloadDigest {
      precondition(isValidUTF8 && domain == .payload)
      return AgentLogPayloadDigest(key: digest.hex())
    }
    public var scannerDigest: ScannerDigest {
      precondition(domain == .component && prefix == nil)
      return ScannerDigest(input: self)
    }
    fileprivate init(overflowDigest: AgentLogDigest) {
      digest = overflowDigest
      prefix = nil
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.prefix == rhs.prefix && lhs.digest == rhs.digest && lhs.domain == rhs.domain
    }
  }
  /// The selective scanner persists its whitespace classification separately. Its overflow
  /// codec exposes a component, never a session transition inferred from an incomplete prefix.
  public struct ScannerDigest: Codable, Equatable {
    private var input: DecodedInput
    fileprivate init(input: DecodedInput) { self.input = input }
    public mutating func consume(_ byte: UInt8) { input.consume(byte) }
    public var component: AgentLogNativeComponent { input.component }
    public var checkpointSafe: Bool { input.checkpointSafe }
    public init(from decoder: Decoder) throws {
      // Preserve version 6's compression-state-only wire representation.
      input = DecodedInput(overflowDigest: try AgentLogDigest(from: decoder))
    }
    public func encode(to encoder: Encoder) throws {
      guard checkpointSafe else {
        throw EncodingError.invalidValue(
          "identity",
          .init(
            codingPath: encoder.codingPath,
            debugDescription: "Only completed overflow digest blocks are checkpointable"))
      }
      try input.digest.encode(to: encoder)
    }
  }
  public static func decodedPath(_ path: String) -> AgentLogPhysicalSource {
    decoded(path, domain: .physicalSource).physicalSource
  }
  public static func legacyPath(_ path: String) -> AgentLogPhysicalSource {
    decoded(path, domain: .legacyPhysicalSource).physicalSource
  }
  public static func instruction(_ tool: AgentLogTool, components: [AgentLogNativeComponent])
    -> AgentLogInstructionIdentity
  {
    let keys = components.map(\.storedKey)
    let literal = tool.rawValue + ":" + keys.joined(separator: ":")
    if literal.utf8.count <= AgentLogMetadata.tokenLimit
      && !keys.contains(where: { $0.utf8.contains(58) }),
      !literal.utf8.starts(with: (tool.rawValue + ":native:sha256:").utf8),
      AgentLogEventParser.isNativePromptIdentity(literal)
    {
      return AgentLogInstructionIdentity(key: literal)
    }
    return AgentLogInstructionIdentity(
      key: tool.rawValue + ":native:sha256:" + hash(keys.map { "\($0.utf8.count):" + $0 }.joined()))
  }
  public static func claude(_ uuid: String) -> AgentLogInstructionIdentity {
    instruction(.claude, components: [decoded(uuid).component])
  }
  public static func codex(thread: AgentLogNativeComponent, turn: String, item: String)
    -> AgentLogInstructionIdentity
  {
    instruction(.codex, components: [thread, decoded(turn).component, decoded(item).component])
  }
  public static func payload(_ masked: String) -> AgentLogPayloadDigest {
    decoded(masked, domain: .payload).payloadDigest
  }
  static func hash(_ text: String) -> String {
    var digest = AgentLogDigest()
    for byte in text.utf8 { digest.consume(byte) }
    return digest.hex()
  }
  static func longKey(_ digest: String) -> String { "activityprobe:long-identity:sha256:" + digest }
  private static func encodeDecoded(_ text: String) -> String {
    let safe = AgentLogEventParser.sanitizedIdentity(text)
    if !safe.utf8.elementsEqual(text.utf8) {
      return "activityprobe:decoded-identity:sha256:" + hash("decoded-subject-v1\0" + text)
    }
    if safe.utf8.count > AgentLogMetadata.tokenLimit { return longKey(hash(safe)) }
    guard
      safe.utf8.elementsEqual("activityprobe".utf8) || safe.utf8.starts(with: "activityprobe:".utf8)
    else { return safe }
    return "activityprobe:literal-identity:sha256:" + hash(safe)
  }
}

public struct AgentLogExactIdentity<Kind>: Hashable, Comparable, Codable, CustomStringConvertible {
  public let storedKey: String
  fileprivate init(key: String) { storedKey = key }
  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.storedKey.utf8.elementsEqual(rhs.storedKey.utf8)
  }
  public func hash(into hasher: inout Hasher) { hasher.combine(Data(storedKey.utf8)) }
  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.storedKey.utf8.lexicographicallyPrecedes(rhs.storedKey.utf8)
  }
  public func hasPrefix(_ prefix: String) -> Bool { storedKey.utf8.starts(with: prefix.utf8) }
  public var description: String { storedKey }
  public var utf8: String.UTF8View { storedKey.utf8 }
  public init(from decoder: Decoder) throws {
    let value = try decoder.singleValueContainer().decode(String.self)
    self = AgentLogIdentityCodec.key(value)
  }
  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(storedKey)
  }
}
public typealias AgentLogPhysicalSource = AgentLogExactIdentity<AgentLogIdentity.PhysicalSourceKind>
public typealias AgentLogSessionSubject = AgentLogExactIdentity<AgentLogIdentity.SessionSubjectKind>
public typealias AgentLogNativeComponent = AgentLogExactIdentity<
  AgentLogIdentity.NativeComponentKind
>
public typealias AgentLogInstructionIdentity = AgentLogExactIdentity<
  AgentLogIdentity.InstructionKind
>
public typealias AgentLogPayloadDigest = AgentLogExactIdentity<AgentLogIdentity.PayloadDigestKind>
public typealias AgentLogLegacyProof = AgentLogExactIdentity<AgentLogIdentity.LegacyProofKind>

public enum AgentLogSessionTransition: Equatable {
  case missing, unusable
  case subject(AgentLogSessionSubject)
  public var subject: AgentLogSessionSubject? {
    if case .subject(let value) = self { return value }
    return nil
  }
}

/// Trusted deserialization only. These keys have already crossed the decoded-input boundary.
/// Kept public for the Storage/Inbound modules; never use for a raw tool field or launch ID.
public enum AgentLogIdentityCodec {
  public static func key<Kind>(_ stored: String) -> AgentLogExactIdentity<Kind> {
    AgentLogExactIdentity(key: storedText(stored))
  }
  private static func storedText(_ stored: String) -> String {
    let safe: String
    if stored.utf8.count > AgentLogMetadata.tokenLimit {
      safe =
        stored.unicodeScalars.contains(where: { !CharacterSet.whitespacesAndNewlines.contains($0) })
        ? AgentLogIdentity.longKey(AgentLogIdentity.hash(stored)) : ""
    } else {
      let masked = AgentLogEventParser.sanitizedIdentity(stored)
      safe =
        masked.utf8.count > AgentLogMetadata.tokenLimit
        ? AgentLogIdentity.longKey(AgentLogIdentity.hash(masked)) : masked
    }
    return safe
  }
  public static func legacySourceLabel(_ stored: String) -> String { storedText(stored) }
  public static func legacyPhysicalSpelling(_ stored: String) -> AgentLogPhysicalSource {
    key(stored)
  }
  public static func session(_ stored: String) -> AgentLogSessionSubject { key(stored) }
  public static func component(_ stored: String) -> AgentLogNativeComponent { key(stored) }
  public static func instruction(_ stored: String) -> AgentLogInstructionIdentity { key(stored) }
  // Historical source lookup candidates retain their spelling; SQL applies its historical key rule.
  // Never copy a raw lookup candidate into a newly created source receipt.
  public static func physical(_ stored: String) -> AgentLogPhysicalSource {
    AgentLogPhysicalSource(key: stored)
  }
  public static func legacy(_ stored: String) -> AgentLogLegacyProof { key(stored) }
  public static func payload(_ stored: String) -> AgentLogPayloadDigest { key(stored) }
}

extension AgentLogSessionSubject {
  // Trusted legacy checkpoints may contain a blank sentinel; input construction never does.
  public var isUsable: Bool { !storedKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  public var nativeComponent: AgentLogNativeComponent { AgentLogNativeComponent(key: storedKey) }
}
