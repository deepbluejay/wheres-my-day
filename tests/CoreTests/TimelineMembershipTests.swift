import Core
import Foundation
import XCTest

final class TimelineMembershipTests: XCTestCase {
  // Every drawn minute belongs to exactly the contiguous piece that counts it.
  func testEveryMinuteHasTheFinalCountedLineAcrossInventedDays() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    for start in [0, 4 * 3600] {
      for shift in 0..<10 {
        var source: [Int: SummaryMinuteKind] = [:]
        var intervals: [NamedInterval] = []
        func add(_ offset: Int, _ count: Int, _ state: SummaryMinuteKind, _ name: String? = nil) {
          let range = TimeRange(start + (offset + shift) * 60, start + (offset + shift + count) * 60)
          for minute in stride(from: range.start, to: range.end, by: 60) { source[minute] = state }
          if let name, let kind = ActivityKind(rawValue: state.rawValue) {
            intervals.append(NamedInterval(range: range, name: name, kind: kind))
          }
        }
        add(-5, 35, .work, "Invented task")
        add(30, 2, .distraction, "Invented interruption")
        add(32, 40, .work, "Invented task")
        add(72, 3, .rest)
        add(78, 8, .private)
        add(86, 2, .unsummarized)
        add(88, 8, .blank)
        add(100, 3, .work, "Invented separate task")
        // Missing (including forgotten) minutes and a future source minute stay unowned.
        source.removeValue(forKey: start + (shift + 80) * 60)
        add(110, 1, .work)
        let now = start + (shift + 105) * 60
        let day = TimelineDay.make(range: TimeRange(start, start + 86400), minutes: source,
          intervals: intervals, now: now, calendar: calendar)
        XCTAssertTrue(day.groups.contains { $0.entryIndices.count > 1 })
        XCTAssertTrue(day.entries.contains { $0.state == .private })
        XCTAssertTrue(day.entries.contains { $0.state == .unsummarized })
        var counted = Array(repeating: 0, count: day.entries.count)
        for (column, value) in day.columns.enumerated() {
          for (minute, slot) in value.slots.enumerated() {
            let time = start + column * 600 + minute * 60
            let expected = day.entries.indices.filter {
              day.entries[$0].range.start <= time && time < day.entries[$0].range.end
            }
            let active = time < now && source[time].flatMap(TimelineGridKind.of) != nil
            XCTAssertEqual(expected.count, active ? 1 : 0)
            XCTAssertEqual(slot.entryIndex, expected.first, "minute \(time)")
            XCTAssertEqual(slot.kind, active ? source[time].flatMap(TimelineGridKind.of) : nil)
            if let index = slot.entryIndex { counted[index] += 1 }
          }
        }
        XCTAssertEqual(counted, day.entries.map { $0.minutes })
      }
    }
  }
}
