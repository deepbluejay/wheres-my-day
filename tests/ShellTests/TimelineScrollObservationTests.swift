import AppKit
import Core
@testable import Shell
import SwiftUI
import XCTest

final class TimelineScrollObservationTests: XCTestCase {
  @MainActor func testStationaryGridHoverRequestsNewTargetAfterModelRefresh() throws {
    let model = inventedModel()
    let refreshed = inventedModel(reassignMinute: 1300)
    let interaction = TimelineInteractionState()
    var requests: [TimelineListTarget] = []
    func view(_ model: TimelinePresentation) -> some View {
      TimelineView(model: model, width: 1088, interaction: interaction,
        onBringIntoView: { requests.append($0) })
        .environment(\.displayScale, 2).frame(width: 1088, height: 720)
    }
    let host = NSHostingView(rootView: view(model))
    host.frame = NSRect(x: 0, y: 0, width: 1088, height: 720)
    settle(host)
    XCTAssertTrue(requests.isEmpty)

    let cell = TimelineGridCell(column: 130, minute: 0)
    interaction.hover.grid(0, cell: cell)
    settle(host)
    XCTAssertEqual(requests, [.group(100)])
    requests.removeAll()

    host.rootView = view(refreshed)
    settle(host)
    XCTAssertEqual(interaction.hover.target, .square(cell))
    XCTAssertEqual(interaction.list.scrollTarget(for: interaction.hover.target, model: refreshed), .group(1))
    XCTAssertEqual(requests, [.group(1)], "the native view must request the refreshed row exactly once")

    requests.removeAll()
    host.rootView = view(refreshed)
    settle(host)
    XCTAssertTrue(requests.isEmpty, "an unchanged target must not request visibility again")
  }

  @MainActor func testNativeHoverObserversIgnoreGapsAndRowExitsAndKeepExplicitClicks() throws {
    let model = inventedModel()
    let interaction = TimelineInteractionState()
    var requests: [TimelineListTarget] = []
    let host = NSHostingView(rootView:
      TimelineView(model: model, width: 1088, interaction: interaction,
        onBringIntoView: { requests.append($0) })
        .environment(\.displayScale, 2).frame(width: 1088, height: 720))
    host.frame = NSRect(x: 0, y: 0, width: 1088, height: 720)
    settle(host)
    func phase(_ expected: [TimelineListTarget], _ action: () -> Void,
      file: StaticString = #filePath, line: UInt = #line) {
      requests.removeAll()
      action()
      settle(host)
      XCTAssertEqual(requests, expected, file: file, line: line)
    }

    let a = TimelineGridCell(column: 0, minute: 0)
    let b = TimelineGridCell(column: 100, minute: 0)
    let nextB = TimelineGridCell(column: 100, minute: 1)
    let layout = TimelineGridLayout(columnCount: 144, width: 1008, displayScale: 2)
    let rect = layout.squareRect(b), nextRect = layout.squareRect(nextB)
    let gap = CGPoint(x: rect.midX, y: (rect.minY + nextRect.maxY) / 2)
    XCTAssertNil(layout.cell(at: gap, band: 0))

    phase([.piece(0)]) { interaction.click(a, model: model) }
    phase([.group(100)]) { interaction.hover.grid(0, cell: b) }
    phase([]) { interaction.hover.grid(0, cell: layout.cell(at: gap, band: 0)) }
    XCTAssertEqual(interaction.list.target(for: interaction.hover.target, model: model), .piece(0))
    phase([.group(100)]) { interaction.hover.grid(0, cell: nextB) }
    phase([]) { interaction.hover.endGrid(0) }
    phase([]) { interaction.hover.row(.group(100), inside: true) }
    phase([]) { interaction.hover.row(.group(100), inside: false) }
    phase([]) { interaction.hover.row(1000, inside: true) }
    phase([]) { interaction.hover.row(1000, inside: false) }
    phase([.piece(0)]) { interaction.click(a, model: model) }
    phase([.piece(0)]) { interaction.click(a, model: model) }
    // Expanding a currently hovered group must use only the explicit-click path.
    phase([.group(100)]) { interaction.hover.grid(0, cell: b) }
    phase([.piece(1000)]) { interaction.click(b, model: model) }
    XCTAssertEqual(interaction.list.selectedPiece, 1000)
  }

  private func inventedModel(reassignMinute: Int? = nil) -> TimelinePresentation {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let minutes = Dictionary(uniqueKeysWithValues: (0..<1440).map { ($0 * 60, SummaryMinuteKind.work) })
    let intervals = (0..<1440).map { minute in
      let name = minute == reassignMinute ? 1 : (minute == 1001 ? 100 : minute % 300)
      return NamedInterval(range: TimeRange(minute * 60, (minute + 1) * 60),
        name: "Invented \(name)", kind: .work)
    }
    let day = TimelineDay.make(range: TimeRange(0, 86400), minutes: minutes, intervals: intervals,
      now: 86400, calendar: calendar)
    return TimelinePresentation(day: day, language: "en", resources: nil, calendar: calendar)
  }

  @MainActor private func settle(_ host: NSView) {
    host.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    host.layoutSubtreeIfNeeded()
  }
}
