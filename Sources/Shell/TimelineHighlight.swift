import Combine
import Core
import Foundation

public struct TimelineGridCell: Hashable {
  public let column: Int
  public let minute: Int
  public init(column: Int, minute: Int) { self.column = column; self.minute = minute }
}

public enum TimelineHoverTarget: Equatable {
  case square(TimelineGridCell)
  case entry(Int)
  case group(Int)
}

public struct TimelineHoverState {
  private enum Owner: Equatable { case row(TimelineHoverTarget), grid(Int) }
  private var owner: Owner?
  public private(set) var target: TimelineHoverTarget?
  public init(target: TimelineHoverTarget? = nil) { self.target = target }

  public mutating func row(_ index: Int, inside: Bool) {
    row(.entry(index), inside: inside)
  }
  public mutating func row(_ value: TimelineHoverTarget, inside: Bool) {
    if inside { owner = .row(value); target = value }
    else if owner == .row(value) { owner = nil; target = nil }
  }
  public mutating func grid(_ band: Int, cell: TimelineGridCell?) {
    owner = .grid(band); target = cell.map(TimelineHoverTarget.square)
  }
  public mutating func endGrid(_ band: Int) {
    if owner == .grid(band) { owner = nil; target = nil }
  }
}

public struct TimelineHighlight: Equatable {
  public let entryIndex: Int
  public let cells: Set<TimelineGridCell>
}

extension TimelinePresentation {
  /// Piece pointers select their own minutes; group rows select the union of their pieces.
  public func highlight(for target: TimelineHoverTarget?) -> TimelineHighlight? {
    let index: Int
    let cells: Set<TimelineGridCell>
    switch target {
    case .entry(let entry):
      guard cellsByEntry.indices.contains(entry) else { return nil }
      index = entry; cells = cellsByEntry[entry]
    case .group(let group):
      guard day.groups.indices.contains(group), let first = day.groups[group].entryIndices.first else { return nil }
      index = first; cells = cellsByGroup[group]
    case .square(let cell):
      guard let entry = entryIndex(for: cell) else { return nil }
      index = entry; cells = cellsByEntry[entry]
    case nil: return nil
    }
    guard !cells.isEmpty else { return nil }
    return TimelineHighlight(entryIndex: index, cells: cells)
  }
}

/// Stable row identities distinguish a collapsed group from one of its pieces.
public enum TimelineListTarget: Hashable { case group(Int), piece(Int) }

public struct TimelineListState {
  public private(set) var expanded: Set<Int>
  public private(set) var selectedPiece: Int?
  public init(expanded: Set<Int> = []) { self.expanded = expanded }
  public mutating func toggle(_ group: Int, day: TimelineDay) {
    guard day.groups.indices.contains(group) else { return }
    if expanded.remove(group) == nil { expanded.insert(group) }
    else if let selectedPiece, day.groups[group].entryIndices.contains(selectedPiece) { self.selectedPiece = nil }
  }
  /// Summary refreshes can insert earlier groups; preserve identity rather than row position.
  public mutating func reconcile(from old: TimelineDay, to new: TimelineDay) {
    guard old.range == new.range else { self = Self(); return }
    expanded = Set(expanded.compactMap { TimelineListIdentity.group($0, from: old, to: new) })
    selectedPiece = selectedPiece.flatMap { TimelineListIdentity.piece($0, from: old, to: new) }
  }
  public mutating func click(_ cell: TimelineGridCell, model: TimelinePresentation) {
    guard let entry = model.entryIndex(for: cell),
      let group = model.groupIndex(for: entry) else { return }
    expanded.insert(group); selectedPiece = entry
  }
  public func target(for hover: TimelineHoverTarget?, model: TimelinePresentation) -> TimelineListTarget? {
    switch hover {
    case .group(let group): return model.day.groups.indices.contains(group) ? .group(group) : nil
    case .entry(let entry): return model.groupIndex(for: entry).map { expanded.contains($0) ? .piece(entry) : .group($0) }
    case .square(let cell):
      guard let entry = model.entryIndex(for: cell),
        let group = model.groupIndex(for: entry) else { return nil }
      return expanded.contains(group) ? .piece(entry) : .group(group)
    case nil: return selectedPiece.map(TimelineListTarget.piece)
    }
  }
  /// Outline fallback is deliberately excluded from hover scroll requests.
  public func scrollTarget(for hover: TimelineHoverTarget?, model: TimelinePresentation) -> TimelineListTarget? {
    guard case .square = hover else { return nil }
    return target(for: hover, model: model)
  }
}

/// Grid and list events share one owner for hover, expansion and explicit click requests.
final class TimelineInteractionState: ObservableObject {
  @Published var list: TimelineListState
  @Published var hover: TimelineHoverState
  @Published var scrollRequest = 0
  init(hovered: TimelineHoverTarget? = nil, expanded: Set<Int> = []) {
    list = TimelineListState(expanded: expanded)
    hover = TimelineHoverState(target: hovered)
  }
  func click(_ cell: TimelineGridCell, model: TimelinePresentation) {
    guard model.entryIndex(for: cell) != nil else { return }
    list.click(cell, model: model)
    scrollRequest += 1
  }
}

private enum TimelineListIdentity {
  static func group(_ index: Int, from old: TimelineDay, to new: TimelineDay) -> Int? {
    guard old.groups.indices.contains(index) else { return nil }
    let group = old.groups[index]
    return new.groups.firstIndex { $0.name == group.name && $0.kind == group.kind && $0.state == group.state }
  }
  static func piece(_ index: Int, from old: TimelineDay, to new: TimelineDay) -> Int? {
    guard old.entries.indices.contains(index) else { return nil }
    let piece = old.entries[index]
    return new.entries.firstIndex {
      $0.range.start <= piece.range.start && piece.range.start < $0.range.end && $0.name == piece.name && $0.state == piece.state
    }
  }
}

extension TimelineHoverState {
  public mutating func reconcile(from old: TimelineDay, to new: TimelineDay) {
    guard old.range == new.range else { self = Self(); return }
    func remap(_ target: TimelineHoverTarget?) -> TimelineHoverTarget? {
      switch target {
      case .group(let index): return TimelineListIdentity.group(index, from: old, to: new).map(TimelineHoverTarget.group)
      case .entry(let index): return TimelineListIdentity.piece(index, from: old, to: new).map(TimelineHoverTarget.entry)
      case .square, nil: return target
      }
    }
    target = remap(target)
    if case .row(let value) = owner { owner = remap(value).map(Owner.row) }
  }
}

extension TimelinePresentation {
  public func groupIndex(for entry: Int) -> Int? {
    groupByEntry.indices.contains(entry) ? groupByEntry[entry] : nil
  }
  public func entryIndex(for cell: TimelineGridCell) -> Int? {
    guard entryByCell.indices.contains(cell.column), entryByCell[cell.column].indices.contains(cell.minute) else { return nil }
    return entryByCell[cell.column][cell.minute]
  }
}

public enum TimelineScrollEdge: Equatable { case top, bottom }
public enum TimelineListScroll {
  /// A visible target needs no movement; an oversized row must not oscillate between edges.
  public static func edge(target: CGRect, viewport: CGRect) -> TimelineScrollEdge? {
    guard viewport.height > 0 else { return nil }
    if target.height > viewport.height && target.intersects(viewport) { return nil }
    if target.minY < viewport.minY { return .top }
    if target.maxY > viewport.maxY { return .bottom }
    return nil
  }
}

public struct TimelineGridEdge: Hashable {
  public enum Side: CaseIterable { case top, bottom, left, right }
  public let cell: TimelineGridCell
  public let side: Side
  public init(cell: TimelineGridCell, side: Side) { self.cell = cell; self.side = side }
}

extension TimelineGridLayout {
  public var highlightStroke: Double { outlineStroke + 1 / displayScale }

  /// The selection includes shared gaps; four selected corners also own their crossing.
  public func highlightInterior(_ cells: Set<TimelineGridCell>, band: Int) -> [CGRect] {
    guard rows.indices.contains(band) else { return [] }
    let columns = rows[band]
    var rects: [CGRect] = []
    for cell in cells where columns.contains(cell.column) {
      let rect = squareRect(cell)
      rects.append(rect)
      let right = TimelineGridCell(column: cell.column + 1, minute: cell.minute)
      let above = TimelineGridCell(column: cell.column, minute: cell.minute + 1)
      let hasRight = columns.contains(right.column) && cells.contains(right)
      let hasAbove = cell.minute < TimelineDay.rows - 1 && cells.contains(above)
      if hasRight {
        rects.append(CGRect(x: rect.maxX, y: rect.minY,
          width: squareRect(right).minX - rect.maxX, height: rect.height))
      }
      if hasAbove {
        rects.append(CGRect(x: rect.minX, y: squareRect(above).maxY,
          width: rect.width, height: rect.minY - squareRect(above).maxY))
      }
      if hasRight && hasAbove && cells.contains(.init(column: right.column, minute: above.minute)) {
        rects.append(CGRect(x: rect.maxX, y: squareRect(above).maxY,
          width: squareRect(right).minX - rect.maxX, height: rect.minY - squareRect(above).maxY))
      }
    }
    return rects
  }

  /// Exposed edges grow outwards; selected square pixels always remain untouched.
  public func highlightRect(for edge: TimelineGridEdge) -> CGRect {
    let rect = squareRect(edge.cell), stroke = highlightStroke
    switch edge.side {
    case .top: return CGRect(x: rect.minX - stroke, y: rect.minY - stroke, width: rect.width + 2 * stroke, height: stroke)
    case .bottom: return CGRect(x: rect.minX - stroke, y: rect.maxY, width: rect.width + 2 * stroke, height: stroke)
    case .left: return CGRect(x: rect.minX - stroke, y: rect.minY - stroke, width: stroke, height: rect.height + 2 * stroke)
    case .right: return CGRect(x: rect.maxX, y: rect.minY - stroke, width: stroke, height: rect.height + 2 * stroke)
    }
  }

  /// At a neighbour, only its directly adjacent device-pixel edge may join the outline.
  public func highlightProtectedRect(_ cell: TimelineGridCell, selection: Set<TimelineGridCell>) -> CGRect {
    var rect = squareRect(cell)
    guard !selection.contains(cell), let band = rows.first(where: { $0.contains(cell.column) }) else { return rect }
    let pixel = 1 / displayScale
    if band.contains(cell.column - 1), selection.contains(.init(column: cell.column - 1, minute: cell.minute)) {
      rect.origin.x += pixel; rect.size.width -= pixel
    }
    if band.contains(cell.column + 1), selection.contains(.init(column: cell.column + 1, minute: cell.minute)) { rect.size.width -= pixel }
    if cell.minute < TimelineDay.rows - 1, selection.contains(.init(column: cell.column, minute: cell.minute + 1)) {
      rect.origin.y += pixel; rect.size.height -= pixel
    }
    if cell.minute > 0, selection.contains(.init(column: cell.column, minute: cell.minute - 1)) { rect.size.height -= pixel }
    return rect
  }

  public func squareRect(_ cell: TimelineGridCell) -> CGRect {
    guard let band = rows.first(where: { $0.contains(cell.column) }) else { return .zero }
    return CGRect(x: origin(at: cell.column - band.lowerBound), y: origin(at: TimelineDay.rows - 1 - cell.minute),
      width: squareSide, height: squareSide)
  }

  /// Hit only the actual square, including a hollow square's inside, never the spacing.
  public func cell(at point: CGPoint, band: Int) -> TimelineGridCell? {
    guard rows.indices.contains(band), point.x >= 0, point.y >= 0 else { return nil }
    let column = Int(point.x / squarePitch)
    let row = Int(point.y / squarePitch)
    guard column < rows[band].count, row < TimelineDay.rows else { return nil }
    // Snapped origins can begin a device pixel before their unsnapped pitch.
    for x in column...min(column + 1, rows[band].count - 1) {
      for y in row...min(row + 1, TimelineDay.rows - 1) {
        let cell = TimelineGridCell(column: rows[band].lowerBound + x, minute: TimelineDay.rows - 1 - y)
        if squareRect(cell).contains(point) { return cell }
      }
    }
    return nil
  }

  public func boundary(of cells: Set<TimelineGridCell>) -> Set<TimelineGridEdge> {
    var edges: Set<TimelineGridEdge> = []
    for cell in cells {
      guard let band = rows.first(where: { $0.contains(cell.column) }), (0..<TimelineDay.rows).contains(cell.minute) else { continue }
      for side in TimelineGridEdge.Side.allCases {
        let neighbour: TimelineGridCell
        switch side {
        case .top: neighbour = .init(column: cell.column, minute: cell.minute + 1)
        case .bottom: neighbour = .init(column: cell.column, minute: cell.minute - 1)
        case .left: neighbour = .init(column: cell.column - 1, minute: cell.minute)
        case .right: neighbour = .init(column: cell.column + 1, minute: cell.minute)
        }
        // Scale labels separate wrapped bands; their exposed edges must close independently.
        if !band.contains(neighbour.column) || !(0..<TimelineDay.rows).contains(neighbour.minute) || !cells.contains(neighbour) {
          edges.insert(TimelineGridEdge(cell: cell, side: side))
        }
      }
    }
    return edges
  }

  /// Tile boundaries bisect the gaps so adjacent squares share one continuous perimeter.
  public func outlineRect(_ cell: TimelineGridCell) -> CGRect {
    guard let band = rows.first(where: { $0.contains(cell.column) }) else { return .zero }
    func boundary(_ index: Int) -> Double {
      let midpoint = (origin(at: index - 1) + squareSide + origin(at: index)) / 2
      return (midpoint * displayScale).rounded(.down) / displayScale
    }
    let x = cell.column - band.lowerBound
    let y = TimelineDay.rows - 1 - cell.minute
    return CGRect(x: boundary(x), y: boundary(y), width: boundary(x + 1) - boundary(x), height: boundary(y + 1) - boundary(y))
  }
}
