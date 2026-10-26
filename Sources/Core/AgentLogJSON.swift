import Foundation

/// Foundation on macOS keeps the first duplicate member and accepts trailing commas.
/// The bounded full-record decoder uses the same strict grammar and last-member policy as metadata.
enum AgentLogJSON {
  // Valid JSON numbers can exceed Foundation's finite numeric representation.
  struct Number { let token: String }
  static func object(_ data: Data) -> Any? {
    var decoder = Decoder(bytes: Array(data))
    do {
      let value = try decoder.value()
      decoder.whitespace()
      return decoder.index == decoder.bytes.count ? value : nil
    } catch { return nil }
  }
  private enum Invalid: Error { case json }
  private struct Decoder {
    let bytes: [UInt8]
    var index = 0
    var depth = 0
    mutating func whitespace() {
      while index < bytes.count && [9,10,13,32].contains(bytes[index]) { index += 1 }
    }
    mutating func take(_ byte: UInt8) -> Bool {
      whitespace()
      guard index < bytes.count, bytes[index] == byte else { return false }
      index += 1; return true
    }
    mutating func string() throws -> String {
      whitespace()
      let start = index
      guard index < bytes.count, bytes[index] == 34 else { throw Invalid.json }
      index += 1
      var escaped = false
      var hasEscape = false
      while index < bytes.count {
        let byte = bytes[index]; index += 1
        guard byte >= 32 else { throw Invalid.json }
        if escaped { escaped = false }
        else if byte == 92 { escaped = true; hasEscape = true }
        else if byte == 34 {
          // Foundation replaces malformed UTF-8 in some escaped strings. The
          // metadata scanner rejects it, so validate bytes before delegating escapes.
          guard String(bytes: bytes[start..<index], encoding: .utf8) != nil else { throw Invalid.json }
          if !hasEscape {
            guard let value = String(bytes: bytes[(start+1)..<(index-1)], encoding: .utf8) else { throw Invalid.json }
            return value
          }
          guard let value = try JSONSerialization.jsonObject(with: Data(bytes[start..<index]), options: [.fragmentsAllowed]) as? String
          else { throw Invalid.json }
          return value
        }
      }
      throw Invalid.json
    }
    mutating func value() throws -> Any {
      whitespace()
      guard index < bytes.count else { throw Invalid.json }
      if bytes[index] == 34 { return try string() }
      if take(123) {
        guard depth < AgentLogMetadata.nestingLimit else { throw Invalid.json }
        depth += 1; defer { depth -= 1 }
        var object: [String: Any] = [:]
        if take(125) { return object }
        repeat {
          let key = try string()
          guard take(58) else { throw Invalid.json }
          object[key] = try value()
          if take(125) { return object }
        } while take(44)
        throw Invalid.json
      }
      if take(91) {
        guard depth < AgentLogMetadata.nestingLimit else { throw Invalid.json }
        depth += 1; defer { depth -= 1 }
        var array: [Any] = []
        if take(93) { return array }
        repeat {
          array.append(try value())
          if take(93) { return array }
        } while take(44)
        throw Invalid.json
      }
      let start = index
      while index < bytes.count && ![9,10,13,32,44,93,125].contains(bytes[index]) { index += 1 }
      guard index > start else { throw Invalid.json }
      let token = Data(bytes[start..<index])
      var grammar = AgentLogMetadata()
      for byte in token { grammar.consume(byte) }
      guard grammar.complete else { throw Invalid.json }
      if let value = try? JSONSerialization.jsonObject(with: token, options: [.fragmentsAllowed]),
        (value as? NSNumber)?.doubleValue.isFinite != false { return value }
      return Number(token: String(decoding: token, as: UTF8.self))
    }
  }
}
