import AppKit
import Core
import SwiftUI

public struct TimelinePalette {
  public let paper: Color
  public let ink: Color
  public let grey = Color(white: 0.5)
  public let yellow = Color(red: 1, green: 0.8, blue: 0)
  public let now = Color(red: 0.9, green: 0.12, blue: 0.12)
  public init(dark: Bool) {
    paper = dark ? .black : .white
    ink = dark ? .white : .black
  }
  func fill(_ style: TimelineSquareStyle) -> Color {
    switch style {
    case .ink, .outline: return ink
    case .grey: return grey
    case .yellow: return yellow
    case .blank: return paper
    }
  }
}

private struct TimelineRowFrames: PreferenceKey {
  static let defaultValue: [TimelineListTarget: CGRect] = [:]
  static func reduce(value: inout [TimelineListTarget: CGRect], nextValue: () -> [TimelineListTarget: CGRect]) {
    value.merge(nextValue(), uniquingKeysWith: { _, new in new })
  }
}
private struct TimelineHeaderHeight: PreferenceKey {
  static let defaultValue: Double = 0
  static func reduce(value: inout Double, nextValue: () -> Double) { value = max(value, nextValue()) }
}

private struct TimelineGridScrollObservation: Equatable {
  let hover: TimelineHoverTarget?
  let target: TimelineListTarget?
  let explicitRequest: Int
}

/// The header and list own separate scroll regions in the window.
public struct TimelineView: View {
  public let model: TimelinePresentation
  public let width: Double
  public var goToSettings: (SettingsSection) -> Void
  private let scrolls: Bool
  private let onBringIntoView: ((TimelineListTarget) -> Void)?
  @StateObject private var interaction: TimelineInteractionState
  @State private var headerHeight = 280.0
  @State private var rowFrames: [TimelineListTarget: CGRect] = [:]
  @State private var pendingScroll: TimelineListTarget?
  @Environment(\.colorScheme) private var scheme
  @Environment(\.displayScale) private var displayScale

  public init(model: TimelinePresentation, width: Double, hovered: TimelineHoverTarget? = nil, expanded: Set<Int> = [], scrolls: Bool = true, goToSettings: @escaping (SettingsSection) -> Void = { _ in }) {
    self.model = model; self.width = width; self.goToSettings = goToSettings; self.scrolls = scrolls
    onBringIntoView = nil
    _interaction = StateObject(wrappedValue: TimelineInteractionState(hovered: hovered, expanded: expanded))
  }
  init(model: TimelinePresentation, width: Double, interaction: TimelineInteractionState,
    onBringIntoView: ((TimelineListTarget) -> Void)? = nil) {
    self.model = model; self.width = width; self.goToSettings = { _ in }; self.scrolls = true
    self.onBringIntoView = onBringIntoView
    _interaction = StateObject(wrappedValue: interaction)
  }
  private var highlight: TimelineHighlight? { model.highlight(for: interaction.hover.target ?? interaction.list.selectedPiece.map(TimelineHoverTarget.entry)) }
  private var palette: TimelinePalette { TimelinePalette(dark: scheme == .dark) }
  private var inset: Double { width < 600 ? 20 : 40 }
  private var contentWidth: Double { max(1, width - 2 * inset) }
  private var listTarget: TimelineListTarget? { interaction.list.target(for: interaction.hover.target, model: model) }
  private var gridScrollObservation: TimelineGridScrollObservation {
    TimelineGridScrollObservation(hover: interaction.hover.target,
      target: interaction.list.scrollTarget(for: interaction.hover.target, model: model),
      explicitRequest: interaction.scrollRequest)
  }
  private var layout: TimelineGridLayout {
    TimelineGridLayout(columnCount: model.day.columns.count, width: contentWidth, displayScale: displayScale)
  }
  private var headline: some View {
    TimelineHeadline(sentence: model.headline, height: width < 600 ? 35 : 42,
      wordSize: width < 600 ? 14 : 15, ink: palette.ink)
      .accessibilityLabel(Text(verbatim: model.headlineAccessibility))
  }
  public var body: some View {
    Group {
      if scrolls {
        GeometryReader { geometry in
          VStack(alignment: .leading, spacing: 0) {
            ScrollView {
              header.fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { proxy in
                  Color.clear.preference(key: TimelineHeaderHeight.self, value: proxy.size.height)
                })
            }.frame(height: min(headerHeight, max(geometry.size.height / 2, geometry.size.height - 160)))
              .onPreferenceChange(TimelineHeaderHeight.self) { if $0 > 0 { headerHeight = $0 } }
            scrollingList
          }
        }
      } else {
        VStack(alignment: .leading, spacing: 0) { header; activityList.padding(.horizontal, inset).padding(.bottom, inset) }
      }
    }.foregroundStyle(palette.ink).frame(width: width, alignment: .leading).background(palette.paper)
      .onChange(of: model.day) { old, new in
        interaction.list.reconcile(from: old, to: new)
        interaction.hover.reconcile(from: old, to: new)
      }
  }
  private var header: some View {
    VStack(alignment: .leading, spacing: 28) {
      VStack(alignment: .leading, spacing: 12) {
        headline
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 20) { totals }
          VStack(alignment: .leading, spacing: 8) { totals }
        }
      }
      // The 40pt total gap leaves 5pt beyond the 30pt label and its 5pt grid clearance.
      grid.padding(.top, 12)
      if !model.notices.isEmpty {
        VStack(alignment: .leading, spacing: 12) {
          ForEach(Array(model.notices.enumerated()), id: \.offset) { _, notice in
            ViewThatFits(in: .horizontal) {
              HStack(spacing: 16) {
                Text(verbatim: model.notice(notice))
                settingsButton(for: notice)
              }
              VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: model.notice(notice))
                settingsButton(for: notice)
              }
            }
          }
        }.font(.system(size: 13))
      }
    }.padding(inset).frame(width: width, alignment: .leading)
  }
  private var scrollingList: some View {
    GeometryReader { geometry in
      ScrollViewReader { proxy in
        ScrollView {
          activityList.padding(.horizontal, inset).padding(.bottom, inset)
        }.coordinateSpace(name: "timelineList")
          .onPreferenceChange(TimelineRowFrames.self) { frames in
            rowFrames = frames
            if let pendingScroll, frames[pendingScroll] != nil {
              bringIntoView(pendingScroll, proxy: proxy, height: geometry.size.height)
            }
          }
          .onChange(of: gridScrollObservation, initial: true) { old, new in
            // A stationary square can resolve to another row after a summary refresh.
            // Clicks have their own request path, including expansion of the hovered group.
            guard old.explicitRequest == new.explicitRequest else { return }
            guard let target = new.target else {
              pendingScroll = nil; return
            }
            pendingScroll = target
            bringIntoView(target, proxy: proxy, height: geometry.size.height)
          }
          .onChange(of: interaction.scrollRequest) { _, _ in
            guard let piece = interaction.list.selectedPiece else { return }
            let target = TimelineListTarget.piece(piece)
            pendingScroll = target
            bringIntoView(target, proxy: proxy, height: geometry.size.height)
          }
      }
    }
  }
  private func bringIntoView(_ target: TimelineListTarget, proxy: ScrollViewProxy, height: Double) {
    onBringIntoView?(target)
    guard let frame = rowFrames[target] else { return }
    pendingScroll = nil
    guard let edge = TimelineListScroll.edge(target: frame, viewport: CGRect(x: 0, y: 0, width: width, height: height)) else { return }
    var transaction = Transaction(); transaction.disablesAnimations = true
    withTransaction(transaction) { proxy.scrollTo(target, anchor: edge == .top ? .top : .bottom) }
  }
  private var activityList: some View {
    let target = listTarget
    let stroke = layout.listHighlightStroke
    return VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(model.day.groups.enumerated()), id: \.offset) { index, group in
        Rectangle().fill(palette.ink.opacity(0.25)).frame(height: 1)
        Button {
          interaction.list.toggle(index, day: model.day)
        } label: {
          HStack(alignment: .top, spacing: 10) {
            Text(verbatim: interaction.list.expanded.contains(index) ? "−" : "+").font(.system(size: 14, design: .monospaced))
            VStack(alignment: .leading, spacing: 6) {
              Text(verbatim: model.name(group)).font(.system(size: 14, weight: .medium))
              Text(verbatim: model.detail(group)).font(.system(size: 11)).monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            }
          }.padding(.vertical, 12).padding(.horizontal, 6).frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
          .accessibilityValue(Text(verbatim: model.strings.text(interaction.list.expanded.contains(index) ? .expanded : .collapsed)))
          .onHover { interaction.hover.row(.group(index), inside: $0) }
          .overlay { rowBorder(.group(index), selected: target, stroke: stroke) }
          .background(rowFrame(.group(index))).id(TimelineListTarget.group(index))
        if interaction.list.expanded.contains(index) {
          ForEach(group.entryIndices, id: \.self) { piece in
            Text(verbatim: model.hoverDetail(model.day.entries[piece]))
              .font(.system(size: 11)).monospacedDigit()
              .padding(.vertical, 9).padding(.leading, 30).padding(.trailing, 6)
              .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
              .onHover { interaction.hover.row(piece, inside: $0) }
              .overlay { rowBorder(.piece(piece), selected: target, stroke: stroke) }
              .background(rowFrame(.piece(piece))).id(TimelineListTarget.piece(piece))
          }
        }
      }
      if !model.day.groups.isEmpty { Rectangle().fill(palette.ink.opacity(0.25)).frame(height: 1) }
    }
  }
  private func rowFrame(_ target: TimelineListTarget) -> some View {
    GeometryReader { geometry in
      Color.clear.preference(key: TimelineRowFrames.self, value: [target: geometry.frame(in: .named("timelineList"))])
    }
  }
  private func rowBorder(_ target: TimelineListTarget, selected: TimelineListTarget?, stroke: Double) -> some View {
    Rectangle().strokeBorder(selected == target ? palette.ink : .clear, lineWidth: stroke, antialiased: false)
      .allowsHitTesting(false)
  }
  private func settingsButton(for notice: TimelineNotice) -> some View {
    Button(action: { goToSettings(notice.kind.settingsSection) }) { Text(verbatim: model.strings.text(.settings)).underline() }
      .buttonStyle(.plain)
  }
  private var totals: some View {
    ForEach(model.recordedKinds, id: \.rawValue) { kind in
      HStack(spacing: 6) {
        if kind == .uninterpreted {
          Rectangle().strokeBorder(palette.ink, lineWidth: 1).frame(width: 8, height: 8)
        } else {
          Rectangle().fill(palette.fill(.of(kind))).frame(width: 8, height: 8)
        }
        Text(verbatim: model.kind(kind) + " " + model.minutes(model.day.minutesByKind[kind, default: 0]))
      }.font(.system(size: 12))
    }
  }
  private var grid: some View {
    let layout = TimelineGridLayout(columnCount: model.day.columns.count, width: contentWidth, displayScale: displayScale)
    // Reserve 30pt for the next hover label, with 5pt clearance on each side.
    return VStack(alignment: .leading, spacing: 40) {
      ForEach(layout.rows.indices, id: \.self) { row in
        gridRow(row, layout: layout)
      }
    }.accessibilityElement(children: .ignore).accessibilityLabel(Text(verbatim: model.strings.text(.grid)))
  }
  private func gridRow(_ band: Int, layout: TimelineGridLayout) -> some View {
    let columns = layout.rows[band]
    let selection = highlight
    let cells = selection?.cells.filter { columns.contains($0.column) } ?? []
    let edges = layout.boundary(of: selection?.cells ?? []).filter { columns.contains($0.cell.column) }
    let bounds = edges.reduce(CGRect.null) { $0.union(layout.highlightRect(for: $1)) }
    let labelWidth = min(400, contentWidth)
    let labelX = bounds.isNull ? 0 : max(0, min(contentWidth - labelWidth, bounds.minX))
    let side = layout.squareSide
    let height = layout.columnHeight
    return VStack(alignment: .leading, spacing: 6) {
      Canvas { context, _ in
        for index in columns {
          for (minute, kind) in model.day.columns[index].squares.enumerated() {
            let style = TimelineSquareStyle.of(kind)
            guard style != .blank else { continue }
            let rect = layout.squareRect(.init(column: index, minute: minute))
            if style == .outline {
              // A filled ring avoids antialiased stroke joins on one-device-pixel borders.
              var outline = Path(rect)
              outline.addRect(rect.insetBy(dx: layout.outlineStroke, dy: layout.outlineStroke))
              context.fill(outline, with: .color(palette.ink), style: FillStyle(eoFill: true, antialiased: false))
            } else { context.fill(Path(rect), with: .color(palette.fill(style))) }
          }
        }
        if !edges.isEmpty {
          let frame = CGRect(x: -layout.highlightStroke, y: -layout.highlightStroke,
            width: contentWidth + 2 * layout.highlightStroke, height: height + 2 * layout.highlightStroke)
          var exterior = Path(frame), grown = Path()
          for rect in layout.highlightInterior(selection?.cells ?? [], band: band) {
            exterior.addRect(rect)
            grown.addRect(rect.insetBy(dx: -layout.highlightStroke, dy: -layout.highlightStroke))
          }
          var protection = Path(frame)
          for column in columns {
            for (minute, slot) in model.day.columns[column].slots.enumerated() where slot.kind != nil {
              protection.addRect(layout.highlightProtectedRect(.init(column: column, minute: minute),
                selection: selection?.cells ?? []))
            }
          }
          var outlineContext = context
          // Subtract the whole union before neighbour protection, including concave internal gaps.
          outlineContext.clip(to: exterior, style: FillStyle(eoFill: true, antialiased: false))
          outlineContext.clip(to: protection, style: FillStyle(eoFill: true, antialiased: false))
          outlineContext.fill(grown, with: .color(palette.ink), style: FillStyle(antialiased: false))
        }
        if let now = model.day.nowColumn, columns.contains(now) {
          context.fill(Path(CGRect(x: layout.origin(at: now - columns.lowerBound), y: layout.nowMarkerY,
            width: side, height: 3)), with: .color(palette.now))
        }
      }.frame(width: contentWidth, height: height + 6)
        .gesture(SpatialTapGesture().onEnded { value in
          if let cell = layout.cell(at: value.location, band: band) {
            interaction.click(cell, model: model)
          }
        })
        .onContinuousHover { phase in
          switch phase {
          case .active(let point): interaction.hover.grid(band, cell: layout.cell(at: point, band: band))
          case .ended: interaction.hover.endGrid(band)
          }
        }
      ZStack(alignment: .topLeading) {
        Color.clear.frame(height: layout.scaleStripHeight)
        ForEach(model.day.scale.filter { columns.contains($0.column) }, id: \.column) { mark in
          TimelineBitmapNumber(text: String(format: "%02d", mark.hour), height: 10.5, ink: palette.ink)
            .offset(x: layout.scaleLabelX(at: mark.column - columns.lowerBound, width: contentWidth))
        }
      }.frame(width: contentWidth, height: layout.scaleStripHeight)
    }
    .overlay(alignment: .topLeading) {
      if let selection, !cells.isEmpty {
        let entry: TimelineEntry = {
          if case .group(let index) = interaction.hover.target, model.day.groups.indices.contains(index) {
            let group = model.day.groups[index]
            return TimelineEntry(range: group.range, state: group.state, name: group.name, minutes: group.minutes)
          }
          return model.day.entries[selection.entryIndex]
        }()
        let name = model.name(entry), kind = model.kind(entry.kind)
        VStack(alignment: .leading, spacing: 0) {
          HStack(spacing: 0) {
            Text(verbatim: kind + (name == kind ? "" : " · ")).fixedSize()
            Text(verbatim: name == kind ? "" : name).lineLimit(1).truncationMode(.tail)
          }
          Text(verbatim: model.hoverDetail(entry)).fixedSize()
        }.font(.system(size: 12)).monospacedDigit()
          .fixedSize(horizontal: false, vertical: true)
          .frame(width: labelWidth, alignment: .leading)
          .background(palette.paper)
          // A zero-height bottom anchor keeps the label above its own band.
          .frame(height: 0, alignment: .bottomLeading)
          .offset(x: labelX, y: -5)
          .allowsHitTesting(false)
      }
    }
  }
}

public enum TimelineOffscreenRender {
  @MainActor public static func png(model: TimelinePresentation, width: Double, dark: Bool, scale: Double = 2, hovered: TimelineHoverTarget? = nil, expanded: Set<Int> = [], height: Double? = nil) -> Data? {
    if let height {
      // Native scroll regions require a hosting view; this never constructs a window.
      let view = TimelineView(model: model, width: width, hovered: hovered, expanded: expanded)
        .environment(\.colorScheme, dark ? .dark : .light).environment(\.displayScale, scale)
        .frame(width: width, height: height)
      let host = NSHostingView(rootView: view)
      host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
      host.frame = NSRect(x: 0, y: 0, width: width, height: height)
      host.layoutSubtreeIfNeeded()
      RunLoop.current.run(until: Date().addingTimeInterval(0.02))
      host.layoutSubtreeIfNeeded()
      guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale),
        pixelsHigh: Int(height * scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
      bitmap.size = NSSize(width: width, height: height)
      host.cacheDisplay(in: host.bounds, to: bitmap)
      return bitmap.representation(using: .png, properties: [:])
    }
    let renderer = ImageRenderer(content: TimelineView(model: model, width: width, hovered: hovered, expanded: expanded, scrolls: false)
      .environment(\.colorScheme, dark ? .dark : .light)
      .environment(\.displayScale, scale))
    renderer.scale = scale
    guard let image = renderer.cgImage else { return nil }
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
  }
}

extension TimelineOffscreenRender {
  @MainActor public static func navigationPNG(model: TimelinePresentation, width: Double, dark: Bool,
    scale: Double, now: Int, calendarOpen: Bool, records: Set<Date>) -> Data? {
    let palette = TimelinePalette(dark: dark)
    let navigation = TimelineDayNavigation(day: model.day.range, now: now, dayStartHour: 4, calendar: model.calendar)
    let view = VStack(alignment: .leading, spacing: 0) {
      TimelineDayControls(navigation: navigation, strings: model.strings, calendarOpen: calendarOpen, records: records, gridWidth: width - (width < 600 ? 40 : 80))
        .padding(.horizontal, width < 600 ? 20 : 40).padding(.top, 16).padding(.bottom, 4)
      TimelineView(model: model, width: width, scrolls: false)
    }.frame(width: width).foregroundStyle(palette.ink).background(palette.paper)
      .environment(\.colorScheme, dark ? .dark : .light).environment(\.displayScale, scale)
    let renderer = ImageRenderer(content: view); renderer.scale = scale
    guard let image = renderer.cgImage else { return nil }
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
  }
}
