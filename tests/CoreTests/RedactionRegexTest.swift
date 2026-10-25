import Foundation
#if SWIFT_PACKAGE
@testable import Core
#endif

/// Compare complete UTF-16 match ranges against the old expressions, on bounded invented
/// input. This catches a speedup that accidentally drops an adjacent or embedded match.
enum RedactionRegexTest {
  private static let oldOCR = try! NSRegularExpression(pattern:
    #"(?i)[A-Za-z0-9._%+\-]{3,}[@8]?(naver|gmail|daum|hanmail|kakao|icloud|outlook|hotmail|nate)\.(com|net)"#)
  private static let oldURL = try! NSRegularExpression(pattern: #"(?i)\b[a-z][a-z0-9+.-]*://[^\s<>\"']+"#)

  private static let oldCredential = try! NSRegularExpression(pattern: #"(?i)\b[a-z][a-z0-9+.-]*://[^\s/@]+@"#)

  static var corpus: [String] {
    var texts = RedactionFormatsTest.harmless + RedactionLabelCorpus.gluedOrdinary + RedactionLabelCorpus.plainOrdinary + RedactionLabelCorpus.secrets.map(\.line)
      + RedactionHistoryTest.invented(1500, seed: 3232)
    for key in RedactionFormatsTest.keys {
      for (before, after) in [("", ""), ("before ", " after"), ("x=(", ");y"), ("https://invented.invalid/", "/more"),
        ("https://invented.invalid/?value=", "&page=2"), ("export INVENTED_VALUE='", "'"), ("{\"value\":\"", "\"}")] {
        texts.append(before + key.written + after)
      }
    }
    for provider in ["naver", "gmail", "daum", "hanmail", "kakao", "icloud", "outlook", "hotmail", "nate"] {
      let suffix = provider + ".com", other = provider.uppercased() + ".NET"
      for prefix in ["", "a", "ab", "abc", "123", "___", "a.b-", "ſabc", "Kabc"] {
        for tail in ["", "!", "abc" + suffix, "abc@" + suffix, "ab@" + suffix, "@abc" + suffix, "@" + other, "1238" + other] {
          texts.append(prefix + suffix + tail)
          texts.append(prefix + "@" + suffix + tail)
        }
      }
    }
    for left in ["", "1", "_", "한", "🙂", "a\u{301}", "\u{200D}", ".", "+", "-"] {
      for scheme in ["abc", "1-abc", "abc-def", "abc.def", "abc+def", "Kabc", "ſabc", "123", "a_abc", "-abc"] {
        for tail in ["", "/", "?note=plain", "#part", "'", " end", "/https://invented.invalid/next"] {
          texts.append(left + scheme + "://invented.invalid" + tail)
          texts.append(left + scheme + ":/invented.invalid" + tail)
          texts.append(left + scheme + "://user@invented.invalid" + tail)
        }
      }
    }
    texts.append("x://\u{301}a@b")
    let pieces = ["abc", "@", "8", ".", "-", "+", "_", "naver.com", "gmail.net", "://", "/", " ", "'", "ſ", "K", "한", "\u{301}", "\u{200D}"]
    var state: UInt64 = 32
    for _ in 0..<2000 {
      var text = ""
      for _ in 0..<12 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        text += pieces[Int((state >> 32) % UInt64(pieces.count))]
      }
      texts.append(text)
    }
    return Array(Set(texts)).sorted()
  }

  static var longURLCorpus: [String] {
    var texts: [String] = []
    for count in [400_000, 1_000_000] {
      for scheme in [String(repeating: "a", count: count), String(repeating: "a-", count: count / 2) + "b"] {
        texts.append(scheme + "://h.invalid/?v=" + RedactionFormatsTest.body(24))
        texts.append(scheme + "://user@h.invalid")
      }
    }
    return texts
  }

  static func failures() -> [String] {
    var failures: [String] = []
    // The huge cases skip the guard-off comparison (every rule on a million characters).
    let cases = corpus.map { ($0, true) } + longURLCorpus.map { ($0, false) }
    for (index, (text, checkGuardOff)) in cases.enumerated() {
      Redaction.forgetCached()
      let clean = Redaction.apply(text).text
      if checkGuardOff, clean != Redaction.withoutGuards(text) { failures.append("regex corpus: guards differ at input \(index)") }
      if text == "x://\u{301}a@b", clean != "x://[secret]@b" { failures.append("regex corpus: combining-mark credential was not masked") }
      if !checkGuardOff, !clean.contains(Redaction.secretMark) { failures.append("regex corpus: long URL lost its secret") }
      let range = NSRange(location: 0, length: (text as NSString).length)
      for (name, old) in [("ocr", oldOCR), ("url", oldURL), ("credential", oldCredential)] {
        // Retired expressions are quadratic on long rejection. URL matching
        // cases pin long ranges; the bounded cost harness exercises rejection.
        if !checkGuardOff, name == "ocr" || name == "credential" && !text.contains("@") {
          if !Redaction.regexRanges(name, text).isEmpty { failures.append("regex ranges: unexpected \(name) on long URL") }
          continue
        }
        let before = old.matches(in: text, range: range).map(\.range)
        let after = Redaction.regexRanges(name, text)
        if before != after { failures.append("regex ranges: \(name) input \(index), \(before) became \(after)") }
      }
    }
    return failures
  }
}
