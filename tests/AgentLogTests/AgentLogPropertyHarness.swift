import Foundation
import XCTest

/// Deterministic traces keep failures reproducible. Shrinking removes operations until no single
/// removal preserves the failure, so the printed witness is minimal under trace deletion.
struct LogTraceRandom {
  var state: UInt64
  mutating func next(_ bound: Int) -> Int {
    state = state &* 6364136223846793005 &+ 1442695040888963407
    return Int((state >> 32) % UInt64(bound))
  }
  mutating func shuffle<T>(_ values: [T]) -> [T] {
    var result = values
    for index in result.indices.reversed() where index > 0 { result.swapAt(index, next(index + 1)) }
    return result
  }
}

func checkLogTrace<T>(seed: UInt64, trace: [T], file: StaticString = #filePath, line: UInt = #line,
  check: ([T]) throws -> String?) throws {
  guard let failure = try check(trace) else { return }
  var minimal = trace
  var index = 0
  while index < minimal.count {
    var candidate = minimal; candidate.remove(at: index)
    if try check(candidate) != nil { minimal = candidate; index = 0 }
    else { index += 1 }
  }
  let reason = try check(minimal) ?? failure
  XCTFail("seed=\(seed), minimal trace=\(minimal), failure=\(reason)", file: file, line: line)
}

/// This model stores original decoded bytes only. No production identity, graph or policy helper
/// is used to determine equality, closure, transitions or admission.
struct LogByteModel {
  var edges: [Data: Set<Data>] = [:]
  var refused = Set<Data>()
  mutating func link(_ a: Data, _ b: Data) {
    edges[a, default: []].insert(b); edges[b, default: []].insert(a)
  }
  func closure(_ seeds: Set<Data>) -> Set<Data> {
    var result = seeds, pending = Array(seeds)
    while let value = pending.popLast() {
      for next in edges[value] ?? [] where result.insert(next).inserted { pending.append(next) }
    }
    return result
  }
  mutating func refuse(_ value: Data) { refused.formUnion(closure([value])) }
  mutating func seal() { refused = closure(refused) }
  func allows(_ value: Data) -> Bool { closure([value]).isDisjoint(with: refused) }
}

let logPropertySeeds: [UInt64] = [0x501, 0xC0FFEE, 0xDEADBEEF, 0x123456789]
let logIdentityCorpus = ["invented-é", "invented-e\u{301}", "invented-Å", "invented-A\u{30a}",
  "", " ", "\u{a0}", "a:b", "a:\u{301}b", "activityprobe:decoded-identity:sha256:invented",
  "native:sha256:invented", "sk-proj-" + String(repeating: "z", count: 48),
  "\\u0041ctivityProbe", "{\"ordinary\":\"invented\"}", "a\u{0}b", "\"\\\n\t",
  String(repeating: "x", count: 4095), String(repeating: "x", count: 4096), String(repeating: "x", count: 4097),
  String(repeating: " ", count: 4097), String(repeating: "\u{a0}", count: 4097)]
