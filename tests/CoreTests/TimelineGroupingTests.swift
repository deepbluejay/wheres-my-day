import Core
import Foundation
import XCTest

final class TimelineGroupingTests: XCTestCase {
  private typealias Part = (SummaryMinuteKind?, String?, Int)
  private func day(_ parts: [Part], forgotten: [TimeRange] = []) -> TimelineDay {
    var minutes: [Int: SummaryMinuteKind] = [:]
    var intervals: [NamedInterval] = []
    var start = 0
    for (state, name, count) in parts {
      let end = start + count * 60
      if let state {
        for minute in stride(from: start, to: end, by: 60) {
          minutes[minute] = forgotten.contains { $0.start <= minute && minute < $0.end } ? .rest : state
        }
        if let name, let kind = ActivityKind(rawValue: state.rawValue) {
          intervals.append(NamedInterval(range: TimeRange(start, end), name: name, kind: kind))
        }
      }
      start = end
    }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return TimelineDay.make(range: TimeRange(0, 86400), minutes: minutes, intervals: intervals,
      now: start, calendar: calendar)
  }

  func testDayWideGroupsUseExactNameKindAndStateInFirstStartOrder() {
    let value = day([(.work, "A", 5), (.personal, "A", 4), (.distraction, "D", 2),
      (.work, "A", 3), (.work, "a", 1), (.work, "A ", 1), (.distraction, "A", 2)])
    XCTAssertEqual(value.groups.map(\.name), ["A", "A", "D", "a", "A ", "A"])
    XCTAssertEqual(value.groups.map(\.state), [.work, .personal, .distraction, .work, .work, .distraction])
    XCTAssertEqual(value.groups.map(\.kind), [.work, .other, .distraction, .work, .work, .distraction])
    XCTAssertEqual(value.groups.map(\.minutes), [8, 4, 2, 1, 1, 2])
    XCTAssertEqual(value.groups[0].entryIndices, [0, 3])
    XCTAssertEqual(value.groups[0].range, TimeRange(0, 840))
    XCTAssertEqual(value.entries.map(\.minutes), [5, 4, 2, 3, 1, 1, 2])
  }

  func testUnnamedPrivateAndPendingGroupOnlyByStateAndKind() {
    let value = day([(.private, nil, 2), (.unnamed, nil, 3), (.unsummarized, nil, 1),
      (.personal, "", 2), (.private, nil, 4), (.blank, nil, 2), (.unnamed, nil, 1), (.personal, nil, 1)])
    XCTAssertEqual(value.groups.map(\.state), [.private, .unnamed, .unsummarized, .personal])
    XCTAssertEqual(value.groups.map(\.minutes), [6, 4, 3, 3])
    XCTAssertEqual(value.groups.map(\.entryIndices), [[0, 4], [1, 6], [2, 5], [3, 7]])
    XCTAssertTrue(value.groups.allSatisfy { $0.name == nil })
  }

  func testMissingRestForgottenAndPendingKeepPiecesSeparateWithinADayGroup() {
    for barrier: SummaryMinuteKind? in [.rest, nil, .unsummarized, .blank] {
      let value = day([(.work, "A", 5), (barrier, nil, 1), (.work, "A", 5)])
      XCTAssertEqual(value.groups.first?.minutes, 10)
      XCTAssertEqual(value.groups.first?.entryIndices.count, 2)
      XCTAssertEqual(value.entries.filter { $0.name == "A" }.map(\.range), [TimeRange(0, 300), TimeRange(360, 660)])
    }
    let deleted = day([(.work, "A", 5), (.work, "A", 5)], forgotten: [TimeRange(240, 360)])
    XCTAssertEqual(deleted.groups.first?.minutes, 8)
    XCTAssertEqual(deleted.groups.first?.entryIndices.count, 2)
  }

  func testGroupingConservesEveryMinuteAndGridSlot() {
    let middle: [Part] = [(.distraction, "D", 1), (.personal, "P", 1), (.private, nil, 1), (.unnamed, nil, 1)]
    let before = day([(.work, "A", 20)] + middle + [(.work, "B", 29)])
    let after = day([(.work, "A", 20)] + middle + [(.work, "A", 29)])
    XCTAssertEqual(before.groups.count, 6)
    XCTAssertEqual(after.groups.count, 5)
    XCTAssertEqual(after.columns, before.columns)
    XCTAssertEqual(after.totalMinutes, 53)
    XCTAssertEqual(after.minutesByKind, [.work: 49, .other: 3, .distraction: 1])
    XCTAssertEqual(after.groups.reduce(0) { $0 + $1.minutes }, after.totalMinutes)
    XCTAssertEqual(after.entries.reduce(0) { $0 + $1.minutes }, after.totalMinutes)
    XCTAssertEqual(after.groups.flatMap(\.entryIndices).sorted(), Array(after.entries.indices))
  }

  func testAdjacentSameNameCallBoundariesAreOneContiguousPiece() {
    let split = day([(.work, "A", 30), (.work, "A", 2), (.distraction, "D", 3),
      (.work, "A", 2), (.work, "A", 38)])
    let whole = day([(.work, "A", 32), (.distraction, "D", 3), (.work, "A", 40)])
    XCTAssertEqual(split.entries, whole.entries)
    XCTAssertEqual(split.groups, whole.groups)
    XCTAssertEqual(split.columns, whole.columns)
    XCTAssertEqual(split.entries.map(\.minutes), [32, 3, 40])
    XCTAssertEqual(split.groups.map(\.minutes), [72, 3])
  }
}
