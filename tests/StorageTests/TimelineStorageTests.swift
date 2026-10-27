import Core
import Foundation
import Storage
import XCTest

final class TimelineStorageTests: XCTestCase {
  func testListGroupingDoesNotRewriteStoredIntervalsOrMinuteStates() throws {
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ACTIVITYPROBE_TEST_ROOT"] ?? NSTemporaryDirectory())
      .appendingPathComponent("timeline-grouping-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("invented.sqlite")
    let storage = try ActivityStorage(url: url, appDataDirectory: root, databaseScope: .directory(root))
    try storage.saveSettings(StorageSettings(general: ["dayStartHour": "0"]), at: 0)
    let intervals = [NamedInterval(range: TimeRange(0, 1200), name: "A", kind: .work),
      NamedInterval(range: TimeRange(1200, 1260), name: "D", kind: .distraction),
      NamedInterval(range: TimeRange(1260, 3000), name: "A", kind: .work)]
    try storage.appendIntervals(intervals)
    let range = TimeRange(0, 3000)
    let before = try SummaryTimeline.minutes(in: range, storage: storage)
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let reopened = try ActivityStorage(url: url, appDataDirectory: root, databaseScope: .directory(root))
    let view = try TimelineDay.read(containing: 0, now: 3000, calendar: calendar, storage: reopened)
    XCTAssertEqual(view.entries.count, 3)
    XCTAssertEqual(view.groups.map(\.minutes), [49, 1])
    XCTAssertEqual(view.groups.first?.entryIndices, [0, 2])
    XCTAssertEqual(view.minutesByKind, [.work: 49, .distraction: 1])
    XCTAssertEqual(try reopened.intervals(in: range), intervals)
    XCTAssertEqual(try SummaryTimeline.minutes(in: range, storage: reopened), before)
    XCTAssertEqual(before[1200], .distraction)
    let preview = try reopened.previewDeletion(in: TimeRange(1200, 1260))
    try reopened.deleteRecords(in: preview.range, confirmation: preview.confirmation)
    let deleted = try TimelineDay.read(containing: 0, now: 3000, calendar: calendar, storage: reopened)
    XCTAssertEqual(deleted.entries.map(\.minutes), [20, 29])
    XCTAssertEqual(deleted.groups.map(\.minutes), [49])
    XCTAssertNil(deleted.columns[2].squares[0])
  }

  // Ideal: overlap is about the activity span, not the call timestamp; touching edges are excluded.
  func testCallOverlapQueryExcludesUnrelatedHistory() throws {
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ACTIVITYPROBE_TEST_ROOT"] ?? NSTemporaryDirectory())
      .appendingPathComponent("timeline-calls-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = try ActivityStorage(url: root.appendingPathComponent("invented.sqlite"), appDataDirectory: root, databaseScope: .directory(root))
    let range = TimeRange(600, 1200)
    let expected = ModelCall(ts: 9000, range: TimeRange(540, 1260), model: "invented", succeeded: true,
      tableFacts: SummaryCallFacts(through: 1260, sentRanges: [TimeRange(540, 1260)], endsAtRest: true, activeMinutes: [600, 720]))
    try storage.appendModelCall(expected)
    let before = try SummaryTimeline.minutes(in: range, storage: storage)
    XCTAssertEqual(before[660], .unnamed)
    XCTAssertEqual(before[780], .rest)
    for span in [TimeRange(0, 600), TimeRange(1200, 1800)] {
      try storage.appendModelCall(ModelCall(ts: 600, range: span, model: "invented", succeeded: true))
    }
    for index in 0..<500 {
      let start = 10000 + index * 600
      try storage.appendModelCall(ModelCall(ts: 700, range: TimeRange(start, start + 600), model: "invented", succeeded: true))
    }
    XCTAssertEqual(try storage.modelCalls(overlapping: range), [expected])
    XCTAssertEqual(try SummaryTimeline.minutes(in: range, storage: storage), before)
    XCTAssertEqual(try SummaryTimeline.unnamedMiddleQuietMinuteCount(in: range, storage: storage), 1)
    XCTAssertEqual(try storage.modelCalls(in: range).count, 502)
  }

  func testProjectionReadsNewStorageAndDeferralsSurviveReopening() throws {
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ACTIVITYPROBE_TEST_ROOT"] ?? NSTemporaryDirectory())
      .appendingPathComponent("timeline-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("invented.sqlite")
    let storage = try ActivityStorage(url: url, appDataDirectory: root, databaseScope: .directory(root))
    var settings = StorageSettings(subscriptionConnected: true, general: ["dayStartHour": "5"])
    TimelineNotices.deferNotice(.screenRecording, in: &settings)
    TimelineNotices.deferNotice(.fileVaultOff, in: &settings)
    try storage.saveSettings(settings, at: 0)
    let pending = try storage.patchSettings(.beginConnection)
    _ = try storage.patchSettings(.completeConnection(generation: pending.connectionGeneration))
    // Summaries use Claude, so Claude use is what keeps the subscription notice away.
    let claude = try storage.patchSettings(.beginClaudeConnection)
    _ = try storage.patchSettings(.completeClaudeConnection(generation: claude.claudeConnectionGeneration))
    let start = 5 * 3600
    try storage.appendIntervals([
      NamedInterval(range: TimeRange(start - 120, start + 360), name: "Invented boundary task", kind: .work),
      NamedInterval(range: TimeRange(start + 360, start + 600), name: "Must remain hidden", state: .private),
    ])
    try storage.appendSamples([TimeSample(ts: start + 1200, keys: 1), TimeSample(ts: start + 1260, keepingAwake: true)])
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    var security = DeviceSecurityHealth(); security.fileVault = .off
    let health = TimelineHealth(missingPermissions: [.screenRecording], security: security)
    let reopened = try ActivityStorage(url: url, appDataDirectory: root, databaseScope: .directory(root))
    let view = try TimelineDay.read(containing: start, now: start + 1800, calendar: calendar, storage: reopened, health: health)
    XCTAssertEqual(view.totalMinutes, 16)
    XCTAssertEqual(view.columns[0].squares, [.work, .work, .work, .work, .work, .work, .other, .other, .other, .other])
    XCTAssertEqual(view.entries.map(\.minutes), [6, 4, 6])
    XCTAssertEqual(view.columns[2].squares, Array(repeating: .uninterpreted, count: 6) + Array(repeating: nil, count: 4))
    XCTAssertEqual(view.entries.last?.kind, .uninterpreted)
    XCTAssertEqual(view.entries.map(\.name), ["Invented boundary task", nil, nil])
    XCTAssertEqual(view.notices, [])
    let saved = try reopened.settings()
    XCTAssertEqual(saved.general.filter { !$0.key.hasPrefix("chat.claude.") }, settings.general)
    XCTAssertEqual(saved.general.count, 4) // Day start, one value for all notice deferrals, and Claude use with its generation.
    XCTAssertEqual(try reopened.intervals(in: TimeRange(0, 86400)).count, 2)
    XCTAssertEqual(try reopened.samples(in: TimeRange(0, 86400)).count, 2)
    XCTAssertEqual(try reopened.modelCalls(in: TimeRange(0, 86400)).count, 0)
  }
}

extension TimelineStorageTests {
  func testMonthAvailabilityUsesShiftedDaysAndCrossMidnightIntervals() throws {
    let root = URL(fileURLWithPath: "/tmp/ap-daynav/month-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = try ActivityStorage(url: root.appendingPathComponent("invented.sqlite"), appDataDirectory: root, databaseScope: .directory(root))
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    func date(_ day: Int, _ hour: Int = 0) -> Date {
      calendar.date(from: DateComponents(year: 2024, month: 2, day: day, hour: hour))!
    }
    func ts(_ day: Int, _ hour: Int) -> Int { Int(date(day, hour).timeIntervalSince1970) }
    try storage.appendIntervals([
      NamedInterval(range: TimeRange(ts(2, 23), ts(3, 2)), name: "Invented", kind: .work),
      NamedInterval(range: TimeRange(ts(4, 3), ts(4, 5)), name: "Invented", kind: .work),
      NamedInterval(range: TimeRange(ts(1, 1), ts(1, 3)), name: "Invented", kind: .work),
      NamedInterval(range: TimeRange(ts(30, 1), ts(30, 2)), name: "Invented", kind: .work)
    ])
    let shifted = try storage.withQuerySnapshot {
      try TimelineDay.recordedDays(inMonth: date(15), dayStartHour: 4, calendar: calendar, storage: storage)
    }
    XCTAssertEqual(shifted, Set([date(2), date(3), date(4), date(29)]))
    let midnight = try TimelineDay.recordedDays(inMonth: date(1), dayStartHour: 0, calendar: calendar, storage: storage)
    XCTAssertEqual(midnight, Set([date(1), date(2), date(3), date(4)]))
    let range = try TimelineDay.range(on: date(4, 1), dayStartHour: 4, calendar: calendar)
    XCTAssertEqual(range, TimeRange(ts(4, 4), ts(5, 4)))
    let day = try TimelineDay.read(containing: range.start, now: ts(30, 4), calendar: calendar, storage: storage)
    XCTAssertEqual(day.range, range)
    XCTAssertEqual(day.totalMinutes, 60)
    XCTAssertNil(day.nowColumn)
  }
}
