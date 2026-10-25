import Foundation
#if SWIFT_PACKAGE
@testable import Core
#endif

extension RedactionFormatsTest {
  static func telephoneFailures() -> [String] {
    var failures: [String] = []
    for number in telephoneShaped {
      for text in [number, "Call " + number + " after lunch.", "연락처 " + number + " 입니다", "電話 " + number + " まで", "{\"note\":\"" + number + "\"}",
        "https://example.org/?tel=" + (number.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "") + "&page=2"] {
        Redaction.forgetCached()
        let result = Redaction.apply(text)
        if result.text != text || !result.rules.isEmpty { failures.append("telephone: changed: " + text + " -> " + result.text) }
        if Redaction.withoutGuards(text) != text { failures.append("telephone: changed without guards: " + text) }
      }
    }
    // Beside something a rule does mask, the number stays and the rest goes as before.
    for (written, expected) in [
      ("hello+tag@example.org +82 10 2345 6789", "[email] +82 10 2345 6789"),
      ("010-2345-6789, card 4111 1111 1111 1111, next", "010-2345-6789, card [secret], next"),
      ("tel (415) 234-5678 password: inventedvalue", "tel (415) 234-5678 [secret]"),
      // A telephone-shaped value another rule owns is still that rule's to mask.
      ("password: 010-2345-6789", "[secret]"), ("api_key = \"+82 10 2345 6789\"", "[secret]"),
      ("https://login:010-2345-6789@example.org/x", "https://[secret]@example.org/x"),
      ("Authorization: Bearer 010-2345-6789-0000", "Authorization: Bearer [secret]"),
      // The mark an earlier build stored is ordinary text now: read back, it stays.
      ("call [phone] now", "call [phone] now"),
      // Two things the telephone mark used to do by accident, now known limits (no rule was
      // added for them). A card right after a telephone number, joined by one space, is one
      // run of digits to the card rule, as after any other digits; the other way round and
      // apart from the number it is masked. A labelled recovery phrase that goes on with a
      // number is not a phrase to its rule, as with any other number.
      ("+82 10 2345 6789 371111 11111110", "+82 10 2345 6789 371111 11111110"),
      ("order 12345 371111 11111110", "order 12345 371111 11111110"),
      ("4111 1111 1111 1111 010-2345-6789", "[secret] 010-2345-6789"),
      ("+82 10 2345 6789, card 4111 1111 1111 1111", "+82 10 2345 6789, card [secret]"),
      ("recovery phrase: " + Array(repeating: "invented", count: 12).joined(separator: " ") + " 010-2345-6789",
        "recovery phrase: " + Array(repeating: "invented", count: 12).joined(separator: " ") + " 010-2345-6789"),
      // A third: an unlabelled word written against a number inside an encoded URL value. The
      // mark once cut the value at the number, and the stump (the word and the first digits)
      // was read as an opaque value on the next reading. It is no credential to any rule: the
      // same text outside a URL stayed before and stays now.
      ("https://invented.invalid/?v=inventedword%2B82%2010%202345%206789&n=2", "https://invented.invalid/?v=inventedword%2B82%2010%202345%206789&n=2"),
      ("inventedword+82 10 2345 6789", "inventedword+82 10 2345 6789"),
    ] {
      Redaction.forgetCached()
      if Redaction.apply(written).text != expected { failures.append("telephone: " + written + " -> " + Redaction.apply(written).text) }
      if Redaction.withoutGuards(written) != expected { failures.append("telephone: guards differ: " + written) }
    }
    return failures
  }

  static func failures() -> [String] {
    var failures = labeledAndRecoveryFailures() + telephoneFailures() + RedactionRegexTest.failures() + RedactionLabelCorpus.failures() + RedactionHistoryTest.failures()
    for (index, key) in keys.enumerated() {
      let name = "\(key.rule)-\(index)"
      // Alone, in a sentence, in a URL path and query, as JSON, on a shell line, and with
      // punctuation on both sides and nothing between.
      let json = String(decoding: (try? JSONSerialization.data(withJSONObject: ["note": "invented " + key.written, "n": 3])) ?? Data(), as: UTF8.self)
      let places: [(String, String, String)] = [
        ("alone", "", ""), ("sentence", "Please rotate ", " before the invented release, thanks."),
        ("path", "https://example.org/invented/", "/more"), ("query", "https://example.org/invented?value=", "&page=2"),
        ("shell", "export INVENTED_VALUE='", "' && ./run.sh --verbose"), ("glued", "x=(", ");y"),
        ("embedded-json", "log: {\"value\":\"", "\",\"n\":3} end"),
      ]
      for (place, before, after) in places {
        let text = before + key.written + after
        let result = Redaction.apply(text)
        if result.text != Redaction.withoutGuards(text) { failures.append("\(name) \(place): guards differ") }
        if result.text.contains(key.secret) { failures.append("\(name) \(place): still there") }
        if !Redaction.mayMatch(text) { failures.append("\(name) \(place): the prefilter does not let it through") }
        if place != "query", !result.rules.contains(key.rule) { failures.append("\(name) \(place): \(result.rules)") }
        // The words around it survive (a URL's own parts may be masked by the URL rules).
        if ["sentence", "shell", "glued"].contains(place), !(result.text.hasPrefix(before) && result.text.hasSuffix(after)) {
          failures.append("\(name) \(place): surrounding text changed")
        }
        if Redaction.apply(result.text).text != result.text { failures.append("\(name) \(place): masking twice differs") }
      }
      let cleaned = Redaction.apply(json)
      if cleaned.text != Redaction.withoutGuards(json) { failures.append("\(name) json: guards differ") }
      if cleaned.text.contains(key.secret) || !cleaned.text.contains("invented") || !cleaned.text.contains("\"n\":3")
        || (try? JSONSerialization.jsonObject(with: Data(cleaned.text.utf8))) == nil { failures.append("\(name) json") }
    }
    var differences = 0
    for (index, text) in harmless.enumerated() {
      for wrapped in harmlessPlaces(text) {
        // The purpose is to retain harmless text. Accepted over-masks are counted separately.
        let actual = Redaction.apply(wrapped).text
        if actual != Redaction.withoutGuards(wrapped) { failures.append("harmless-\(index) guards differ") }
        if actual != wrapped {
          differences += 1
          if !acceptedHarmlessOverMasks.contains(index) || !masksAtLeast(actual, wrapped)
            || Redaction.applyKnownSecrets(wrapped).text != wrapped {
            failures.append("harmless-\(index) new difference from ideal kept text")
          }
        }
      }
    }
    if differences > acceptedHarmlessOverMasks.count * 3 {
      failures.append("harmless differences exceeded the accepted count")
    }
    return failures
  }

  // Every harmless fixture remains ideal-kept, including public ids needed to interpret a record.
  // This is an explicit allowance for measured shape over-masking, never a changed ideal.
  static let acceptedHarmlessOverMasks: Set<Int> = [
    13, 14, 16, 19, 21, 31, 37, 42, 43, 44, 45, 64, 93, 94, 95, 96, 98, 99,
    102, 105, 106, 107, 108, 109, 111, 112, 113, 114, 150, 152, 154, 159, 160, 161,
    162, 163, 164, 218,
  ]

  static func harmlessPlaces(_ text: String) -> [String] {
    [text, "see " + text + " in the log", "{\"value\":\"" + text + "\"}"]
  }

  static func idealFixtureSummary() -> [[String: Any]] {
    let groups: [(String, Set<Int>)] = [
      ("public opaque ids and keys", [13, 14, 16, 19, 42, 43, 44, 45, 102, 105, 106, 107, 108, 109, 111, 112, 113, 114, 160, 161, 218]),
      ("public base64 bodies and checksums", [93, 94, 95, 96]),
      ("readable code, names, files and versions", [21, 31, 37, 64, 98, 99, 150, 152, 154, 159, 162, 163, 164]),
    ]
    var summary: [[String: Any]] = []
    for (name, indices) in groups + [("other harmless prose and structure", Set(harmless.indices).subtracting(groups.reduce(into: Set<Int>()) { $0.formUnion($1.1) }))] {
      let over = indices.reduce(0) { count, index in
        count + harmlessPlaces(harmless[index]).filter { Redaction.apply($0).text != $0 }.count
      }
      summary.append(["group": name, "fixtures": indices.count, "ideal_masked": 0,
        "ideal_kept": indices.count * 3, "actual_masked": over,
        "actual_kept": indices.count * 3 - over, "miss": 0, "over_mask": over])
    }
    return summary
  }

  /// Whether `now` is `before` with more of it replaced by the mark and nothing else changed:
  /// every piece of text between marks in `now` stands in `before`, in the same order, the
  /// first at its start and the last at its end. So a character hidden in `before` is hidden in `now`.
  static func masksAtLeast(_ now: String, _ before: String) -> Bool {
    // Which mark stands there does not matter: the rules read the text again after the
    // glued names are masked, and may then find an address.
    func oneMark(_ text: String) -> String { text.replacingOccurrences(of: Redaction.emailMark, with: Redaction.secretMark) }
    let now = oneMark(now), before = oneMark(before)
    let pieces = now.components(separatedBy: Redaction.secretMark)
    if pieces.count == 1 { return now == before }
    guard before.hasPrefix(pieces[0]), before.hasSuffix(pieces[pieces.count - 1]) else { return false }
    var from = before.index(before.startIndex, offsetBy: pieces[0].count)
    for piece in pieces.dropFirst().dropLast() where !piece.isEmpty {
      guard let found = before.range(of: piece, range: from..<before.endIndex) else { return false }
      from = found.upperBound
    }
    return before.distance(from: from, to: before.endIndex) >= pieces[pieces.count - 1].count
  }

  /// A glued credential-word name in front of a value that is itself labelled:
  /// the outer name once took the inner label and the opening quote as its value, and the rest
  /// of the quoted secret stayed in plain text. Nothing the rules hid before the glued names
  /// were recognised (`Redaction.withoutGluedTokens`) may be visible now.
  static func nestedLabelFailures() -> [String] {
    var failures: [String] = []
    for (written, expected) in [
      ("authtoken=password:\"invented secret words\"", "auth[secret]"),
      ("authtoken=token:\"invented secret words\"", "auth[secret]"),
      // "app" is no longer on the list: the inner label alone masks, as it did before.
      ("apptoken=passphrase:'invented secret words'", "apptoken=[secret]"),
    ] where Redaction.apply(written).text != expected {
      failures.append("nested label: " + written + " -> " + Redaction.apply(written).text + ", expected " + expected)
    }
    let words = ["inventedalpha", "inventedbeta", "inventedgamma"]
    var tried = 0
    var newlyMasked = 0
    func hold(_ written: String) {
      tried += 1
      let before = Redaction.withoutGluedTokens(written).text
      let now = Redaction.apply(written).text
      if now != before { newlyMasked += 1 }
      if failures.count > 12 { return }
      if !masksAtLeast(now, before) { failures.append("nested label: not a further masking: " + written + " -> " + now + ", before " + before) }
      for word in words where !before.contains(word) && now.contains(word) {
        failures.append("nested label: " + word + " was hidden and is shown: " + written + " -> " + now + ", before " + before)
      }
      if Redaction.apply(now).text != now { failures.append("nested label: masking twice differs: " + written + " -> " + now + " -> " + Redaction.apply(now).text) }
    }
    let inner = ["password", "passwd", "passphrase", "passcode", "secret", "secret_key", "secret key", "api_key", "api key", "apikey", "token",
      "dbPassword", "accessToken", "seed phrase"]
    for word in Redaction.gluedTokenWords {
      for outer in [word + "token", "my_" + word + "token", "my" + word.prefix(1).uppercased() + word.dropFirst() + "token", "oauth" + word + "token"] {
        for outerEnd in ["=", ": ", " = ", "：", "\":"] {
          for label in inner {
            for innerEnd in [":", "=", ": "] {
              for value in [words.joined(separator: " "), words.joined(separator: ","), words[0]] {
                for quote in ["\"", "'", ""] {
                  let nested = outer + outerEnd + label + innerEnd + quote + value + quote
                  hold(nested)
                  // Held on its own too, not only against the rules of this build: an inner
                  // label word with a quoted or one-word value hides every word of it.
                  if label != "seed phrase", quote != "" || !value.contains(" "), failures.count <= 12,
                    words.contains(where: { Redaction.apply(nested).text.contains($0) }) {
                    failures.append("nested label: a word of the inner value is shown: " + nested + " -> " + Redaction.apply(nested).text)
                  }
                  hold("Set " + outer + outerEnd + quote + label + innerEnd + value + quote + " then run " + words[2] + ".")
                }
              }
            }
          }
        }
      }
      // The inner value has a shape another rule masks, with a space inside it.
      for value in ["Authorization: Bearer " + body(24) + " " + words[0], "4111 1111 1111 1111 " + words[1], "+82 10 2345 6789 " + words[1],
        "https://example.org/?note=" + word + "token%3D" + words[0] + "%20" + words[1] + "&page=2", "hello+tag@example.org " + words[2]] {
        for quote in ["\"", "'", ""] { hold(word + "token=" + quote + value + quote); hold("see " + value + " " + word + "token: " + quote + value + quote) }
      }
    }
    if newlyMasked < tried / 2 { failures.append("nested label: only \(newlyMasked) of \(tried) cases reach the glued names") }
    return failures
  }

  static func labeledAndRecoveryFailures() -> [String] {
    var failures: [String] = []
    func check(_ name: String, _ text: String, _ expected: String, _ rule: String? = nil) {
      let result = Redaction.apply(text)
      if result.text != expected { failures.append("\(name): surrounding text or value differs") }
      if let rule, !result.rules.contains(rule) || !Redaction.mayMatch(text) { failures.append("\(name): rule or prefilter missed") }
      if Redaction.apply(result.text).text != result.text { failures.append("\(name): masking twice differs") }
    }
    func encoded(_ value: String) -> String {
      value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    }
    // Low-entropy invented values: no other shape can hide a missing label rule.
    for label in ["secret_key", "SECRET-KEY", "secret key", "APP_SECRET_KEY", "passphrase", "PASSCODE", "api key"] {
      let masked = label.hasPrefix("APP_") ? "APP_[secret]" : "[secret]"
      for separator in [":", "="] {
        let written = label + separator + " inventedvalue"
        check("label alone", written, masked, "labeled-secret")
        check("label sentence", "Rotate " + written + " before release.", "Rotate " + masked + " before release.", "labeled-secret")
        check("label shell", "export " + label + separator + "'invented value' && ./run.sh", "export " + masked + " && ./run.sh", "labeled-secret")
        check("label URL", "https://example.org/?note=" + encoded(written) + "&page=2", "https://example.org/?note=[secret]&page=2", "labeled-secret")
        check("label quoted", label + separator + "\"invented value\"; next", masked + "; next", "labeled-secret")
      }
    }
    // A credential's name inside a longer name: camelCase humps, capitals glued together. Each of
    // these was masked before the label got a left boundary and must stay masked.
    for (written, masked) in [
      ("dbPassword=inventedvalue", "db[secret]"), ("accessToken: inventedvalue", "access[secret]"),
      ("clientSecret = \"invented value\"", "client[secret]"), ("refreshToken=inventedvalue", "refresh[secret]"),
      ("openaiApiKey=inventedvalue", "openai[secret]"), ("PGPASSWORD=inventedvalue", "PG[secret]"),
      ("userpasswd: inventedvalue", "user[secret]"), ("JWTToken=inventedvalue", "JWT[secret]"),
      ("oauth2TOKEN=inventedvalue", "oauth2[secret]"), ("appsecret=inventedvalue", "app[secret]"),
      ("APP_TOKEN=inventedvalue", "APP_[secret]"), ("AUTHTOKEN=inventedvalue", "AUTH[secret]"),
      ("oauth2token=inventedvalue", "oauth2[secret]"), ("JWTtoken: inventedvalue", "JWT[secret]"), ("X-Api-Key: inventedvalue", "X-[secret]"),
      // The wholly small-letter "token" glued after a credential word that begins the name, at
      // the start, after a non-letter, at a hump, or after another such word.
      ("authtoken=inventedvalue", "auth[secret]"), ("csrftoken: inventedvalue", "csrf[secret]"),
      ("xsrftoken=inventedvalue", "xsrf[secret]"), ("apitoken = inventedvalue", "api[secret]"),
      ("accesstoken=inventedvalue", "access[secret]"), ("refreshtoken：inventedvalue", "refresh[secret]"),
      ("bearertoken=inventedvalue", "bearer[secret]"), ("sessiontoken=inventedvalue", "session[secret]"),
      ("deploytoken=inventedvalue", "deploy[secret]"), ("oauthtoken=inventedvalue", "oauth[secret]"),
      ("logintoken=inventedvalue", "login[secret]"), ("jwttoken=inventedvalue", "jwt[secret]"),
      ("secrettoken=inventedvalue", "secret[secret]"), ("webhooktoken=inventedvalue", "webhook[secret]"),
      ("my_authtoken=inventedvalue", "my_auth[secret]"),
      ("x-csrftoken: inventedvalue", "x-csrf[secret]"), ("myAuthtoken=inventedvalue", "myAuth[secret]"),
      ("v2apitoken=inventedvalue", "v2api[secret]"), ("oauthaccesstoken=inventedvalue", "oauthaccess[secret]"),
      ("oauthaccessrefreshtoken=inventedvalue", "oauthaccessrefresh[secret]"),
      // A capital starts the count of three again.
      ("oauthAccessRefreshSessiontoken=inventedvalue", "oauthAccessRefreshSession[secret]"),
      ("oauthRefreshtoken=inventedvalue", "oauthRefresh[secret]"), ("XYZsessiontoken=inventedvalue", "XYZsession[secret]"),
      ("\"authtoken\": \"inventedvalue\"", "\"auth[secret]"),
      // Every other casing after a small letter was masked before the list and still is.
      ("authtOKEN=inventedvalue", "auth[secret]"), ("authtoKEN: inventedvalue", "auth[secret]"),
      ("authtokeN=inventedvalue", "auth[secret]"), ("csrftOken: inventedvalue", "csrf[secret]"),
    ] {
      check("label inside a name", written, masked, "labeled-secret")
      check("label inside a name, sentence", "Set " + written + " then run.", "Set " + masked + " then run.", "labeled-secret")
    }
    // Four small-letter words in a row are not a name the list reaches, and the words taken off
    // the list name no credential: each of these stays as written.
    for written in ["oauthaccessrefreshsessiontoken=inventedvalue", "privatetoken=inventedvalue", "registrytoken: inventedvalue",
      "bottoken=inventedvalue", "apptoken = inventedvalue", "servicetoken=inventedvalue", "personaltoken：inventedvalue",
      "invitetoken=inventedvalue", "my_apptoken=inventedvalue", "myServicetoken=inventedvalue"] {
      check("glued word not on the list", written, written)
    }
    failures += nestedLabelFailures()
    // Every ASCII casing of every label word, behind each kind of prefix, before each separator.
    // The values left unmasked are exactly the documented exception and nothing else.
    var kept: Set<String> = []
    var tried = 0
    for word in ["password", "passwd", "passphrase", "passcode", "secret", "secret_key", "api_key", "apikey", "token"] {
      let letters = Array(word)
      let places = letters.indices.filter { letters[$0].isLetter }
      for bits in 0..<(1 << places.count) {
        var cased = letters
        for (n, place) in places.enumerated() where bits >> n & 1 == 1 { cased[place] = Character(cased[place].uppercased()) }
        for prefix in ["auth", "AUTH", "auth2", "auth_", "authT", "", "my", "myauth"] {
          for separator in ["=", ":", "：", " = "] {
            let written = prefix + String(cased) + separator + "inventedvalue"
            tried += 1
            if Redaction.apply(written).text.contains("inventedvalue") { kept.insert(written) }
          }
        }
      }
    }
    // Since the credential words: "authtoken" is masked like every other form. What is left is
    // the small-letter "token" glued after letters that are no credential word ("mytoken"), and
    // after a credential word that does not begin the name ("myauthtoken").
    let documented: Set<String> = Set(["my", "myauth"].flatMap { name in ["=", ":", "：", " = "].map { name + "token" + $0 + "inventedvalue" } })
    if kept != documented {
      failures.append("label casing: \(tried) forms, \(kept.count) kept, expected the \(documented.count) documented; e.g. \(kept.symmetricDifference(documented).sorted().prefix(4))")
    }
    for (written, masked) in [("myseedPHRASE", "myseedPHRASE"), ("myseedPhrase", "myseedPhrase"), ("myrecovery_Phrase", "myrecovery_Phrase")] {
      let phrase = Array(repeating: "invented", count: 12).joined(separator: " ")
      check("phrase label casing", written + ": " + phrase, masked + ": [secret]", "wallet-recovery")
    }
    let glued = "myseedphrase: " + Array(repeating: "invented", count: 12).joined(separator: " ")
    check("phrase label glued in small letters", glued, glued)
    // The full-width colon a screen reading gives, and JSON written inside a line.
    check("full-width colon", "password：inventedvalue next", "[secret] next", "labeled-secret")
    check("JSON in a line", "curl -d '{\"password\":\"inventedvalue\"}' example.org", "curl -d '{\"[secret]}' example.org", "labeled-secret")
    check("escaped JSON in a line", #"body {\"apiKey\":\"inventedvalue\"} sent"#, #"body {\"[secret] sent"#, "labeled-secret")
    // A list of digits is not an identifier list: each card in it is a card.
    check("card list", "4111111111111111,4111111111111111", "[secret],[secret]", "payment-card")
    check("hex list", "0123456789abcdef,4111111111111111", "0123456789abcdef,4111111111111111")
    // Punctuation may be part of a password; preserve the original broad unquoted coverage.
    for value in ["invented,secret", "invented;secret", "invented)secret", "invented]secret"] {
      check("punctuation in secret", "SECRET_KEY=" + value, "[secret]", "labeled-secret")
    }
    for count in [12, 15, 18, 21, 24] {
      for length in [3, 5, 8] {
        let words = (0..<count).map { body(length, "abcdefghijklmnopqrstuvwxyz", seed: UInt64($0 + 21)) }
        let phrase = words.joined(separator: " ")
        // A bare word run has no credential shape. No wordlist or copied test vector is used.
        check("unlabelled phrase", phrase, phrase)
        for label in ["seed phrase", "RECOVERY_PHRASE", "mnemonic-phrase", "mySeedPhrase", "WALLET_SEED_PHRASE", "seedphrase"] {
          let written = label + ": " + phrase
          check("phrase alone", written, label + ": [secret]", "wallet-recovery")
          check("phrase sentence", "Store " + written + ", then close.", "Store " + label + ": [secret], then close.", "wallet-recovery")
          check("phrase shell", "export " + label + "='" + phrase + "' && ./run.sh", "export " + label + "='[secret]' && ./run.sh", "wallet-recovery")
          check("phrase URL", "https://example.org/?note=" + encoded(written) + "&page=2", "https://example.org/?note=[secret]&page=2", "wallet-recovery")
          check("phrase tabs", label + "=\"" + words.joined(separator: "\t") + "\"", label + "=\"[secret]\"", "wallet-recovery")
          let json = String(decoding: try! JSONSerialization.data(withJSONObject: ["note": written, "n": 3], options: [.sortedKeys]), as: UTF8.self)
          let expected = String(decoding: try! JSONSerialization.data(withJSONObject: ["note": label + ": [secret]", "n": 3], options: [.sortedKeys]), as: UTF8.self)
          check("phrase JSON value", json, expected, "wallet-recovery")
        }
      }
    }
    // No partial prefix of an invalid count or longer word can be accepted as a phrase.
    for count in [1, 11, 13, 14, 16, 17, 19, 20, 22, 23, 25, 27] {
      let text = "recovery phrase: " + Array(repeating: "invented", count: count).joined(separator: " ")
      check("phrase invalid count", text, text)
    }
    let twelve = Array(repeating: "invented", count: 12).joined(separator: " ")
    for suffix in ["extra", "extraordinary", "12", "_extra", "-extra"] {
      let text = "recovery phrase: " + twelve + " " + suffix
      check("phrase continuation", text, text)
    }
    for word in ["ab", "abcdefghi", "abc123", "word_part"] {
      let text = "recovery phrase: " + Array(repeating: "invented", count: 11).joined(separator: " ") + " " + word
      check("phrase invalid word", text, text)
    }
    for text in ["recovery phrase\n: " + twelve, "recovery phrase: " + twelve.replacingOccurrences(of: " ", with: "\n")] {
      check("phrase separate lines", text, text)
    }
    // JSON keys are machine state; neither new labelled rule changes this existing contract.
    for label in ["SECRET_KEY", "passphrase", "passcode", "recovery phrase"] {
      let text = String(decoding: try! JSONSerialization.data(withJSONObject: [label: label == "recovery phrase" ? twelve : "inventedvalue"], options: [.sortedKeys]), as: UTF8.self)
      check("JSON key without adjacent label", text, text)
    }
    return failures
  }
}
