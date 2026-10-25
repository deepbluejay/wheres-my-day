import AppKit
import Core
@testable import Shell
import SwiftUI
import XCTest

final class TimelineHoverPixelTests: XCTestCase {
  @MainActor func testNowMarkerHasOnlySolidPixelsAtIntermediateWidths() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let minutes = Dictionary(uniqueKeysWithValues: stride(from: 0, to: 86400, by: 60).map { ($0, SummaryMinuteKind.distraction) })
    let day = TimelineDay.make(range: TimeRange(0, 86400), minutes: minutes, intervals: [], now: 20000, calendar: calendar)
    let model = TimelinePresentation(day: day, language: "en", resources: nil, calendar: calendar)
    let reference = ImageRenderer(content: TimelinePalette(dark: false).now.frame(width: 3, height: 3))
    let solidColor = rgba(NSBitmapImageRep(cgImage: try XCTUnwrap(reference.cgImage)), 1, 1)
    for width in [360.0, 436, 480, 872, 900, 944, 1120] {
      for scale in [1.0, 2] {
        let layout = TimelineGridLayout(columnCount: 144, width: width - (width < 600 ? 40 : 80), displayScale: scale)
        XCTAssertEqual(layout.columnHeight * scale, (layout.columnHeight * scale).rounded())
        XCTAssertEqual(layout.nowMarkerY * scale, (layout.nowMarkerY * scale).rounded())
        let image = try bitmap(model, width: width, scale: scale, dark: false)
        var solid = 0, blended = 0
        for y in 0..<image.pixelsHigh {
          for x in 0..<image.pixelsWide {
            let pixel = rgba(image, x, y)
            if pixel[0] > pixel[1] + 5 && abs(pixel[1] - pixel[2]) < 30 {
              if pixel == solidColor { solid += 1 }
              else { blended += 1 }
            }
          }
        }
        XCTAssertEqual(solid, Int((layout.squareSide * 3 * scale * scale).rounded()), "\(width), \(scale)x")
        XCTAssertEqual(blended, 0, "\(width), \(scale)x")
      }
    }
  }
  private func fixture() -> TimelinePresentation {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    var minutes: [Int: SummaryMinuteKind] = [:]
    var intervals: [NamedInterval] = []
    func add(_ start: Int, _ end: Int, _ kind: SummaryMinuteKind, _ name: String? = nil) {
      for minute in start..<end { minutes[minute * 60] = kind }
      if let name, let activity = ActivityKind(rawValue: kind.rawValue) {
        intervals.append(NamedInterval(range: TimeRange(start * 60, end * 60), name: name, kind: activity))
      }
    }
    add(300, 315, .work, "Invented A")
    add(315, 316, .distraction, "Invented interruption")
    add(316, 331, .work, "Invented A")
    add(380, 392, .private)
    add(780, 831, .unsummarized)
    add(450, 451, .personal, "Invented B")
    add(460, 485, .private)
    add(700, 735, .work, "Invented wrap")
    let day = TimelineDay.make(range: TimeRange(0, 86400), minutes: minutes, intervals: intervals,
      now: 50000, calendar: calendar)
    return TimelinePresentation(day: day, language: "en", resources: nil, calendar: calendar)
  }

  @MainActor func testHoverPreservesSelectedPixelsAndOnlyTouchesAdjacentNeighbourEdges() throws {
    let model = fixture()
    for scale in [1.0, 2.0] {
      for width in [360.0, 480, 1088, 1120, 1280] {
        for dark in [false, true] {
          let inset = width < 600 ? 20.0 : 40.0
          let layout = TimelineGridLayout(columnCount: 144, width: width - 2 * inset, displayScale: scale)
          let plain = try bitmap(model, width: width, scale: scale, dark: dark)
          // The fixture's sole yellow minute locates the grid independently of the view's layout.
          let gridTop = try yellowGridTop(plain, layout: layout, inset: inset, scale: scale,
            cell: .init(column: 31, minute: 5))
          for index in model.day.entries.indices {
            let selection = try XCTUnwrap(model.highlight(for: .entry(index)))
            let hover = try bitmap(model, width: width, scale: scale, dark: dark, target: .entry(index))
            XCTAssertEqual(hover.pixelsWide, plain.pixelsWide)
            XCTAssertEqual(hover.pixelsHigh, plain.pixelsHigh)
            var selectedChanges = 0
            var neighbourChanges = 0
            var strayGridChanges = 0
            var internalGapChanges = 0
            for (band, columns) in layout.rows.enumerated() {
              let top = gridTop + Double(band) * (layout.columnHeight + 52 + layout.scaleStripHeight)
              for column in columns {
                for minute in 0..<10 {
                  guard model.day.columns[column].slots[minute].kind != nil else { continue }
                  let cell = TimelineGridCell(column: column, minute: minute)
                  let rect = layout.squareRect(cell)
                  let x0 = Int(((inset + rect.minX) * scale).rounded())
                  let y0 = Int(((top + rect.minY) * scale).rounded())
                  let side = Int((rect.width * scale).rounded())
                  for y in 0..<side {
                    for x in 0..<side where plain.colorAt(x: x0 + x, y: y0 + y) != hover.colorAt(x: x0 + x, y: y0 + y) {
                      if selection.cells.contains(cell) { selectedChanges += 1; continue }
                      let allowed = (x == 0 && columns.contains(column - 1) && selection.cells.contains(.init(column: column - 1, minute: minute)))
                        || (x == side - 1 && columns.contains(column + 1) && selection.cells.contains(.init(column: column + 1, minute: minute)))
                        || (y == 0 && minute < 9 && selection.cells.contains(.init(column: column, minute: minute + 1)))
                        || (y == side - 1 && minute > 0 && selection.cells.contains(.init(column: column, minute: minute - 1)))
                      if !allowed { neighbourChanges += 1 }
                    }
                  }
                }
              }
              // Gaps with selected squares on both sides, including four-square crossings, are interior.
              var internalGaps: [CGRect] = []
              for cell in selection.cells where columns.contains(cell.column) {
                let rect = layout.squareRect(cell)
                let right = TimelineGridCell(column: cell.column + 1, minute: cell.minute)
                let above = TimelineGridCell(column: cell.column, minute: cell.minute + 1)
                if columns.contains(right.column), selection.cells.contains(right) {
                  let next = layout.squareRect(right)
                  internalGaps.append(CGRect(x: rect.maxX, y: rect.minY, width: next.minX - rect.maxX, height: rect.height))
                  if cell.minute < 9, selection.cells.contains(above),
                    selection.cells.contains(.init(column: right.column, minute: above.minute)) {
                    let upper = layout.squareRect(above)
                    internalGaps.append(CGRect(x: rect.maxX, y: upper.maxY, width: next.minX - rect.maxX,
                      height: rect.minY - upper.maxY))
                  }
                }
                if cell.minute < 9, selection.cells.contains(above) {
                  let upper = layout.squareRect(above)
                  internalGaps.append(CGRect(x: rect.minX, y: upper.maxY, width: rect.width, height: rect.minY - upper.maxY))
                }
              }
              for gap in internalGaps {
                for y in Int((gap.minY * scale).rounded())..<Int((gap.maxY * scale).rounded()) {
                  for x in Int((gap.minX * scale).rounded())..<Int((gap.maxX * scale).rounded()) {
                    let px = Int(inset * scale) + x, py = Int((top * scale).rounded()) + y
                    if plain.colorAt(x: px, y: py) != hover.colorAt(x: px, y: py) { internalGapChanges += 1 }
                  }
                }
              }
              // Any changed grid pixel must belong to the exterior of the exposed perimeter.
              let edges = layout.boundary(of: selection.cells).filter { columns.contains($0.cell.column) }
              let reach = layout.highlightStroke
              for edge in edges {
                let rect = layout.squareRect(edge.cell), pixel = 1 / scale
                let point: CGPoint
                switch edge.side {
                case .top: point = CGPoint(x: rect.midX, y: rect.minY - pixel / 2)
                case .bottom: point = CGPoint(x: rect.midX, y: rect.maxY + pixel / 2)
                case .left: point = CGPoint(x: rect.minX - pixel / 2, y: rect.midY)
                case .right: point = CGPoint(x: rect.maxX + pixel / 2, y: rect.midY)
                }
                let color = try XCTUnwrap(hover.colorAt(x: Int((inset + point.x) * scale),
                  y: Int((top + point.y) * scale))?.usingColorSpace(.deviceRGB))
                XCTAssertEqual(Int((color.redComponent * 255).rounded()), dark ? 255 : 0, "edge \(edge), width \(width), scale \(scale), dark \(dark)")
                XCTAssertEqual(Int((color.greenComponent * 255).rounded()), dark ? 255 : 0, "edge \(edge), width \(width), scale \(scale), dark \(dark)")
                XCTAssertEqual(Int((color.blueComponent * 255).rounded()), dark ? 255 : 0, "edge \(edge), width \(width), scale \(scale), dark \(dark)")
              }
              let allowedRects = edges.map { edge -> CGRect in
                let r = layout.squareRect(edge.cell)
                switch edge.side {
                case .top: return CGRect(x: r.minX - reach, y: r.minY - reach, width: r.width + 2 * reach, height: reach)
                case .bottom: return CGRect(x: r.minX - reach, y: r.maxY, width: r.width + 2 * reach, height: reach)
                case .left: return CGRect(x: r.minX - reach, y: r.minY - reach, width: reach, height: r.height + 2 * reach)
                case .right: return CGRect(x: r.maxX, y: r.minY - reach, width: reach, height: r.height + 2 * reach)
                }
              }
              for y in 0..<Int(layout.columnHeight * scale) {
                for x in 0..<Int((width - 2 * inset) * scale) {
                  let px = Int(inset * scale) + x, py = Int((top * scale).rounded()) + y
                  if plain.colorAt(x: px, y: py) != hover.colorAt(x: px, y: py),
                    !allowedRects.contains(where: { $0.contains(CGPoint(x: (Double(x) + 0.5) / scale, y: (Double(y) + 0.5) / scale)) }) {
                    strayGridChanges += 1
                  }
                }
              }
            }
            let context = "entry \(index), width \(width), scale \(scale), dark \(dark)"
            XCTAssertEqual(selectedChanges, 0, context)
            XCTAssertEqual(neighbourChanges, 0, context)
            XCTAssertEqual(strayGridChanges, 0, context)
            XCTAssertEqual(internalGapChanges, 0, context)
            XCTAssertNotEqual(hover.tiffRepresentation, plain.tiffRepresentation, context)
          }
        }
      }
    }
  }

  @MainActor func testEveryLocalizedHoverValueIsVisibleAndLabelsClearTotalsAndEveryGrid() throws {
    let resources = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: resources) }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let compiler = Process()
    compiler.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    compiler.arguments = [root.appendingPathComponent("tools/strings.py").path, "compile", resources.path]
    try compiler.run(); compiler.waitUntilExit()
    XCTAssertEqual(compiler.terminationStatus, 0)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let name = String(("Invented " + String(repeating: "long name ", count: 30)).prefix(250))
    var minutes = Dictionary(uniqueKeysWithValues: (600..<720).map { ($0 * 60, SummaryMinuteKind.work) })
    minutes[300 * 60] = .distraction
    for minute in 730..<760 { minutes[minute * 60] = minute == 745 ? .distraction : .work }
    for minute in 380..<392 { minutes[minute * 60] = .private }
    for minute in 800..<812 { minutes[minute * 60] = .unsummarized }
    let day = TimelineDay.make(range: TimeRange(0, 86400), minutes: minutes, intervals: [
      NamedInterval(range: TimeRange(600 * 60, 720 * 60), name: "Invented first band", kind: .work),
      NamedInterval(range: TimeRange(730 * 60, 745 * 60), name: name, kind: .work),
      NamedInterval(range: TimeRange(745 * 60, 746 * 60), name: "Invented interruption", kind: .distraction),
      NamedInterval(range: TimeRange(746 * 60, 760 * 60), name: name, kind: .work)
    ], now: 50000, calendar: calendar)
    // These expectations come from the invented 120-minute and 15-minute pieces,
    // not from the presentation formatter or a second truncated rendering.
    let translations = [
      ("en", "120 min", "15 min", "Work", "Other", "Private", "Not yet interpreted", "12 min"),
      ("ko", "120분", "15분", "일", "그 밖", "비공개", "아직 해석되지 않음", "12분"),
      ("ja", "120分", "15分", "仕事", "その他", "非公開", "まだ解釈されていません", "12分"),
      ("zh-Hans", "120 分钟", "15 分钟", "工作", "其他", "不公开", "尚未解读", "12 分钟"),
      ("zh-Hant", "120 分鐘", "15 分鐘", "工作", "其他", "不公開", "尚未解讀", "12 分鐘"),
      ("de", "120 Min.", "15 Min.", "Arbeit", "Sonstiges", "Privat", "Noch nicht interpretiert", "12 Min."),
      ("fr", "120 min", "15 min", "Travail", "Autre", "Privé", "Pas encore interprété", "12 min"),
      ("es", "120 min", "15 min", "Trabajo", "Otro", "Privado", "Aún sin interpretar", "12 min"),
      ("ru", "120 мин", "15 мин", "Работа", "Прочее", "Скрыто", "Ещё не интерпретировано", "12 мин")
    ]
    // 360pt is the earlier narrower window case; 400pt gives 360pt of content.
    for width in [360.0, 400.0, 480.0, 1088.0, 1280.0] {
      for (language, firstMinutes, countedMinutes, work, other, privateName, pendingName, fixedMinutes) in translations {
        let model = TimelinePresentation(day: day, language: language, resources: resources, calendar: calendar)
        let index = try XCTUnwrap(day.entries.firstIndex { $0.name == name })
        XCTAssertEqual(model.name(day.entries[index]), name)
        let largestDetail = "23:59–23:59 · " + countedMinutes.replacingOccurrences(of: "15", with: "1499")
        let largest = ImageRenderer(content: Text(verbatim: largestDetail)
          .font(.system(size: 12)).monospacedDigit().fixedSize())
        largest.scale = 2
        XCTAssertLessThanOrEqual(Double(try XCTUnwrap(largest.cgImage).width) / 2, 320, language)
        for scale in [1.0, 2.0] {
          for dark in [false, true] {
            let inset = width < 600 ? 20.0 : 40.0, contentWidth = width - 2 * inset
            let layout = TimelineGridLayout(columnCount: 144, width: contentWidth, displayScale: scale)
            let plain = try bitmap(model, width: width, scale: scale, dark: dark)
            let gridTop = try yellowGridTop(plain, layout: layout, inset: inset, scale: scale, cell: .init(column: 30, minute: 0))
            let paper = dark ? 0 : 255
            let headerEnd = try XCTUnwrap((0..<Int((gridTop - 5) * scale)).last { y in
              (0..<plain.pixelsWide).contains { x in rgba(plain, x, y)[0] != paper }
            }) + 1
            let hover = try bitmap(model, width: width, scale: scale, dark: dark, target: .square(.init(column: 74, minute: 4)))
            XCTAssertEqual(day.columns[74].slots[4].kind, .work)
            XCTAssertEqual(try XCTUnwrap(model.highlight(for: .square(.init(column: 74, minute: 4)))).entryIndex, index)
            var previousBandChanges = 0
            for y in 0..<Int((layout.columnHeight + 30) * scale) {
              for x in 0..<Int(contentWidth * scale) {
                let px = Int(inset * scale) + x, py = Int((gridTop * scale).rounded()) + y
                if plain.colorAt(x: px, y: py) != hover.colorAt(x: px, y: py) { previousBandChanges += 1 }
              }
            }
            if layout.rows.count == 2 { XCTAssertEqual(previousBandChanges, 0, "\(language), \(scale)x") }
            // Compare the complete capped label at an independently calculated left edge.
            // The first band exercises right clamping; the second keeps its natural edge
            // at 480pt and clamps to the full content width in the narrow cases.
            let first = try XCTUnwrap(day.entries.firstIndex { $0.name == "Invented first band" })
            let privateIndex = try XCTUnwrap(day.entries.firstIndex { $0.state == .private })
            let pendingIndex = try XCTUnwrap(day.entries.firstIndex { $0.kind == .uninterpreted })
            for entry in [first, index, privateIndex, pendingIndex] {
              let band = (entry == index || entry == pendingIndex) && layout.rows.count == 2 ? 1 : 0
              let selected = try XCTUnwrap(model.highlight(for: .entry(entry)))
              let left = try XCTUnwrap(selected.cells.filter { layout.rows[band].contains($0.column) }
                .map { layout.squareRect($0).minX }.min()) - layout.highlightStroke
              let labelWidth = min(400, contentWidth)
              let expectedX = inset + max(0, min(contentWidth - labelWidth, left))
              let expectedKind = entry == privateIndex ? other : entry == pendingIndex ? pendingName : work
              let expectedName = entry == privateIndex ? privateName : entry == pendingIndex ? pendingName
                : entry == index ? name : "Invented first band"
              let expectedDetail = entry == privateIndex ? "06:20–06:32 · " + fixedMinutes
                : entry == pendingIndex ? "13:20–13:32 · " + fixedMinutes
                : entry == index ? "12:10–12:25 · " + countedMinutes
                : "10:00–12:00 · " + firstMinutes
              XCTAssertEqual(model.hoverDetail(day.entries[entry]), expectedDetail)
              let fullDetail = ImageRenderer(content: Text(verbatim: expectedDetail)
                .font(.system(size: 12)).monospacedDigit().fixedSize()
                .environment(\.displayScale, scale))
              fullDetail.scale = scale
              let fullWidth = Double(try XCTUnwrap(fullDetail.cgImage).width) / scale
              XCTAssertLessThanOrEqual(fullWidth, labelWidth, "full numerical detail must fit, \(language)")
              let reference = ImageRenderer(content: VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                  Text(verbatim: expectedKind + (entry == pendingIndex ? "" : " · ")).fixedSize()
                  if entry != pendingIndex {
                    Text(verbatim: expectedName).lineLimit(1).truncationMode(.tail)
                  }
                }
                // No line limit or truncation: every glyph in this reference must be painted.
                Text(verbatim: expectedDetail).fixedSize()
              }.font(.system(size: 12)).monospacedDigit()
                .fixedSize(horizontal: false, vertical: true).frame(width: labelWidth, alignment: .leading)
                .foregroundStyle(dark ? Color.white : Color.black).background(dark ? Color.black : Color.white).environment(\.displayScale, scale))
              reference.scale = scale
              let expected = NSBitmapImageRep(cgImage: try XCTUnwrap(reference.cgImage))
              let actual = entry == index ? hover : try bitmap(model, width: width, scale: scale, dark: dark, target: .entry(entry))
              let y0 = Int(((gridTop + Double(band) * (layout.columnHeight + 52 + layout.scaleStripHeight) - 5) * scale).rounded()) - expected.pixelsHigh
              var mismatches = 0, inkPixels = 0
              for y in 0..<expected.pixelsHigh {
                for x in 0..<expected.pixelsWide {
                  if rgba(expected, x, y) != rgba(actual, Int((expectedX * scale).rounded()) + x, y0 + y) { mismatches += 1 }
                  if (rgba(expected, x, y)[0] < 128) != dark { inkPixels += 1 }
                }
              }
              // Compare the full last totals line, where the old label overlapped.
              // Headline glyph rasterization can vary slightly between offscreen renders.
              let stripStart = max(0, headerEnd - Int(18 * scale))
              let byteOffset = stripStart * plain.bytesPerRow
              let byteCount = (headerEnd - stripStart) * plain.bytesPerRow
              XCTAssertEqual(plain.bytesPerRow, actual.bytesPerRow)
              let totalsUnchanged = Data(bytes: try XCTUnwrap(plain.bitmapData) + byteOffset, count: byteCount)
                == Data(bytes: try XCTUnwrap(actual.bitmapData) + byteOffset, count: byteCount)
              XCTAssertTrue(totalsUnchanged, "totals strip must remain visible, \(language), \(width), \(scale)x, entry \(entry), dark \(dark)")
              if band == 0 { XCTAssertGreaterThanOrEqual(y0 - headerEnd, Int(5 * scale)) }
              XCTAssertGreaterThan(inkPixels, 0)
              XCTAssertLessThanOrEqual(Double(expected.pixelsHigh) / scale, 30)
              XCTAssertEqual(mismatches, 0, "full visible detail and alignment, \(language), \(width), \(scale)x, band \(band)")
              // A full fixed kind is part of the independently painted reference.
              let kindWidth = ImageRenderer(content: Text(verbatim: expectedKind + " · ")
                .font(.system(size: 12)).monospacedDigit().fixedSize())
              kindWidth.scale = scale
              XCTAssertLessThan(Double(try XCTUnwrap(kindWidth.cgImage).width) / scale, labelWidth)
              if entry == privateIndex || entry == pendingIndex {
                let fullHeader = ImageRenderer(content: Text(verbatim: entry == pendingIndex ? pendingName : expectedKind + " · " + expectedName)
                  .font(.system(size: 12)).monospacedDigit().fixedSize())
                fullHeader.scale = scale
                XCTAssertLessThanOrEqual(Double(try XCTUnwrap(fullHeader.cgImage).width) / scale, labelWidth,
                  "fixed name must fit completely, \(language)")
              }
              XCTAssertEqual(mismatches == 0 ? expectedKind : "", expectedKind, "missing painted kind")
              // Equality to the entire untruncated reference proves which text is visible.
              let visibleText = mismatches == 0 && fullWidth <= labelWidth ? expectedDetail : ""
              for value in entry == privateIndex ? ["06:20", "06:32", fixedMinutes]
                : entry == pendingIndex ? ["13:20", "13:32", fixedMinutes]
                : entry == index ? ["12:10", "12:25", countedMinutes] : ["10:00", "12:00", firstMinutes] {
                XCTAssertTrue(visibleText.contains(value), "missing visible value \(value), \(language), \(width), \(scale)x")
              }
            }
          }
        }
      }
    }
  }

  @MainActor func testFreeOutlineSideHasExactlyItsNominalThickness() throws {
    let model = fixture()
    for (width, scale, thickness) in [(480.0, 1.0, 2), (1088.0, 2.0, 3), (1280.0, 2.0, 3)] {
      let inset = width < 600 ? 20.0 : 40.0
      let layout = TimelineGridLayout(columnCount: 144, width: width - 2 * inset, displayScale: scale)
      let plain = try bitmap(model, width: width, scale: scale, dark: false)
      let gridTop = try yellowGridTop(plain, layout: layout, inset: inset, scale: scale, cell: .init(column: 31, minute: 5))
      let index = try XCTUnwrap(model.day.entries.firstIndex { $0.name == "Invented B" })
      let hover = try bitmap(model, width: width, scale: scale, dark: false, target: .entry(index))
      let square = layout.squareRect(.init(column: 45, minute: 0))
      let x = Int(((inset + square.minX) * scale).rounded())
      let y = Int(((gridTop + square.midY) * scale).rounded(.down))
      for distance in 1...thickness { XCTAssertEqual(rgba(hover, x - distance, y), [0, 0, 0, 255], "width \(width), scale \(scale), distance \(distance)") }
      XCTAssertEqual(rgba(hover, x - thickness - 1, y), [255, 255, 255, 255])
    }
  }

  private func rgba(_ image: NSBitmapImageRep, _ x: Int, _ y: Int) -> [Int] {
    let color = image.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
    return [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent].map { Int(($0 * 255).rounded()) }
  }

  private func yellowGridTop(_ image: NSBitmapImageRep, layout: TimelineGridLayout, inset: Double,
    scale: Double, cell: TimelineGridCell) throws -> Double {
    let marker = layout.squareRect(cell)
    let x = Int((inset + marker.minX) * scale)
    let y = try XCTUnwrap((0..<image.pixelsHigh).last { y in
      let color = rgba(image, x, y)
      return color[0] > 240 && (180..<230).contains(color[1]) && color[2] < 25
    })
    return Double(y + 1) / scale - marker.maxY
  }

  func testDelayedExitOnlyClearsItsOwnRowOrGrid() {
    var state = TimelineHoverState()
    state.row(0, inside: true)
    state.row(1, inside: true)
    state.row(0, inside: false)
    XCTAssertEqual(state.target, .entry(1))
    state.row(1, inside: false)
    XCTAssertNil(state.target)
    state.grid(0, cell: .init(column: 71, minute: 0))
    state.grid(1, cell: .init(column: 72, minute: 0))
    state.endGrid(0)
    XCTAssertEqual(state.target, .square(.init(column: 72, minute: 0)))
    state.row(1, inside: true)
    state.endGrid(1)
    XCTAssertEqual(state.target, .entry(1))
    state.grid(0, cell: .init(column: 4, minute: 0))
    state.row(1, inside: false)
    XCTAssertEqual(state.target, .square(.init(column: 4, minute: 0)))
    state.grid(0, cell: nil)
    XCTAssertNil(state.target)
    state.endGrid(0)
    XCTAssertNil(state.target)
  }

  @MainActor private func bitmap(_ model: TimelinePresentation, width: Double, scale: Double,
    dark: Bool, target: TimelineHoverTarget? = nil) throws -> NSBitmapImageRep {
    let png = try XCTUnwrap(TimelineOffscreenRender.png(model: model, width: width, dark: dark,
      scale: scale, hovered: target))
    return try XCTUnwrap(NSBitmapImageRep(data: png))
  }
}
