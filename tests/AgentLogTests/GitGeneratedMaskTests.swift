@testable import Core
import Foundation
import SQLite3
@testable import Storage
import XCTest

private indirect enum InventedJSON {
  case string(String, escaped: Bool = false)
  case array([InventedJSON])
  case object([(String, InventedJSON)])
}
private struct InventedJSONSource {
  struct Span { var bytes: Range<Int>; var decoded: [Range<Int>] = [] }
  var bytes = Data()
  var spans: [String: Span] = [:]
  mutating func write(_ node: InventedJSON, path: [String] = []) {
    let start = bytes.count
    var decoded: [Range<Int>] = []
    func key(_ path: [String]) -> String { path.joined(separator: "/") }
    switch node {
    case .string(let value, let escaped):
      bytes.append(34)
      for scalar in value.unicodeScalars {
        let at = bytes.count
        let piece: String
        switch scalar.value {
        case 34: piece = "\\\""
        case 92: piece = "\\\\"
        case 10: piece = "\\n"
        case 13: piece = "\\r"
        case 9: piece = "\\t"
        case 0..<32: piece = String(format: "\\u%04x", scalar.value)
        default:
          piece = escaped && scalar.value > 127 && scalar.value <= 65535
            ? String(format: "\\u%04x", scalar.value) : String(scalar)
        }
        bytes.append(contentsOf: piece.utf8)
        for _ in 0..<(scalar.value > 65535 ? 2 : 1) { decoded.append(at..<bytes.count) }
      }
      bytes.append(34)
    case .array(let values):
      bytes.append(91)
      for (index, value) in values.enumerated() {
        if index > 0 { bytes.append(44) }
        write(value, path: path + ["a:\(index)"])
      }
      bytes.append(93)
    case .object(let values):
      bytes.append(123)
      for (index, pair) in values.enumerated() {
        if index > 0 { bytes.append(44) }
        write(.string(pair.0), path: path + ["key:" + pair.0])
        bytes.append(58); write(pair.1, path: path + ["k:" + pair.0])
      }
      bytes.append(125)
    }
    spans[key(path)] = Span(bytes: start..<bytes.count, decoded: decoded)
  }
}

extension GitStreamingMaskTests {
  func testSeededLargeGrammarDifferentialSourcePositions() throws {
    let chunks = [1, 3, 4095, 4096, 65535, 65536]
    let spaces = [" ", "\t", "\n", "\r", "\u{000B}", "\u{000C}", "\u{001C}", "\u{001D}", "\u{001E}", "\u{001F}", "\u{0085}", "\u{00A0}", "\u{1680}"]
      + (0x2000...0x200A).map { String(UnicodeScalar($0)!) }
      + ["\u{2028}", "\u{2029}", "\u{202F}", "\u{205F}", "\u{3000}", "\u{FEFF}"]
    let randomOnly = "azbycxdwevfugthsirjqkplom_n"
    let huge = String(repeating: "x", count: 70000)
    var seed: UInt64 = 0x7b51b69d03111
    func next() -> UInt64 { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return seed }
    var cases = 0, failures = 0, required = 0, extra = 0, clear = 0
    func compare(_ data: Data, required flags: [Bool], chunk: Int) throws {
      XCTAssertGreaterThan(data.count, 65536)
      let (_, hidden) = try prepare(data, chunk: chunk)
      var leaked = 0
      for i in flags.indices {
        if flags[i] { required += 1; if !hidden[i] { leaked += 1 } }
        else { clear += 1; if hidden[i] { extra += 1 } }
      }
      if leaked > 0 { failures += 1 }
      XCTAssertEqual(leaked, 0, "grammar case=\(cases) chunk=\(chunk) leaked source bytes")
      cases += 1
    }
    // Every Unicode separator occurs inside a mixed oversized run; read=1 forces
    // every multibyte scalar to cross a read boundary.
    for space in spaces {
      for variant in 0..<3 {
        let body = variant == 0 ? randomOnly : variant == 1 ? "password = invented-value" : "https://" + String(repeating: "q", count: 1000) + ":invented@example.test/path"
        let input = huge + space + body + space + huge
        let (_, ranges) = Redaction.gitTracePlain(input) { exact(Data(input.utf8)) }
        var flags = [Bool](repeating: false, count: input.utf8.count)
        for ns in ranges {
          let r = try XCTUnwrap(Range(ns, in: input))
          let offset = input[..<r.lowerBound].utf8.count
          for i in offset..<offset + input[r].utf8.count { flags[i] = true }
        }
        for chunk in chunks { try compare(Data(input.utf8), required: flags, chunk: chunk) }
      }
    }
    let longJWT = "eyJ" + String(repeating: "a", count: 70000) + "." + String(repeating: "b", count: 70000) + "." + String(repeating: "c", count: 70000)
    let unbounded = huge + " " + longJWT + " permitted"
    let (_, unboundedRanges) = Redaction.gitTracePlain(unbounded) { exact(Data(unbounded.utf8)) }
    var unboundedFlags = [Bool](repeating: false, count: unbounded.utf8.count)
    for ns in unboundedRanges {
      let r = try XCTUnwrap(Range(ns, in: unbounded))
      let offset = unbounded[..<r.lowerBound].utf8.count
      for i in offset..<offset + unbounded[r].utf8.count { unboundedFlags[i] = true }
    }
    for chunk in chunks { try compare(Data(unbounded.utf8), required: unboundedFlags, chunk: chunk) }
    let entropyLetters = String(repeating: "abcdeflmnqruvwzABCDEFLMNQRUVWZ", count: 4000)
    let dottedLetters = String(entropyLetters.prefix(35000)) + "." + String(entropyLetters.dropFirst(35000))
    let pathForms: [(String, String)] = [("", ""), ("a/", ""), ("ab/", ""), ("/", ""),
      ("a/b/", ""), ("a/bb/", ""), ("a//", ""), ("α/", ""),
      ("\"b'a/", "\""), ("'b\"a/", "'"), ("\"ab/", "\""), ("'a/", "'")]
    for (prefix, suffix) in pathForms {
      for value in [entropyLetters, dottedLetters] {
        let input = huge + " " + prefix + value + suffix + " permitted"
        XCTAssertFalse(Redaction.mayMatch(input), "Exercise entropy-only mixed units")
        let (_, ranges) = Redaction.gitTracePlain(input) { exact(Data(input.utf8)) }
        var flags = [Bool](repeating: false, count: input.utf8.count)
        for ns in ranges {
          let r = try XCTUnwrap(Range(ns, in: input))
          let offset = input[..<r.lowerBound].utf8.count
          for i in offset..<offset + input[r].utf8.count { flags[i] = true }
        }
        for chunk in chunks { try compare(Data(input.utf8), required: flags, chunk: chunk) }
      }
    }
    let quoteRun = String(repeating: "\"credential\"", count: 7000)
    var spans = ["[https://invented" + quoteRun + "@example.test]",
      "[https://invented\u{001C}" + quoteRun + "@example.test]",
      "★https://invented" + quoteRun + "@example.test",
      huge + "\nhttps://invented\u{001C}" + quoteRun + "@example.test"]
    for quotes in ["\"\"", "''"] {
      spans.append(huge + "\npassword=" + quotes + String(repeating: quotes, count: 50000) + "last\npermitted")
    }
    for input in spans {
      let (_, ranges) = Redaction.gitTracePlain(input) { exact(Data(input.utf8)) }
      XCTAssertGreaterThan(ranges.reduce(0) { $0 + $1.length }, 65536)
      var flags = [Bool](repeating: false, count: input.utf8.count)
      for ns in ranges {
        let r = try XCTUnwrap(Range(ns, in: input))
        let offset = input[..<r.lowerBound].utf8.count
        for i in offset..<offset + input[r].utf8.count { flags[i] = true }
      }
      for chunk in chunks { try compare(Data(input.utf8), required: flags, chunk: chunk) }
    }
    // Valid JSON with array/object ancestry, sensitive/non-sensitive keys and
    // exact refusal depths 0...20. Source locations survive key reordering.
    for depth in 0...20 {
      for variant in 0..<4 {
        let lexicalSize = [65535, 65536, 65537, 70002][variant]
        let payload = variant == 3 ? "ordinary 한글 \\" + huge : String(repeating: "x", count: lexicalSize - 2)
        let secret = [randomOnly, "password = invented-value", "https://" + huge + ":invented@example.test/path", "ordinary\n한글"][Int(next() % 4)]
        var node: InventedJSON = .string(payload, escaped: variant == 3)
        for level in 0..<depth {
          switch next() % 3 {
          case 0: node = .array([.string("ordinary"), node])
          case 1: node = .object([("ordinary", node), ("note", .string(secret))])
          default: node = .object([(level % 3 == 0 ? "password" : "ordinary", node)])
          }
        }
        var source = InventedJSONSource(); source.write(node)
        // Legal trailing JSON whitespace crosses the field bound without changing
        // any value's depth or the lexical-unit boundary under investigation.
        if source.bytes.count <= 65536 { source.bytes.append(Data(repeating: 32, count: 65537 - source.bytes.count)) }
        let input = String(decoding: source.bytes, as: UTF8.self)
        let (traced, positions) = AgentLogEventParser.gitTraceJSON(input)
        XCTAssertEqual(traced, exact(source.bytes))
        var flags = [Bool](repeating: false, count: source.bytes.count)
        for position in positions {
          let span = try XCTUnwrap(source.spans[position.path.joined(separator: "/")])
          if let ranges = position.ranges {
            for range in ranges {
              for unit in range.location..<NSMaxRange(range) {
                for byte in span.decoded[unit] { flags[byte] = true }
              }
            }
          } else { for byte in span.bytes { flags[byte] = true } }
        }
        for chunk in chunks { try compare(source.bytes, required: flags, chunk: chunk) }
      }
    }
    print("invented seeded grammar differential seed=0x7b51b69d03111 cases=\(cases) failures=\(failures) exact_masked_bytes=\(required) extra_masked_bytes=\(extra) nonsecret_bytes=\(clear) overmask_rate=\(Double(extra) / Double(max(1, clear)))")
  }
  func testMaskedJSONContainersRetainAllTrailingSiblings() throws {
    var cases = 0, required = 0, extra = 0, clear = 0
    for depth in Array(0...20) + [63, 64, 65] {
      for variant in 0..<3 {
        let huge = String(repeating: "q", count: [65534, 65536, 70001][variant])
        var node: InventedJSON = .array([.string(huge), .string("invented@example.test")])
        for level in 0..<depth {
          if (level + variant) % 2 == 0 {
            node = .array([node, .string("ordinary sibling")])
          } else {
            let key = variant == 0 ? "ordinary" : level % 3 == 0 ? "password" : "memo"
            node = .object([(key, node), ("a", .string("arbitrary sibling"))])
          }
        }
        // This root sibling is outside any masked inner container.
        node = .object([("ordinary", node), ("tail", .string("permitted"))])
        var source = InventedJSONSource(); source.write(node)
        let input = String(decoding: source.bytes, as: UTF8.self)
        let (traced, positions) = AgentLogEventParser.gitTraceJSON(input)
        XCTAssertEqual(traced, exact(source.bytes))
        var flags = [Bool](repeating: false, count: source.bytes.count)
        for position in positions {
          let span = try XCTUnwrap(source.spans[position.path.joined(separator: "/")])
          if let ranges = position.ranges {
            for range in ranges {
              for unit in range.location..<NSMaxRange(range) {
                for byte in span.decoded[unit] { flags[byte] = true }
              }
            }
          } else { for byte in span.bytes { flags[byte] = true } }
        }
        for chunk in [1, 3, 4095, 4096, 65535, 65536] {
          let (output, hidden) = try prepare(source.bytes, chunk: chunk)
          var leaked = 0
          for i in flags.indices {
            if flags[i] { required += 1; if !hidden[i] { leaked += 1 } }
            else { clear += 1; if hidden[i] { extra += 1 } }
          }
          XCTAssertEqual(leaked, 0, "depth=\(depth) variant=\(variant) chunk=\(chunk)")
          if depth < 63 { XCTAssertTrue(output.contains("permitted")) }
          cases += 1
        }
      }
    }
    print("invented trailing-sibling differential cases=\(cases) failures=0 exact_masked_bytes=\(required) extra_masked_bytes=\(extra) nonsecret_bytes=\(clear) overmask_rate=\(Double(extra) / Double(max(1, clear)))")
  }
  func testUncertifiableJSONContainersMaskRemainingField() throws {
    let huge = String(repeating: "q", count: 70001)
    let overflow = String(repeating: "[", count: 65) + "\"" + huge + "\"" + String(repeating: "]", count: 65) + " permitted"
    let mismatch = "{\"password\":[\"" + huge + "\"},\"a\":\"arbitrary sibling\"} permitted"
    for input in [overflow, mismatch] {
      let data = Data(input.utf8)
      for chunk in [1, 3, 4095, 4096, 65535, 65536] {
        let (output, hidden) = try prepare(data, chunk: chunk)
        XCTAssertTrue(hidden.suffix(10).allSatisfy { $0 })
        XCTAssertFalse(output.contains("permitted"))
      }
    }
  }
  func testOversizedQuotedValuesAtExactDepthBoundary() throws {
    for depth in [10, 11, 12] {
      for size in [65535, 65536, 65537, 70002] {
        for object in [false, true] {
          var node: InventedJSON = .string(String(repeating: "x", count: size - 2))
          for _ in 0..<depth { node = object ? .object([("ordinary", node)]) : .array([node]) }
          var source = InventedJSONSource(); source.write(node)
          let exactValue = exact(source.bytes)
          for chunk in [1, 3, 4095, 4096, 65535, 65536] {
            let (masked, hidden) = try prepare(source.bytes, chunk: chunk)
            if exactValue.contains(String(repeating: "x", count: 100)) { continue }
            let leafPath = (0..<depth).map { _ in object ? "k:ordinary" : "a:0" }.joined(separator: "/")
            let leaf = try XCTUnwrap(source.spans[leafPath])
            XCTAssertTrue(hidden[leaf.bytes].allSatisfy { $0 }, "depth=\(depth) lexical bytes=\(size) chunk=\(chunk)")
            XCTAssertFalse(masked.contains(String(repeating: "x", count: 100)))
          }
        }
      }
    }
  }
}

extension GitCollectionTests {
  func testProductionCommitsMaskDepthElevenAndUnicodeRandomValue() throws {
    let huge = String(repeating: "x", count: 70000)
    let token = "azbycxdwevfugthsirjqkplom_n"
    var hashes: [(String, Bool)] = []
    for depth in [10, 11, 12] {
      let message = root.appendingPathComponent("invented-depth-message")
      let body = String(repeating: "[", count: depth) + "\"" + huge + "\"" + String(repeating: "]", count: depth)
      try Data(body.utf8).write(to: message)
      try git(["commit", "--allow-empty", "--quiet", "-F", message.path])
      hashes.append((try git(["rev-parse", "HEAD"]), depth >= 11))
    }
    let message = root.appendingPathComponent("invented-unicode-message")
    try Data((huge + "\u{2003}" + token + "\u{2003}" + huge).utf8).write(to: message)
    try git(["commit", "--allow-empty", "--quiet", "-F", message.path])
    let unicodeHash = try git(["rev-parse", "HEAD"])
    try observe(); try scan()
    for (hash, hidden) in hashes + [(unicodeHash, false)] {
      let id = try store.connection.integer("SELECT id FROM git_commits WHERE hash=? AND complete=1", [.key(hash)])
      XCTAssertGreaterThan(id, 0)
      var text = ""
      try store.connection.namedRows("SELECT message FROM git_commits WHERE id=?", [.integer(id)]) { text = try $0.text("message") }
      try store.connection.rows("SELECT payload FROM git_commit_text WHERE commit_id=? AND field=2 ORDER BY ordinal", [.integer(id)]) { row in
        if let bytes = sqlite3_column_blob(row, 0) {
          text += String(decoding: Data(bytes: bytes, count: Int(sqlite3_column_bytes(row, 0))), as: UTF8.self)
        }
      }
      XCTAssertEqual(text.contains(huge), !hidden)
      XCTAssertFalse(text.contains(token))
    }
  }
}
