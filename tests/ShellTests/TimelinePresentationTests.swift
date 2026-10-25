import Core
import Foundation
@testable import Shell
import XCTest

final class TimelinePresentationTests: XCTestCase {
  private var utc: Calendar {
    var value = Calendar(identifier: .gregorian)
    value.timeZone = TimeZone(secondsFromGMT: 0)!
    return value
  }
  private func groupedDay() -> TimelineDay {
    let minutes = Dictionary(uniqueKeysWithValues: (0..<50).map { ($0 * 60, $0 == 20 ? SummaryMinuteKind.distraction : .work) })
    return TimelineDay.make(range: TimeRange(0, 86400), minutes: minutes, intervals: [
      NamedInterval(range: TimeRange(0, 1200), name: "Invented task", kind: .work),
      NamedInterval(range: TimeRange(1200, 1260), name: "Invented diversion", kind: .distraction),
      NamedInterval(range: TimeRange(1260, 3000), name: "Invented task", kind: .work)
    ], now: 3000, calendar: utc)
  }
  // Ideal: black work, grey other, yellow distraction, hollow pending, invisible rest.
  func testEveryGridStyleHasItsMeaning() {
    XCTAssertEqual(TimelineSquareStyle.of(.work), .ink)
    XCTAssertEqual(TimelineSquareStyle.of(.other), .grey)
    XCTAssertEqual(TimelineSquareStyle.of(.distraction), .yellow)
    XCTAssertEqual(TimelineSquareStyle.of(.uninterpreted), .outline)
    XCTAssertEqual(TimelineSquareStyle.of(nil), .blank)
  }
  // A grouped line counts only its pieces and preserves the full first-last span.
  func testGroupAndPieceDetailsPreserveExactNumbers() throws {
    let model = TimelinePresentation(day: groupedDay(), language: "en", resources: nil, calendar: utc)
    let entry = try XCTUnwrap(model.day.entries.first)
    XCTAssertEqual(model.headline, "Recorded today: 50 min.")
    XCTAssertEqual(model.detail(entry), "Work · 00:00–00:20 · 20 min")
    XCTAssertEqual(model.detail(model.day.groups[0]), "Work · 49 min · Pieces: 2 · 00:00–00:50")
    XCTAssertEqual(model.name(entry), "Invented task")
  }
  // Ideal: the headline spells out hours and remaining minutes, without a zero-hour prefix.
  func testHeadlineUsesHoursAndMinutes() {
    for (count, duration) in [(0, "0 min"), (45, "45 min"), (60, "1 h"), (120, "2 h"), (455, "7 h 35 min")] {
      let minutes = Dictionary(uniqueKeysWithValues: (0..<count).map { ($0 * 60, SummaryMinuteKind.work) })
      let day = TimelineDay.make(range: TimeRange(0, 86400), minutes: minutes, intervals: [],
        now: count * 60, calendar: utc)
      let model = TimelinePresentation(day: day, language: "en", resources: nil, calendar: utc)
      XCTAssertEqual(model.headlineDuration, duration)
      XCTAssertEqual(model.headline, "Recorded today: \(duration).")
    }
  }
  // Compile the shipped catalog so missing substitutions or swapped duration parts fail here.
  func testLocalizedHeadlineDurations() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let resources = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: resources) }
    let compiler = Process()
    compiler.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    compiler.arguments = [root.appendingPathComponent("tools/strings.py").path, "compile", resources.path]
    try compiler.run()
    compiler.waitUntilExit()
    XCTAssertEqual(compiler.terminationStatus, 0)
    let units = [
      ("en", "h", "min", "7 h 35 min", "45 min"),
      ("ko", "시간", "분", "7시간 35분", "45분"),
      ("ja", "時間", "分", "7時間35分", "45分"),
      ("zh-Hans", "小时", "分钟", "7小时35分钟", "45 分钟"),
      ("zh-Hant", "小時", "分鐘", "7小時35分鐘", "45 分鐘"),
      ("de", "Std.", "Min.", "7 Std. 35 Min.", "45 Min."),
      ("fr", "h", "min", "7 h 35 min", "45 min"),
      ("es", "h", "min", "7 h 35 min", "45 min"),
      ("ru", "ч", "мин", "7 ч 35 мин", "45 мин")
    ]
    let pastHeadlines = [
      "en": "Recorded that day: %@.", "ko": "이날 기록된 활동: %@.",
      "ja": "その日に記録された活動：%@。", "zh-Hans": "当日记录的活动：%@。",
      "zh-Hant": "當日記錄的活動：%@。", "de": "An jenem Tag aufgezeichnet: %@",
      "fr": "Activité enregistrée ce jour-là : %@.", "es": "Actividad registrada ese día: %@.",
      "ru": "В тот день записано: %@."
    ]
    for (language, hour, minute, mixed, short) in units {
      for count in [0, 45, 60, 120, 455] {
        let minutes = Dictionary(uniqueKeysWithValues: (0..<count).map { ($0 * 60, SummaryMinuteKind.work) })
        let day = TimelineDay.make(range: TimeRange(0, 86400), minutes: minutes, intervals: [],
          now: count * 60, calendar: utc)
        let model = TimelinePresentation(day: day, language: language, resources: resources, calendar: utc)
        let duration = model.headlineDuration
        XCTAssertTrue(model.headline.contains(duration), language)
        let dated = TimelinePresentation(day: day, language: language, resources: resources, calendar: utc, isToday: false)
        XCTAssertTrue(dated.headline.contains(duration), language)
        XCTAssertFalse(dated.headline.contains("%@"), language)
        XCTAssertNotEqual(dated.headline, model.headline, language)
        XCTAssertEqual(dated.headline, String(format: try XCTUnwrap(pastHeadlines[language]), duration), language)
        XCTAssertEqual(dated.headline.filter(\.isNumber), duration.filter(\.isNumber), language)
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: language); formatter.calendar = utc
        formatter.timeZone = utc.timeZone; formatter.setLocalizedDateFormatFromTemplate("yMMMMd")
        let fullDate = formatter.string(from: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(dated.headlineAccessibility.contains(fullDate), language)
        XCTAssertTrue(dated.headlineAccessibility.contains(duration), language)
        XCTAssertFalse(dated.headlineAccessibility.contains("%@"), language)
        XCTAssertEqual(model.headlineAccessibility, model.headline, language)
        if count == 455 {
          XCTAssertEqual(duration, mixed, language)
          XCTAssertTrue(duration.contains(hour) && duration.contains(minute), language)
        } else if count < 60 {
          XCTAssertFalse(duration.contains(hour), language)
          XCTAssertTrue(duration.contains(minute), language)
          if count == 45 { XCTAssertEqual(duration, short, language) }
        } else {
          XCTAssertTrue(duration.contains(hour), language)
          XCTAssertFalse(duration.contains(minute), language)
          XCTAssertEqual(duration.filter(\.isNumber), String(count / 60), language)
          if language == "en" { XCTAssertEqual(duration, "\(count / 60) h") }
          if language == "ko" { XCTAssertEqual(duration, "\(count / 60)시간") }
        }
      }
    }
  }
  // Ideal: no problem means no placeholder row; every supplied problem gets a settings action.
  func testNoNoticesMeansNoNoticeRows() {
    let model = TimelinePresentation(day: groupedDay(), language: "en", resources: nil)
    XCTAssertTrue(model.notices.isEmpty)
    var day = groupedDay()
    day.notices = TimelineNotices.make(settings: StorageSettings(), health: TimelineHealth())
    let problems = TimelinePresentation(day: day, language: "en", resources: nil)
    XCTAssertEqual(problems.notices.count, day.notices.count)
    XCTAssertFalse(problems.notices.isEmpty)
    XCTAssertTrue(problems.notices.allSatisfy { !$0.line.isEmpty && $0.target == .settings })
  }
  // Ideal: private, unnamed and pending lines have fixed localized names.
  func testFixedNamesDoNotExposePrivateSourceNames() {
    let day = TimelineDay.make(range: TimeRange(0, 86400), minutes: [0: .private, 60: .unnamed, 120: .blank],
      intervals: [NamedInterval(range: TimeRange(0, 60), name: "Must be hidden", state: .private)], now: 180, calendar: utc)
    let model = TimelinePresentation(day: day, language: "en", resources: nil, calendar: utc)
    XCTAssertEqual(day.entries.map(model.name), ["Private", "Unnamed activity", "Not yet interpreted"])
    XCTAssertEqual(day.entries.map(model.detail), ["Other · 00:00–00:01 · 1 min", "Other · 00:01–00:02 · 1 min", "00:02–00:03 · 1 min"])
  }
  // Ideal: kinds with no recorded minutes take no space beneath the headline.
  func testKindTotalsOnlyIncludeRecordedKinds() {
    let model = TimelinePresentation(day: groupedDay(), language: "en", resources: nil)
    XCTAssertEqual(model.recordedKinds, [.work, .distraction])
    let empty = TimelineDay.make(range: TimeRange(0, 86400), minutes: [:], intervals: [], now: 0, calendar: utc)
    XCTAssertTrue(TimelinePresentation(day: empty, language: "en", resources: nil).recordedKinds.isEmpty)
  }
  // Fit each band to the available width, retaining half-point pitch steps.
  func testLargerGridFitsRequestedWindowWidths() {
    for scale in [1.0, 2.0] {
      for count in [138, 144, 150] {
        for window in [360.0, 480, 600, 800, 1088, 1120, 1280] {
          let width = window - (window < 600 ? 40 : 80)
          let layout = TimelineGridLayout(columnCount: count, width: width, displayScale: scale)
          let longest = Double(layout.rows.map(\.count).max()!)
          let fittedPitch = max(2, (width / longest * 2).rounded(.down) / 2)
          XCTAssertEqual(layout.squarePitch, max(3 + 1 / scale, fittedPitch))
          XCTAssertEqual(layout.rows.flatMap(Array.init), Array(0..<count))
          for row in layout.rows {
            XCTAssertLessThanOrEqual(layout.origin(at: row.count - 1) + layout.squareSide, width)
            for index in row.indices {
              let rect = layout.squareRect(.init(column: index, minute: 0))
              XCTAssertEqual(rect.minX * scale, (rect.minX * scale).rounded())
              XCTAssertEqual(rect.width * scale, (rect.width * scale).rounded())
            }
          }
        }
      }
    }
    let wide = TimelineGridLayout(columnCount: 144, width: 1200)
    XCTAssertEqual(wide.squarePitch, 8)
    XCTAssertEqual(wide.squareSide, 7.5)
    XCTAssertEqual(wide.columnHeight, 80)
    let narrow = TimelineGridLayout(columnCount: 144, width: 440)
    XCTAssertEqual(narrow.squarePitch, 6)
    XCTAssertEqual(narrow.squareSide, 5.5)
  }
  func testExactBandGeometryAtWideAndNarrowWidths() {
    for scale in [1.0, 2.0] {
      for (width, pitch, bands) in [(320.0, 4.0, 2), (440, 6, 2), (1040, 7, 1), (1200, 8, 1)] {
        let layout = TimelineGridLayout(columnCount: 144, width: width, displayScale: scale)
        XCTAssertEqual(layout.rows.count, bands)
        XCTAssertEqual(layout.squarePitch, pitch)
        XCTAssertEqual(layout.squareSide, pitch - (scale == 1 ? 1 : 0.5))
        XCTAssertEqual(layout.columnHeight, pitch * 10)
        XCTAssertEqual(layout.nowMarkerY, pitch * 10 + 3)
      }
    }
  }
  func testScaleStripFitsDigitsAndLabelsWithoutOverlaps() {
    for scale in [1.0, 2.0] {
      for width in [320.0, 440, 1040, 1200] {
        let layout = TimelineGridLayout(columnCount: 144, width: width, displayScale: scale)
        XCTAssertEqual(layout.scaleDigitWidth, scale == 2 ? 16.5 : 22)
        XCTAssertEqual(layout.scaleStripHeight, scale == 2 ? 14.5 : 18)
        XCTAssertLessThanOrEqual(layout.scaleStripHeight, 18)
        for band in layout.rows {
          // The shipped scale marks every second hour, twelve ten-minute columns apart.
          let positions = band.filter { $0 % 12 == 0 }.map {
            layout.scaleLabelX(at: $0 - band.lowerBound, width: width)
          }
          for (left, right) in zip(positions, positions.dropFirst()) {
            XCTAssertLessThan(left + layout.scaleDigitWidth, right)
          }
          XCTAssertLessThanOrEqual((positions.last ?? 0) + layout.scaleDigitWidth, width)
        }
        XCTAssertEqual(layout.scaleLabelX(at: 1000, width: width), width - layout.scaleDigitWidth)
      }
    }
  }
  func testListSelectionBorderMatchesMainAcrossWidthsAndScales() {
    for scale in [1.0, 2.0] {
      for count in [138, 144, 150] {
        for width in stride(from: 320.0, through: 2048, by: 0.5) {
          let pitchOnMain = max(2, (width / Double(count) * 2).rounded(.down) / 2) * 0.75
          let originalPitch = max(3 + 1 / scale, pitchOnMain / 1.5)
          let side = min(((originalPitch - 0.5) * scale).rounded(.down),
            (originalPitch * scale).rounded(.down) - 1) / scale
          let expected = max(1 / scale, side < 3.5 ? 0.5 : 1) + 1 / scale
          XCTAssertEqual(TimelineGridLayout(columnCount: count, width: width, displayScale: scale).listHighlightStroke, expected)
        }
      }
    }
  }
  func testListSelectionBorderKeepsItsPreviousStroke() {
    for (window, scale, stroke) in [(480.0, 1.0, 2.0), (480, 2, 1), (1088, 2, 1), (1280, 2, 1.5)] {
      let width = window - (window < 600 ? 40 : 80)
      XCTAssertEqual(TimelineGridLayout(columnCount: 144, width: width, displayScale: scale).listHighlightStroke, stroke)
    }
  }
  // Wrap only when the minimum-pitch row no longer fits, including clock-change days.
  func testWrapBoundaryUsesMinimumPitchFit() {
    for (scale, boundaries) in [(1.0, [552.0, 576, 600]), (2.0, [483.0, 504, 525])] {
      for (count, boundary) in zip([138, 144, 150], boundaries) {
        XCTAssertEqual(TimelineGridLayout(columnCount: count, width: boundary - 0.5, displayScale: scale).rows.count, 2)
        let single = TimelineGridLayout(columnCount: count, width: boundary, displayScale: scale)
        XCTAssertEqual(single.rows.count, 1)
        XCTAssertEqual(single.squareSide, 3)
        XCTAssertEqual(single.columnHeight, scale == 1 ? 40 : 35)
        XCTAssertEqual(TimelineGridLayout(columnCount: count, width: boundary + 0.5, displayScale: scale).rows.count, 1)
      }
    }
  }
  // Squares shrink within a fixed band count; wrapping regains the available width per band.
  func testSquaresNeverGrowWhenWidthNarrowsWithinTheSameBandCount() {
    for scale in [1.0, 2.0] {
      for count in [138, 144, 150] {
        var previous = Double.infinity, previousBands = 1
        for width in stride(from: 2048.0, through: 1.0, by: -0.5) {
          let layout = TimelineGridLayout(columnCount: count, width: width, displayScale: scale)
          if layout.rows.count == previousBands { XCTAssertLessThanOrEqual(layout.squareSide, previous) }
          previous = layout.squareSide; previousBands = layout.rows.count
        }
      }
    }
  }
  // Device-pixel geometry preserves the hollow center on both standard and Retina displays.
  func testSquaresSnapToDisplayPixelsAndKeepAHole() {
    for scale in [1.0, 2.0] {
      for count in [138, 144, 150] {
        for width in stride(from: 1.0, through: 2048.0, by: 0.5) {
          let layout = TimelineGridLayout(columnCount: count, width: width, displayScale: scale)
          XCTAssertGreaterThanOrEqual(layout.squareSide, 3)
          XCTAssertEqual(layout.squareSide * scale, (layout.squareSide * scale).rounded())
          XCTAssertGreaterThanOrEqual(layout.outlineStroke * scale, 1)
          XCTAssertEqual(layout.outlineStroke * scale, (layout.outlineStroke * scale).rounded())
          XCTAssertGreaterThanOrEqual(layout.squareSide - 2 * layout.outlineStroke, 1)
          // The same origins place both the columns and the ten minutes within each column.
          let longest = layout.rows.map(\.count).max() ?? 0
          let minimumGap = (0..<max(longest, TimelineDay.rows)).map {
            layout.origin(at: $0 + 1) - layout.origin(at: $0) - layout.squareSide
          }.min()!
          XCTAssertGreaterThanOrEqual(minimumGap * scale, 1, "scale=\(scale), columns=\(count), width=\(width)")
        }
      }
      for width in [440.0, 504, 792, 1008, 1080, 1151, 1200, 1224, 1295] {
        let layout = TimelineGridLayout(columnCount: 144, width: width, displayScale: scale)
        for index in 0..<144 {
          let origin = layout.origin(at: index)
          XCTAssertEqual(origin * scale, (origin * scale).rounded())
          XCTAssertLessThanOrEqual(origin, Double(index) * layout.squarePitch)
          XCTAssertLessThan(Double(index) * layout.squarePitch - origin, 1 / scale)
          XCTAssertGreaterThanOrEqual(layout.origin(at: index + 1) - origin - layout.squareSide, 1 / scale)
        }
      }
      let minimum = TimelineGridLayout(columnCount: 144, width: 320, displayScale: scale)
      XCTAssertEqual(minimum.squareSide, scale == 1 ? 3 : 3.5)
      XCTAssertEqual(minimum.outlineStroke * scale, scale == 1 ? 1 : 2)
      XCTAssertEqual((minimum.squareSide - 2 * minimum.outlineStroke) * scale, scale == 1 ? 1 : 3)
    }
  }
  // Ideal: at 480 points all 144 columns remain in chronological order in two readable rows.
  func testNarrowLayoutFitsIncludingClockChangeDays() {
    for count in [138, 144, 150] {
      let narrow = TimelineGridLayout(columnCount: count, width: 440)
      XCTAssertEqual(narrow.rows.count, 2)
      XCTAssertEqual(narrow.rows.flatMap(Array.init), Array(0..<count))
      for row in narrow.rows.indices {
        XCTAssertLessThanOrEqual(narrow.squarePitch * Double(narrow.rows[row].count), 440)
        XCTAssertGreaterThanOrEqual(narrow.squareSide, 3)
      }
      let longest = Double(narrow.rows.map(\.count).max()!)
      XCTAssertEqual(narrow.squarePitch, max(3.5, max(2, (440 / longest * 2).rounded(.down) / 2)))
      XCTAssertEqual(TimelineGridLayout(columnCount: count, width: 1200).rows.count, 1)
    }
  }
  // Ideal: every visible fixed label and notice has all nine languages in the existing catalog.
  func testVisibleStringsExistInEveryLanguage() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("Resources/Localizable.xcstrings"))) as! [String: Any]
    let strings = json["strings"] as! [String: [String: Any]]
    for label in TimelineLabel.allCases {
      let entry = try XCTUnwrap(strings[label.key], label.key)
      XCTAssertNotEqual(entry["extractionState"] as? String, "stale", label.key)
      let translations = try XCTUnwrap(entry["localizations"] as? [String: Any], label.key)
      for language in ["ko", "ja", "zh-Hans", "zh-Hant", "de", "fr", "es", "ru"] {
        XCTAssertNotNil(translations[language], "\(language): \(label.key)")
      }
    }
  }
}
