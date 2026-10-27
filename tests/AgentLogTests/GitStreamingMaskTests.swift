@testable import Core
import Foundation
import Inbound
import XCTest

final class GitStreamingMaskTests: XCTestCase {
  private var root: URL!
  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("invented-git-mask-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  }
  override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

  func prepare(_ raw: Data, chunk: Int = 65536) throws -> (String, [Bool]) {
    let directory = root.appendingPathComponent(UUID().uuidString)
    let first = try GitTextPreparation(directory: directory, digest: GitSHA256Digest())
    var cursor = 0
    while cursor < raw.count {
      let end = min(raw.count, cursor + chunk)
      try autoreleasepool { try first.consume(Data(raw[cursor..<end])) }; cursor = end
    }
    try first.seal()
    var hidden = [Bool](repeating: false, count: raw.count)
    if raw.count > 65536 {
      let receipt = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("receipt"))) as! [String: Any]
      if receipt["encoded"] as? Bool == true { hidden = [Bool](repeating: true, count: raw.count) }
      else {
        let plan = try Data(contentsOf: directory.appendingPathComponent("plan"))
        var at = 0
        for offset in stride(from: 0, to: plan.count, by: 16) {
          let length = Int(plan.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self).littleEndian })
          if plan[offset + 8] != 0 { for position in at..<at + length { hidden[position] = true } }
          at += length
        }
        XCTAssertEqual(at, raw.count)
      }
    }
    let second = try GitTextPreparation(replaying: directory, digest: GitSHA256Digest())
    cursor = 0
    while cursor < raw.count {
      let end = min(raw.count, cursor + chunk)
      try autoreleasepool { try second.replay(Data(raw[cursor..<end])) }; cursor = end
    }
    let value = try second.finishReplay()
    var bytes = Data(); try value.forEachChunk { bytes.append($0) }
    return (String(decoding: bytes, as: UTF8.self), hidden)
  }
  func exact(_ raw: Data) -> String { Redaction.apply(AgentLogEventParser.safeString(String(decoding: raw, as: UTF8.self))).text }

  func differential(_ input: String, chunk: Int, secretBytes: inout Int, extraBytes: inout Int, clearBytes: inout Int) throws {
    let data = Data(input.utf8)
    if data.count <= 65536 { XCTAssertEqual(try prepare(data, chunk: chunk).0, exact(data)); return }
    let (expected, ranges) = Redaction.gitTracePlain(input) { exact(data) }
    let (actual, hidden) = try prepare(data, chunk: chunk)
    _ = actual
    var required = [Bool](repeating: false, count: data.count)
    for nsRange in ranges {
      let range = try XCTUnwrap(Range(nsRange, in: input))
      let start = input[..<range.lowerBound].utf8.count
      for offset in start..<start + input[range].utf8.count { required[offset] = true }
    }
    var leaked = 0, firstLeak: Int?
    for index in required.indices {
      if required[index] {
        secretBytes += 1
        if !hidden[index] { leaked += 1; if firstLeak == nil { firstLeak = index } }
      } else {
        clearBytes += 1
        if hidden[index] { extraBytes += 1 }
      }
    }
    XCTAssertEqual(leaked, 0, "unmasked source bytes; first=\(firstLeak ?? -1), expected_bytes=\(expected.utf8.count)")
  }
  func testExactSmallFieldsIncludingExpansionInvalidUTF8AndSplits() throws {
    let corpus: [Data] = [65535, 65536].map { count in
      Data((String(repeating: "x", count: count - 46) + " sk-" + String(repeating: "a", count: 42)).utf8)
    } + [Data(), Data("Invented plain text 한글".utf8), Data([255, 0xc3, 40]),
      Data("password = \"invented two words\"".utf8), Data("[\"\(String(repeating: "/", count: 40000))\"]".utf8),
      Data((String(repeating: "x", count: 65480) + " sk-" + String(repeating: "a", count: 40)).utf8),
      Data("{\"password\":{\"nested\":\"invented\"},\"safe\":\"한글\"}".utf8)]
    for data in corpus {
      for chunk in [1, 3, 4095, 4096, 65535, 65536] { XCTAssertEqual(try prepare(data, chunk: chunk).0, exact(data)) }
    }
  }
  func testLargeDifferentialRandomAndAllSecretCrossingOffsets() throws {
    let keys = ["sk-" + String(repeating: "a", count: 40), "invented@example.test", "password = \"invented several words\"",
      "Authorization: Bearer " + String(repeating: "Ab3_", count: 8), "4111 1111 1111 1111",
      "seed phrase: alpha bravo cedar delta ember fable giant honey ivory joker karma lemon"]
    var required = 0, extra = 0, clear = 0, cases = 0
    for secret in keys {
      for offset in 0...secret.utf8.count {
        let input = String(repeating: "x", count: 65536 - offset) + " " + secret + "\npermitted한글\n"
        try differential(input, chunk: 65536, secretBytes: &required, extraBytes: &extra, clearBytes: &clear); cases += 1
      }
    }
    var seed: UInt64 = 0x17293
    let words = ["permitted", "ordinary", "changes", "한글", "docs/path.txt", "dbPassword", "=", "invented", "\"quoted text\""]
    for index in 0..<120 {
      var input = index % 2 == 0 ? String(repeating: "x", count: 65537) + "\n" : ""
      for _ in 0..<12 {
        seed = seed &* 6364136223846793005 &+ 1
        input += words[Int(seed % UInt64(words.count))] + (seed & 4 == 0 ? "\n" : " ")
      }
      input += keys[index % keys.count] + "\n"
      try differential(input, chunk: [7, 31, 65536][index % 3], secretBytes: &required, extraBytes: &extra, clearBytes: &clear); cases += 1
    }
    print("invented Git differential cases=\(cases) exact_masked_bytes=\(required) extra_masked_bytes=\(extra) nonsecret_bytes=\(clear) overmask_rate=\(Double(extra) / Double(max(1, clear)))")
  }
  func testLargeUnitsLongLookbehindDeepJSONAndEncodedFallback() throws {
    let huge = String(repeating: "x", count: 100000)
    for input in [huge, String(repeating: "한글", count: 20000)] {
      XCTAssertEqual(try prepare(Data(input.utf8), chunk: 13).0, input)
    }
    for secret in [huge + "@example.test", "https://" + huge + ":invented@example.test/path",
      huge + "password：invented-secret-value", huge + "password = invented-secret-value",
      "{\"password\":{\"nested\":\"invented-secret-value\"},\"safe\":\"" + huge + "\"}",
      String(repeating: "[", count: 30) + "\"invented-secret-value\"" + String(repeating: "]", count: 30) + huge,
      huge + "\\u0070assword=invented-secret-value", "-----BEGIN PRIVATE KEY-----\n" + huge + "\n-----END PRIVATE KEY-----\npermitted"] {
      let (masked, flags) = try prepare(Data(secret.utf8), chunk: 17)
      XCTAssertTrue(flags.contains(true))
      XCTAssertFalse(masked.contains("invented-secret-value"))
      if secret.contains("@") { XCTAssertFalse(masked.contains(huge)) }
    }
    var required = 0, extra = 0, clear = 0
    for input in [huge + "\n" + String(repeating: "0123456789abcdef", count: 2) + "\npermitted",
      huge + "\n" + String(repeating: "x", count: 5000) + "password = invented-secret-value\npermitted",
      huge + ".dapi" + String(repeating: "a", count: 32) + "/permitted"] {
      try differential(input, chunk: 23, secretBytes: &required, extraBytes: &extra, clearBytes: &clear)
    }
    let invalid = Data(huge.utf8) + Data([0xf0, 0x80, 0x80, 255]) + Data(" sk-\(String(repeating: "a", count: 40)) 한글".utf8)
    let masked = try prepare(invalid, chunk: 1).0
    XCTAssertFalse(masked.contains("sk-")); XCTAssertTrue(masked.contains("한글"))
    let json = "{\"safe\":\"" + huge + "\",\"nested\":" + String(repeating: "[ \n", count: 15)
      + "\"invented-secret-value\"" + String(repeating: "]", count: 15) + "}"
    let jsonResult = try prepare(Data(json.utf8), chunk: 19).0
    XCTAssertTrue(jsonResult.contains(huge)); XCTAssertFalse(jsonResult.contains("invented-secret-value"))
    let credentials = try prepare(Data((huge + "\nhttps://invented\"credential\"@example.test/path\npermitted").utf8), chunk: 29).0
    XCTAssertFalse(credentials.contains("credential")); XCTAssertFalse(credentials.contains("invented"))
    let lateURL = huge + "\nhttps://invented" + String(repeating: "\"credential\"", count: 5000) + "@example.test/path\npermitted"
    let lateResult = try prepare(Data(lateURL.utf8), chunk: 31).0
    XCTAssertFalse(lateResult.contains("credential")); XCTAssertFalse(lateResult.contains("invented"))
    let lateLabel = huge + "\npassword=first" + String(repeating: "\"credential\"", count: 5000) + "last\npermitted"
    let lateLabelResult = try prepare(Data(lateLabel.utf8), chunk: 37).0
    XCTAssertFalse(lateLabelResult.contains("credential")); XCTAssertFalse(lateLabelResult.contains("last"))
    for input in [huge + "\npassword " + String(repeating: "\u{2003}", count: 30000) + " = invented-secret-value\npermitted",
      huge + "\npassword=first\u{001C}second\npermitted"] {
      try differential(input, chunk: 23, secretBytes: &required, extraBytes: &extra, clearBytes: &clear)
    }
    let unfinished = try prepare(Data(("\"" + huge).utf8), chunk: 13)
    XCTAssertTrue(unfinished.1.allSatisfy { $0 }); XCTAssertFalse(unfinished.0.contains(huge))
    let recovery = "{\"password\": invented-primitive , \"safe\":\"" + huge + "\" INVALID}"
    let recoveryResult = try prepare(Data(recovery.utf8), chunk: 11)
    let fragment = Data(": invented-primitive , ".utf8)
    let fragmentRange = try XCTUnwrap(Data(recovery.utf8).range(of: fragment))
    XCTAssertTrue(recoveryResult.1[fragmentRange].allSatisfy { $0 })
    let repeatedRules = huge + "\nseed phrase: alpha bravo cedar delta ember fable giant honey ivory joker karma lemon sk-"
      + String(repeating: "a", count: 40) + "\npermitted"
    try differential(repeatedRules, chunk: 23, secretBytes: &required, extraBytes: &extra, clearBytes: &clear)
    let nonKey = huge + "\n-----BEGIN NOTE-----\npermitted\n"
    XCTAssertEqual(try prepare(Data(nonKey.utf8), chunk: 17).0, nonKey)
    let lowerKey = "dapi" + String(repeating: "a", count: 32)
    XCTAssertFalse(try prepare(Data((huge + "\n" + lowerKey + "\npermitted").utf8), chunk: 17).0.contains(lowerKey))
    let oversizedHeader = "-----BEGIN " + String(repeating: "LONG ", count: 5000) + "PRIVATE KEY-----\n"
      + "invented-secret-value\n-----END PRIVATE KEY-----\npermitted"
    let pemResult = try prepare(Data((huge + "\n" + oversizedHeader).utf8), chunk: 23).0
    XCTAssertFalse(pemResult.contains("invented-secret-value")); XCTAssertTrue(pemResult.contains("permitted"))
    let authorization = huge + "\nAuthorization" + String(repeating: "\u{2003}", count: 30000)
      + ": Bearer " + String(repeating: "a", count: 70000) + "\npermitted"
    XCTAssertFalse(exact(Data(authorization.utf8)).contains(String(repeating: "a", count: 70000)))
    let authorizationResult = try prepare(Data(authorization.utf8), chunk: 31).0
    XCTAssertFalse(authorizationResult.contains(String(repeating: "a", count: 70000)))
  }
  func testReplayRejectsChangedSourceAndDisposesOutput() throws {
    let directory = root.appendingPathComponent("changed")
    let first = try GitTextPreparation(directory: directory, digest: GitSHA256Digest())
    try first.consume(Data(repeating: 120, count: 70000)); try first.seal()
    let next = try GitTextPreparation(replaying: directory, digest: GitSHA256Digest())
    XCTAssertThrowsError(try next.replay(Data(repeating: 121, count: 70000)))
  }
}


extension GitStreamingMaskTests {
  func testOversizedJWTHasUnboundedComponentContext() throws {
    let jwt = "eyJ" + String(repeating: "a", count: 70000) + "." + String(repeating: "b", count: 70000) + "." + String(repeating: "c", count: 70000)
    let input = String(repeating: "x", count: 70000) + " " + jwt + " permitted"
    var required = 0, extra = 0, clear = 0
    for chunk in [1, 3, 4095, 4096, 65535, 65536] {
      try differential(input, chunk: chunk, secretBytes: &required, extraBytes: &extra, clearBytes: &clear)
    }
    XCTAssertGreaterThan(required, 210000)
  }
}

extension GitStreamingMaskTests {
  func testOversizedEntropyOnlyMixedUnitsFailClosed() throws {
    let alphabet = "abcdeflmnqruvwzABCDEFLMNQRUVWZ"
    let letters = String(repeating: alphabet, count: 4000)
    let huge = String(repeating: "x", count: 70000)
    let dotted = String(letters.prefix(35000)) + "." + String(letters.dropFirst(35000))
    for body in [dotted, "a/" + letters, "\"b'a/" + letters + "\""] {
      let input = huge + " " + body + " permitted"
      XCTAssertFalse(Redaction.mayMatch(input), "Must exercise entropy without a known-shape candidate")
      var required = 0, extra = 0, clear = 0
      for chunk in [1, 3, 4095, 4096, 65535, 65536] {
        try differential(input, chunk: chunk, secretBytes: &required, extraBytes: &extra, clearBytes: &clear)
      }
      XCTAssertGreaterThan(required, 65536)
    }
  }
}

extension GitStreamingMaskTests {
  func testLongURLCredentialsKeepSchemeAcrossUnitsAndRegexNonWhitespace() throws {
    let quoted = String(repeating: "\"credential\"", count: 7000)
    let inputs = ["[https://invented" + quoted + "@example.test]",
      "[https://invented\u{001C}" + quoted + "@example.test]",
      "★https://invented" + quoted + "@example.test",
      String(repeating: "x", count: 70000) + "\nhttps://invented\u{001C}" + quoted + "@example.test"]
    for input in inputs {
      var required = 0, extra = 0, clear = 0
      for chunk in [1, 3, 4095, 4096, 65535, 65536] {
        try differential(input, chunk: chunk, secretBytes: &required, extraBytes: &extra, clearBytes: &clear)
      }
      XCTAssertGreaterThan(required, 65536)
    }
  }
  func testEmptyQuotedLabelUsesExactUnquotedFallbackAcrossUnits() throws {
    for quotes in ["\"\"", "''"] {
      let input = String(repeating: "x", count: 70000) + "\npassword=" + quotes + String(repeating: quotes, count: 50000) + "last\npermitted"
      var required = 0, extra = 0, clear = 0
      for chunk in [1, 3, 4095, 4096, 65535, 65536] {
        try differential(input, chunk: chunk, secretBytes: &required, extraBytes: &extra, clearBytes: &clear)
      }
      XCTAssertGreaterThan(required, 65536)
    }
  }
}
