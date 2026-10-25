import AppKit
import Core
@testable import Shell
import XCTest
import SwiftUI

final class TimelineSplitRenderTests: XCTestCase {
  @MainActor func testOneHeavyInventedDayHoverUpdate() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let minutes = Dictionary(uniqueKeysWithValues: (0..<1440).map { ($0 * 60, SummaryMinuteKind.work) })
    let intervals = (0..<1440).map {
      NamedInterval(range: TimeRange($0 * 60, ($0 + 1) * 60), name: "Invented \($0 % 300)", kind: .work)
    }
    let day = TimelineDay.make(range: TimeRange(0, 86400), minutes: minutes, intervals: intervals,
      now: 86400, calendar: calendar)
    let model = TimelinePresentation(day: day, language: "en", resources: nil, calendar: calendar)
    XCTAssertEqual(day.entries.count, 1440)
    XCTAssertEqual(day.groups.count, 300)
    let interaction = TimelineInteractionState()
    let host = NSHostingView(rootView: TimelineView(model: model, width: 1280, interaction: interaction)
      .environment(\.displayScale, 2).frame(width: 1280, height: 720))
    host.frame = NSRect(x: 0, y: 0, width: 1280, height: 720)
    host.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    host.layoutSubtreeIfNeeded()
    let start = ProcessInfo.processInfo.systemUptime
    interaction.hover.grid(0, cell: .init(column: 29, minute: 9))
    host.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    host.layoutSubtreeIfNeeded()
    let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
    XCTAssertEqual(interaction.list.scrollTarget(for: interaction.hover.target, model: model), .group(299))
    XCTAssertEqual(model.highlight(for: interaction.hover.target)?.cells.count, 1)
    print(String(format: "HEAVY_DAY_HOVER pieces=1440 names=300 one_native_hover_scroll_layout_ms=%.3f includes_20ms_runloop_drain", elapsed))
  }
  @MainActor func testNativeScrollCaptureKeepsHeaderAndListVisible() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let day = TimelineDay.make(range: TimeRange(0, 86400), minutes: [0: .work, 120: .distraction, 240: .work],
      intervals: [NamedInterval(range: TimeRange(0, 60), name: "Invented task", kind: .work),
        NamedInterval(range: TimeRange(240, 300), name: "Invented task", kind: .work)], now: 300, calendar: calendar)
    let model = TimelinePresentation(day: day, language: "en", resources: nil, calendar: calendar)
    for width in [480.0, 1280.0] {
      let data = try XCTUnwrap(TimelineOffscreenRender.png(model: model, width: width, dark: false,
        scale: 1, hovered: .group(0), expanded: [0], height: 720))
      let image = try XCTUnwrap(NSBitmapImageRep(data: data))
      var yellow = 0, headerInk = 0, listInk = 0
      for y in 0..<image.pixelsHigh {
        for x in 0..<image.pixelsWide {
          let color = try XCTUnwrap(image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
          if color.redComponent > 0.9 && color.greenComponent > 0.6 && color.blueComponent < 0.1 { yellow += 1 }
          if color.redComponent < 0.1 {
            if y < 150 { headerInk += 1 }
            if y > 360 { listInk += 1 }
          }
        }
      }
      XCTAssertGreaterThan(yellow, 0, "fixed header grid must remain visible")
      XCTAssertGreaterThan(headerInk, 0, "headline must remain visible")
      XCTAssertGreaterThan(listInk, 0, "list has its own visible region")
    }
  }
}
