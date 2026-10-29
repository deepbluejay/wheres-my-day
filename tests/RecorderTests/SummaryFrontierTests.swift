@testable import Core
import Foundation
@testable import Storage
import XCTest

private struct Random {
  var state: UInt64
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
  mutating func int(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
  mutating func int(_ range: ClosedRange<Int>) -> Int { range.lowerBound + int(range.count) }
  mutating func chance(_ p: Double) -> Bool { Double(next() % 1_000_000) < p * 1_000_000 }
}

/// The plan that reads only past the in-memory frontier must equal the plan over the whole history
/// on every pass, while invented history changes between passes the way its writers change it.
final class SummaryFrontierTests: XCTestCase {
  /// Invented history in a real store, written only as its writers write it.
  private final class History {
    let store: ActivityStorage
    let base: Int
    var now: Int
    var times = Set<Int>()
    var forgotten: [TimeRange] = []
    var off: [TimeRange] = []
    var excluding = false
    /// Where the last pass ended, so a forget can reach back past the newest row it saw.
    var lastPass: Int
    init(store: ActivityStorage, base: Int) { self.store = store; self.base = base; now = base; lastPass = base }
    /// A time with no stored sample within the input age around it, so a row there adds unsummarized activity.
    func quiet(before limit: Int, _ random: inout Random) -> Int? {
      for _ in 0..<40 {
        let ts = random.int(base...max(base, limit))
        if !refused(ts) && !times.contains(where: { abs($0 - ts) <= 420 }) { return ts }
      }
      return nil
    }
    func refused(_ ts: Int) -> Bool {
      times.contains(ts) || (forgotten + off).contains { ts >= $0.start && ts < $0.end }
    }
    /// The recorder refuses a repeated second and forgotten or recording-off times.
    func sample(_ ts: Int, input: Bool, awake: Bool, excluded: Bool) throws {
      guard !refused(ts) else { return }
      times.insert(ts)
      try store.locked {
        try store.connection.run("""
          INSERT INTO samples(ts,bundle_id,app,window,document_key,keys,clicks,scrolls,moved,synthetic,keeping_awake,excluded)
          VALUES(?,'invented.editor','Invented','Invented','',?,0,0,0,0,?,?)
          """, [.integer(ts), .integer(input ? 1 : 0), .integer(awake ? 1 : 0), .integer(excluded ? 1 : 0)])
      }
    }
    func run(_ sql: String, _ values: [SQLValue] = []) throws { try store.locked { try store.connection.run(sql, values) } }
    func ids(_ table: String) throws -> [Int] {
      var result: [Int] = []
      try store.locked { try store.connection.rows("SELECT id FROM \(table)") { result.append(SQLiteConnection.int($0, 0)) } }
      return result
    }
    /// What forget does to the tables a plan reads: the marker first, then samples, intervals and pending calls.
    func forget(_ range: TimeRange) throws {
      forgotten.append(range)
      try run("INSERT INTO forgotten_ranges(start_ts,end_ts) VALUES(?,?)", [.integer(range.start), .integer(range.end)])
      try run("DELETE FROM samples WHERE ts>=? AND ts<?", [.integer(range.start), .integer(range.end)])
      try run("DELETE FROM intervals WHERE end_ts>? AND start_ts<?", [.integer(range.start), .integer(range.end)])
      try run("DELETE FROM model_calls WHERE pending=1 AND end_ts>? AND start_ts<?", [.integer(range.start), .integer(range.end)])
      times = times.filter { $0 < range.start || $0 >= range.end }
    }
    func overlapsForgotten(_ range: TimeRange) -> Bool { forgotten.contains { $0.start < range.end && $0.end > range.start } }
    func call(_ range: TimeRange, succeeded: Bool, pending: Bool) throws {
      guard !overlapsForgotten(range) else { return }
      try run("INSERT INTO model_calls(ts,start_ts,end_ts,model,input_tokens,cached_tokens,output_tokens,succeeded,pending) VALUES(?,?,?,'invented',1,0,1,?,?)",
        [.integer(now), .integer(range.start), .integer(range.end), .integer(succeeded ? 1 : 0), .integer(pending ? 1 : 0)])
    }
    func interval(_ range: TimeRange, isPrivate: Bool) throws {
      guard !overlapsForgotten(range), range.start < range.end else { return }
      try run("INSERT INTO intervals(start_ts,end_ts,name,description,kind,project,state) VALUES(?,?,'Invented','Invented',?,'',?)",
        [.integer(range.start), .integer(range.end), isPrivate ? .null : .text("work"), .text(isPrivate ? "private" : "named")])
    }
  }

  /// Today's plan: every sample, call, interval and forgotten range in the whole range.
  private func fullPlan(_ store: ActivityStorage, from start: Int, through end: Int, requested: Bool) throws -> SummaryPlan {
    let range = TimeRange(start, end)
    let calls = try store.modelCalls(in: TimeRange(Int.min + 1, Int.max))
    let existing = try store.intervals(in: range).map(\.range)
    return SummaryPolicy.plan(samples: try store.samples(in: TimeRange(start - RestPolicy.inputAgeSeconds - 1, end)),
      forgotten: try store.forgottenRanges(in: range), through: end,
      completed: calls.filter { !$0.pending }.map(\.range) + existing, requested: requested, from: start)
  }

  private func activity(_ history: History, through end: Int, _ random: inout Random) throws {
    var t = history.now
    while t < end {
      let length = random.int(20...900), kind = random.int(5)
      let stop = min(end, t + length)
      switch kind {
      case 0, 1:
        // Active: input seconds among observed seconds, some missing.
        for ts in t..<stop where !random.chance(0.1) {
          try history.sample(ts, input: random.chance(0.3), awake: false, excluded: history.excluding && random.chance(0.6))
        }
      case 2:
        for ts in t..<stop where !random.chance(0.2) {
          try history.sample(ts, input: false, awake: true, excluded: history.excluding && random.chance(0.6))
        }
      case 3:
        // Lone inputs near the input age, around the read margins.
        var ts = t
        while ts < stop {
          try history.sample(ts, input: true, awake: false, excluded: history.excluding && random.chance(0.6))
          ts += [59, 60, 61, 299, 300, 301, 302, 359, 360, 361, 420][random.int(11)]
        }
      default: break
      }
      t = stop
    }
    history.now = end
  }

  /// Saves calls and intervals for most planned pieces, as passes do, so history settles.
  private func settle(_ history: History, _ plan: SummaryPlan, _ random: inout Random) throws {
    for piece in plan.pieces where random.chance(0.8) {
      if piece.isPrivate { try history.interval(piece.range, isPrivate: true); continue }
      if random.chance(0.08) { try history.call(piece.range, succeeded: false, pending: true); continue }
      let succeeded = random.chance(0.85)
      try history.call(piece.range, succeeded: succeeded, pending: false)
      if succeeded, let sent = piece.sentRanges.first {
        try history.interval(sent, isPrivate: false)
      }
    }
  }

  private func mutate(_ history: History, settled: Int, _ random: inout Random) throws {
    let past = max(history.base + 60, history.now - 60)
    func pastTime(_ random: inout Random) -> Int {
      // Half near the frontier, half anywhere before now.
      random.chance(0.5) ? max(history.base, settled + random.int(-900...900)) : random.int(history.base...past)
    }
    if random.chance(0.15) {
      // Late rows: staging, busy retries and flushes after a stall store old times.
      for _ in 0..<random.int(1...4) {
        let ts = pastTime(&random)
        if random.chance(0.5) {
          for second in ts..<(ts + random.int(1...240)) {
            try history.sample(second, input: random.chance(0.4), awake: random.chance(0.2), excluded: history.excluding && random.chance(0.5))
          }
        } else { try history.sample(ts, input: true, awake: false, excluded: false) }
      }
    }
    if random.chance(0.06) {
      let start = pastTime(&random)
      try history.forget(TimeRange(start, start + random.int(30...4000)))
    }
    if random.chance(0.05) {
      // Forget every row since the last pass and a little before, then store an old row
      // in quiet history: SQLite reuses the freed ids, at or below the mark the last pass took.
      try history.forget(TimeRange(history.lastPass - random.int(20...400), history.now + 1))
      for _ in 0..<random.int(1...3) {
        if let ts = history.quiet(before: settled, &random) { try history.sample(ts, input: true, awake: false, excluded: false) }
      }
    }
    if random.chance(0.1) {
      for id in try history.ids("intervals").shuffledPrefix(random.int(1...3), &random) {
        try history.run("DELETE FROM intervals WHERE id=?", [.integer(id)])
      }
    }
    if random.chance(0.1) {
      for id in try history.ids("model_calls").shuffledPrefix(random.int(1...3), &random) {
        try history.run("DELETE FROM model_calls WHERE id=?", [.integer(id)])
      }
    }
    if random.chance(0.1) {
      let start = pastTime(&random) / 60 * 60
      try history.call(TimeRange(start, start + 60 * random.int(1...60)), succeeded: false, pending: random.chance(0.3))
    }
    if random.chance(0.1) { history.excluding.toggle() }
    if random.chance(0.05) {
      // Recording turned off for a past range: later rows there are refused, stored rows stay.
      let start = pastTime(&random)
      history.off.append(TimeRange(start, start + random.int(60...3600)))
    }
  }

  /// The read edges at their exact seconds: an input `margin` before a window keeps its first second
  /// active, and an active second `spill - 1` after a window's end decides whether its stretch ended.
  func testReadMarginsAreExact() throws {
    let edge = 1_000_000_020 + 7200
    try XCTAssertEqual(edge % 60, 0)
    let scenarios: [(String, (History) throws -> Void)] = [
      ("margin", { history in
        try history.interval(TimeRange(edge - 3600, edge), isPrivate: false)
        try history.sample(edge - 300, input: true, awake: false, excluded: false)
      }),
      ("spill", { history in
        for ts in stride(from: edge - 2400, through: edge - 400, by: 100) {
          try history.sample(ts, input: true, awake: false, excluded: false)
        }
        try history.sample(edge - RestPolicy.inputAgeSeconds - 1, input: true, awake: false, excluded: false)
        try history.interval(TimeRange(edge, edge + 3600), isPrivate: false)
        try history.sample(edge + 59, input: false, awake: true, excluded: false)
      }),
    ]
    for (name, write) in scenarios {
      let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: folder) }
      let store = try ActivityStorage(url: folder.appendingPathComponent("invented.sqlite"), appDataDirectory: folder, databaseScope: .directory(folder))
      let history = History(store: store, base: 1_000_000_020)
      try write(history)
      let service = SummaryService(storage: store, caller: SummaryFakeCaller(), settleLag: 600)
      for through in [edge + 7200, edge + 7260] {
        let expected = try fullPlan(store, from: 0, through: through, requested: false)
        let planned = try service.plan(from: 0, through: through)
        XCTAssertEqual(planned.pieces, expected.pieces, name)
        XCTAssertEqual(planned.waiting, expected.waiting, name)
        XCTAssertFalse(expected.pieces.isEmpty, name)
      }
      XCTAssertEqual(service.lastReads?.skipped.isEmpty, false, name)
    }
  }

  func testIncrementalPlanEqualsFullPlanWhileHistoryChanges() throws {
    let environment = ProcessInfo.processInfo.environment
    let histories = environment["ACTIVITYPROBE_FRONTIER_HISTORIES"].flatMap(Int.init) ?? 24
    let passes = environment["ACTIVITYPROBE_FRONTIER_PASSES"].flatMap(Int.init) ?? 70
    let firstSeed = environment["ACTIVITYPROBE_FRONTIER_SEED"].flatMap(UInt64.init) ?? 1
    var incremental = 0, full = 0, compared = 0
    for seed in firstSeed..<(firstSeed + UInt64(histories)) {
      var random = Random(state: seed)
      let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: folder) }
      let store = try ActivityStorage(url: folder.appendingPathComponent("invented.sqlite"), appDataDirectory: folder, databaseScope: .directory(folder))
      try store.saveFixtureSettings(StorageSettings(subscriptionConnected: true).withClaudeUse, at: 0)
      let base = 1_000_000_000 + random.int(0...59)
      let history = History(store: store, base: base)
      let lag = [300, 900, 1800, 3600, 7200][random.int(5)]
      let service = SummaryService(storage: store, caller: SummaryFakeCaller(), settleLag: lag)
      var settled = base
      passLoop: for pass in 0..<passes {
        try activity(history, through: history.now + (pass == 0 ? random.int(3600...10800) : random.int(60...700)), &random)
        if pass > 0 { try mutate(history, settled: settled, &random) }
        var start = 0, through = history.now, requested = false
        // A later start, sometimes on the pass that first builds the frontier.
        if random.chance(pass == 0 ? 0.3 : 0.03) { start = base + random.int(0...3600) }
        if random.chance(0.1) { requested = true; through = max(base + 1, history.now - random.int(0...5000)) }
        else if random.chance(0.05) { requested = true }
        if random.chance(0.12) {
          // A real pass, through the service's own plan, writing its own calls and intervals.
          try service.summarize(from: start, through: through, dayStart: base, locale: "en-US", requested: requested, at: history.now)
        }
        let expected = try fullPlan(store, from: start, through: through, requested: requested)
        let planned = try service.plan(from: start, through: through, requested: requested)
        compared += 1
        if service.lastReads?.skipped.isEmpty == false { incremental += 1 } else { full += 1 }
        if planned.pieces != expected.pieces || planned.waiting != expected.waiting {
          XCTFail("seed \(seed) pass \(pass): planned \(planned.pieces.map(\.range)) waiting \(planned.waiting) expected \(expected.pieces.map(\.range)) waiting \(expected.waiting)")
          break passLoop
        }
        settled = max(settled, (through - lag) / 60 * 60)
        history.lastPass = history.now
        if !requested { try settle(history, expected, &random) }
      }
    }
    print("SUMMARY-FRONTIER compared=\(compared) incremental=\(incremental) full=\(full)")
    XCTAssertGreaterThan(incremental, compared / 2)
  }
}

private extension Array where Element == Int {
  func shuffledPrefix(_ count: Int, _ random: inout Random) -> [Int] {
    var copy = self, result: [Int] = []
    while result.count < count && !copy.isEmpty { result.append(copy.remove(at: random.int(copy.count))) }
    return result
  }
}
