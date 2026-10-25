import Foundation
import XCTest
@testable import Core

final class RedactionShapeTests: XCTestCase {
  static let value = "aB7xQ2pL9mR4zT6v"
  static let labels = ["password", "비밀번호", "パスワード", "密码", "密碼", "Passwort", "mot_de_passe", "contraseña", "senha"]

  func testInventedSecretKindsInEveryContext() throws {
    let secrets = [Self.value, Self.value + "_-", Self.value + "+/nF8dH1sW5uC0",
                   "!aB7xQ2pL9mR4zT6v$", String(repeating: Self.value, count: 4),
                   "7QxL2pBm9RzT4vAc"]
    for (kind, value) in secrets.enumerated() {
      XCTAssertTrue(RandomValueMask.accepts(value), "invented kind \(kind)")
      for label in Self.labels {
        for text in [label + ": " + value, label + "=" + value] {
          XCTAssertFalse(redactSecrets(text).contains(value), "invented kind \(kind)")
        }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: [label: value]), as: UTF8.self)
        let clean = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(redactSecrets(json).utf8)) as? [String: String])
        XCTAssertEqual(clean[label], Redaction.secretMark)
        let encoded = value.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let query = "https://invented.invalid/read?" + label + "=" + encoded
        let expected = label == "password" ? "https://invented.invalid/read?[secret]" : "https://invented.invalid/read?" + label + "=" + Redaction.secretMark
        XCTAssertEqual(redactSecrets(query), expected)
      }
      for text in [value, "shown " + value + " end", "\n" + value + "\n", "[\"" + value + "\"]"] {
        XCTAssertFalse(redactSecrets(text).contains(value))
      }
    }
  }

  func testLengthClassesAndEntropyBoundaries() {
    XCTAssertFalse(RandomValueMask.accepts("aB7xQ2pL9mR4zT6")) // 15 unique characters.
    XCTAssertTrue(RandomValueMask.accepts(Self.value)) // Exactly 16, entropy exactly 4.
    XCTAssertFalse(RandomValueMask.accepts("abcdefghijklmnopQRSTUVWX")) // Letters only, two classes.
    XCTAssertFalse(RandomValueMask.accepts("!#$%&*+-_/.=:@^~")) // Symbols only, entropy exactly 4.
    XCTAssertFalse(RandomValueMask.accepts(String(repeating: "aA7!", count: 8)))
    for value in ["hunter2", "Abcdef7x", "123456", "abcdefghijklmnop", "0123456789012345"] {
      XCTAssertFalse(RandomValueMask.accepts(value))
    }
  }

  func testNonASCIIAndUnspacedSentencesStay() {
    for text in ["日本語文章読書作業記録確認試験設計実装2026!", "中文简体连续句子阅读记录设计实现测试2026!",
                 "中文繁體連續句子閱讀記錄設計實現測試2026!", "한국어문장읽기활동기록설계구현시험확인2026!",
                 Self.value + "한", Self.value + "é", Self.value + "🙂"] {
      XCTAssertEqual(redactSecrets(text), text)
      XCTAssertTrue(RandomValueMask.ranges(text).isEmpty)
    }
  }

  func testReadableStructureStays() {
    for text in ["longMeaningfulIdentifierName", "readableReadableCounter2026", "long_meaningful_identifier_name_2026",
                 "v123.456.7890", "2026.10.14.123456", "/readable/project/documentation/source2.swift",
                 "https://invented.invalid/readable/project/source2.swift?longReadableParameterName=ordinary",
                 "https://" + Self.value + ".invalid/read", "https://invented.invalid/read?" + Self.value + "=ordinary",
                 "2b45a111-1222-4333-8444-555566667777", "d41d8cd98f00b204e9800998ecf8427e012345678"] {
      XCTAssertEqual(redactSecrets(text), text)
    }
    XCTAssertFalse(RandomValueMask.accepts("2b45a111-1222-4333-8444-555566667777"))
    XCTAssertTrue(RandomValueMask.accepts("01234567-89ab-cdef-0123-456789abcdef"))
    XCTAssertEqual(redactSecrets("01234567-89ab-cdef-0123-456789abcdef"), "01234567-89ab-cdef-0123-456789abcdef")
    XCTAssertFalse(RandomValueMask.accepts("d41d8cd98f00b204e9800998ecf8427e012345678"))
    // The threshold itself is not a hex/UUID exemption. Existing bare identifiers stay exempt.
    XCTAssertTrue(RandomValueMask.accepts("0123456789abcdef"))
    XCTAssertEqual(redactSecrets("0123456789abcdef"), "0123456789abcdef")
    // A displayed checksum is ideal-kept; its accepted over-mask is counted below.
  }

  func testTokenBoundariesAndQueryDecoding() {
    let v = Self.value
    XCTAssertEqual(redactSecrets("\"" + v + "\""), "\"[secret]\"")
    XCTAssertEqual(redactSecrets("senha:" + v), "senha:[secret]")
    XCTAssertEqual(redactSecrets("/readable/" + v + "/notes"), "/readable/[secret]/notes")
    XCTAssertEqual(redactSecrets("²:" + v), "²:[secret]")
    XCTAssertTrue(RandomValueMask.ranges("e\u{301}:" + v).isEmpty)
    XCTAssertEqual(RandomValueMask.ranges("🙂 " + v), [NSRange(location: 3, length: 16)])
    XCTAssertEqual(RandomValueMask.ranges("httpſ://" + v + ".invalid/read?v=" + v), [NSRange(location: 40, length: 16)])
    for text in ["\"" + v + "\"", "[" + v + "]", "(" + v + "),", "ordinary=" + v, "senha:" + v,
                 "/readable/" + v + "/notes", "https://invented.invalid/read/" + v + "/notes"] {
      XCTAssertEqual(RandomValueMask.ranges(text).count, 1)
      XCTAssertFalse(redactSecrets(text).contains(v))
    }
    let encoded = v.utf8.map { String(format: "%%%02X", $0) }.joined()
    let url = "https://invented.invalid/read?ordinary=" + encoded + "&page=2"
    XCTAssertEqual(RandomValueMask.ranges(url), [NSRange(location: 39, length: encoded.utf16.count)])
    XCTAssertEqual(redactSecrets(url), "https://invented.invalid/read?ordinary=[secret]&page=2")
    let body = v + "+/nF8dH1sW5uC0=="
    XCTAssertEqual(redactSecrets(body), Redaction.secretMark)
    XCTAssertEqual(redactSecrets("AbCdEfGhIjKlMnOp/" + v), Redaction.secretMark)
    // Exactly one decoding layer for this rule, and decoded whitespace is not a token boundary.
    // Decoded values are tokenized without recursively treating inner addresses as new parents.
    let nested = "notes.example/read?v=" + v
    XCTAssertEqual(RandomValueMask.ranges(nested, componentsOnly: true), [NSRange(location: 0, length: nested.utf16.count)])
    let once = "https://invented.invalid/read?v=" + v + "%20ordinary"
    XCTAssertTrue(RandomValueMask.ranges(once).isEmpty)
    XCTAssertEqual(RandomValueMask.ranges("https://invented.invalid/read?v=" + v + "%FF"), [])
  }

  func testJSONStructureAndLegacyRulesStay() throws {
    let json = String(decoding: try JSONSerialization.data(withJSONObject: [Self.value: "ordinary", "nested": ["value": Self.value], "number": 123456]), as: UTF8.self)
    let clean = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(redactSecrets(json).utf8)) as? [String: Any])
    XCTAssertEqual(clean[Self.value] as? String, "ordinary")
    XCTAssertEqual((clean["nested"] as? [String: String])?["value"], Redaction.secretMark)
    XCTAssertEqual(clean["number"] as? Int, 123456)
    for text in ["password: hunter2", "ghp_" + String(repeating: "a", count: 30), "4111 1111 1111 1111",
                 "-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----"] {
      XCTAssertTrue(redactSecrets(text).contains(Redaction.secretMark))
    }
    XCTAssertEqual(Redaction.applyKnownSecrets(Self.value).text, Self.value)
    XCTAssertEqual(redactSecrets(Self.value), Redaction.secretMark)
    XCTAssertEqual(Redaction.applyKnownSecrets("password: hunter2").text, Redaction.secretMark)
  }
  func testBareAddressesAndReadableRelativePaths() {
    let uuid = "01234567-89ab-cdef-0123-456789abcdef"
    for prefix in ["", "https://"] {
      // Predicate witnesses for the accepted public-reference over-masks below.
      XCTAssertEqual(RandomValueMask.ranges(prefix + "chat.example/c/" + uuid),
        [NSRange(location: prefix.utf16.count + 15, length: uuid.utf16.count)])
      XCTAssertEqual(RandomValueMask.ranges(prefix + "notes.example/Page-Name-0123456789abcdef0123456789abcdef"),
        [NSRange(location: prefix.utf16.count + 14, length: 42)])
      XCTAssertEqual(redactSecrets(prefix + "clips.example/glanceJVFBBZ"), prefix + "clips.example/glanceJVFBBZ")
      XCTAssertEqual(redactSecrets(prefix + "notes.example/read?v=" + Self.value), prefix + "notes.example/read?v=[secret]")
    }
    for path in ["Sources/Shell/Commands", "/invented/My Projects/ActivityProbe/client-work",
      "/invented/home/Library/Application Support/ActivityProbe/agent-window"] {
      XCTAssertEqual(redactSecrets(path), path)
    }
    // An alphabet-only slash run is a path; + is sufficient to preserve a detached body whole.
    XCTAssertTrue(RandomValueMask.ranges("AbCdEfGhIjKlMnOp/QrStUvWxYz").isEmpty)
    XCTAssertEqual(redactSecrets("AbCdEfGhIjKlMnOp/QrStUvWxYz+"), Redaction.secretMark)
  }

  func testIdealKeptReferencesHaveBoundedAcceptedDifferences() {
    // A chat page id identifies a conversation; no bearer access is established by this
    // fixture. Like a public page suffix or checksum, it is needed to read a reference.
    let uuid = "01234567-89ab-cdef-0123-456789abcdef"
    let ideals = ["shown 0123456789abcdef"] + ["", "https://"].flatMap { prefix in
      [prefix + "chat.example/c/" + uuid,
       prefix + "notes.example/Page-Name-0123456789abcdef0123456789abcdef"]
    }
    let acceptedOverMasks = Set(ideals.indices)
    XCTAssertEqual(acceptedOverMasks.count, 5)
    var differences = 0
    for (index, ideal) in ideals.enumerated() {
      let actual = redactSecrets(ideal)
      if actual != ideal {
        differences += 1
        XCTAssertTrue(acceptedOverMasks.contains(index), "new difference from ideal-kept reference")
        XCTAssertEqual(Redaction.applyKnownSecrets(ideal).text, ideal)
        let kept = actual.components(separatedBy: Redaction.secretMark)
        XCTAssertEqual(kept.count, 2)
        if kept.count == 2 {
          XCTAssertTrue(ideal.hasPrefix(kept[0]) && ideal.hasSuffix(kept[1]))
        }
      } else {
        XCTAssertEqual(actual, ideal)
      }
      // The accepted difference never permits loss of the host or readable surrounding text.
      let prefix = ideal.hasPrefix("shown ") ? "shown " : String(ideal.prefix(through: ideal.firstIndex(of: "/")!))
      XCTAssertTrue(actual.hasPrefix(prefix))
      if ideal.contains("notes.example/") { XCTAssertTrue(actual.contains("notes.example/")) }
      if ideal.contains("chat.example/c/") { XCTAssertTrue(actual.contains("chat.example/c/")) }
    }
    XCTAssertLessThanOrEqual(differences, 5, "accepted over-mask count grew")
  }

  func testTokenizerConditionsHaveDistinctWitnesses() {
    let v = Self.value
    XCTAssertEqual(RandomValueMask.ranges(v + "."), [NSRange(location: 0, length: 16)])
    // A high-entropy word is part of an opaque value, not a readable label.
    let labelled = "AbCdEfGhIjKlMnOp:tiny"
    XCTAssertEqual(RandomValueMask.ranges(labelled), [NSRange(location: 0, length: labelled.utf16.count)])
    for separator in ["\u{3000}", "\u{00a0}", "\u{1c}", "\u{1d}", "\u{1e}", "\u{1f}"] {
      XCTAssertEqual(RandomValueMask.ranges("漢" + separator + v), [NSRange(location: 2, length: 16)])
    }
    let unpadded = "AbCdEfGhIjKlMnOp/" + v
    XCTAssertEqual(RandomValueMask.ranges(unpadded + "=="), [NSRange(location: 0, length: 35)])
    XCTAssertEqual(RandomValueMask.ranges(unpadded + "==="), [NSRange(location: 17, length: 16)])
  }

}
