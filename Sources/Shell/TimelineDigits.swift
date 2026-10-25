import Foundation
import SwiftUI

public enum TimelineDigits {
  public static let bitmaps = [
    ["01110", "10001", "10001", "10001", "10001", "10001", "01110"],
    ["00100", "01100", "00100", "00100", "00100", "00100", "01110"],
    ["01110", "10001", "00001", "00010", "00100", "01000", "11111"],
    ["11110", "00001", "00001", "01110", "00001", "00001", "11110"],
    ["00010", "00110", "01010", "10010", "11111", "00010", "00010"],
    ["11111", "10000", "11110", "00001", "00001", "10001", "01110"],
    ["00110", "01000", "10000", "11110", "10001", "10001", "01110"],
    ["11111", "00001", "00010", "00100", "01000", "01000", "01000"],
    ["01110", "10001", "10001", "01110", "10001", "10001", "01110"],
    ["01110", "10001", "10001", "01111", "00001", "00010", "01100"]
  ]
  public static func cellSize(height: Double, scale: Double) -> Double {
    max(1, (height * scale / 7).rounded()) / scale
  }
  public static func rectangles(_ text: String, height: Double, scale: Double) -> [CGRect] {
    let cell = cellSize(height: height, scale: scale)
    return text.enumerated().flatMap { index, character -> [CGRect] in
      guard let digit = character.wholeNumberValue, bitmaps.indices.contains(digit) else { return [] }
      return bitmaps[digit].enumerated().flatMap { y, row in
        row.enumerated().compactMap { x, value in
          value == "1" ? CGRect(x: Double(index * 6 + x) * cell, y: Double(y) * cell, width: cell, height: cell) : nil
        }
      }
    }
  }
}

public struct TimelineBitmapNumber: View {
  let text: String
  let height: Double
  let ink: Color
  @Environment(\.displayScale) private var scale
  public init(text: String, height: Double, ink: Color) { self.text = text; self.height = height; self.ink = ink }
  public var body: some View {
    let cell = TimelineDigits.cellSize(height: height, scale: scale)
    Canvas { context, _ in
      var path = Path()
      for rect in TimelineDigits.rectangles(text, height: height, scale: scale) { path.addRect(rect) }
      context.fill(path, with: .color(ink), style: FillStyle(antialiased: false))
    }.frame(width: Double(max(0, text.count * 6 - 1)) * cell, height: 7 * cell)
      .visualEffect { [scale] content, proxy in
        let origin = proxy.frame(in: .global).origin
        return content.offset(x: (origin.x * scale).rounded() / scale - origin.x,
          y: (origin.y * scale).rounded() / scale - origin.y)
      }
      .alignmentGuide(.firstTextBaseline) { $0.height }
      .accessibilityLabel(Text(verbatim: text))
  }
}

struct TimelineHeadline: View {
  let sentence: String
  let height: Double
  let wordSize: Double
  let ink: Color
  @Environment(\.displayScale) private var scale
  private var tokens: [String] {
    var tokens: [String] = [], token = "", previous: Bool?
    for character in sentence {
      let digit = character.wholeNumberValue != nil
      if !token.isEmpty && (previous != digit || token.last?.isWhitespace == true) {
        tokens.append(token); token = ""
      }
      token.append(character); previous = digit
    }
    if !token.isEmpty { tokens.append(token) }
    return tokens
  }
  var body: some View {
    TimelineSentenceLayout {
      ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
        if token.first?.wholeNumberValue != nil {
          TimelineBitmapNumber(text: token, height: height, ink: ink)
            // Bitmap glyphs lack the side-bearings of adjacent font glyphs.
            .padding(.horizontal, TimelineDigits.cellSize(height: height, scale: scale))
        } else { Text(verbatim: token).font(.system(size: wordSize)).fixedSize() }
      }
    }.accessibilityElement(children: .ignore).accessibilityLabel(Text(verbatim: sentence))
  }
}

/// Wrap localized words while aligning the drawn numbers to the sentence baseline.
struct TimelineSentenceLayout: Layout {
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    arrange(subviews, width: proposal.width ?? .infinity).size
  }
  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let result = arrange(subviews, width: bounds.width)
    for (index, point) in result.points.enumerated() {
      subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
    }
  }
  private func arrange(_ subviews: Subviews, width: Double) -> (size: CGSize, points: [CGPoint]) {
    var points = Array(repeating: CGPoint.zero, count: subviews.count)
    var line: [Int] = [], x = 0.0, y = 0.0, used = 0.0
    let dimensions = subviews.map { $0.dimensions(in: .unspecified) }
    func finish() {
      guard !line.isEmpty else { return }
      let baseline = line.map { dimensions[$0][.firstTextBaseline] }.max() ?? 0
      let descent = line.map { dimensions[$0].height - dimensions[$0][.firstTextBaseline] }.max() ?? 0
      for index in line { points[index].y = y + baseline - dimensions[index][.firstTextBaseline] }
      y += baseline + descent + 4
      used = max(used, x); x = 0; line = []
    }
    for index in subviews.indices {
      let size = dimensions[index]
      if x > 0 && x + size.width > width { finish() }
      points[index].x = x; x += size.width; line.append(index)
    }
    finish()
    return (CGSize(width: min(width, used), height: max(0, y - 4)), points)
  }
}
