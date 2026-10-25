import Foundation

// Shared input generation keeps the historical and current cost engines comparable.
enum RedactionCostHarness {
  static func run(_ arguments: [String]) {
    if arguments[1] == "cost-operations" {
      print(Redaction.costOperations.joined(separator: "\n"))
      return
    }
    let operation = arguments[2], size = Int(arguments[3])!
    let kind = arguments[4]
    let unit: String
    switch kind {
    case "digits": unit = "1"
    case "split-digits": unit = String(repeating: "1", count: max(1, size / 2 - 1)) + " "
    case "hex": unit = "a1b2c3d4"
    case "dots": unit = "."
    case "slashes": unit = "/"
    case "percents": unit = "%"
    case "backslashes": unit = "\\"
    case "labels": unit = "password secret token api_key recovery_phrase "
    case "joined-prefixes": unit = "ask-axapp-aAKIA"
    case "credential-prefixes": unit = "a-"
    case "letters", "ocr-path": unit = "a"
    case "log-like": unit = "2026-10-12 08:42:11 event=42 elapsed=125 count=3\n"
    case "source-like": unit = "let count = 42\nlet limit = 2026\nif count < limit { count += 1 }\n"
    // URL parameter values that hold nothing to mask: one long encoded value,
    // values encoded five and fifty times over, and many short parameters.
    case "url-value": unit = "ordinary%20words%2C%20"
    case "url-five-deep": unit = "ordinary%" + String(repeating: "25", count: 4) + "20"
    case "url-fifty-deep": unit = "ordinary%" + String(repeating: "25", count: 49) + "20"
    case "url-percent-chain": unit = "25"
    case "url-parameters": unit = "ab=cd%20ef&"
    default: unit = "ordinary prose for a bounded cost fixture "
    }
    let text: String
    if kind == "ordinary-few-digits" {
      let tail = " There are 2 notes, 3 lines and 4 tasks in 2026."
      text = String(String(repeating: unit, count: size / unit.count + 1).prefix(size - tail.count)) + tail
    } else if kind == "credential-prefixes" {
      let tail = "a x://y z@"
      text = String(String(repeating: unit, count: size / unit.count + 1).prefix(size - tail.count)) + tail
    } else if kind.hasPrefix("url-") {
      // One percent sign encoded as deep as the text is long, then a letter.
      let head = "https://invented.invalid/p?" + (kind == "url-parameters" ? "" : "v=") + (kind == "url-percent-chain" ? "%" : "")
      let tail = kind == "url-percent-chain" ? "41" : ""
      text = head + String(String(repeating: unit, count: size / unit.count + 1).prefix(size - head.count - tail.count)) + tail
    } else if kind == "ocr-path" {
      let head = "https://invented.invalid/"
      text = head + String(repeating: "a", count: size - head.count - 4) + ".com"
    } else {
      text = String(String(repeating: unit, count: size / unit.count + 1).prefix(size))
    }
    // Warm the static expressions, not a cached result. Every measured apply is cold.
    _ = Redaction.costProbe(operation, "ordinary")
    let count = size <= 2000 ? 5 : 1
    let start = DispatchTime.now().uptimeNanoseconds
    var result = 0
    for _ in 0..<count { result &+= Redaction.costProbe(operation, text) }
    let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9 / Double(count)
    let data = try! JSONSerialization.data(withJSONObject: ["seconds": seconds, "result": result])
    print(String(decoding: data, as: UTF8.self)); return
  }
}

#if REDACTION_COST_ONLY
@main struct CostMain {
  static func main() { RedactionCostHarness.run(CommandLine.arguments) }
}
#endif
