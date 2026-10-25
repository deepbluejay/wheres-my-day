import AppKit
@testable import Shell
import SwiftUI
import XCTest

final class TimelineDigitTests: XCTestCase {
  @MainActor func testKoreanMultiNumberInkHasOneCellClearanceOnBothSides() throws {
    let sentence = "오늘 기록: 5시간 30분."
    for scale in [1.0, 2.0] {
      for height in [35.0, 42.0] {
        let cell = TimelineDigits.cellSize(height: height, scale: scale)
        let renderer = ImageRenderer(content: TimelineHeadline(sentence: sentence, height: height,
          wordSize: height == 35 ? 14 : 15, ink: .black)
          .foregroundStyle(.black).background(.white).environment(\.displayScale, scale))
        renderer.scale = scale
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
        var allInk = Set<Int>(), tallInk = Set<Int>()
        for x in 0..<bitmap.pixelsWide {
          for y in 0..<bitmap.pixelsHigh {
            let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
            if color.redComponent < 0.5 {
              allInk.insert(x)
              // Words are only 14/15pt high, so this band contains digits alone.
              if Double(y) < 2 * cell * scale { tallInk.insert(x) }
            }
          }
        }
        var digitRuns: [ClosedRange<Int>] = []
        for x in tallInk.sorted() {
          if let previous = digitRuns.last, previous.upperBound + 1 == x {
            digitRuns[digitRuns.count - 1] = previous.lowerBound...x
          } else { digitRuns.append(x...x) }
        }
        XCTAssertEqual(digitRuns.count, 3, "5 and 30 must both be rendered")
        guard digitRuns.count == 3 else { continue }
        for number in [digitRuns[0], digitRuns[1].lowerBound...digitRuns[2].upperBound] {
          let before = try XCTUnwrap(allInk.filter { $0 < number.lowerBound }.max())
          let after = try XCTUnwrap(allInk.filter { $0 > number.upperBound }.min())
          XCTAssertGreaterThanOrEqual(number.lowerBound - before - 1, Int(cell * scale))
          XCTAssertGreaterThanOrEqual(after - number.upperBound - 1, Int(cell * scale))
        }
      }
    }
  }
  func testRequestedDigitCells() {
    for scale in [1.0, 2.0] {
      XCTAssertEqual(TimelineDigits.cellSize(height: 42, scale: scale), 6)
      XCTAssertEqual(TimelineDigits.cellSize(height: 35, scale: scale), 5)
      XCTAssertEqual(TimelineDigits.cellSize(height: 10.5, scale: scale), scale == 2 ? 1.5 : 2)
    }
  }
  func testApprovedBitmapTableAndDistinctFive() {
    let expected = [
      "01110 10001 10001 10001 10001 10001 01110",
      "00100 01100 00100 00100 00100 00100 01110",
      "01110 10001 00001 00010 00100 01000 11111",
      "11110 00001 00001 01110 00001 00001 11110",
      "00010 00110 01010 10010 11111 00010 00010",
      "11111 10000 11110 00001 00001 10001 01110",
      "00110 01000 10000 11110 10001 10001 01110",
      "11111 00001 00010 00100 01000 01000 01000",
      "01110 10001 10001 01110 10001 10001 01110",
      "01110 10001 10001 01111 00001 00010 01100"
    ]
    XCTAssertEqual(TimelineDigits.bitmaps.map { $0.joined(separator: " ") }, expected)
    XCTAssertEqual(TimelineDigits.bitmaps[5][0].first, "1")
    XCTAssertEqual(TimelineDigits.bitmaps[5][1].first, "1")
  }
  @MainActor func testRasterUsesOnlySolidWholeDevicePixelsAtBothScales() throws {
    for scale in [1.0, 2.0] {
      for height in [10.5, 35, 42] {
        let cell = TimelineDigits.cellSize(height: height, scale: scale)
        let rects = TimelineDigits.rectangles("0123456789", height: height, scale: scale)
        for rect in rects {
          for coordinate in [rect.minX, rect.minY, rect.width, rect.height] {
            XCTAssertEqual(coordinate * scale, (coordinate * scale).rounded())
          }
        }
        let view = TimelineBitmapNumber(text: "0123456789", height: height, ink: .black)
          .background(.white).environment(\.displayScale, scale)
        let renderer = ImageRenderer(content: view); renderer.scale = scale
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
        XCTAssertEqual(bitmap.pixelsHigh, Int(7 * cell * scale))
        for y in 0..<bitmap.pixelsHigh {
          for x in 0..<bitmap.pixelsWide {
            let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
            let filled = rects.contains { $0.contains(CGPoint(x: (Double(x) + 0.5) / scale, y: (Double(y) + 0.5) / scale)) }
            XCTAssertEqual(Int((color.redComponent * 255).rounded()), filled ? 0 : 255)
            XCTAssertEqual(Int((color.greenComponent * 255).rounded()), filled ? 0 : 255)
            XCTAssertEqual(Int((color.blueComponent * 255).rounded()), filled ? 0 : 255)
            XCTAssertEqual(Int((color.alphaComponent * 255).rounded()), 255)
          }
        }
      }
    }
  }
}
