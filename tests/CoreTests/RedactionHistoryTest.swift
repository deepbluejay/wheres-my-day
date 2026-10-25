import Foundation
#if SWIFT_PACKAGE
@testable import Core
#endif

/// Two things the masking must not depend on: what was masked before in the same
/// process (the cache), and whether a cheap guard in front of a rule lets the text through.
/// Every value here is invented.
enum RedactionHistoryTest {
  /// The text masked in a fresh state: nothing an earlier call left can answer.
  static func cold(_ text: String) -> String {
    Redaction.forgetCached()
    return Redaction.apply(text).text
  }

  private static func shown(_ text: String) -> String {
    String(text.unicodeScalars.map { $0.isASCII && $0.value >= 32 ? String($0) : "<" + String($0.value, radix: 16) + ">" }.joined().prefix(110))
  }

  private struct Random {
    var state: UInt64
    mutating func next() -> UInt64 {
      state &+= 0x9E37_79B9_7F4A_7C15
      var z = state
      z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
      z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
      return z ^ (z >> 31)
    }
    mutating func below(_ count: Int) -> Int { Int(next() % UInt64(count)) }
  }

  /// A few thousand strings put together from pieces the rules react to: names, separators,
  /// digits, marks an earlier masking left, percent-encoded and JSON-escaped letters.
  static func invented(_ count: Int, seed: UInt64) -> [String] {
    let pieces = ["authtoken", "csrftoken", "apptoken", "sessiontoken", "token", "password", "auth", "=", ":", ": ", " = ", "：",
      "\"", "'", " ", " ", "\n", "4111 1111 1111 1111", "4111", "1111 ", "010-2345-6789", "+82 10 2345 6789", "inventedvalue", "invented",
      "hello+tag@example.org", "https://example.invalid/?note=", "https://example.invalid/page#", "auth%74oken%3D", "toke%6E%3d", "%20", "&page=2",
      "[secret]", "[phone]", "[email]", "x", "A", "seed phrase", "Authorization: Bearer ", RedactionFormatsTest.body(24), "sk-" + RedactionFormatsTest.body(24),
      ",", "(", ")", "-", "/", "{\"a\":\"", "\"}", "\\u0040", "\\n", "\u{200D}", "\u{A0}", "\u{301}", "naver.com", "see ", " then run."]
    var random = Random(state: seed)
    return (0..<count).map { _ in (0..<(2 + random.below(8))).map { _ in pieces[random.below(pieces.count)] }.joined() }
  }

  /// The cache keeps one invariant: an entry is the result of masking exactly its key. So
  /// whatever was masked before, in whatever order, every text gets its cold result.
  static func historyFailures() -> [String] {
    var failures: [String] = []
    // Two addresses written together: one reading masks the first (A gives B), and B read
    // again loses the second. An entry once stood under a result as well as under its input,
    // and B was then returned as it stood. This pair checks that address masking cannot
    // return a stale cached result.
    let a = "hello+tag@example.orghello+tag@example.org"
    let b = "[email]+tag@example.org"
    let coldB = cold(b)
    Redaction.forgetCached()
    let maskedA = Redaction.apply(a).text
    let warmB = Redaction.apply(b).text
    if warmB != coldB { failures.append("history: B after A is " + shown(warmB) + ", alone " + shown(coldB)) }
    if coldB.contains("tag@example") { failures.append("history: B keeps its address: " + shown(coldB)) }
    if maskedA.contains("tag@example") { failures.append("history: A keeps the address its own result would lose: " + shown(maskedA)) }

    // The invariant does not lean on a result being stable. With one reading A gives B, and
    // B masked again loses its address. B must lose it right after A too.
    Redaction.readings = 1
    let onceB = cold(b)
    Redaction.forgetCached()
    let onceA = Redaction.apply(a).text
    let afterA = Redaction.apply(b).text
    Redaction.readings = 6
    Redaction.forgetCached()
    if onceA != b || onceB == b { failures.append("history: with one reading the pair is stable, it no longer shows what an entry under a result would do") }
    if afterA != onceB { failures.append("history: a result was answered from the text that produced it: " + shown(afterA) + ", alone " + shown(onceB)) }

    let inputs = invented(3000, seed: 31)
    var expected: [String: String] = [:]
    for text in inputs {
      expected[text] = cold(text)
      if expected[text] != Redaction.withoutGuards(text) { failures.append("history: guards differ: " + shown(text)) }
    }
    // What a masking produced is itself an input the next time the same text is stored.
    for result in Set(expected.values) where expected[result] == nil { expected[result] = cold(result) }
    var unstable = 0
    for (text, result) in expected where expected[result] != nil && expected[result] != result {
      unstable += 1
      if unstable <= 3 { failures.append("history: masked twice differs: " + shown(text) + " -> " + shown(result) + " -> " + shown(expected[result] ?? "")) }
    }
    var order = expected.keys.sorted()
    var random = Random(state: 3131)
    Redaction.forgetCached()
    var wrong = 0
    for _ in 0..<2 {
      for index in order.indices.reversed() where index > 0 { order.swapAt(index, random.below(index + 1)) }
      for text in order where Redaction.apply(text).text != expected[text] {
        wrong += 1
        if wrong <= 3 { failures.append("history: " + shown(text) + " -> " + shown(Redaction.apply(text).text) + ", alone " + shown(expected[text] ?? "")) }
      }
    }
    if wrong > 3 { failures.append("history: \(wrong) texts differ from their cold result") }
    if unstable > 3 { failures.append("history: \(unstable) results change when masked again") }
    if expected.count < 3500 || expected.filter({ $0.key != $0.value }).count < 650 {
      failures.append("history: only \(expected.count) texts, \(expected.filter { $0.key != $0.value }.count) of them changed")
    }
    return failures
  }

  /// A letter of "token" written percent-encoded in a URL value, with no other word in
  /// the text a rule looks for. The whole value as written goes; nothing decoded is written.
  static func encodedLetterFailures() -> [String] {
    var failures: [String] = []
    var cases: [(String, String)] = []
    let letters = Array("token")
    for index in letters.indices {
      for capital in [true, false] {
        let code = String(format: capital ? "%%%02X" : "%%%02x", letters[index].asciiValue ?? 0)
        let word = String(letters[..<index]) + code + String(letters[(index + 1)...])
        cases.append(("https://example.invalid/?note=auth" + word + "%3Dinventedvalue", "https://example.invalid/?note=[secret]"))
        cases.append(("https://example.invalid/page#session" + word + "%3Dinventedvalue", "https://example.invalid/page#[secret]"))
        cases.append(("see https://example.invalid/?page=2&note=csrf" + word + ":inventedvalue&lang=en#api" + word + "%3dinventedother now",
          "see https://example.invalid/?page=2&note=[secret]&lang=en#[secret] now"))
      }
    }
    cases += [
      ("https://example.invalid/?note=auth%74%6F%6B%65%6E%3Dinventedvalue", "https://example.invalid/?note=[secret]"),
      ("https://example.invalid/?a=1&b=deploy%74oken%3Dinventedvalue&c=jwtto%6Ben%3Dinventedother", "https://example.invalid/?a=1&b=[secret]&c=[secret]"),
      // A word that is not on the list stays, encoded or not.
      ("https://example.invalid/?note=next%74oken%3Dinventedvalue", "https://example.invalid/?note=next%74oken%3Dinventedvalue"),
    ]
    for (written, expected) in cases {
      let result = cold(written)
      if result != expected { failures.append("encoded letter: " + written + " -> " + result) }
      if result.contains("authtoken") || result.contains("=inventedvalue") && expected.contains("[secret]") { failures.append("encoded letter: decoded text written back: " + result) }
      if cold(result) != result { failures.append("encoded letter: masking twice differs: " + written) }
    }
    return failures
  }

  /// The sweep. Each of these was kept out by a guard that asked less than its rule: a
  /// character-wise look for ":" or "@" that a joiner or combining mark hides, the anchors
  /// asked of JSON as written when the rule reads it decoded.
  static func guardFailures() -> [String] {
    var failures: [String] = []
    for (written, hidden) in [
      ("password:\u{200D}inventedvalue", "inventedvalue"), ("password:\u{301}inventedvalue", "inventedvalue"),
      ("token=\u{FE0F}inventedvalue", "inventedvalue"), ("someone1238naver.com\u{301}", "someone1238"),
      ("https://login:inventedvalue@\u{200D}example.org/x", "inventedvalue"),
      ("{\"a\":\"hello\\u0040example.org\"}", "hello"), ("{\"a\":\"password\\n: inventedvalue\"}", "inventedvalue"),
      ("[\"authto\\u006ben=inventedvalue\"]", "inventedvalue"),
      ("\u{17F}ecret_acce\u{17F}s_key: inventedvalue" + RedactionFormatsTest.body(12), "inventedvalue"),
    ] where cold(written).contains(hidden) {
      failures.append("guard: still there: " + shown(written) + " -> " + shown(cold(written)))
    }
    // Every fixture a rule changes passes that rule's guards: with all of them off the result
    // is the same. Keys in their places, labels, shapes, the JSON-escaped spelling of each,
    // and the invented strings of the history.
    var texts: [String] = RedactionFormatsTest.harmless + RedactionLabelCorpus.gluedOrdinary + RedactionLabelCorpus.secrets.map(\.line)
    for key in RedactionFormatsTest.keys {
      for (before, after) in [("", ""), ("Please rotate ", " before the invented release."), ("https://example.org/invented?value=", "&page=2"),
        ("x=(", ");y"), ("log: {\"value\":\"", "\",\"n\":3} end"), ("\u{200D}", "\u{301}"), ("é", "é")] {
        texts.append(before + key.written + after)
      }
    }
    for label in ["password", "PASSWD", "passphrase", "passcode", "secret", "secret_key", "Secret Key", "api_key", "api key", "apikey", "token",
      "dbPassword", "accessToken", "authtoken", "AUTHTOKEN", "seed phrase", "RECOVERY_PHRASE", "Authorization"] {
      for end in [":", "=", "：", " = ", "\":", "\\\": ", ":\u{200D}", "=\u{301}"] {
        for value in ["inventedvalue", "\"invented value\"", Array(repeating: "invented", count: 12).joined(separator: " "), "Bearer " + RedactionFormatsTest.body(24)] {
          texts.append(label + end + value)
          texts.append("https://example.invalid/?note=" + ((label + end + value).addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "") + "&page=2")
        }
      }
    }
    texts += ["hello+tag@example.org", "user@xn--bcher-kva.example", "someone12348naver.com", "SOMEONE1234GMAIL.COM", "https://login:inventedvalue@example.org/path",
      "https://example.org/?anything=aB3dE5fG7hJ9kL2mN4pQ6rS8", "https://example.org/#aB3dE5fG7hJ9kL2mN4pQ6rS8", "4111 1111 1111 1111", "4111-1111-1111-1111",
      "4111111111111111", "card 4111 1111 1111 1111, next", "-----BEGIN PRIVATE KEY-----\ninvented\n-----END PRIVATE KEY-----"]
    for count in [13, 19] {
      let prefix = String(repeating: "7", count: count - 1)
      let card = (0...9).map { prefix + String($0) }.first(where: Redaction.passesLuhn) ?? ""
      for spelling in [card, String(card.prefix(6)) + " " + card.dropFirst(6), String(card.prefix(6)) + "-" + card.dropFirst(6)] {
        for wrapped in [spelling, "before " + spelling + " after"] {
          texts.append(wrapped)
          if cold(wrapped) == wrapped { failures.append("guard: invented \(count)-digit card was not masked") }
        }
      }
    }
    texts += invented(1500, seed: 77)
    // The same texts as one JSON string each, every character written as an escape.
    for text in texts.prefix(900) where !text.unicodeScalars.contains(where: { $0.value > 0xFFFF }) {
      texts.append("[\"" + text.utf16.map { String(format: "\\u%04x", $0) }.joined() + "\"]")
    }
    var changed = 0
    var differing = 0
    for text in texts {
      let guarded = cold(text)
      let open = Redaction.withoutGuards(text)
      if guarded != text { changed += 1 }
      if guarded != open {
        differing += 1
        if differing <= 6 { failures.append("guard: kept out by a guard: " + shown(text) + " -> " + shown(guarded) + ", without guards " + shown(open)) }
      }
    }
    if differing > 6 { failures.append("guard: \(differing) of \(texts.count) texts differ without the guards") }
    if changed < texts.count / 3 { failures.append("guard: only \(changed) of \(texts.count) texts are changed by a rule") }
    return failures
  }

  /// The card candidate once took the two digits of "%20" and the number after
  /// it as one checksum-valid card; the mark left "%[secret]", the value no longer decoded,
  /// and the glued credential names of the decoded value were never looked for: the secret
  /// words of a quoted value stayed. An encoded value is now judged decoded and
  /// masked whole (`decodedFailures`); what is left here is the text as written.
  static func escapeFailures() -> [String] {
    var failures: [String] = []
    let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
    func encoded(_ text: String, small: Bool) -> String {
      let upper = text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
      guard small else { return upper }
      let units = Array(upper)
      var out = "", index = 0
      while index < units.count {
        if units[index] == "%", index + 2 < units.count { out += "%" + String(units[index + 1...index + 2]).lowercased(); index += 3 }
        else { out.append(units[index]); index += 1 }
      }
      return out
    }
    if cold("https://invented.invalid/?v=authtoken%3D%22inventedvalue%20010-2345-6789%22&n=2") != "https://invented.invalid/?v=[secret]&n=2" {
      failures.append("escape: the reproduction: " + cold("https://invented.invalid/?v=authtoken%3D%22inventedvalue%20010-2345-6789%22&n=2"))
    }
    let numbers = Array(RedactionFormatsTest.telephoneShaped.prefix(7))
    for label in ["authtoken", "csrftoken", "sessiontoken", "oauthaccesstoken"] {
      for end in ["=", ":", " = ", "："] {
        for number in numbers + [""] {
          for value in ["inventedfirst " + number, number + " inventedlast", "inventedfirst " + number + " inventedlast", "inventedfirst" + number + "inventedlast"] {
            for small in [false, true] {
              let written = "see https://invented.invalid/a%20b?first=1&v=" + encoded(label + end + "\"" + value + "\"", small: small) + "&n=2 now"
              for (name, result) in [("", cold(written)), (" without guards", Redaction.withoutGuards(written))] where result.contains("invented.invalid") == false
                || result.contains("inventedfirst") || result.contains("inventedlast") || !result.hasSuffix("&n=2 now") {
                failures.append("escape: secret word still there" + name + ": " + written + " -> " + result)
              }
              if cold(cold(written)) != cold(written) { failures.append("escape: masking twice differs: " + written) }
            }
          }
        }
      }
    }
    // A number after an escape is read from the escape's end: the telephone number stays, the
    // card goes, and the escape is whole either way.
    for (written, expected) in [
      ("note%20010-2345-6789%22", "note%20010-2345-6789%22"), ("note%204111 1111 1111 1111%22", "note%20[secret]%22"),
      ("https://invented.invalid/p%204111111111111111/x", "https://invented.invalid/p%20[secret]/x"),
      ("https://invented.invalid/?v=nexttoken%3A%22inventedvalue%20010-2345-6789%22&n=2", "https://invented.invalid/?v=nexttoken%3A%22inventedvalue%20010-2345-6789%22&n=2"),
      // Known limit: right after a bare "%" the first two digits are an escape to this rule.
      ("%4111 1111 1111 1111", "%4111 1111 1111 1111"),
      // A run of digits is read once, from the escape's end: its tail is not a card of its own.
      ("see %22857 5771 2128 8664 17 end", "see %22857 5771 2128 8664 17 end"),
    ] where cold(written) != expected || Redaction.withoutGuards(written) != expected {
      failures.append("escape: " + written + " -> " + cold(written))
    }
    // The other rules whose match can begin with a hexadecimal letter or digit (a key prefix, a
    // label, a number): in a URL value the mark stands beside a percent sign, and the whole
    // value goes. In text nothing decodes the half escape stays where it was.
    func undecodable(_ text: String) -> [String] { Redaction.urlValues(text).filter { $0.contains("%") && $0.removingPercentEncoding == nil } }
    var begun = 0
    for key in RedactionFormatsTest.keys {
      for half in ["%4", "%a", "%A", "%", "%E", "%EA%B0%8", "%ea%b0%8", "%C3%A"] {
        let value = "authtoken%3Dinventedvalue" + half + key.written
        let written = "https://invented.invalid/?v=" + value + "&n=2"
        // Only where the half and the key's first letters are an escape (and the value decodes).
        guard value.removingPercentEncoding != nil else { continue }
        let result = cold(written)
        begun += 1
        if result.contains("inventedvalue") || !undecodable(result).isEmpty || Redaction.withoutGuards(written) != result {
          failures.append("escape: key after " + half + ": " + written + " -> " + result)
        }
      }
    }
    if begun < 20 { failures.append("escape: only \(begun) keys begin inside an escape that decodes") }
    for (written, expected) in [("see %4api_key=inventedvalue end", "see %4[secret] end"), ("x %EA%B0%8AIza" + RedactionFormatsTest.body(32) + " y", "x %EA%B0%8[secret] y"),
      ("https://invented.invalid/?v=%EA%B0%8AIza" + RedactionFormatsTest.body(32) + "&n=2", "https://invented.invalid/?v=[secret]&n=2")] where cold(written) != expected {
      failures.append("escape: " + written + " -> " + cold(written))
    }
    // Every URL value that decoded as written still decodes when masked, a value that spells
    // a percent sign among them; decoded text was once written back there.
    var texts = RedactionRegexTest.corpus + invented(1500, seed: 77) + invented(1500, seed: 3737)
    for key in RedactionFormatsTest.keys {
      for half in ["", "%20", "%3D", "%4", "%a", "%EA%B0%80", "%EA%B0%8"] {
        texts.append("https://invented.invalid/p" + half + key.written + "?v=" + half + key.written + "&w=" + encoded("note " + key.written, small: false) + "#" + half + key.written)
      }
    }
    for body in ["password: inventedvalue", "authtoken=\"invented value\"", "hello+tag@example.org", "4111 1111 1111 1111", "pay 4111-1111-1111-1111 today", "가 4111111111111111 나",
      "recovery phrase: " + Array(repeating: "invented", count: 12).joined(separator: " ")] + numbers {
      for other in ["", " 4111 1111 1111 1111", " hello+tag@example.org", " 010-2345-6789", " 가나다", " 50% off", "%"] {
        for small in [false, true] {
          texts.append("https://invented.invalid/?v=" + encoded(body + other, small: small) + "&n=" + encoded(other + body, small: small) + "#" + encoded(body, small: small))
        }
      }
    }
    var checked = 0
    for text in texts {
      let values = Redaction.urlValues(text).filter { $0.contains("%") }
      guard !values.isEmpty, values.allSatisfy({ $0.removingPercentEncoding != nil }) else { continue }
      checked += 1
      for result in [cold(text), Redaction.withoutGuards(text)] where !undecodable(result).isEmpty {
        failures.append("escape: a masked value no longer decodes: " + shown(text) + " -> " + shown(result))
      }
    }
    if checked < 500 { failures.append("escape: only \(checked) texts hold an encoded URL value") }
    return Array(failures.prefix(12))
  }

  /// An invented number of that many digits that passes the card checksum.
  static func card(_ digits: Int, lead: Int) -> String {
    var random = Random(state: UInt64(digits * 100 + lead))
    let body = String(lead) + (0..<(digits - 2)).map { _ in String(random.below(10)) }.joined()
    return (0...9).map { body + String($0) }.first(where: Redaction.passesLuhn) ?? body
  }

  /// The masked text holds nothing the text did not: with the marks taken out, what is left
  /// stands in the text, in order. Decoded text written into a result fails this.
  static func onlyMasked(_ text: String, _ result: String) -> Bool {
    let whole = text as NSString, masked = result as NSString
    // By unit, as the rules read: a piece may begin with a combining mark.
    func next(_ mark: String, _ at: Int) -> NSRange { masked.range(of: mark, options: .literal, range: NSRange(location: at, length: masked.length - at)) }
    var at = 0, from = 0
    while at <= masked.length {
      let marks = [next("[secret]", at), next("[email]", at)].filter { $0.location != NSNotFound }
      let stop = marks.map(\.location).min() ?? masked.length
      if stop > at {
        let found = whole.range(of: masked.substring(with: NSRange(location: at, length: stop - at)), options: .literal, range: NSRange(location: from, length: whole.length - from))
        guard found.location != NSNotFound else { return false }
        from = NSMaxRange(found)
      }
      guard let mark = marks.min(by: { $0.location < $1.location }) else { break }
      at = NSMaxRange(mark)
    }
    return true
  }

  /// If what a URL parameter value says when decoded holds anything a rule masks,
  /// the whole value as written becomes the mark, and decoded text is never written into the
  /// result. The mechanism before decoded a value, masked inside the decoded text and wrote
  /// that back, spaces and separators with it; the URL read next ended at the first space,
  /// and the word after it stayed. A label whose separator was encoded once more than
  /// the rest was never seen. A value that spelt a percent sign stopped decoding.
  static func decodedFailures() -> [String] {
    var failures: [String] = []
    let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
    func encoded(_ text: String, _ times: Int = 1) -> String {
      (0..<times).reduce(text) { value, _ in value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value }
    }
    let url = "https://invented.invalid/"
    for (written, expected) in [
      (url + "?v=authtoken%3D%2522inventedfirst%20%25204307418529637%20inventedlast%2522&n=2", url + "?v=[secret]&n=2"),
      (url + "?v=authtoken%253D%2522inventedfirst%20010-2345-6789%20inventedlast%2522&n=2", url + "?v=[secret]&n=2"),
      (url + "?v=%25204111%201111%201111%201111%25&n=2", url + "?v=[secret]&n=2"),
      // Nothing to mask at any depth: exactly as written.
      (url + "?v=50%25%20off&w=a%2520b%252520c&q=how%20to%20bake%20bread#part%202", url + "?v=50%25%20off&w=a%2520b%252520c&q=how%20to%20bake%20bread#part%202"),
      (url + "login?next=https%3A%2F%2Fother.invalid%2Fa%3Fx%3D1%26q%3Dtwo%2520words&page=2", url + "login?next=https%3A%2F%2Fother.invalid%2Fa%3Fx%3D1%26q%3Dtwo%2520words&page=2"),
      (url + "?tel=%252B82%252010%25202345%25206789&n=2", url + "?tel=%252B82%252010%25202345%25206789&n=2"),
      // The ordinary words beside the secret go with it.
      (url + "?q=write%20to%20hello%2Btag%40example.org%20please&n=2", url + "?q=[secret]&n=2"),
      (url + "?q=how%20to%20reset%20password%3A%20inventedvalue&n=2", url + "?q=[secret]&n=2"),
      // As written (nothing encoded) a value is masked where the rule matches, as before.
      (url + "?to=hello+tag@example.org&n=2", url + "?to=[email]&n=2"),
      // A value that does not decode strictly is read with the escapes it has.
      (url + "?v=authtoken%3Dinventedvalue%zz%&n=2", url + "?v=[secret]&n=2"),
      (url + "?v=password%253D%22inventedfirst%2050%25%20inventedlast%22&n=2", url + "?v=[secret]&n=2"),
      // Any depth: the form with nothing left to decode is asked.
      (url + "?v=" + encoded("csrftoken: \"inventedfirst inventedlast\"", 50) + "&n=2", url + "?v=[secret]&n=2"),
      (url + "?v=" + encoded("pay " + card(16, lead: 4) + " today", 7) + "&n=2", url + "?v=[secret]&n=2"),
      (url + "?next=" + encoded("https://login:inventedvalue@other.invalid/path", 3) + "&n=2", url + "?next=[secret]&n=2"),
      // Half a letter after a card: a reader that decodes one layer at a time loses it and is
      // left with the card alone. That reading is checked too.
      (url + "?v=%25204111%25201111%25201111%25201111%C3%25A9&n=2", url + "?v=[secret]&n=2"),
      // Both readings are of the text as it stood. A card that runs across the end of a URL
      // whose value goes is masked whole, not cut in two; a key that takes the scheme with it
      // does not keep the opaque value after it from being read.
      (url + "?note=auth%74oken%3D/:4111 1111 1111 1111 end", url + "?note=[secret] end"),
      // The values are read once more in the text the rules left: what a mark joined to the
      // URL is part of the value that goes.
      (url + "?note=auth%74oken%3D/:4111 1111 1111 1111,inventedlast end", url + "?note=[secret] end"),
      ("sk-" + RedactionFormatsTest.body(24) + url + "page#A" + RedactionFormatsTest.body(24) + "x end", "[secret]://invented.invalid/page#[secret] end"),
    ] {
      let result = cold(written)
      if result != expected { failures.append("decoded: " + shown(written) + " -> " + shown(result)) }
      if Redaction.withoutGuards(written) != result { failures.append("decoded: guards differ: " + shown(written)) }
      if cold(result) != result { failures.append("decoded: masking twice differs: " + shown(written)) }
    }
    // What the forms are.
    for (written, once, fully) in [("a%2520b%25", "a%20b%", "a b%"), ("%252541%zz%4", "%2541%zz%4", "A%zz%4"), ("%2%35%32%30x", "%252 0x".replacingOccurrences(of: " ", with: ""), " x"),
      ("%EA%B0%80%25EA%25B0%2580", "가%EA%B0%80", "가가")] {
      if Redaction.unescaped(written, fully: false) != once || Redaction.unescaped(written, fully: true) != fully {
        failures.append("decoded: forms of " + written + ": " + Redaction.unescaped(written, fully: false) + ", " + Redaction.unescaped(written, fully: true))
      }
    }
    func undecodable(_ text: String) -> [String] { Redaction.urlValues(text).filter { $0.contains("%") && $0.removingPercentEncoding == nil } }
    var checked = 0
    func hidden(_ name: String, _ written: String, _ words: [String]) {
      checked += 1
      let result = cold(written)
      // A JSON text is written out again by the serializer; its strings are checked as text below.
      let plain = !written.hasPrefix("{")
      if words.contains(where: result.contains) || !undecodable(result).isEmpty || Redaction.withoutGuards(written) != result || cold(result) != result
        || (plain && !onlyMasked(written, result)) || !result.contains("n=2") {
        failures.append("decoded: " + name + ": " + shown(written) + " -> " + shown(result))
      }
    }
    func wrapped(_ text: String, _ how: Int) -> String {
      let json = { (value: [String: String]) in String(decoding: (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data(), as: UTF8.self) }
      return how == 0 ? text : how == 1 ? json(["note": text]) : json(["outer": json(["note": text])])
    }
    let glued = ["authtoken", "csrftoken", "sessiontoken", "oauthaccesstoken"]
    let ends = ["=", ":", " = ", "："]
    // The separator encoded once, the quotes twice, an escape encoded twice right before a
    // card, a word on each side, with and without a percent sign that is no escape.
    for label in glued {
      for end in ends {
        for digits in [13, 16, 19] {
          for quote in ["\"", "'"] {
            for before in [" ", "\t", ","] {
              for tail in ["", "%25"] {
                for how in [0, 1] {
                  let value = label + encoded(end) + encoded(quote, 2) + "inventedfirst%20" + encoded(before, 2) + card(digits, lead: 3 + digits % 3)
                    + "%20inventedlast" + tail + encoded(quote, 2)
                  hidden("single-encoded separator with double-encoded quotes and card prefix", wrapped(url + "?v=" + value + "&n=2", how), ["inventedfirst", "inventedlast"])
                }
              }
            }
          }
        }
      }
    }
    // The separator and the quotes encoded twice, the number and the spaces once.
    for label in glued + ["password", "api_key", "token", "secret"] {
      for end in ends {
        for number in RedactionFormatsTest.telephoneShaped.prefix(3) {
          for body in ["inventedfirst " + number, number + " inventedlast", "inventedfirst " + number + " inventedlast", "inventedfirst" + number + "inventedlast"] {
            for how in [0, 1, 2] {
              let value = label + encoded(end, 2) + encoded("\"", 2) + encoded(body) + encoded("\"", 2)
              hidden("double-encoded separator and quotes with single-encoded value", wrapped(url + "?v=" + value + "&n=2", how), ["inventedfirst", "inventedlast"])
            }
          }
        }
      }
    }
    // Every key, at depths one to five, alone and among ordinary words.
    for key in RedactionFormatsTest.keys {
      for depth in 1...5 {
        hidden("key depth \(depth)", url + "?first=1&v=" + encoded("note " + key.written + " end", depth) + "&n=2", [key.secret])
      }
    }
    // The bytes of one letter encoded to different depths. The form with one
    // pass read holds half a letter, which a string cannot keep; the form with nothing left to
    // decode is made from the value as written and holds the address.
    func escaped(_ byte: UInt8, _ depth: Int) -> String {
      (1..<depth).reduce("%" + String(byte, radix: 16, uppercase: true)) { value, _ in value.replacingOccurrences(of: "%", with: "%25") }
    }
    var split = 0
    for letter in ["é", "ß", "가", "あ", "д", "中"] {
      let bytes = Array(letter.utf8)
      var depths = [Int](repeating: 1, count: bytes.count)
      repeat {
        if Set(depths).count > 1 {
          let written = zip(bytes, depths).map(escaped).joined()
          for value in ["person%40" + written + ".invalid", "person%2540inv" + written + "nted.invalid", "write%20to%20person%40" + written + ".invalid"] {
            for how in [0, 1, 2] {
              split += 1
              let text = wrapped(url + "?v=" + value + "&n=2", how)
              hidden("split letter", text, ["person"])
              if how == 0, cold(text) != url + "?v=[secret]&n=2" { failures.append("decoded: split letter: " + shown(text) + " -> " + shown(cold(text))) }
            }
          }
        }
        var at = 0
        while at < depths.count { depths[at] += 1; if depths[at] <= 3 { break }; depths[at] = 1; at += 1 }
        if at == depths.count { break }
      } while true
    }
    if split < 500 { failures.append("decoded: only \(split) split letters") }
    // A value masked whole for the mark it already holds beside an escape is a
    // change with a rule name, so a JSON text around it is written again with guards as without.
    for mark in ["[secret]", "[email]"] {
      for space in ["%20", "%2520", "%09"] {
        for how in [0, 1, 2] {
          let text = wrapped(url + "?v=ordinary" + space + mark + space + "words&n=2", how)
          let result = cold(text)
          if result.contains("ordinary") || Redaction.withoutGuards(text) != result || cold(result) != result || Redaction.apply(text).rules.isEmpty {
            failures.append("decoded: mark beside an escape: " + shown(text) + " -> " + shown(result))
          }
        }
      }
    }
    if checked < 2500 { failures.append("decoded: only \(checked) cases") }
    // Nothing decoded is ever written: over the invented texts, what a masking leaves stands
    // in the text it was given.
    var written = 0
    for text in RedactionRegexTest.corpus + invented(3000, seed: 38) where !text.hasPrefix("{") && !text.hasPrefix("[") {
      let result = cold(text)
      guard result != text else { continue }
      written += 1
      if !onlyMasked(text, result) { failures.append("decoded: the result holds text the input did not: " + shown(text) + " -> " + shown(result)) }
    }
    if written < 500 { failures.append("decoded: only \(written) changed texts were compared") }
    return Array(failures.prefix(12))
  }

  static func failures() -> [String] { historyFailures() + encodedLetterFailures() + escapeFailures() + decodedFailures() + guardFailures() }
}
