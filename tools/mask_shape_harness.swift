import Foundation
@main struct MaskShapeHarness {
  static func main() {
    #if !MASK_SHAPE_BASELINE
    if CommandLine.arguments.contains("shape-batch") {
      while let line = readLine() {
        let text = try! JSONDecoder().decode(String.self, from: Data(line.utf8))
        let spans = RandomValueMask.ranges(text).map { [$0.location, $0.location + $0.length] }
        print(String(decoding: try! JSONEncoder().encode(spans), as: UTF8.self))
      }
      return
    }
    #endif
    if CommandLine.arguments.contains("batch") || CommandLine.arguments.contains("known-batch") {
      while let line = readLine() {
        let text = try! JSONDecoder().decode(String.self, from: Data(line.utf8))
        #if MASK_SHAPE_BASELINE
        let out = Redaction.apply(text).text
        #else
        let out = CommandLine.arguments.contains("known-batch") ? Redaction.applyKnownSecrets(text).text : Redaction.apply(text).text
        #endif
        print(String(decoding: try! JSONEncoder().encode(out), as: UTF8.self))
      }
      return
    }
    if CommandLine.arguments.contains("nested-bare-benchmark") {
      for size in [65_536, 262_144, 1_048_576] {
        let text = String(String(repeating: "notes.example/read?v=", count: size / 20 + 1).prefix(size))
        var times: [Double] = []
        for _ in 0..<3 {
          Redaction.forgetCached()
          let start = DispatchTime.now().uptimeNanoseconds
          _ = Redaction.apply(text)
          times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }
        print(String(decoding: try! JSONSerialization.data(withJSONObject: ["bytes": size, "median_ms": times.sorted()[1]], options: [.sortedKeys]), as: UTF8.self))
      }
      return
    }
    _ = Redaction.withoutGuards("warmup invented")
    var state: UInt64 = 50120261014
    func random(_ n: Int) -> String {
      let alphabet = Array((33...126).map { UInt8($0) })
      return String(decoding: (0..<n).map { _ in
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return alphabet[Int(state >> 32) % alphabet.count]
      }, as: UTF8.self)
    }
    let lines = (0..<1000).map { i in "invented note \(i) /readable/project/source.swift value=" + random(32) }
    let randomLine = random(1_048_576)
    let repeatedLine = String(repeating: "g", count: 1_048_576)
    for (name, values) in [("1000_lines", lines), ("random_1MiB", [randomLine]), ("repeated_1MiB", [repeatedLine])] {
      var times: [Double] = [], checksum = 0
      for _ in 0..<5 {
        Redaction.forgetCached()
        let start = DispatchTime.now().uptimeNanoseconds
        for value in values { checksum += Redaction.apply(value).text.utf8.count }
        times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
      }
      let output: [String: Any] = ["kind": name, "median_ms": times.sorted()[2], "min_ms": times.min()!, "max_ms": times.max()!, "checksum": checksum]
      print(String(decoding: try! JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), as: UTF8.self))
    }
  }
}
