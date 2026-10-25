import AppKit
import Core
@testable import Shell
import SwiftUI
import XCTest

final class TimelineDayNavigationTests: XCTestCase {
  private var calendar: Calendar {
    var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0)!; return value
  }
  func testCalendarRefreshReusesCellsAndLabelsUntilMonthCalendarOrLocaleChanges() throws {
    let cache = TimelineCalendarMonthCache()
    let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2024, month: 9, day: 9)))
    let locale = Locale(identifier: "en")
    let first = cache.month(containing: date, calendar: calendar, locale: locale)
    for offset in 0..<60 {
      let refreshed = cache.month(containing: date.addingTimeInterval(Double(offset)), calendar: calendar, locale: locale)
      XCTAssertEqual(refreshed.cells, first.cells)
    }
    XCTAssertEqual(cache.rebuildCount, 1, "one-second snapshot refreshes must not rebuild calendar labels")
    _ = cache.month(containing: calendar.date(byAdding: .month, value: 1, to: date)!, calendar: calendar, locale: locale)
    XCTAssertEqual(cache.rebuildCount, 2)
    let english = cache.month(containing: date, calendar: calendar, locale: locale)
    let korean = cache.month(containing: date, calendar: calendar, locale: Locale(identifier: "ko"))
    XCTAssertEqual(cache.rebuildCount, 4)
    XCTAssertNotEqual(english.cells.compactMap { $0?.label }, korean.cells.compactMap { $0?.label })
    var changed = calendar; changed.firstWeekday = 2
    _ = cache.month(containing: date, calendar: changed, locale: Locale(identifier: "ko"))
    XCTAssertEqual(cache.rebuildCount, 5)
    changed.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Santiago"))
    let result = cache.month(containing: date, calendar: changed, locale: Locale(identifier: "ko"))
    XCTAssertEqual(cache.rebuildCount, 6)
    let ninth = try XCTUnwrap(result.cells.compactMap { $0 }.first { changed.component(.day, from: $0.date) == 9 })
    XCTAssertEqual(ninth.date, changed.startOfDay(for: ninth.date))
    XCTAssertEqual(changed.component(.hour, from: ninth.date), 0)
    XCTAssertEqual(result.cells.compactMap { $0 }.count, 30)
    XCTAssertFalse(ninth.label.isEmpty)
  }

  func testShiftedTodayAndFutureSelection() throws {
    let day = try TimelineDay.range(containing: 2 * 86400 + 3 * 3600, dayStartHour: 4, calendar: calendar)
    let state = TimelineDayNavigation(day: day, now: 2 * 86400 + 3 * 3600, dayStartHour: 4, calendar: calendar)
    XCTAssertTrue(state.isToday); XCTAssertFalse(state.canGoNext); XCTAssertNil(state.step(1))
    XCTAssertEqual(state.shown, Date(timeIntervalSince1970: 86400))
    XCTAssertFalse(state.canSelect(Date(timeIntervalSince1970: 2 * 86400)))
    let previous = try XCTUnwrap(state.step(-1))
    let past = try TimelineDay.range(on: previous, dayStartHour: 4, calendar: calendar)
    let earlier = TimelineDayNavigation(day: past, now: 2 * 86400 + 3 * 3600, dayStartHour: 4, calendar: calendar)
    XCTAssertFalse(earlier.isToday); XCTAssertTrue(earlier.canGoNext)
    XCTAssertEqual(earlier.step(1), state.shown)
  }
  func testArrowsLeaveTextFieldsAndModifiedKeysAlone() {
    for code: UInt16 in [123, 124] {
      XCTAssertNil(TimelineDayNavigation.keyStep(code: code, typing: true, dayVisible: true, modified: false))
      XCTAssertNil(TimelineDayNavigation.keyStep(code: code, typing: false, dayVisible: false, modified: false))
      XCTAssertNil(TimelineDayNavigation.keyStep(code: code, typing: false, dayVisible: true, modified: true))
    }
    XCTAssertEqual(TimelineDayNavigation.keyStep(code: 123, typing: false, dayVisible: true, modified: false), -1)
    XCTAssertEqual(TimelineDayNavigation.keyStep(code: 124, typing: false, dayVisible: true, modified: false), 1)
    XCTAssertNil(TimelineDayNavigation.keyStep(code: 125, typing: false, dayVisible: true, modified: false))
  }
  func testChangingDayResetsExpansionSelectionAndSquareHover() {
    let first = TimelineDay.make(range: TimeRange(0, 86400), minutes: [0: .work], intervals: [], now: 86400, calendar: calendar)
    let second = TimelineDay.make(range: TimeRange(86400, 172800), minutes: [86400: .work], intervals: [], now: 172800, calendar: calendar)
    let model = TimelinePresentation(day: first, language: "en", resources: nil)
    var list = TimelineListState(expanded: [0]); list.click(.init(column: 0, minute: 0), model: model)
    var hover = TimelineHoverState(); hover.grid(0, cell: .init(column: 0, minute: 0))
    list.reconcile(from: first, to: second); hover.reconcile(from: first, to: second)
    XCTAssertTrue(list.expanded.isEmpty); XCTAssertNil(list.selectedPiece); XCTAssertNil(hover.target)
  }
  func testPastDayHasDateOnlyInAccessibilityAndNoLiveMark() {
    let day = TimelineDay.make(range: TimeRange(0, 86400), minutes: [0: .work], intervals: [], now: 172800, calendar: calendar)
    let model = TimelinePresentation(day: day, language: "en", resources: nil, calendar: calendar, isToday: false)
    XCTAssertNil(day.nowColumn); XCTAssertFalse(model.headline.contains("today"))
    XCTAssertEqual(model.headline, "Recorded that day: 1 min.")
    XCTAssertTrue(model.headlineAccessibility.contains("January 1, 1970"))
  }
  @MainActor func testPixelArrowsAndCalendarDigitsUseWholeDevicePixels() throws {
    for scale in [1.0, 2.0] {
      for rect in TimelinePixelArrow.rectangles(right: false, scale: scale) + TimelinePixelArrow.rectangles(right: true, scale: scale)
        + TimelineDigits.rectangles("0123456789", height: 14, scale: scale)
        + TimelineDigits.rectangles("2026", height: 14, scale: scale) {
        for value in [rect.minX, rect.minY, rect.width, rect.height] { XCTAssertEqual(value * scale, (value * scale).rounded()) }
      }
      let navigation = TimelineDayNavigation(day: TimeRange(0, 86400), now: 86400, dayStartHour: 0, calendar: calendar)
      let renderer = ImageRenderer(content: TimelineDayControls(navigation: navigation,
        strings: TimelineStrings(language: "en", resources: nil), calendarOpen: true, records: [Date(timeIntervalSince1970: 0)])
        .padding(8).frame(width: 360).background(.white).environment(\.displayScale, scale))
      renderer.scale = scale
      let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
      var arrowInk = 0
      for x in Int(8 * scale)..<Int(36 * scale) {
        for y in Int(8 * scale)..<Int(40 * scale) {
          let pixel = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
          let red = Int((pixel.redComponent * 255).rounded())
          XCTAssertTrue(red == 0 || red == 255, "arrow edges must not be antialiased")
          if red == 0 { arrowInk += 1 }
        }
      }
      XCTAssertGreaterThan(arrowInk, 0)
      let todayCorner = try XCTUnwrap(bitmap.colorAt(x: Int(352 * scale) - 1, y: Int(8 * scale))?.usingColorSpace(.deviceRGB))
      XCTAssertLessThan(todayCorner.redComponent, 0.1, "Today has a visible square outline without hovering")
      // The panel has a square outer border, including solid corner pixels.
      let y = bitmap.pixelsHigh - Int(8 * scale) - 1
      let x = Int(8 * scale)
      let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
      XCTAssertLessThan(color.redComponent, 0.1)
    }
  }
  @MainActor func testCalendarDayGlyphsAreFourteenPointsAndDimmedDaysRemainLegible() throws {
    for dark in [false, true] {
      for scale in [1.0, 2.0] {
        let navigation = TimelineDayNavigation(day: TimeRange(0, 86400), now: 31 * 86400,
          dayStartHour: 0, calendar: calendar)
        let renderer = ImageRenderer(content: TimelineDayControls(navigation: navigation,
          strings: TimelineStrings(language: "en", resources: nil), calendarOpen: true, records: [])
          .padding(8).frame(width: 360).background(dark ? Color.black : Color.white)
          .environment(\.colorScheme, dark ? .dark : .light).environment(\.displayScale, scale))
        renderer.scale = scale
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
        XCTAssertEqual(bitmap.pixelsWide, Int(360 * scale))
        // January 28 is an empty, unselected day in the final row's fourth cell.
        let bottom = bitmap.pixelsHigh - Int(16 * scale)
        var rows = Set<Int>()
        for y in (bottom - Int(32 * scale))..<bottom {
          for x in Int(136 * scale)..<Int(176 * scale) {
            let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
            let contrast = dark ? color.redComponent : 1 - color.redComponent
            if contrast > 0.1 {
              XCTAssertGreaterThan(contrast, 0.4, "dimmed glyphs retain visible contrast after color conversion")
              XCTAssertLessThan(contrast, 0.8, "empty days remain dimmer than recorded days")
              rows.insert(y)
            }
          }
        }
        XCTAssertEqual(rows.count, Int(14 * scale), "calendar glyph height at \(scale)x, dark: \(dark)")
      }
    }
  }
}
