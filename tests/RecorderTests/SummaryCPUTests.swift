import Core
import Darwin
import Foundation
@testable import Storage
import Shell
import XCTest

/// The summaries stage on a steady tick: everything already summarized, so a pass only plans.
/// Measured only with ACTIVITYPROBE_SUMMARY_CPU=1, on invented samples:
/// ACTIVITYPROBE_SUMMARY_CPU_DAYS days (default 21) of 8 active hours, one sample a second,
/// and one completed call with its interval for every 45 active minutes.
final class SummaryCPUTests: XCTestCase {
  private static func threadCPU() -> Double {
    var time = timespec()
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
    return Double(time.tv_sec) + Double(time.tv_nsec) / 1e9
  }
  func testSteadySummaryPassCost() throws {
    let environment = ProcessInfo.processInfo.environment
    try XCTSkipUnless(environment["ACTIVITYPROBE_SUMMARY_CPU"] == "1")
    let days = environment["ACTIVITYPROBE_SUMMARY_CPU_DAYS"].flatMap(Int.init) ?? 21
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("invented.sqlite")
    let store = try ActivityStorage(url: url, appDataDirectory: folder, databaseScope: .directory(folder))
    try store.saveFixtureSettings(StorageSettings(subscriptionConnected: true).withClaudeUse, at: 0)
    let day = 86400, active = 8 * 3600, base = 1_000_000_020
    try store.locked {
      try store.connection.run("BEGIN")
      for index in 0..<days {
        try store.connection.run("""
          WITH RECURSIVE s(n) AS (SELECT 0 UNION ALL SELECT n+1 FROM s WHERE n<\(active - 1))
          INSERT INTO samples(ts,bundle_id,app,window,document_key,keys,clicks,scrolls,moved,synthetic,keeping_awake,excluded)
          SELECT \(base + index * day)+n,'invented.editor','Invented editor','Invented window title '||(n/600),'invented/document/'||(n/900),
            n%3,n%5=0,0,n%2,0,0,0 FROM s
          """)
        for piece in stride(from: 0, to: active, by: 2700) {
          let start = base + index * day + piece, end = start + 2700
          try store.connection.run("INSERT INTO model_calls(ts,start_ts,end_ts,model,input_tokens,cached_tokens,output_tokens,succeeded) VALUES(?,?,?,'invented',1,0,1,1)",
            [.integer(end + 30), .integer(start), .integer(end)])
          try store.connection.run("INSERT INTO intervals(start_ts,end_ts,name,description,kind,project,state) VALUES(?,?,'Invented task','Invented description','work','invented','named')",
            [.integer(start), .integer(end)])
        }
      }
      try store.connection.run("COMMIT")
    }
    let end = base + (days - 1) * day + active + 3600
    let service = SummaryService(storage: store, caller: SummaryFakeCaller())
    let passes = environment["ACTIVITYPROBE_SUMMARY_CPU_PASSES"].flatMap(Int.init) ?? 5
    var seconds: [Double] = []
    for pass in 0..<passes {
      let before = Self.threadCPU()
      try service.summarize(from: 0, through: end + pass * 300, dayStart: end - 8 * 3600, locale: "en-US", at: end + pass * 300)
      seconds.append(Self.threadCPU() - before)
    }
    XCTAssertEqual(service.health.calls, 0)
    print("SUMMARY-CPU days=\(days) samples=\(days * active) passSeconds=\(seconds.map { String(format: "%.3f", $0) })")
  }
  /// The lean planning read must plan exactly as the full sample read does.
  func testPlanningSamplesPlanAsTheFullSamples() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = try ActivityStorage(url: folder.appendingPathComponent("invented.sqlite"), appDataDirectory: folder, databaseScope: .directory(folder))
    try store.saveFixtureSettings(StorageSettings(subscriptionConnected: true).withClaudeUse, at: 0)
    var rows: [TimeSample] = []
    for ts in stride(from: 6000, to: 12000, by: 7) {
      // Every planned column varies: input kinds, keeping awake, and excluded minutes.
      rows.append(TimeSample(ts: ts, bundleID: "invented.editor", app: "Invented", window: "Invented \(ts / 600)",
        keys: ts % 3 == 0 ? 1 : 0, clicks: ts % 5 == 0 ? 2 : 0, scrolls: ts % 11 == 0 ? 1 : 0, moved: ts % 13 == 0,
        keepingAwake: ts % 17 == 0, excluded: (ts / 60) % 4 == 0))
    }
    try store.locked {
      for row in rows {
        try store.connection.run("INSERT INTO samples(ts,bundle_id,app,window,document_key,keys,clicks,scrolls,moved,synthetic,keeping_awake,excluded) VALUES(?,?,?,?,'',?,?,?,?,0,?,?)",
          [.integer(row.ts), .key(row.bundleID), .key(row.app), .key(row.window), .integer(row.keys), .integer(row.clicks), .integer(row.scrolls),
           .integer(row.moved ? 1 : 0), .integer(row.keepingAwake ? 1 : 0), .integer(row.excluded ? 1 : 0)])
      }
    }
    let range = TimeRange(0, 13000)
    let lean = try store.planningSamples(in: range), full = try store.samples(in: range)
    XCTAssertEqual(lean.count, full.count)
    for (a, b) in zip(lean, full) {
      XCTAssertEqual([a.ts, a.keys, a.clicks, a.scrolls], [b.ts, b.keys, b.clicks, b.scrolls])
      XCTAssertEqual([a.moved, a.keepingAwake, a.excluded, a.hasInput], [b.moved, b.keepingAwake, b.excluded, b.hasInput])
    }
    for requested in [false, true] {
      let planned = SummaryPolicy.plan(samples: lean, forgotten: [TimeRange(8000, 8100)], through: 13000, requested: requested, from: 0)
      let expected = SummaryPolicy.plan(samples: full, forgotten: [TimeRange(8000, 8100)], through: 13000, requested: requested, from: 0)
      XCTAssertEqual(planned.pieces, expected.pieces)
      XCTAssertEqual(planned.waiting, expected.waiting)
      XCTAssertTrue(planned.pieces.contains(where: \.isPrivate))
    }
  }
}
