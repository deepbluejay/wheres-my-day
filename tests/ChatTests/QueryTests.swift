import Core
import Foundation
import Storage
import XCTest

final class QueryTests: XCTestCase {
  var root: URL!
  var writer: ActivityStorage!
  var reader: ActivityStorage!
  var query: ActivityQueries!
  var calendar: Calendar!
  let start = 14400
  override func setUpWithError() throws {
    root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ACTIVITYPROBE_TEST_ROOT"] ?? NSTemporaryDirectory())
      .appendingPathComponent("chat-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appendingPathComponent("invented.sqlite")
    writer = try ActivityStorage(url: url, appDataDirectory: root, databaseScope: .directory(root))
    try writer.saveSettings(StorageSettings(excludedApps: [], general: ["dayStartHour": "4"]), at: 0)
    try writer.appendIntervals([
      NamedInterval(range: TimeRange(start - 120, start + 120), name: "Invented plan", description: "Review plan", kind: .work),
      NamedInterval(range: TimeRange(start + 120, start + 180), name: "Private canary", project: "Hidden", state: .private),
      NamedInterval(range: TimeRange(start + 180, start + 240), name: "Excluded canary", description: "Hidden", kind: .work),
      NamedInterval(range: TimeRange(start + 240, start + 300), name: "Invented restock", kind: .personal),
    ])
    try writer.appendSamples([TimeSample(ts: start + 180, bundleID: "invented.excluded"),
      TimeSample(ts: start + 360, keys: 1)])
    // These rows predate the exclusion; clearing it may reveal already-allowed history.
    try writer.saveSettings(StorageSettings(excludedApps: ["invented.excluded"], general: ["dayStartHour": "4"]), at: 0)
    calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    reader = try ActivityStorage(url: url, appDataDirectory: root, readOnly: true, databaseScope: .directory(root))
    query = ActivityQueries(storage: reader, calendar: calendar, now: { 15000 })
  }
  override func tearDownWithError() throws {
    query = nil; reader = nil; writer = nil
    try FileManager.default.removeItem(at: root)
  }

  // Ideal: 04:00 clips the plan to 2 minutes, private minutes give time only, the excluded
  // minute keeps its timeline kind without content, personal is 1, pending input+quiet is 4.
  func testFiveIdealAnswers() throws {
    let range = TimeRange(start, start + 600)
    let recent = try query.recentWork(in: range)
    XCTAssertEqual(recent.rows.map(\.state), ["uninterpreted", "personal", "work", "private", "work"])
    XCTAssertEqual(recent.rows.map(\.minutes), [4, 1, 1, 1, 2])
    XCTAssertNil(recent.rows[2].name); XCTAssertNil(recent.rows[2].description)
    XCTAssertEqual(recent.rows.last?.name, "Invented plan")
    let doing = try query.whatWasIDoing(at: start + 60, minutes: 1)
    XCTAssertEqual(doing.rows.first?.name, "Invented plan")
    XCTAssertEqual(doing.rows.first?.minutes, 2)
    XCTAssertEqual(try query.search("review plan", in: range).rows.map(\.name), ["Invented plan"])
    XCTAssertTrue(try query.search("canary", in: range).rows.isEmpty)
    let totals = try query.timeTotals(in: range)
    XCTAssertEqual(totals.minutesByState, ["work": 3, "private": 1, "personal": 1, "uninterpreted": 4])
    XCTAssertEqual(totals.minutesByTimelineKind, ["work": 3, "other": 2, "distraction": 0, "uninterpreted": 4])
    XCTAssertEqual(totals.totalMinutes, 9)
    let day = try query.daySummary(containing: start)
    XCTAssertEqual(day.range, TimeRange(start, start + 86400))
    XCTAssertEqual(day.dayStartHour, 4)
    XCTAssertEqual(day.totalMinutes, 9)
    let text = String(decoding: try JSONEncoder().encode(day), as: UTF8.self)
    XCTAssertFalse(text.contains("canary")); XCTAssertFalse(text.contains("Hidden"))
    XCTAssertEqual(try query.daySummary(containing: start - 1).totalMinutes, 2)
  }

  // Ideal: whichever tool answers, each timeline kind and the total are the timeline's own
  // minutes, even where excluded or own-app minutes hide their names.
  func testDayAnswersMatchTimelineMinutes() throws {
    try writer.appendIntervals([
      NamedInterval(range: TimeRange(start + 900, start + 1200), name: "Invented feed", kind: .distraction),
      NamedInterval(range: TimeRange(start + 1200, start + 1500), name: "Invented draft", kind: .work),
      NamedInterval(range: TimeRange(start + 1620, start + 1800), name: "Invented errand", kind: .personal),
      NamedInterval(range: TimeRange(start + 1800, start + 1860), name: "Private canary", state: .private),
    ])
    try writer.appendSamples([TimeSample(ts: start + 960, bundleID: "invented.excluded"),
      TimeSample(ts: start + 1020, bundleID: "dev.local.ActivityProbe"),
      TimeSample(ts: start + 1260, bundleID: "invented.other", excluded: true),
      TimeSample(ts: start + 2400, keys: 1)])
    let now = start + 3600
    let query = ActivityQueries(storage: reader, calendar: calendar, now: { now })
    let timeline = try TimelineDay.read(containing: now, now: now, calendar: calendar, storage: reader)
    let expected = Dictionary(uniqueKeysWithValues: TimelineGridKind.allCases.map {
      ($0.rawValue, timeline.minutesByKind[$0] ?? 0)
    })
    XCTAssertEqual(expected, ["work": 8, "other": 6, "distraction": 5, "uninterpreted": 12])
    for answer in [try query.daySummary(containing: now), try query.timeTotals(in: timeline.range)] {
      XCTAssertEqual(answer.minutesByTimelineKind, expected)
      XCTAssertEqual(answer.totalMinutes, timeline.totalMinutes)
    }
    let day = try query.daySummary(containing: now)
    XCTAssertEqual(day.minutesByState["distraction"], 5)
    for minute in [start + 960, start + 1020, start + 1260] {
      let row = day.rows.first { $0.range.start <= minute && $0.range.end > minute }
      XCTAssertNotNil(row); XCTAssertNil(row?.name); XCTAssertNil(row?.description); XCTAssertNil(row?.project)
    }
    let text = String(decoding: try JSONEncoder().encode(day), as: UTF8.self)
    XCTAssertFalse(text.contains("canary"))
    XCTAssertTrue(text.contains("\"minutesByTimelineKind\""))
    // A search answer counts only its matches, so it carries no timeline figures to misread.
    let search = try query.search("invented draft", in: timeline.range)
    XCTAssertEqual(search.minutesByState, ["work": 4])
    let searchText = String(decoding: try JSONEncoder().encode(search), as: UTF8.self)
    XCTAssertFalse(searchText.contains("minutesByTimelineKind"))
    XCTAssertTrue(searchText.contains("\"totalMinutes\":4"))
  }

  // Ideal: the tools that list rows tell the model that nameless minutes carry only kind and
  // time, and the search tool says its totals are not the timeline's.
  func testToolDescriptionsExplainContentFreeAndMatchOnlyFigures() {
    let descriptions = Dictionary(uniqueKeysWithValues: QueryToolContract.tools.map {
      ($0["name"] as! String, $0["description"] as! String)
    })
    for name in ["recent_work", "what_was_i_doing"] {
      XCTAssertTrue(descriptions[name]!.contains("Some minutes show only their kind and time."), name)
    }
    XCTAssertTrue(descriptions["search_activity"]!.contains("count only the matching rows"))
    XCTAssertFalse(descriptions["search_activity"]!.contains("minutesByTimelineKind"))
  }

  // Ideal: an already-open reader must not return a deleted name from a cached answer.
  func testForgetRecheckAndReadOnly() throws {
    let range = TimeRange(start, start + 120)
    XCTAssertEqual(try query.recentWork(in: range).totalMinutes, 2)
    let preview = try writer.previewDeletion(in: range, allowOver24Hours: false)
    try writer.deleteRecords(in: range, confirmation: preview.confirmation, allowOver24Hours: false)
    XCTAssertEqual(try query.recentWork(in: range).totalMinutes, 0)
    XCTAssertThrowsError(try reader.saveSettings(StorageSettings()))
    XCTAssertThrowsError(try reader.appendIntervals([NamedInterval(range: TimeRange(16000, 16060), name: "No write")]))
    XCTAssertThrowsError(try query.timeTotals(in: TimeRange(Int.min, Int.max)))
    XCTAssertThrowsError(try query.whatWasIDoing(at: Int.max, minutes: 1))
  }

  // Ideal: one transactional preference patch preserves concurrent privacy changes.
  func testSelectionPatchPreservesPrivacy() throws {
    let selection = ChatSelection(provider: .claude, model: "sonnet", reasoning: "high")
    let patched = try writer.patchSettings(.chatSelection(selection))
    XCTAssertEqual(patched.chatSelection, selection)
    XCTAssertEqual(patched.excludedApps, ["invented.excluded"])
    XCTAssertEqual(patched.general["dayStartHour"], "4")
    XCTAssertThrowsError(try writer.patchSettings(.chatSelection(ChatSelection(provider: .codex, model: "bad\nmodel", reasoning: "high"))))
  }
  func testRawEvidenceAndChangedExclusions() throws {
    try writer.appendEvidence([EvidenceText(ts: start, kind: .prompt, source: "invented", text: "Raw evidence canary")])
    XCTAssertTrue(try query.search("raw evidence", in: TimeRange(start, start + 600)).rows.isEmpty)
    XCTAssertTrue(try query.search("excluded", in: TimeRange(start, start + 600)).rows.isEmpty)
    var settings = try writer.settings(); settings.excludedApps = []
    try writer.saveSettings(settings, at: 0)
    XCTAssertEqual(try query.search("excluded", in: TimeRange(start, start + 600)).rows.first?.minutes, 1)
    XCTAssertEqual(try writer.settings().general["dayStartHour"], "4")
  }
  func testDayBoundariesAcrossClockChanges() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    var settings = try writer.settings(); settings.general["dayStartHour"] = "0"
    try writer.saveSettings(settings, at: 0)
    let query = ActivityQueries(storage: reader, calendar: calendar, now: { 2_000_000_000 })
    for (month, day, hours) in [(3, 8, 23), (11, 1, 25)] {
      let date = calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12))!
      let answer = try query.daySummary(containing: Int(date.timeIntervalSince1970))
      XCTAssertEqual(answer.range.end - answer.range.start, hours * 3600)
      XCTAssertEqual(answer.dayStartHour, 0)
    }
  }
}
