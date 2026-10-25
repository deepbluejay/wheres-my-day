import Core
import Foundation
import XCTest

final class TimelineTests: XCTestCase {
  private var utc: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
  }
  private func day(_ kinds: [SummaryMinuteKind], intervals: [NamedInterval] = [], now: Int = 86400) -> TimelineDay {
    TimelineDay.make(range: TimeRange(0, 86400),
      minutes: Dictionary(uniqueKeysWithValues: kinds.enumerated().map { ($0.offset * 60, $0.element) }),
      intervals: intervals, now: now, calendar: utc)
  }
  private func drawn(_ kinds: [SummaryMinuteKind]) -> [TimelineGridKind?] { day(kinds).columns[0].squares }

  // Ideal: every column keeps ten minute slots, including its empty positions.
  func testFullPartialAndEmptyColumns() {
    XCTAssertEqual(TimelineDay.rows, 10)
    XCTAssertEqual(drawn(Array(repeating: .work, count: 10)), Array(repeating: .work, count: 10))
    XCTAssertEqual(drawn(Array(repeating: .work, count: 6) + Array(repeating: .rest, count: 4)),
      Array(repeating: .work, count: 6) + Array(repeating: nil, count: 4))
    XCTAssertEqual(drawn(Array(repeating: .rest, count: 10)), Array(repeating: nil, count: 10))
    XCTAssertEqual(drawn(Array(repeating: .blank, count: 10)), Array(repeating: .uninterpreted, count: 10))
    let adjacent = day(Array(repeating: .work, count: 10) + [.work] + Array(repeating: .rest, count: 9))
    XCTAssertEqual(adjacent.columns[0].squares, Array(repeating: .work, count: 10))
    XCTAssertEqual(adjacent.columns[1].squares.compactMap { $0 }, [.work])
    XCTAssertEqual(adjacent.totalMinutes, 11)
  }

  // Ideal: a lone minute fills its own slot, regardless of its position or kind.
  func testEachMinuteFillsOnlyItsOwnSlot() {
    for (state, kind) in [(SummaryMinuteKind.work, TimelineGridKind.work), (.personal, .other), (.distraction, .distraction),
      (.unsummarized, .uninterpreted), (.blank, .uninterpreted)] {
      for index in 0..<10 {
        var source = Array(repeating: SummaryMinuteKind.rest, count: 10)
        source[index] = state
        var expected = Array<TimelineGridKind?>(repeating: nil, count: 10)
        expected[index] = kind
        let view = day(source)
        XCTAssertEqual(drawn(source), expected)
        XCTAssertEqual(view.totalMinutes, 1)
        XCTAssertEqual(view.entries.first?.minutes, 1)
      }
    }
  }

  // Ideal: bottom to top follows time, with holes preserved between activities.
  func testSquaresPreserveMinuteOrderAndEmptyGaps() {
    XCTAssertEqual(drawn(Array(repeating: .distraction, count: 3) + Array(repeating: .work, count: 7)),
      [.distraction, .distraction, .distraction, .work, .work, .work, .work, .work, .work, .work])
    XCTAssertEqual(drawn([.distraction, .rest, .work, .blank, .personal, .work, .rest, .private, .unnamed, .unsummarized]),
      [.distraction, nil, .work, .uninterpreted, .other, .work, nil, .other, .other, .uninterpreted])
    let missing = TimelineDay.make(range: TimeRange(0, 600), minutes: [0: .distraction, 120: .work, 540: .personal],
      intervals: [], now: 600, calendar: utc)
    let expected: [TimelineGridKind?] = [.distraction, nil, .work, nil, nil, nil, nil, nil, nil, .other]
    XCTAssertEqual(missing.columns[0].squares, expected)
  }

  func testEveryMinuteKindHasAnExplicitDisplayMeaning() {
    let view = day(SummaryMinuteKind.allCases)
    XCTAssertEqual(view.totalMinutes, 7)
    XCTAssertEqual(view.minutesByKind, [.work: 1, .other: 3, .distraction: 1, .uninterpreted: 2])
    XCTAssertEqual(view.entries.last?.minutes, 2)
    XCTAssertEqual(view.entries.map(\.state), [.work, .personal, .distraction, .private, .unnamed, .unsummarized])
    XCTAssertTrue(view.entries.allSatisfy { $0.name == nil })
  }

  // Ideal: figures, list and occupied grid slots count the same source minutes.
  func testListTotalAndGridShareOneInventedDay() {
    let kinds: [SummaryMinuteKind] = [.work, .work, .work, .personal, .personal, .distraction, .private, .unnamed, .unsummarized, .blank, .rest]
    let intervals = [NamedInterval(range: TimeRange(0, 180), name: "Invented task", kind: .work),
      NamedInterval(range: TimeRange(180, 300), name: "Invented errand", kind: .personal),
      NamedInterval(range: TimeRange(300, 360), name: "Invented diversion", kind: .distraction),
      NamedInterval(range: TimeRange(360, 420), name: "Must not appear", state: .private)]
    let view = day(kinds, intervals: intervals)
    XCTAssertEqual(view.totalMinutes, 10)
    XCTAssertEqual(view.minutesByKind, [.work: 3, .other: 4, .distraction: 1, .uninterpreted: 2])
    XCTAssertEqual(view.entries.reduce(0) { $0 + $1.minutes }, 10)
    XCTAssertEqual(view.columns.reduce(0) { $0 + $1.minutesByKind.values.reduce(0, +) }, 10)
    XCTAssertEqual(view.entries.map(\.minutes), [3, 2, 1, 1, 1, 2])
    XCTAssertEqual(view.entries.map(\.name), ["Invented task", "Invented errand", "Invented diversion", nil, nil, nil])
    XCTAssertEqual(view.columns[0].squares.compactMap { $0 }.count, 10)
    XCTAssertEqual(view.entries[0].range, TimeRange(0, 180))
  }

  func testAdjacentSameNameIntervalsJoinAndAreClippedToTheDay() {
    let first = NamedInterval(range: TimeRange(-120, 120), name: "Invented same name", kind: .work)
    let second = NamedInterval(range: TimeRange(120, 240), name: "Invented same name", kind: .work)
    let view = day(Array(repeating: .work, count: 4), intervals: [first, second])
    XCTAssertEqual(view.entries.map(\.range), [TimeRange(0, 240)])
    XCTAssertEqual(view.entries.map(\.minutes), [4])
  }

  func testDayStartAtFiveAndMinutesBeforeBelongToPreviousDay() throws {
    let range = try TimelineDay.range(containing: 6 * 3600, dayStartHour: 5, calendar: utc)
    XCTAssertEqual(range, TimeRange(5 * 3600, 29 * 3600))
    let view = TimelineDay.make(range: range, minutes: [5 * 3600 - 60: .work, 5 * 3600: .work], intervals: [], now: 6 * 3600, calendar: utc)
    XCTAssertEqual(view.columns.count, 144)
    XCTAssertEqual(view.columns[0].range, TimeRange(5 * 3600, 5 * 3600 + 600))
    XCTAssertEqual(view.totalMinutes, 1)
    XCTAssertEqual(view.scale.first, TimelineScaleMark(column: 6, hour: 6))
    XCTAssertEqual(try TimelineDay.range(containing: 5 * 3600 - 1, dayStartHour: 5, calendar: utc).end, 5 * 3600)
  }

  func testNowColumnAndFutureTime() {
    let source = Array(repeating: SummaryMinuteKind.work, count: 30)
    let view = day(source, now: 650)
    XCTAssertEqual(view.nowColumn, 1)
    XCTAssertEqual(view.totalMinutes, 10) // Only completed source minutes, no invented future seconds.
    XCTAssertTrue(view.columns.dropFirst().allSatisfy { $0.squares.count == 10 && $0.squares.allSatisfy { $0 == nil } })
    let partial = day(source, now: 790)
    XCTAssertEqual(partial.nowColumn, 1)
    let expected: [TimelineGridKind?] = [.work, .work, .work, nil, nil, nil, nil, nil, nil, nil]
    XCTAssertEqual(partial.columns[1].squares, expected)
    XCTAssertEqual(day(source, now: 600).nowColumn, 1)
    XCTAssertEqual(day([], now: 0).nowColumn, 0)
    XCTAssertEqual(day([], now: 86399).nowColumn, 143)
    XCTAssertNil(day([], now: 86400).nowColumn)
    XCTAssertNil(day([], now: -1).nowColumn)
    XCTAssertEqual(day(source, now: -1).totalMinutes, 0)
  }

  func testReadUsesSummaryMinuteStatesAndHidesForgottenAndPrivateNames() throws {
    let storage = InventedTimelineStorage()
    storage.intervalsValue = [NamedInterval(range: TimeRange(0, 600), name: "Invented work", kind: .work),
      NamedInterval(range: TimeRange(600, 720), name: "Must stay private", state: .private)]
    storage.forgotten = [TimeRange(120, 180)]
    storage.samplesValue = [TimeSample(ts: 1200, keys: 1), TimeSample(ts: 1260, keepingAwake: true)]
    let view = try TimelineDay.read(containing: 0, now: 1800, calendar: utc, storage: storage)
    XCTAssertEqual(view.totalMinutes, 17) // Nine work, two private, six pending minutes.
    XCTAssertEqual(view.minutesByKind, [.work: 9, .other: 2, .uninterpreted: 6])
    XCTAssertEqual(view.entries.map(\.range), [TimeRange(0, 120), TimeRange(180, 600), TimeRange(600, 720), TimeRange(1200, 1560)])
    XCTAssertNil(view.entries.first { $0.state == .private }?.name)
    XCTAssertFalse(view.entries.contains { $0.range.start <= 120 && $0.range.end > 120 })
    storage.settingsValue.general["dayStartHour"] = "5"
    XCTAssertEqual(try TimelineDay.read(containing: 6 * 3600, now: 6 * 3600, calendar: utc, storage: storage).range.start, 5 * 3600)
    storage.settingsValue.general["dayStartHour"] = "invalid"
    XCTAssertEqual(try TimelineDay.read(containing: 6 * 3600, now: 6 * 3600, calendar: utc, storage: storage).range.start, 4 * 3600)
  }

  func testSuccessfulOmissionsUsePersistedFactsWithoutInventingNames() throws {
    let storage = InventedTimelineStorage()
    storage.calls = [ModelCall(ts: 600, range: TimeRange(0, 600), model: "invented", succeeded: true,
      tableFacts: SummaryCallFacts(through: 600, sentRanges: [TimeRange(0, 600)], endsAtRest: true, activeMinutes: [0, 120]))]
    let view = try TimelineDay.read(containing: 0, now: 86400, calendar: utc, storage: storage)
    XCTAssertEqual(view.totalMinutes, 3)
    XCTAssertEqual(view.entries.map(\.state), [.unnamed])
    XCTAssertEqual(view.entries.first?.range, TimeRange(0, 180))
    XCTAssertNil(view.entries.first?.name)
  }

  // Ideal: every pending minute counts before and after a successful hour is interpreted.
  func testPendingHourAndSuccessfulHourCountTheSameMinutes() throws {
    let storage = InventedTimelineStorage()
    storage.samplesValue = stride(from: 0, to: 3600, by: 120).map { TimeSample(ts: $0, keys: 1) }
    let view = try TimelineDay.read(containing: 0, now: 3600, calendar: utc, storage: storage)
    XCTAssertEqual(view.entries.count, 1)
    XCTAssertEqual(view.entries.first?.range, TimeRange(0, 3600))
    XCTAssertEqual(view.entries.first?.minutes, 60)
    XCTAssertEqual(view.totalMinutes, 60)
    XCTAssertEqual(view.columns.prefix(6).map { $0.minutesByKind[.uninterpreted] }, Array(repeating: 10, count: 6))
    let expected = Array<TimelineGridKind?>(repeating: .uninterpreted, count: 10)
    XCTAssertEqual(view.columns.prefix(6).map(\.squares), Array(repeating: expected, count: 6))
    XCTAssertEqual(view.entries.map(\.state), [.unsummarized])
    XCTAssertNil(view.entries.first?.name)
    storage.intervalsValue = [
      NamedInterval(range: TimeRange(0, 1200), name: "Invented work", kind: .work),
      NamedInterval(range: TimeRange(1200, 2400), name: "Invented errand", kind: .personal),
      NamedInterval(range: TimeRange(2400, 3600), name: "Invented diversion", kind: .distraction),
    ]
    storage.calls = [ModelCall(ts: 4000, range: TimeRange(0, 3600), model: "invented", succeeded: true,
      tableFacts: SummaryCallFacts(through: 3600, sentRanges: [TimeRange(0, 3600)], endsAtRest: false,
        activeMinutes: Array(stride(from: 0, to: 3600, by: 120))))]
    let interpreted = try TimelineDay.read(containing: 0, now: 3600, calendar: utc, storage: storage)
    XCTAssertEqual(interpreted.totalMinutes, view.totalMinutes)
    XCTAssertEqual(interpreted.minutesByKind, [.work: 20, .other: 20, .distraction: 20])
    for (column, kind) in [(0, TimelineGridKind.work), (2, .other), (4, .distraction)] {
      XCTAssertEqual(interpreted.columns[column].squares, Array(repeating: kind, count: 10))
    }
  }

  // Ideal: the shell exposes 91 counted pending minutes and their range as separate values.
  func testPendingLineExposesCountSeparatelyFromLongDisplayRange() throws {
    let storage = InventedTimelineStorage()
    storage.samplesValue = stride(from: 0, through: 5400, by: 30).map { TimeSample(ts: $0, keepingAwake: true) }
    storage.samplesValue += [TimeSample(ts: 0, keys: 1), TimeSample(ts: 5400, keys: 1)]
    let view = try TimelineDay.read(containing: 0, now: 5460, calendar: utc, storage: storage)
    XCTAssertEqual(view.entries.count, 1)
    let line = try XCTUnwrap(view.entries.first)
    XCTAssertEqual(line.state, .unsummarized)
    XCTAssertNil(line.name)
    XCTAssertEqual(line.range, TimeRange(0, 5460))
    XCTAssertEqual((line.range.end - line.range.start) / 60, 91)
    XCTAssertEqual(line.minutes, 91)
    XCTAssertEqual(view.totalMinutes, 91)
    XCTAssertEqual(line.kind, .uninterpreted)
  }

  func testPendingLinesDoNotJoinAcrossRestMissingOrOtherActivity() {
    for barrier in [SummaryMinuteKind.rest, .private, .work, .unnamed] {
      let view = day([.unsummarized, .blank, barrier, .blank, .unsummarized])
      XCTAssertEqual(view.entries.filter { $0.state == .unsummarized }.map(\.range), [TimeRange(0, 120), TimeRange(180, 300)])
    }
    let missing = TimelineDay.make(range: TimeRange(0, 600), minutes: [0: .unsummarized, 60: .blank, 180: .blank, 240: .unsummarized],
      intervals: [], now: 600, calendar: utc)
    XCTAssertEqual(missing.entries.map(\.minutes), [2, 2])
  }

  // Ideal: pending, failed and disconnected activity has the same hollow slots.
  func testUninterpretedActivityDoesNotRequireAConnectionOrSuccessfulCall() throws {
    for status in 0..<3 {
      let storage = InventedTimelineStorage()
      storage.settingsValue.subscriptionConnected = status != 2
      storage.samplesValue = stride(from: 0, to: 3600, by: 120).map { TimeSample(ts: $0, keys: 1) }
      if status == 1 {
        storage.calls = [ModelCall(ts: 3600, range: TimeRange(0, 3600), model: "invented", succeeded: false)]
      }
      let view = try TimelineDay.read(containing: 0, now: 3600, calendar: utc, storage: storage)
      XCTAssertEqual(view.totalMinutes, 60)
      XCTAssertEqual(view.minutesByKind, [.uninterpreted: 60])
      XCTAssertEqual(view.entries.map(\.minutes), [60])
      XCTAssertTrue(view.columns.prefix(6).allSatisfy { $0.squares == Array(repeating: .uninterpreted, count: 10) })
    }
  }

  // Ideal: input age is inclusive at 300 s; display-on adds only its own minute.
  func testUninterpretedWindowBoundaryDisplayOnlyAndEmptyTime() throws {
    let storage = InventedTimelineStorage()
    storage.samplesValue = [TimeSample(ts: 0, keys: 1), TimeSample(ts: 600, keepingAwake: true)]
    let view = try TimelineDay.read(containing: 0, now: 720, calendar: utc, storage: storage)
    XCTAssertEqual(view.totalMinutes, 7)
    XCTAssertEqual(view.entries.map(\.range), [TimeRange(0, 360), TimeRange(600, 660)])
    XCTAssertEqual(view.entries.map(\.minutes), [6, 1])
    XCTAssertEqual(view.columns[0].squares, Array(repeating: .uninterpreted, count: 6) + Array(repeating: nil, count: 4))
    XCTAssertEqual(view.columns[1].squares, [.uninterpreted] + Array(repeating: nil, count: 9))
    storage.forgotten = [TimeRange(60, 120)]
    let deleted = try TimelineDay.read(containing: 0, now: 720, calendar: utc, storage: storage)
    XCTAssertNil(deleted.columns[0].squares[1])
    XCTAssertEqual(deleted.totalMinutes, 6)
    XCTAssertEqual(deleted.entries.map(\.minutes), [1, 4, 1])
    let future = day([.unsummarized, .blank, .unsummarized], now: 90)
    XCTAssertEqual(future.totalMinutes, 1)
    XCTAssertEqual(future.columns[0].squares, [.uninterpreted] + Array(repeating: nil, count: 9))
  }

  // Ideal: only the omitted quiet tail becomes empty when interpretation arrives.
  func testSuccessfulCallKeepsActivityAndEmptiesOnlyOmittedRestTail() throws {
    let storage = InventedTimelineStorage()
    storage.samplesValue = [TimeSample(ts: 0, keys: 1), TimeSample(ts: 120, keys: 1)]
    let pending = try TimelineDay.read(containing: 0, now: 420, calendar: utc, storage: storage)
    XCTAssertEqual(pending.totalMinutes, 7)
    storage.calls = [ModelCall(ts: 480, range: TimeRange(0, 420), model: "invented", succeeded: true,
      tableFacts: SummaryCallFacts(through: 420, sentRanges: [TimeRange(0, 420)], endsAtRest: true,
        activeMinutes: [0, 120]))]
    storage.intervalsValue = [
      NamedInterval(range: TimeRange(0, 60), name: "Invented work", kind: .work),
      NamedInterval(range: TimeRange(120, 180), name: "Invented diversion", kind: .distraction),
    ]
    let interpreted = try TimelineDay.read(containing: 0, now: 420, calendar: utc, storage: storage)
    XCTAssertEqual(interpreted.totalMinutes, 3)
    XCTAssertEqual(interpreted.columns[0].squares, [.work, .other, .distraction] + Array(repeating: nil, count: 7))
    XCTAssertEqual(interpreted.entries.map(\.state), [.work, .unnamed, .distraction])
  }

  // Ideal: calls finishing after the view still supply facts; unrelated history is never requested.
  func testSummaryReadBoundsModelCallsAndPreservesClippedFacts() throws {
    let storage = InventedTimelineStorage()
    storage.calls = [ModelCall(ts: 9000, range: TimeRange(0, 600), model: "invented", succeeded: true,
      tableFacts: SummaryCallFacts(through: 600, sentRanges: [TimeRange(0, 600)], endsAtRest: true, activeMinutes: [0, 120]))]
    let range = TimeRange(60, 180)
    let expected = try SummaryTimeline.minutes(in: range, storage: storage)
    XCTAssertEqual(expected, [60: .unnamed, 120: .unnamed])
    storage.calls += (0..<1000).map { index in
      ModelCall(ts: 10000 + index * 600, range: TimeRange(10000 + index * 600, 10600 + index * 600), model: "invented", succeeded: true)
    }
    storage.callReads = []
    XCTAssertEqual(try SummaryTimeline.minutes(in: range, storage: storage), expected)
    XCTAssertEqual(storage.callReads, [range])
  }

  func testClockChangesKeepTenMinuteSlotsAndCompleteCivilDays() throws {
    var calendar = utc
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    for (month, day, columns) in [(3, 8, 138), (11, 1, 150)] {
      let date = calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12))!
      let range = try TimelineDay.range(containing: Int(date.timeIntervalSince1970), dayStartHour: 0, calendar: calendar)
      let source = Dictionary(uniqueKeysWithValues: stride(from: range.start, to: range.end, by: 60).enumerated().map {
        ($0.element, $0.offset % 10 < 3 ? SummaryMinuteKind.distraction : .work)
      })
      let view = TimelineDay.make(range: range, minutes: source, intervals: [], now: range.end, calendar: calendar)
      XCTAssertEqual(view.columns.count, columns)
      XCTAssertTrue(view.columns.allSatisfy { $0.range.end - $0.range.start == 600 && $0.squares.count == 10 })
      let expected: [TimelineGridKind?] = [.distraction, .distraction, .distraction, .work, .work, .work, .work, .work, .work, .work]
      XCTAssertTrue(view.columns.allSatisfy { $0.squares == expected })
      XCTAssertEqual(view.totalMinutes, columns * 10)
    }
  }

  private var healthy: TimelineHealth {
    var security = DeviceSecurityHealth(); security.fileVault = .on
    return TimelineHealth(security: security)
  }
  func testEachMissingItemMakesOneSettingsNoticeAndHealthyMakesNone() {
    let settings = StorageSettings(subscriptionConnected: true)
    XCTAssertEqual(TimelineNotices.make(settings: settings, health: healthy), [])
    for permission in TimelinePermission.allCases {
      var health = healthy; health.missingPermissions = [permission]
      let notices = TimelineNotices.make(settings: settings, health: health)
      XCTAssertEqual(notices.count, 1)
      XCTAssertEqual(notices.first?.target, .settings)
      XCTAssertFalse(notices.first!.line.isEmpty)
      XCTAssertFalse(notices.first!.line.contains("\n"))
    }
    var health = healthy; health.security.fileVault = .off
    XCTAssertEqual(TimelineNotices.make(settings: settings, health: health).map(\.kind), [.fileVaultOff])
    health.security.fileVault = .unknown
    XCTAssertEqual(TimelineNotices.make(settings: settings, health: health).map(\.kind), [.fileVaultUnknown])
    XCTAssertEqual(TimelineNotices.make(settings: StorageSettings(), health: healthy).map(\.kind), [.subscription])
    health = healthy; health.summary = SummaryHealth(); health.summary?.subscriptionConnected = true
    health.summary?.failedRanges = [TimeRange(0, 60), TimeRange(120, 180)]
    XCTAssertEqual(TimelineNotices.make(settings: settings, health: health).map(\.kind), [.summaryFailure])
    health.summary?.subscriptionConnected = false
    XCTAssertEqual(TimelineNotices.make(settings: settings, health: health).map(\.kind), [.subscription, .summaryFailure])
    health = healthy; health.summary = SummaryHealth(); health.summary?.subscriptionConnected = true
    health.summary?.localPreparationFailed = true
    XCTAssertEqual(TimelineNotices.make(settings: settings, health: health).map(\.kind), [.summaryPreparation])
    for failure in [StorageSecurityFailure.backupExclusionFailed, .backupExclusionSkippedOverride] {
      health = healthy; health.security.backupExclusionFailure = failure
      XCTAssertEqual(TimelineNotices.make(settings: settings, health: health).map(\.kind), [.backupExclusion])
    }
  }

  // Ideal: with consent on, every ChatGPT state that keeps summaries waiting gives one notice that leads to Settings.
  func testPausedSummariesGiveANotice() {
    let settings = StorageSettings(subscriptionConnected: true)
    var health = healthy
    for status in ChatGPTConnectionStatus.allCases {
      health.chatGPT = status
      XCTAssertEqual(TimelineNotices.make(settings: settings, health: health).map(\.kind), status == .connected ? [] : [.summaryPaused],
        status.rawValue)
    }
    // Without consent the subscription notice says it; no second notice.
    health.chatGPT = .usageLimited
    XCTAssertEqual(TimelineNotices.make(settings: StorageSettings(), health: health).map(\.kind), [.subscription])
    XCTAssertEqual(TimelineNoticeKind.summaryPaused.settingsSection, .subscription)
    // An unread status keeps a deferral; a status that is fine again resolves it.
    var deferred = settings
    TimelineNotices.deferNotice(.summaryPaused, in: &deferred)
    health.chatGPT = nil
    XCTAssertNil(TimelineNotices.resolved(settings: deferred, health: health))
    health.chatGPT = .notAccepted
    XCTAssertNil(TimelineNotices.resolved(settings: deferred, health: health))
    XCTAssertEqual(TimelineNotices.make(settings: deferred, health: health), [])
    health.chatGPT = .connected
    XCTAssertNotNil(TimelineNotices.resolved(settings: deferred, health: health))
  }

  func testDeferralsAreOneSettingsValueAndDoNotHideDifferentProblems() {
    var settings = StorageSettings(subscriptionConnected: true)
    var health = healthy; health.missingPermissions = [.screenRecording, .inputMonitoring]
    TimelineNotices.deferNotice(.screenRecording, in: &settings)
    TimelineNotices.deferNotice(.screenRecording, in: &settings)
    XCTAssertEqual(settings.general.count, 1)
    XCTAssertEqual(TimelineNotices.make(settings: settings, health: health).map(\.kind), [.inputMonitoring])
    TimelineNotices.deferNotice(.inputMonitoring, in: &settings)
    XCTAssertEqual(settings.general.count, 1)
    XCTAssertEqual(TimelineNotices.make(settings: settings, health: health), [])
    settings.general[TimelineNotices.deferredSettingKey] = "broken"
    XCTAssertEqual(TimelineNotices.make(settings: settings, health: health).count, 2)
  }

  func testAttemptFailuresWithoutFailedRangesGiveNoNotice() {
    var health = healthy
    health.summary = SummaryHealth()
    health.summary?.subscriptionConnected = true
    health.summary?.transportFailures = 3
    health.summary?.unbilledExecFailures = 2
    XCTAssertEqual(TimelineNotices.make(settings: StorageSettings(subscriptionConnected: true), health: health), [])
  }

  // Ideal: an unread snapshot cannot resolve either deferred summary problem.
  func testUnreadSummaryHealthKeepsSummaryDeferrals() throws {
    for kind in [TimelineNoticeKind.summaryFailure, .summaryPreparation] {
      var settings = StorageSettings(subscriptionConnected: true)
      TimelineNotices.deferNotice(kind, in: &settings)
      var health = healthy
      health.summary = SummaryHealth()
      health.summary?.subscriptionConnected = true
      if kind == .summaryFailure { health.summary?.failedRanges = [TimeRange(0, 60)] }
      else { health.summary?.localPreparationFailed = true }
      XCTAssertNil(TimelineNotices.resolved(settings: settings, health: health))
      health.summary = nil
      XCTAssertNil(TimelineNotices.resolved(settings: settings, health: health))
      health.summary = SummaryHealth()
      health.summary?.subscriptionConnected = true
      settings = try XCTUnwrap(TimelineNotices.resolved(settings: settings, health: health))
      if kind == .summaryFailure { health.summary?.failedRanges = [TimeRange(0, 60)] }
      else { health.summary?.localPreparationFailed = true }
      XCTAssertEqual(TimelineNotices.make(settings: settings, health: health).map(\.kind), [kind])
    }
  }

  // Ideal: resolving one problem clears only its deferral, and recurrence is visible again.
  func testResolvedDeferralsReturnSettingsToSaveAndRecurrenceShowsAgain() throws {
    var settings = StorageSettings(subscriptionConnected: true, general: ["unrelated": "kept"])
    TimelineNotices.deferNotice(.screenRecording, in: &settings)
    TimelineNotices.deferNotice(.fileVaultOff, in: &settings)
    var health = healthy
    health.missingPermissions = [.screenRecording]
    health.security.fileVault = .off
    XCTAssertNil(TimelineNotices.resolved(settings: settings, health: health))
    XCTAssertEqual(TimelineNotices.make(settings: settings, health: health), [])
    health.missingPermissions = []
    settings = try XCTUnwrap(TimelineNotices.resolved(settings: settings, health: health))
    XCTAssertEqual(settings.general.count, 2)
    XCTAssertEqual(settings.general["unrelated"], "kept")
    health.missingPermissions = [.screenRecording]
    XCTAssertEqual(TimelineNotices.make(settings: settings, health: health).map(\.kind), [.screenRecording])
    settings = try XCTUnwrap(TimelineNotices.resolved(settings: settings, health: healthy))
    XCTAssertNil(TimelineNotices.resolved(settings: settings, health: healthy))
    health.security.fileVault = .off
    XCTAssertEqual(TimelineNotices.make(settings: settings, health: health).map(\.kind), [.screenRecording, .fileVaultOff])
  }
}

private final class InventedTimelineStorage: TimelineStorageReader {
  var settingsValue = StorageSettings(subscriptionConnected: true, general: ["dayStartHour": "0"])
  var samplesValue: [TimeSample] = []
  var intervalsValue: [NamedInterval] = []
  var forgotten: [TimeRange] = []
  var calls: [ModelCall] = []
  var callReads: [TimeRange] = []
  var intervalReads: [TimeRange] = []
  func settings() throws -> StorageSettings { settingsValue }
  func samples(in range: TimeRange) throws -> [TimeSample] { samplesValue.filter { $0.ts >= range.start && $0.ts < range.end } }
  func intervals(in range: TimeRange) throws -> [NamedInterval] {
    intervalReads.append(range)
    return intervalsValue.filter { $0.range.start < range.end && $0.range.end > range.start }
  }
  func forgottenRanges(in range: TimeRange) throws -> [TimeRange] { forgotten.filter { $0.start < range.end && $0.end > range.start } }
  func modelCalls(in range: TimeRange) throws -> [ModelCall] {
    callReads.append(range)
    return calls.filter { $0.ts >= range.start && $0.ts < range.end }
  }
  func modelCalls(overlapping range: TimeRange) throws -> [ModelCall] {
    callReads.append(range)
    return calls.filter { $0.range.start < range.end && $0.range.end > range.start }
  }
}


extension TimelineTests {
  func testSelectedDayBoundariesAcrossHalfHourAndHourDSTChanges() throws {
    let cases = [
      ("Australia/Lord_Howe", 10, 6, 2, 2, 30, 23 * 3600 + 1800),
      ("Australia/Lord_Howe", 4, 7, 1, 1, 0, 24 * 3600 + 1800),
      ("America/New_York", 3, 10, 2, 3, 0, 23 * 3600),
      ("America/New_York", 11, 3, 1, 1, 0, 25 * 3600)
    ]
    for (zone, month, day, boundaryHour, startHour, startMinute, duration) in cases {
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = try XCTUnwrap(TimeZone(identifier: zone))
      let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2024, month: month, day: day)))
      let range = try TimelineDay.range(on: date, dayStartHour: boundaryHour, calendar: calendar)
      let start = Date(timeIntervalSince1970: Double(range.start))
      XCTAssertTrue(calendar.isDate(start, inSameDayAs: date), zone)
      XCTAssertEqual(calendar.component(.hour, from: start), startHour, zone)
      XCTAssertEqual(calendar.component(.minute, from: start), startMinute, zone)
      XCTAssertEqual(range.end - range.start, duration, zone)
      for time in [range.start, range.end - 1] {
        XCTAssertEqual(try TimelineDay.range(containing: time, dayStartHour: boundaryHour, calendar: calendar), range, zone)
      }
      XCTAssertEqual(try TimelineDay.range(containing: range.start - 1, dayStartHour: boundaryHour, calendar: calendar).end, range.start, zone)
      XCTAssertEqual(try TimelineDay.range(containing: range.end, dayStartHour: boundaryHour, calendar: calendar).start, range.end, zone)
      for hour in [1, 12] {
        let selected = try XCTUnwrap(calendar.date(from: DateComponents(year: 2024, month: month, day: day, hour: hour)))
        XCTAssertEqual(try TimelineDay.range(on: selected, dayStartHour: boundaryHour, calendar: calendar), range, zone)
      }
      let storage = InventedTimelineStorage()
      storage.intervalsValue = [NamedInterval(range: TimeRange(range.start, range.start + 60), name: "Invented", kind: .work)]
      XCTAssertEqual(try TimelineDay.recordedDays(inMonth: date, dayStartHour: boundaryHour, calendar: calendar, storage: storage), [date], zone)
      storage.intervalsValue = [NamedInterval(range: TimeRange(range.end, range.end + 60), name: "Invented", kind: .work)]
      let nextDate = calendar.startOfDay(for: Date(timeIntervalSince1970: Double(range.end)))
      XCTAssertEqual(try TimelineDay.recordedDays(inMonth: date, dayStartHour: boundaryHour, calendar: calendar, storage: storage), [nextDate], zone)
    }
  }

  func testRecordedDayKeysStayNormalizedAfterMidnightDST() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Santiago"))
    func date(_ day: Int, hour: Int = 0) throws -> Date {
      try XCTUnwrap(calendar.date(from: DateComponents(year: 2024, month: 9, day: day, hour: hour)))
    }
    let storage = InventedTimelineStorage()
    storage.intervalsValue = try [8, 9, 30].map { day in
      NamedInterval(range: TimeRange(Int(try date(day, hour: 5).timeIntervalSince1970),
        Int(try date(day, hour: 6).timeIntervalSince1970)), name: "Invented", kind: .work)
    }
    let days = try TimelineDay.recordedDays(inMonth: date(1), dayStartHour: 4, calendar: calendar, storage: storage)
    XCTAssertEqual(days, Set(try [8, 9, 30].map { calendar.startOfDay(for: try date($0)) }))
    XCTAssertEqual(storage.intervalReads.count, 1)
    XCTAssertEqual(calendar.component(.hour, from: try date(9)), 0)
    XCTAssertTrue(try days.contains(date(9)))
    for day in days { XCTAssertEqual(day, calendar.startOfDay(for: day)) }
  }

  func testArbitraryPastDateAndOneMonthRead() throws {
    let storage = InventedTimelineStorage()
    let date = utc.date(from: DateComponents(year: 1998, month: 7, day: 18, hour: 1))!
    let range = try TimelineDay.range(on: date, dayStartHour: 5, calendar: utc)
    XCTAssertEqual(utc.component(.day, from: Date(timeIntervalSince1970: Double(range.start))), 18)
    XCTAssertEqual(utc.component(.hour, from: Date(timeIntervalSince1970: Double(range.start))), 5)
    storage.intervalsValue = [NamedInterval(range: range, name: "Invented", kind: .work)]
    let days = try TimelineDay.recordedDays(inMonth: date, dayStartHour: 5, calendar: utc, storage: storage)
    XCTAssertEqual(days, [utc.startOfDay(for: date)])
    XCTAssertEqual(storage.intervalReads.count, 1)
    XCTAssertEqual(utc.component(.day, from: Date(timeIntervalSince1970: Double(storage.intervalReads[0].start))), 1)
    XCTAssertEqual(utc.component(.month, from: Date(timeIntervalSince1970: Double(storage.intervalReads[0].end))), 8)
    XCTAssertEqual(utc.component(.hour, from: Date(timeIntervalSince1970: Double(storage.intervalReads[0].end))), 5)
  }
}
