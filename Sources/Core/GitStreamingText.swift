import Foundation

public protocol GitPreparationDigest: AnyObject {
  func consume(_ bytes: Data)
  func finish() -> String
  func block(_ bytes: Data) -> Data
}
private final class GitPreparationPermission {
  private let check: () throws -> Void
  private var last = -Double.infinity
  init(_ check: @escaping () throws -> Void) { self.check = check }
  func poll(force: Bool = false) throws {
    let now = ProcessInfo.processInfo.systemUptime
    if force || now - last >= 0.05 { try check(); last = now }
  }
}

/// A two-pass recipe contains only offsets, flags and hashes. Raw text never spills.
/// Replaying the source lets a late suffix mask an arbitrarily long preceding unit.
public final class GitTextPreparation {
  private struct Receipt: Codable {
    var bytes: Int
    var digest: String
    var small: Bool
    var encoded: Bool
  }
  public let directory: URL
  private var small = Data()
  private var scanner: GitLexicalPlan?
  private let hash: GitPreparationDigest
  private var count = 0
  private var receipt: Receipt?
  private var output: FileHandle?
  private var plan: FileHandle?
  private var planBuffer = Data()
  private var planOffset = 0
  private var remaining = 0
  private var hidden = false
  private var outputCount = 0
  private var outputBuffer = Data()
  private var utf8 = GitUTF8Stream()
  private var replayCount = 0
  private var transferred = false
  private var blocks: FileHandle?
  private var block = Data()
  private let permission: GitPreparationPermission
  private let cancellation: GitTaskCancellation?

  public init(directory: URL, digest: GitPreparationDigest, cancellation: GitTaskCancellation? = nil, check: @escaping () throws -> Void = {}) throws {
    hash = digest
    self.cancellation = cancellation
    permission = GitPreparationPermission(check)
    self.directory = directory
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    blocks = try Self.file(directory.appendingPathComponent("blocks"))
  }
  public init(replaying directory: URL, digest: GitPreparationDigest, cancellation: GitTaskCancellation? = nil, check: @escaping () throws -> Void = {}) throws {
    hash = digest
    self.cancellation = cancellation
    permission = GitPreparationPermission(check)
    self.directory = directory
    receipt = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: directory.appendingPathComponent("receipt")))
    blocks = try FileHandle(forReadingFrom: directory.appendingPathComponent("blocks"))
    if receipt!.small { return }
    output = try Self.file(directory.appendingPathComponent("text"))
    plan = try FileHandle(forReadingFrom: directory.appendingPathComponent("plan"))
  }
  deinit {
    try? output?.close(); try? plan?.close(); try? blocks?.close()
    if !transferred {
      try? FileManager.default.removeItem(at: directory.appendingPathComponent("text"))
      GitScratchCleanup.discard(directory, cancellation: cancellation)
    }
  }
  private static func file(_ url: URL) throws -> FileHandle {
    guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
      throw CocoaError(.fileWriteUnknown)
    }
    return try FileHandle(forWritingTo: url)
  }
  public func consume(_ bytes: Data) throws {
    try permission.poll()
    if bytes.count > 4096 {
      var offset = bytes.startIndex
      while offset < bytes.endIndex {
        let end = min(bytes.endIndex, offset + 4096)
        try autoreleasepool { try consume(Data(bytes[offset..<end])) }; offset = end
      }
      return
    }
    hash.consume(bytes); count += bytes.count
    try checkBlocks(bytes, replay: false)
    if let scanner { try scanner.consume(bytes); return }
    if small.count + bytes.count <= 65536 { small.append(bytes); return }
    let next = try GitLexicalPlan(file: directory.appendingPathComponent("plan"), permission: permission)
    var offset = small.startIndex
    while offset < small.endIndex {
      try permission.poll()
      let end = min(small.endIndex, offset + 4096)
      try next.consume(Data(small[offset..<end])); offset = end
    }
    small = Data()
    scanner = next
    try next.consume(bytes)
  }
  /// Persist the numeric recipe; the next Git invocation opens it one token at a time.
  public func seal() throws {
    try permission.poll(force: true)
    if !block.isEmpty { try blocks?.write(contentsOf: hash.block(block)); block = Data() }
    try blocks?.close(); blocks = nil
    let digest = hash.finish()
    if let scanner { try scanner.finish() }
    else { small = Data() }
    let value = Receipt(bytes: count, digest: digest, small: scanner == nil, encoded: scanner?.encoded ?? false)
    let file = try Self.file(directory.appendingPathComponent("receipt"))
    try file.write(contentsOf: JSONEncoder().encode(value)); try file.close()
    // The caller owns the recipe directory between passes.
    transferred = true
  }
  public var identity: String { receipt?.digest ?? "" }
  public func replay(_ bytes: Data) throws {
    try permission.poll()
    guard receipt != nil else { throw CocoaError(.fileReadCorruptFile) }
    hash.consume(bytes); replayCount += bytes.count
    try checkBlocks(bytes, replay: true)
  }
  private func checkBlocks(_ bytes: Data, replay: Bool) throws {
    var at = bytes.startIndex
    while at < bytes.endIndex {
      let end = min(bytes.endIndex, at + 65536 - block.count)
      block.append(contentsOf: bytes[at..<end]); at = end
      if block.count == 65536 {
        if replay { try verifiedReplayBlock() }
        else { try blocks?.write(contentsOf: hash.block(block)) }
        block.removeAll(keepingCapacity: true)
      }
    }
  }
  private func verifiedReplayBlock() throws {
    try permission.poll()
    guard let expected = try blocks?.read(upToCount: 32), expected == hash.block(block) else { throw CocoaError(.fileReadCorruptFile) }
    guard let receipt else { throw CocoaError(.fileReadCorruptFile) }
    // Small text is retained only during verified replay, never in the recipe
    // between passes. Abandoned recipes therefore contain no user text.
    if receipt.small { small.append(block); return }
    if receipt.encoded { return }
    let bytes = block
    var at = bytes.startIndex
    var clearStart = at
    while at < bytes.endIndex {
      if remaining == 0 {
        if planOffset == planBuffer.count {
          planBuffer = try plan?.read(upToCount: 65536) ?? Data(); planOffset = 0
        }
        guard planBuffer.count - planOffset >= 16 else { throw CocoaError(.fileReadCorruptFile) }
        remaining = Int(planBuffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: planOffset, as: UInt64.self).littleEndian })
        hidden = planBuffer[planOffset + 8] != 0; planOffset += 16
        guard remaining > 0 else { throw CocoaError(.fileReadCorruptFile) }
        if hidden {
          if clearStart < at { try emit(utf8.consume(Data(bytes[clearStart..<at]))) }
          try emit(utf8.finish()); try emit(Data(Redaction.secretMark.utf8))
        }
      }
      let end = min(bytes.endIndex, at + remaining)
      if hidden { clearStart = end }
      remaining -= end - at; at = end
    }
    if clearStart < at { try emit(utf8.consume(Data(bytes[clearStart..<at]))) }
  }
  public func finishReplay() throws -> GitMaskedText {
    try permission.poll(force: true)
    if !block.isEmpty { try verifiedReplayBlock(); block = Data() }
    guard let receipt, replayCount == receipt.bytes,
      hash.finish() == receipt.digest else {
      throw CocoaError(.fileReadCorruptFile)
    }
    guard (try blocks?.read(upToCount: 1))?.isEmpty != false else { throw CocoaError(.fileReadCorruptFile) }
    try blocks?.close(); blocks = nil
    if receipt.small {
      let value = Redaction.apply(AgentLogEventParser.safeString(String(decoding: small, as: UTF8.self))).text
      try permission.poll(force: true)
      let file = try Self.file(directory.appendingPathComponent("text"))
      try file.write(contentsOf: Data(value.utf8)); try file.close()
      small = Data()
    } else {
      if receipt.encoded { try emit(Data(Redaction.secretMark.utf8)) }
      else {
        guard remaining == 0, planOffset == planBuffer.count, (try plan?.read(upToCount: 1))?.isEmpty != false else { throw CocoaError(.fileReadCorruptFile) }
        try emit(utf8.finish())
      }
      try flush(); try output?.close(); output = nil
    }
    let text = directory.appendingPathComponent("text")
    let size = receipt.small ? try FileManager.default.attributesOfItem(atPath: text.path)[.size] as! Int : outputCount
    let owned = FileManager.default.temporaryDirectory.appendingPathComponent("activityprobe-git-masked-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    do { try FileManager.default.moveItem(at: text, to: owned.appendingPathComponent("text")) }
    catch { try? FileManager.default.removeItem(at: owned); throw error }
    return GitMaskedText(maskedFile: owned.appendingPathComponent("text"), byteCount: size, ownedDirectory: owned, cancellation: cancellation)
  }
  private func emit(_ bytes: Data) throws {
    outputCount += bytes.count; outputBuffer.append(bytes)
    if outputBuffer.count >= 65536 { try flush() }
  }
  private func flush() throws {
    if !outputBuffer.isEmpty { try output?.write(contentsOf: outputBuffer); outputBuffer.removeAll(keepingCapacity: true) }
  }
}

/// Repairs invalid UTF-8 exactly as String(decoding:as:) without splitting a valid scalar.
private struct GitUTF8Stream {
  private var carry = Data()
  mutating func consume(_ bytes: Data) -> Data {
    var input = carry; input.append(bytes); carry = Data()
    var end = input.count
    if end > 0 {
      var start = end - 1
      while start > 0, end - start < 4, (input[start] & 0xc0) == 0x80 { start -= 1 }
      let lead = input[start]
      let needed = (0xc2...0xdf).contains(lead) ? 2 : (0xe0...0xef).contains(lead) ? 3 : (0xf0...0xf4).contains(lead) ? 4 : 0
      if needed > end - start {
        carry = Data(input[start..<end]); end = start
      }
    }
    return Data(String(decoding: input.prefix(end), as: UTF8.self).utf8)
  }
  mutating func finish() -> Data {
    defer { carry = Data() }
    return Data(String(decoding: carry, as: UTF8.self).utf8)
  }
}

private final class GitLexicalPlan {
  private struct Context { var ordinal: Int; var text: String; var space: Bool }
  private let file: FileHandle
  private let permission: GitPreparationPermission
  private var records = Data()
  private var recordBase = 0
  private var ordinal = 0
  private var length = 0
  private var sample = Data()
  private var tail = Data()
  private var shapeProbe = Data()
  private var directoryProof = Redaction.GitDirectoryCertificate()
  private var hasSlash = false
  private var certifiedPath = false
  private var pathAtStart = true
  private var space = false
  private var quote: UInt8?
  private var escaped = false
  private var unsafeLong = false
  private var context: [Context] = []
  private var contextHead = 0
  private var pem = false
  private var structured: Bool?
  private var depth = 0
  private var sensitiveDepth: Int?
  // A masked subtree owns its receipt until its matching close. Nested keys
  // must not shorten that lifetime. Uncertifiable structure masks the suffix.
  private var maskedContainerDepth: Int?
  private var containers: [UInt8] = []
  private var uncertifiedContainer = false
  private var sensitiveNext = false
  private var sensitiveTail = false
  private var lastString: String?
  private var scalarCarry = Data()
  private var previous: UInt8 = 0
  private var beforePrevious: UInt8 = 0
  private var urlStart: Int?
  private var urlSchemeStart: Int?
  private var shapeWhitespace = true
  private var urlMaskStart: Int?
  private var whitespaceDecoder = GitUTF8Stream()
  private var unicodeWhitespace = true
  private var labelDecoder = GitUTF8Stream()
  private var labelProbe = GitLabelProbe()
  private var labelSpace = false
  private var labelHot = false
  private var unitLabel = false
  private var normalSample = Data()
  private var normalTail = Data()
  private var normalCount = 0
  private var unitContextAnchor = false
  private var contextRisk = 0
  private var uncertainLabel = false
  private var beginHeader = GitPEMHeader("-----BEGIN ")
  private var endHeader = GitPEMHeader("-----END ")
  private var unitPEM = false
  private var pemMaskStart: Int?
  private(set) var encoded = false

  init(file url: URL, permission: GitPreparationPermission) throws {
    self.permission = permission
    guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
    file = try FileHandle(forUpdating: url)
  }
  deinit { try? file.close() }
  func consume(_ incoming: Data) throws {
    var bytes = scalarCarry
    bytes.append(incoming); scalarCarry = Data()
    // Keep only an incomplete scalar between reads; recipes still address raw bytes.
    if let last = bytes.last, last >= 128 {
      var start = bytes.count - 1
      while start > 0 && bytes.count - start < 4 && bytes[start] & 0xc0 == 0x80 { start -= 1 }
      let lead = bytes[start]
      let needed = (0xc2...0xdf).contains(lead) ? 2 : (0xe0...0xef).contains(lead) ? 3 : (0xf0...0xf4).contains(lead) ? 4 : 0
      if needed > bytes.count - start {
        scalarCarry = Data(bytes[start...]); bytes = Data(bytes[..<start])
      }
    }
    try scan(bytes)
  }
  private func scan(_ bytes: Data) throws {
    var preceding = previous, earlier = beforePrevious, quoted = quote, escape = escaped, unitSpace = space
    var structure = structured, encoding = encoded
    try bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
      var start = 0, index = 0
      func append(_ end: Int) { space = unitSpace; add(Data(raw[start..<end])) }
      func flush(_ end: Int) throws {
        append(end); quote = quoted; escaped = escape
        try endUnit(); start = end; unitSpace = false
      }
      while index < raw.count {
        let byte = raw[index]
        if (byte == 45 || beginHeader.active), let first = beginHeader.consume(byte, ordinal: ordinal) {
          pem = true; unitPEM = true; pemMaskStart = min(pemMaskStart ?? first, first)
        }
        if (byte == 45 || endHeader.active), endHeader.consume(byte, ordinal: ordinal) != nil, pem { unitPEM = true; pem = false }
        if preceding == 92 && byte == 117 { encoding = true }
        var end = index + 1
        var whitespace = Redaction.gitASCIIWhitespace(byte)
        var shapeSpace = whitespace && byte < 128 && Redaction.gitShapeASCIIWhitespace(byte)
        if byte >= 128 {
          let scalarBytes = (0xc2...0xdf).contains(byte) ? 2 : (0xe0...0xef).contains(byte) ? 3 : (0xf0...0xf4).contains(byte) ? 4 : 1
          end = min(raw.count, index + scalarBytes)
          let candidate = Data(raw[index..<end])
          let decoded = String(decoding: candidate, as: UTF8.self)
          if Data(decoded.utf8) == candidate, let scalar = decoded.unicodeScalars.first {
            whitespace = Redaction.gitWhitespace(scalar)
            shapeSpace = Redaction.gitShapeWhitespace(scalar)
          } else {
            // A malformed lead must not swallow an ASCII quote or separator.
            end = index + 1; whitespace = false; shapeSpace = false
          }
        }
        if byte == 58 { urlSchemeStart = ordinal }
        if shapeSpace { urlStart = nil; urlSchemeStart = nil }
        else if byte == 47 {
          urlStart = preceding == 47 && earlier == 58 ? (urlSchemeStart ?? ordinal) : nil
        } else if byte == 64, let first = urlStart {
          urlMaskStart = min(urlMaskStart ?? first, first); urlStart = nil
        }
        earlier = preceding; preceding = byte
        if structure == nil, !whitespace {
          structure = byte >= 128 || byte == 123 || byte == 91 || byte == 34
          structured = structure
        }
        if let delimiter = quoted {
          if escape { escape = false }
          else if byte == 92 { escape = true }
          else if byte == delimiter { quoted = nil; try flush(index + 1) }
        } else if structure == true && (byte == 123 || byte == 125 || byte == 91 || byte == 93 || byte == 44 || byte == 58) {
          try flush(index); try flush(index + 1)
        } else if byte == 34 || byte == 39 {
          try flush(index); quoted = byte
        } else {
          if (length > 0 || index > start) && whitespace != unitSpace { try flush(index) }
          unitSpace = whitespace
        }
        index = end
      }
      append(raw.count)
    }
    previous = preceding; beforePrevious = earlier; quote = quoted; escaped = escape; space = unitSpace; encoded = encoding
  }
  private func add(_ bytes: Data) {
    guard !bytes.isEmpty else { return }
    let uniform = bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
      guard let first = raw.first, first >= 97 && first <= 122 else { return false }
      return raw.allSatisfy { $0 == first }
    }
    observeLabel(bytes, uniform: uniform)
    length += bytes.count
    if unicodeWhitespace || shapeWhitespace {
      let decoded = String(decoding: whitespaceDecoder.consume(bytes), as: UTF8.self)
      if unicodeWhitespace { unicodeWhitespace = decoded.unicodeScalars.allSatisfy { $0.properties.isWhitespace } }
      if shapeWhitespace { shapeWhitespace = decoded.unicodeScalars.allSatisfy { Redaction.gitShapeWhitespace($0) } }
    }
    if sample.count < 65536 { sample.append(bytes.prefix(65536 - sample.count)) }
    tail = bytes.count >= 512 ? Data(bytes.suffix(512)) : Data((tail + bytes).suffix(512))
    // Only letter components and certified slash paths can bypass whole-unit
    // masking. Dots, opposite quotes and other mixed punctuation fail closed;
    // their entropy boundaries cannot be inferred from an abbreviated window.
    var asciiLettersOnly = true
    if !unsafeLong && !uniform {
      var unicode = false
      unsafeLong = bytes.contains { byte in
        if byte >= 128 { unicode = true; asciiLettersOnly = false; return false }
        if byte == 34 || byte == 39 { asciiLettersOnly = false; return byte != sample.first }
        if byte == 47 { asciiLettersOnly = false; return false }
        return !(byte >= 65 && byte <= 90) && !(byte >= 97 && byte <= 122)
      }
      if !unsafeLong && unicode {
        unsafeLong = String(decoding: bytes, as: UTF8.self).unicodeScalars.contains {
          let matchingQuote = ($0 == "\"" || $0 == "'") && $0.value == sample.first.map(UInt32.init)
          return !$0.properties.isAlphabetic && $0 != "/" && !matchingQuote
        }
      }
    }
    if !unsafeLong {
      observePath(bytes, asciiLettersOnly: asciiLettersOnly)
      // Repeating one lowercase letter cannot introduce a new shape prefix.
      // Keep ample repeated context without rescanning every byte of giant runs.
      shapeProbe.append(uniform ? bytes.prefix(128) : bytes)
      if shapeProbe.count >= 4096 {
        inspectShapes()
        shapeProbe = Data(shapeProbe.suffix(512))
      }
    }
  }
  private func observePath(_ bytes: Data, asciiLettersOnly: Bool) {
    if asciiLettersOnly {
      // The preceding alphabet check certified every byte; directory recognition
      // needs their count, not another scalar-by-scalar scan of the same letters.
      directoryProof.appendASCII(97, count: bytes.count); pathAtStart = false
      return
    }
    for scalar in String(decoding: bytes, as: UTF8.self).unicodeScalars {
      if scalar == "\"" || scalar == "'" { continue }
      if scalar == "/" {
        hasSlash = true
        certifiedPath = certifiedPath || pathAtStart || directoryProof.isReadable
        directoryProof = Redaction.GitDirectoryCertificate()
      } else { directoryProof.append(scalar) }
      pathAtStart = false
    }
  }
  private func inspectShapes() {
    let text = String(decoding: shapeProbe, as: UTF8.self)
    // A candidate can need unbounded context (for example, JWT components).
    // A negative shared guard certifies this window; a positive one fails closed.
    if Redaction.mayMatch(text) { unsafeLong = true }
  }
  private func observeLabel(_ bytes: Data, uniform: Bool) {
    let decoded = labelDecoder.consume(bytes)
    guard !decoded.isEmpty else { return }
    let asciiRun = uniform || decoded.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
      var ascii = true
      for byte in raw {
        if byte == 58 || byte == 61 || (byte >= 48 && byte <= 57) { unitContextAnchor = true }
        if byte >= 128 || byte == 32 || (byte >= 9 && byte <= 13) { ascii = false }
      }
      return ascii
    }
    let normal: String
    if asciiRun { normal = String(decoding: decoded, as: UTF8.self); labelSpace = false }
    else {
      var scalars = String.UnicodeScalarView()
      for scalar in String(decoding: decoded, as: UTF8.self).unicodeScalars {
        if scalar.value == 0xff1a { unitContextAnchor = true }
        if Redaction.gitShapeWhitespace(scalar) {
          // Quoted units retain internal separators. Their oversized interior
          // cannot be certified by a single bounded exact-sanitizer invocation.
          unsafeLong = true
          if !labelSpace { scalars.append(" "); labelSpace = true }
        } else { scalars.append(scalar); labelSpace = false }
      }
      normal = String(scalars)
    }
    if labelHot, !normal.hasPrefix(" "), !normal.isEmpty { unitLabel = true }
    let normalBytes = Data(normal.utf8)
    normalCount += normalBytes.count
    if normalSample.count < 512 { normalSample.append(normalBytes.prefix(512 - normalSample.count)) }
    normalTail.append(normalBytes); normalTail = Data(normalTail.suffix(256))
    let hasAnchor = labelProbe.hasAnchor || normalBytes.contains { $0 == 58 || $0 == 61 || $0 >= 128 }
    let tail = hasAnchor && Redaction.gitLabelTail(labelProbe.text + normal)
    labelHot = (labelHot && !normal.contains(" ")) || tail
    unitLabel = unitLabel || tail
    labelProbe.append(normalBytes)
  }
  private func mark(_ index: Int) throws {
    if index >= recordBase { records[(index - recordBase) * 16 + 8] = 1; return }
    try file.seek(toOffset: UInt64(index * 16 + 8)); try file.write(contentsOf: Data([1])); try file.seekToEnd()
  }
  private func markRange(from first: Int, through last: Int) throws {
    var offset = first * 16
    let end = min(recordBase, last + 1) * 16
    while offset < end {
      try permission.poll()
      try file.seek(toOffset: UInt64(offset))
      let count = min(65536, end - offset)
      guard var bytes = try file.read(upToCount: count), bytes.count == count else { throw CocoaError(.fileReadCorruptFile) }
      for position in stride(from: 8, to: count, by: 16) { bytes[position] = 1 }
      try file.seek(toOffset: UInt64(offset)); try file.write(contentsOf: bytes); offset += count
    }
    for index in max(first, recordBase)...last { try mark(index) }
    try file.seekToEnd()
  }
  private func endUnit() throws {
    guard length > 0 else { return }
    if unicodeWhitespace || shapeWhitespace {
      let decoded = String(decoding: whitespaceDecoder.finish(), as: UTF8.self)
      if unicodeWhitespace { unicodeWhitespace = decoded.unicodeScalars.allSatisfy { $0.properties.isWhitespace } }
      if shapeWhitespace { shapeWhitespace = decoded.unicodeScalars.allSatisfy { Redaction.gitShapeWhitespace($0) } }
    }
    let separator = space || unicodeWhitespace
    if separator && shapeWhitespace { urlStart = nil; urlSchemeStart = nil }
    let raw = String(decoding: sample, as: UTF8.self)
    if raw.hasPrefix("\"") { sensitiveTail = false }
    let text = length <= 65536 ? raw : String(decoding: sample.prefix(512), as: UTF8.self) + String(decoding: tail, as: UTF8.self)
    // One lowercase character class cannot qualify as a random value. Known shapes
    // still use the shared guard, including all-letter dapi credentials.
    let plainWord = length <= 65536 && sample.allSatisfy { (97...122).contains($0) } && !Redaction.mayMatch(raw)
    let safe = length <= 65536 && !separator && !plainWord ? Redaction.apply(AgentLogEventParser.gitSafeString(raw, depth: structured == true ? depth : 0)).text : text
    if length > 65536 {
      if !RandomValueMask.lettersAreEntropyExempt || (hasSlash && !certifiedPath) { unsafeLong = true }
      if !unsafeLong { inspectShapes() }
    }
    let refusedStringDepth = raw.hasPrefix("\"") && AgentLogEventParser.gitSafeString("\"ordinary\"", depth: structured == true ? depth : 0).contains(Redaction.secretMark)
    var hide = maskedContainerDepth != nil || uncertifiedContainer || (separator && !unicodeWhitespace) || refusedStringDepth || pem || unitPEM || sensitiveDepth != nil || sensitiveTail || AgentLogEventParser.gitValueDepthRefused(depth) || (unitLabel && !separator)
      || (raw.hasPrefix("\"") && quote != nil)
    if !separator {
      let changedSecret = (safe != raw && (safe.contains(Redaction.secretMark) || safe.contains("[email]")))
        || (length <= 65536 && !plainWord && Redaction.gitUnitHasSecret(raw))
      hide = hide || (length <= 65536 ? changedSecret : unsafeLong)
      if structured == true {
        if text == ":" {
          if let lastString {
            let key = AgentLogEventParser.safeString(lastString)
            sensitiveNext = Redaction.applyKnownSecrets(key + "=invented-value").text != Redaction.applyKnownSecrets(key).text + "=invented-value"
            if sensitiveNext { sensitiveDepth = min(sensitiveDepth ?? depth, depth); hide = true }
          }
        } else if text == "{" || text == "[" {
          if sensitiveNext { sensitiveDepth = min(sensitiveDepth ?? depth, depth); sensitiveNext = false; hide = true }
          if hide && maskedContainerDepth == nil { maskedContainerDepth = depth }
          if containers.count < 64 { containers.append(text == "{" ? 125 : 93) }
          else { uncertifiedContainer = true; hide = true }
          depth += 1
          lastString = nil
        } else if text == "}" || text == "]" {
          if containers.last == (text == "}" ? 125 : 93) { containers.removeLast() }
          else { uncertifiedContainer = true; hide = true }
          depth = max(0, depth - 1)
          if maskedContainerDepth == depth { maskedContainerDepth = nil }
          if let sensitiveDepth, depth <= sensitiveDepth { self.sensitiveDepth = nil; sensitiveTail = true }
          lastString = nil
        } else if text == "," {
          sensitiveNext = false; lastString = nil
          if let sensitiveDepth, depth <= sensitiveDepth { self.sensitiveDepth = nil; sensitiveTail = true }
        } else {
          if sensitiveNext { hide = true; sensitiveNext = false }
          lastString = text.hasPrefix("\"") ? (length > 65536 ? "password"
            : (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])) as? String) : nil
        }
      }
    }
    if uncertainLabel && !separator {
      hide = true; labelHot = true; uncertainLabel = false
    }
    // A label may be buried in the middle of an uncertifiable long name. Its
    // following value must fail closed even when bounded context omits that name.
    if length > 65536 && unitContextAnchor { uncertainLabel = true }
    var record = Data()
    var size = UInt64(length).littleEndian
    withUnsafeBytes(of: &size) { record.append(contentsOf: $0) }
    record.append(hide ? 1 : 0); record.append(Data(repeating: 0, count: 7))
    records.append(record)
    if let first = urlMaskStart { try markRange(from: first, through: ordinal); urlMaskStart = nil }
    if let first = pemMaskStart { try markRange(from: first, through: ordinal); pemMaskStart = nil }
    // Normalize only separator runs. This retains unlimited lookbehind whitespace with
    // bounded context, while keeping line boundaries for quoted/recovery rules.
    // Folding separator runs keeps arbitrarily long Unicode lookbehind from consuming
    // the context window. Both ends of a long name remain available to its label rule.
    let snippet = separator ? (raw.contains("\n") || raw.contains("\r") ? "\n" : unicodeWhitespace ? " " : String(raw.prefix(512)))
      : String(decoding: normalCount <= 512 ? normalSample : normalSample.prefix(256) + normalTail, as: UTF8.self)
    let entry = Context(ordinal: ordinal, text: snippet, space: separator)
    if context.count < 96 { context.append(entry) }
    else { context[contextHead] = entry; contextHead = (contextHead + 1) % 96 }
    contextRisk = unitContextAnchor ? 96 : max(0, contextRisk - 1)
    if contextRisk > 0 {
      let ordered = contextHead == 0 ? context : Array(context[contextHead...]) + Array(context[..<contextHead])
      let masking = Redaction.gitContextMasks(ordered.map(\.text).joined())
      if !separator, masking.continuingLabel { labelHot = true }
      if !masking.ranges.isEmpty {
        var offset = 0
        for unit in ordered {
          let range = NSRange(location: offset, length: (unit.text as NSString).length)
          if masking.ranges.contains(where: { NSIntersectionRange($0, range).length > 0 }) { try mark(unit.ordinal) }
          offset += range.length
        }
      }
    }
    ordinal += 1; length = 0; sample.removeAll(keepingCapacity: true); tail.removeAll(keepingCapacity: true)
    if records.count >= 65536 + 96 * 16 {
      try file.seekToEnd(); try file.write(contentsOf: records.prefix(65536))
      records = Data(records.dropFirst(65536)); recordBase += 4096
    }
    unsafeLong = false; space = false; unitPEM = false; shapeProbe.removeAll(keepingCapacity: true)
    directoryProof = Redaction.GitDirectoryCertificate(); hasSlash = false; certifiedPath = false; pathAtStart = true
    // A quoted-looking first value can still use the exact rule's unquoted
    // fallback (notably empty quotes). Keep the receipt until actual whitespace.
    unitLabel = false
    whitespaceDecoder = GitUTF8Stream(); unicodeWhitespace = true; shapeWhitespace = true
    normalSample.removeAll(keepingCapacity: true); normalTail.removeAll(keepingCapacity: true); normalCount = 0
    unitContextAnchor = false
  }
  func finish() throws {
    if !scalarCarry.isEmpty { let pending = scalarCarry; scalarCarry = Data(); try scan(pending) }
    try endUnit(); try file.seekToEnd(); try file.write(contentsOf: records)
    records = Data(); try file.synchronize(); try file.close()
  }
}

/// Ordinary words need lookbehind storage, but no regex or String reconstruction until
/// a separator could introduce a credential value. The ring keeps that cost bounded.
private struct GitLabelProbe {
  private var bytes = [UInt8](repeating: 0, count: 256)
  private var count = 0
  private var next = 0
  private var anchors = 0
  var hasAnchor: Bool { anchors > 0 }
  private func anchor(_ byte: UInt8) -> Bool { byte == 58 || byte == 61 || byte >= 128 }
  mutating func append(_ incoming: Data) {
    if incoming.count >= 256 {
      bytes = Array(incoming.suffix(256)); count = 256; next = 0
      anchors = bytes.reduce(0) { $0 + (anchor($1) ? 1 : 0) }
      return
    }
    for byte in incoming {
      if count == 256 { if anchor(bytes[next]) { anchors -= 1 } }
      else { count += 1 }
      bytes[next] = byte
      if anchor(byte) { anchors += 1 }
      next = (next + 1) & 255
    }
  }
  var text: String {
    if count < 256 { return String(decoding: bytes.prefix(count), as: UTF8.self) }
    return String(decoding: bytes[next...] + bytes[..<next], as: UTF8.self)
  }
}

/// Header candidates can be arbitrarily long. Only a suffix and a source ordinal survive.
private struct GitPEMHeader {
  private let prefix: [UInt8]
  private var index = 0
  private var first = 0
  private var dashRun = 0
  private var tail: String?
  private var closingDashes = 0
  private(set) var active = false
  init(_ prefix: String) { self.prefix = Array(prefix.utf8) }
  mutating func consume(_ byte: UInt8, ordinal: Int) -> Int? {
    if var header = tail {
      if closingDashes > 0 {
        if byte == 45 {
          closingDashes += 1
          if closingDashes == 5 { tail = nil; closingDashes = 0; active = false; return first }
          return nil
        }
        tail = nil; closingDashes = 0
      } else if byte == 45, header.hasSuffix("PRIVATE KEY") {
        closingDashes = 1; return nil
      } else if byte == 32 || (byte >= 65 && byte <= 90) {
        header.append(Character(UnicodeScalar(byte))); tail = String(header.suffix(32)); return nil
      } else { tail = nil }
    }
    dashRun = byte == 45 ? min(dashRun + 1, 5) : 0
    if byte == prefix[index] {
      if index == 0 { first = ordinal }
      index += 1
      if index == prefix.count { index = 0; tail = ""; closingDashes = 0 }
    } else {
      index = min(dashRun, 5)
      if index > 0 { first = ordinal }
    }
    active = index > 0 || tail != nil
    return nil
  }
}
