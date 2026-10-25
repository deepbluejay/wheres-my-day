import Core
import Foundation
import Shell
import XCTest

final class TimelineHighlightTests: XCTestCase {
  private func model(_ minutes: [Int: SummaryMinuteKind], intervals: [NamedInterval] = []) -> TimelinePresentation {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let day = TimelineDay.make(range: TimeRange(0, 86400), minutes: minutes, intervals: intervals,
      now: 50000, calendar: calendar)
    return TimelinePresentation(day: day, language: "en", resources: nil, calendar: calendar)
  }
  func testBoundaryEdgesAreExactlyTheExposedNeighbours() {
    // A staircase, with all four sides of a single minute checked by the same function.
    let cells: Set<TimelineGridCell> = [
      .init(column: 0, minute: 0), .init(column: 0, minute: 1),
      .init(column: 1, minute: 1), .init(column: 1, minute: 2), .init(column: 2, minute: 2)
    ]
    let layout = TimelineGridLayout(columnCount: 144, width: 1008)
    func edge(_ column: Int, _ minute: Int, _ side: TimelineGridEdge.Side) -> TimelineGridEdge {
      .init(cell: .init(column: column, minute: minute), side: side)
    }
    let expected: Set<TimelineGridEdge> = [
      edge(0, 0, .left), edge(0, 0, .right), edge(0, 0, .bottom),
      edge(0, 1, .left), edge(0, 1, .top),
      edge(1, 1, .right), edge(1, 1, .bottom),
      edge(1, 2, .left), edge(1, 2, .top),
      edge(2, 2, .right), edge(2, 2, .top), edge(2, 2, .bottom)
    ]
    XCTAssertEqual(layout.boundary(of: cells), expected)
    let single = TimelineGridCell(column: 4, minute: 5)
    XCTAssertEqual(layout.boundary(of: [single]), Set(TimelineGridEdge.Side.allCases.map {
      TimelineGridEdge(cell: single, side: $0)
    }))
  }
  func testSquareAndPieceUseSameMembershipAndGroupIncludesAllItsPieces() throws {
    let minutes = Dictionary(uniqueKeysWithValues: (0..<31).map { ($0 * 60, $0 == 15 ? SummaryMinuteKind.distraction : .work) })
    let value = model(minutes, intervals: [
      NamedInterval(range: TimeRange(0, 900), name: "Invented task", kind: .work),
      NamedInterval(range: TimeRange(900, 960), name: "Invented interruption", kind: .distraction),
      NamedInterval(range: TimeRange(960, 1860), name: "Invented task", kind: .work)
    ])
    let group = try XCTUnwrap(value.highlight(for: .group(0)))
    XCTAssertEqual(group.cells.count, 30)
    XCTAssertFalse(group.cells.contains(.init(column: 1, minute: 5)))
    for minute in 0..<31 {
      let piece = minute < 15 ? 0 : minute == 15 ? 1 : 2
      XCTAssertEqual(value.highlight(for: .square(.init(column: minute / 10, minute: minute % 10))), value.highlight(for: .entry(piece)))
    }
    var state = TimelineListState()
    let cell = TimelineGridCell(column: 2, minute: 0)
    XCTAssertEqual(state.target(for: .square(cell), model: value), .group(0))
    XCTAssertTrue(state.expanded.isEmpty)
    state.toggle(0, day: value.day)
    XCTAssertEqual(state.target(for: .square(cell), model: value), .piece(2))
    XCTAssertEqual(state.target(for: .group(0), model: value), .group(0))
    state.toggle(0, day: value.day)
    XCTAssertTrue(state.expanded.isEmpty)
    state.click(cell, model: value)
    XCTAssertEqual(state.expanded, [0])
    XCTAssertEqual(state.selectedPiece, 2)
    XCTAssertEqual(state.target(for: nil, model: value), .piece(2))
    state.click(.init(column: 1, minute: 5), model: value)
    XCTAssertEqual(state.expanded, [0, 1])
    state.toggle(1, day: value.day)
    XCTAssertNil(state.selectedPiece)
    XCTAssertEqual(state.expanded, [0])
  }
  func testSummaryRefreshKeepsExpansionSelectionAndHoverWithTheSameActivity() {
    let first = model([600: .work], intervals: [NamedInterval(range: TimeRange(600, 660), name: "Invented task", kind: .work)])
    let refreshed = model([0: .distraction, 600: .work], intervals: [
      NamedInterval(range: TimeRange(0, 60), name: "Invented earlier task", kind: .distraction),
      NamedInterval(range: TimeRange(600, 660), name: "Invented task", kind: .work)])
    var state = TimelineListState()
    state.click(.init(column: 1, minute: 0), model: first)
    var hover = TimelineHoverState(); hover.row(.group(0), inside: true)
    state.reconcile(from: first.day, to: refreshed.day)
    hover.reconcile(from: first.day, to: refreshed.day)
    XCTAssertEqual(state.expanded, [1])
    XCTAssertEqual(state.selectedPiece, 1)
    XCTAssertEqual(hover.target, .group(1))
    hover.row(.group(0), inside: false)
    XCTAssertEqual(hover.target, .group(1))
    let removed = model([0: .distraction])
    state.reconcile(from: refreshed.day, to: removed.day)
    hover.reconcile(from: refreshed.day, to: removed.day)
    XCTAssertTrue(state.expanded.isEmpty)
    XCTAssertNil(state.selectedPiece)
    XCTAssertNil(hover.target)
  }
  func testScrollOnlyMovesToTheNearestClippedEdge() {
    let viewport = CGRect(x: 0, y: 0, width: 400, height: 300)
    func target(_ y: Double, _ height: Double = 50) -> CGRect { CGRect(x: 0, y: y, width: 400, height: height) }
    XCTAssertNil(TimelineListScroll.edge(target: target(0), viewport: viewport))
    XCTAssertNil(TimelineListScroll.edge(target: target(250), viewport: viewport))
    XCTAssertEqual(TimelineListScroll.edge(target: target(-1), viewport: viewport), .top)
    XCTAssertEqual(TimelineListScroll.edge(target: target(251), viewport: viewport), .bottom)
    XCTAssertEqual(TimelineListScroll.edge(target: target(700), viewport: viewport), .bottom)
    XCTAssertNil(TimelineListScroll.edge(target: target(-10, 500), viewport: viewport))
  }
  func testClickedOutlineDoesNotScrollBackAcrossGridGapsOrRowExits() throws {
    let value = model([0: .work, 48000: .work, 48060: .work], intervals: [
      NamedInterval(range: TimeRange(0, 60), name: "Invented A", kind: .work),
      NamedInterval(range: TimeRange(48000, 48120), name: "Invented B", kind: .work)])
    let layout = TimelineGridLayout(columnCount: 144, width: 1008, displayScale: 2)
    let a = TimelineGridCell(column: 0, minute: 0)
    let b = TimelineGridCell(column: 80, minute: 0)
    let nextB = TimelineGridCell(column: 80, minute: 1)
    let rect = layout.squareRect(b), nextRect = layout.squareRect(nextB)
    let gap = CGPoint(x: rect.midX, y: (rect.minY + nextRect.maxY) / 2)
    let band = try XCTUnwrap(layout.rows.firstIndex { $0.contains(b.column) })
    XCTAssertNil(layout.cell(at: gap, band: band))
    var state = TimelineListState()
    var hover = TimelineHoverState()
    state.click(a, model: value)
    XCTAssertEqual(state.selectedPiece, 0)
    var requests: [TimelineListTarget] = [.piece(0)] // Explicit click request.
    func request() {
      if let target = state.scrollTarget(for: hover.target, model: value) { requests.append(target) }
    }
    hover.grid(band, cell: layout.cell(at: CGPoint(x: rect.midX, y: rect.midY), band: band)); request()
    hover.grid(band, cell: layout.cell(at: gap, band: band)); request()
    XCTAssertEqual(state.target(for: hover.target, model: value), .piece(0), "clicked outline remains")
    hover.grid(band, cell: layout.cell(at: CGPoint(x: nextRect.midX, y: nextRect.midY), band: band)); request()
    XCTAssertEqual(requests, [.piece(0), .group(1), .group(1)])
    hover.endGrid(band); request()
    hover.row(.group(1), inside: true); request()
    hover.row(.group(1), inside: false); request()
    hover.row(1, inside: true); request()
    hover.row(1, inside: false); request()
    XCTAssertEqual(Array(requests.dropFirst()), [.group(1), .group(1)])
    XCTAssertEqual(state.target(for: hover.target, model: value), .piece(0))
  }
  func testRestEmptyFutureAndPointerGapsHaveNoHighlightOrText() {
    let value = model([0: .rest, 60: .work, 60000: .work])
    for target: TimelineHoverTarget? in [nil, .square(.init(column: 0, minute: 0)),
      .square(.init(column: 1, minute: 0)), .square(.init(column: 100, minute: 0)), .entry(-1), .entry(10)] {
      XCTAssertNil(value.highlight(for: target))
    }
    let layout = TimelineGridLayout(columnCount: 144, width: 1008)
    let rect = layout.squareRect(.init(column: 0, minute: 1))
    XCTAssertEqual(layout.cell(at: CGPoint(x: rect.midX, y: rect.midY), band: 0), .init(column: 0, minute: 1))
    XCTAssertNil(layout.cell(at: CGPoint(x: rect.maxX + 0.1, y: rect.midY), band: 0))
    XCTAssertNil(layout.cell(at: CGPoint(x: -1, y: 0), band: 0))
  }
  func testWrapUsesDrawnNeighboursAndClosesBothBands() {
    let layout = TimelineGridLayout(columnCount: 144, width: 440)
    let cells: Set<TimelineGridCell> = [.init(column: 71, minute: 0), .init(column: 72, minute: 0), .init(column: 73, minute: 0)]
    XCTAssertEqual(layout.boundary(of: cells).count, 10)
    XCTAssertTrue(layout.boundary(of: cells).contains(.init(cell: .init(column: 71, minute: 0), side: .right)))
    XCTAssertTrue(layout.boundary(of: cells).contains(.init(cell: .init(column: 72, minute: 0), side: .left)))
    XCTAssertFalse(layout.boundary(of: cells).contains(.init(cell: .init(column: 72, minute: 0), side: .right)))
    XCTAssertEqual(layout.cell(at: CGPoint(x: 1, y: layout.origin(at: 9) + 1), band: 1), .init(column: 72, minute: 0))
    for scale in [1.0, 2.0] {
      let geometry = TimelineGridLayout(columnCount: 144, width: 440, displayScale: scale)
      XCTAssertGreaterThan(geometry.highlightStroke, geometry.outlineStroke)
      XCTAssertEqual(geometry.highlightStroke * scale, (geometry.highlightStroke * scale).rounded())
    }
  }
  func testHitTargetsAndPerimeterTilesAgreeAtBothDisplayScales() {
    for scale in [1.0, 2.0] {
      for width in [440.0, 1008.0, 1200.0] {
        let layout = TimelineGridLayout(columnCount: 144, width: width, displayScale: scale)
        for (band, columns) in layout.rows.enumerated() {
          for column in columns {
            for minute in 0..<10 {
              let cell = TimelineGridCell(column: column, minute: minute)
              let square = layout.squareRect(cell)
              let tile = layout.outlineRect(cell)
              XCTAssertEqual(layout.cell(at: CGPoint(x: square.midX, y: square.midY), band: band), cell)
              XCTAssertTrue(tile.contains(square))
              if column + 1 < columns.upperBound {
                let next = TimelineGridCell(column: column + 1, minute: minute)
                XCTAssertEqual(tile.maxX, layout.outlineRect(next).minX)
                let gap = CGPoint(x: (square.maxX + layout.squareRect(next).minX) / 2, y: square.midY)
                XCTAssertNil(layout.cell(at: gap, band: band))
              }
              if minute < 9 {
                XCTAssertEqual(tile.minY, layout.outlineRect(.init(column: column, minute: minute + 1)).maxY)
              }
            }
          }
        }
      }
    }
  }

}
