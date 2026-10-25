import Foundation

@main
struct RedactionHarness {
  static func main() {
    switch CommandLine.arguments.dropFirst().first ?? "fixtures" {
    case "ideal-fixtures":
      print(String(decoding: try! JSONSerialization.data(withJSONObject: RedactionFormatsTest.idealFixtureSummary(), options: [.sortedKeys]), as: UTF8.self)); return
    case "regex-fixtures":
      let failures = RedactionRegexTest.failures()
      failures.prefix(10).forEach { print($0) }
      print("Exact old/new ranges: \(RedactionRegexTest.corpus.count) inputs, \(failures.count) changes")
      if !failures.isEmpty { exit(1) }; return
    case "unicode-fixtures":
      let failures = RedactionFormatsTest.telephoneFailures() + RedactionFormatsTest.unicodeHarmless.enumerated().compactMap { index, text -> String? in
        for wrapped in [text, "before " + text + " after", "🙂 " + text + " end"] {
          if Redaction.apply(wrapped).text != wrapped || Redaction.withoutGuards(wrapped) != wrapped { return "unicode harmless-\(index) changed" }
        }
        return nil
      }
      failures.forEach { print($0) }
      print("Telephone-shaped numbers left as written and \(RedactionFormatsTest.unicodeHarmless.count) harmless inputs: \(failures.count) failures")
      if !failures.isEmpty { exit(1) }; return
    case "cost-operations", "cost":
      RedactionCostHarness.run(CommandLine.arguments); return
    case "batch":
      while let line = readLine() {
        guard let data = line.data(using: .utf8), let text = try? JSONDecoder().decode(String.self, from: data) else { exit(2) }
        let result = Redaction.apply(text)
        let report: [String: Any] = ["rules": result.rules, "changed": result.text != text]
        let out = try! JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print(String(decoding: out, as: UTF8.self))
        fflush(stdout)
      }
    case "bench":
      let title = "Review the recording pipeline and improve privacy fixtures"
      let screen = String(repeating: "Read the privacy design and verify stored records. ", count: 6)
      var result: [String: Any] = [:]
      // Strings that reach the rules: a shell line with a path and a hash, a note about keys.
      let shell = "git -C /Users/someone/work/app log --oneline 0a1b2c3d4e5f60718293a4b5c6d7e8f901234567 -- Sources/App/Network.swift && npm_config_loglevel=warn npm test"
      let note = "Authorization is checked first; the task_id and hf_hub cache are in glob-parent, see sk_test notes and 12:30 standup"
      for (name, text) in [("title", title), ("screen", screen), ("shell", shell), ("note", note)] {
        for warm in [false, true] {
          let count = 20000
          let values = warm ? Array(repeating: text, count: count) : (0..<count).map { text + " \($0)" }
          _ = Redaction.apply(text)
          let start = ProcessInfo.processInfo.systemUptime
          var bytes = 0
          for value in values { bytes += Redaction.apply(value).text.utf8.count }
          let duration = ProcessInfo.processInfo.systemUptime - start
          result[name + (warm ? "_cached" : "_distinct")] = ["base_chars": text.count, "iterations": count, "seconds": duration,
            "microseconds_per_call": duration / Double(count) * 1e6,
            "calls_per_second": Double(count) / duration, "checked_bytes": bytes]
        }
      }
      print(String(decoding: try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
    default:
      fixtures()
    }
  }

  static func fixtures() {
    let positives: [(String, String)] = [
      ("연락처: hello+tag@example.org", "email"), ("メール: user+tag@例え.テスト", "email"),
      ("Adresse: grüße@bücher.example", "email"), ("user@xn--bcher-kva.example", "email"),
      ("https://login:plain-password@example.org/path", "url-credential"),
      ("https://example.org/?anything=aB3dE5fG7hJ9kL2mN4pQ6rS8", "url-secret"),
      ("https://example.org/#aB3dE5fG7hJ9kL2mN4pQ6rS8", "url-secret"),
      ("(https://example.org/?v=aB3dE5fG7hJ9kL2mN4pQ6rS8)", "url-secret"),
      ("https://example.org/?v=hello%2Btag%40example.org", "email"),
      ("ghp_" + String(repeating: "a", count: 30), "github-token"),
      ("sk-" + String(repeating: "b", count: 30), "api-key"),
      ("AKIA0123456789ABCDEF", "aws-key"),
      ("xoxb-0123456789abc", "slack-token"),
      ("eyJabcdefghijk.abcdefghijk.abcdefghijk", "jwt"),
      ("-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----", "private-key"),
      ("4111 1111 1111 1111", "payment-card"),
      // OCR repair requires a supported provider suffix; this local part is invented.
      ("inventedperson12348gmail.com", "email"), ("password: hunter2", "labeled-secret"),
    ]
    let negatives = [
      "version 2026.10.09.123", "v123.456.7890", "2026-10-09 12:34:56", "1791449173",
      "2026-10-09T12:34:56+09:00", "20261009123456", "37.566535, 126.977969",
      "192.168.100.200", "2001:db8:0000:0000:0000:0000:0000:0001", "12345678901234567890",
      "order 1234567890", "order ORD-123456789012", "order 1234-5678-9012",
      "hash d41d8cd98f00b204e9800998ecf8427e",
      "hash abc4111111111111111def", "call_4111111111111111", "abc-4111111111111111-def",
      "1234 5678 9012 3456", "plain-login-name",
      "https://example.org/?page=42&date=2026-10-09", "[redacted] [email] [phone] [secret]",
      // Telephone numbers are not masked.
      "연락처 010-2345-6789", "電話 090-2345-6789", "Telefon +49 30 2345 6789", "Call (415) 234-5678",
      "Call +1 415 234 5678", "+82 10 2345 6789", "+81-90-2345-6789", "+33 1 23 45 67 89",
      "https://example.org/?v=%2B82%2010%202345%206789",
    ]
    var failures: [String] = []
    for (index, fixture) in positives.enumerated() {
      if RedactionFormatsTest.harmless.contains(fixture.0) {
        failures.append("positive-\(index) conflicts with ideal-kept fixture")
      }
      let result = Redaction.apply(fixture.0)
      if !result.rules.contains(fixture.1) { failures.append("positive-\(index)-\(fixture.1)") }
      if Redaction.apply(result.text).text != result.text { failures.append("idempotence-\(index)") }
    }
    // An all-digit hex token that passes the card checksum, inside an id list, stays a key.
    for list in ["4111111111111111,bea64c445f9d96c6", "bea64c445f9d96c6,4111111111111111", "0a1b2c3d-1111-2222-3333-444455556666"] {
      if Redaction.apply(list).text != list { failures.append("id-list") }
    }
    if Redaction.apply("4111111111111111").text == "4111111111111111" { failures.append("bare-card") }
    for (index, fixture) in negatives.enumerated() {
      if Redaction.apply(fixture).text != fixture { failures.append("negative-\(index)") }
    }
    let json = #"{"value":"https:\/\/login:plain-password@example.org/?v=aB3dE5fG7hJ9kL2mN4pQ6rS8","email":"hello+tag@example.org"}"#
    let clean = Redaction.apply(json)
    if clean.text.contains("plain-password") || clean.text.contains("hello+tag") || clean.text.contains("aB3dE5") || (try? JSONSerialization.jsonObject(with: Data(clean.text.utf8))) == nil { failures.append("json") }
    let numberJSON = Redaction.apply(#"{"card":4111111111111111,"timestamp":1791449173}"#)
    // JSON numbers and keys are machine state (offsets, hashes, millisecond times): one in ten
    // 13 to 19 digit numbers passes the card checksum, so rewriting them would corrupt state.
    if !numberJSON.text.contains("4111111111111111") || !numberJSON.text.contains("1791449173") || !numberJSON.rules.isEmpty { failures.append("json-number") }
    let stringJSON = Redaction.apply(#"{"card":"4111 1111 1111 1111","ids":"4a16f3b0092c5f44,bea64c445f9d96c6"}"#)
    if stringJSON.text.contains("4111 1111") || !stringJSON.text.contains("4a16f3b0092c5f44,bea64c445f9d96c6") { failures.append("json-string") }
    for plain in ["4a16f3b0092c5f44,bea64c445f9d96c6", "/Users/someone/.claude/projects/-Users-someone-work/0a1b2c3d-1111-2222-3333-444455556666.jsonl", "dev.local.ActivityProbe", #"{"offset":123456,"ts":1791449173,"open":[]}"#] {
      if Redaction.apply(plain).text != plain { failures.append("id-changed") }
    }
    let nested = try! JSONSerialization.data(withJSONObject: ["nested": json])
    let nestedClean = Redaction.apply(String(decoding: nested, as: UTF8.self))
    if nestedClean.text.contains("plain-password") || nestedClean.text.contains("hello+tag") { failures.append("nested-json") }
    var reads = 0
    for (role, subrole) in [("AXSecureTextField", nil), ("AXTextField", "AXSecureTextField")] {
      if RecordingText.focused(role: role, subrole: subrole, readValue: { reads += 1; return "fixture-password" }) != nil { failures.append("secure-field") }
    }
    if reads != 0 { failures.append("secure-value-read") }
    let ordinary = RecordingText.focused(role: "AXTextArea", subrole: nil) { "hello+tag@example.org +82 10 2345 6789" }
    if ordinary?.value != "[email] +82 10 2345 6789" { failures.append("normal-field") }
    let formats = RedactionFormatsTest.failures()
    failures += formats
    print("vendor formats: \(RedactionFormatsTest.keys.count) invented keys in 8 places each, \(RedactionFormatsTest.harmless.count) harmless strings in 3 places each; failures: \(formats.count)")
    print("shape fixtures: \(positives.count) positive, \(negatives.count) negative, JSON, secure closure; failures: \(failures.count)")
    for failure in failures { print(failure) }
    if !failures.isEmpty { exit(1) }
  }
}
