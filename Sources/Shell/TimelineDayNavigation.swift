import AppKit
import Core
import SwiftUI

/// Dates in this state name calendar days, rather than instants before the activity boundary.
public struct TimelineDayNavigation {
  public let shown: Date
  public let today: Date
  public let calendar: Calendar
  public let columnCount: Int
  public init(day: TimeRange, now: Int, dayStartHour: Int, calendar: Calendar) {
    self.calendar = calendar; columnCount = (day.end - day.start + 599) / 600
    shown = calendar.startOfDay(for: Date(timeIntervalSince1970: Double(day.start)))
    let range = try? TimelineDay.range(containing: now, dayStartHour: dayStartHour, calendar: calendar)
    today = calendar.startOfDay(for: Date(timeIntervalSince1970: Double(range?.start ?? now)))
  }
  public var isToday: Bool { calendar.isDate(shown, inSameDayAs: today) }
  public var canGoNext: Bool { shown < today }
  public func canSelect(_ date: Date) -> Bool { calendar.startOfDay(for: date) <= today }
  public func step(_ amount: Int) -> Date? {
    calendar.date(byAdding: .day, value: amount, to: shown).flatMap { canSelect($0) ? $0 : nil }
  }
  public static func keyStep(code: UInt16, typing: Bool, dayVisible: Bool, modified: Bool) -> Int? {
    guard dayVisible, !typing, !modified else { return nil }
    return code == 123 ? -1 : code == 124 ? 1 : nil
  }
}

public enum TimelinePixelArrow {
  public static func rectangles(right: Bool, scale: Double) -> [CGRect] {
    let bitmap = ["0001000", "0011000", "0111000", "1111111", "0111000", "0011000", "0001000"]
    let cell = max(1, (2 * scale).rounded()) / scale
    return bitmap.enumerated().flatMap { y, row in
      row.enumerated().compactMap { x, bit in
        bit == "1" ? CGRect(x: Double(right ? 6 - x : x) * cell, y: Double(y) * cell,
          width: cell, height: cell) : nil
      }
    }
  }
}

private struct PixelButtonStyle: ButtonStyle {
  let ink: Color
  let stroke: Double
  var selected = false
  @State private var hovered = false
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.contentShape(Rectangle())
      .overlay { Rectangle().strokeBorder(hovered || selected || configuration.isPressed ? ink : .clear,
        lineWidth: stroke, antialiased: false).allowsHitTesting(false) }
      .onHover { hovered = $0 }
  }
}

private struct PixelArrow: View {
  let right: Bool
  let ink: Color
  @Environment(\.displayScale) private var scale
  var body: some View {
    Canvas { context, _ in
      var path = Path()
      for rect in TimelinePixelArrow.rectangles(right: right, scale: scale) { path.addRect(rect) }
      context.fill(path, with: .color(ink), style: FillStyle(antialiased: false))
    }.frame(width: 14, height: 14)
      .visualEffect { [scale] content, proxy in
        let origin = proxy.frame(in: .global).origin
        return content.offset(x: (origin.x * scale).rounded() / scale - origin.x,
          y: (origin.y * scale).rounded() / scale - origin.y)
      }
  }
}

struct TimelineCalendarCell: Equatable {
  let date: Date
  let number: String
  let label: String
}

struct TimelineCalendarMonth {
  let cells: [TimelineCalendarCell?]
  let weekdays: [String]
  let year: String
  let title: String
}

/// Kept in view state so snapshot publications reuse the month's formatted labels.
final class TimelineCalendarMonthCache {
  private struct Key: Equatable {
    let month: Date
    let calendar: Calendar
    let locale: Locale
  }
  private var key: Key?
  private var value: TimelineCalendarMonth?
  private(set) var rebuildCount = 0

  func month(containing date: Date, calendar: Calendar, locale: Locale) -> TimelineCalendarMonth {
    let month = calendar.dateInterval(of: .month, for: date)!.start
    let nextKey = Key(month: month, calendar: calendar, locale: locale)
    if key == nextKey, let value { return value }
    let formatter = DateFormatter()
    formatter.locale = locale; formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
    let symbols = formatter.veryShortStandaloneWeekdaySymbols!
    let weekdays = (0..<7).map { symbols[(calendar.firstWeekday - 1 + $0) % 7] }
    formatter.setLocalizedDateFormatFromTemplate("y")
    let year = formatter.string(from: month)
    formatter.setLocalizedDateFormatFromTemplate("MMMM")
    let title = formatter.string(from: month)
    formatter.setLocalizedDateFormatFromTemplate("yMMMMd")
    let offset = (calendar.component(.weekday, from: month) - calendar.firstWeekday + 7) % 7
    let count = calendar.range(of: .day, in: .month, for: month)!.count
    let size = ((offset + count + 6) / 7) * 7
    let cells: [TimelineCalendarCell?] = (0..<size).map { index in
      guard index >= offset, index < offset + count,
        let value = calendar.date(byAdding: .day, value: index - offset, to: month) else { return nil }
      let day = calendar.startOfDay(for: value)
      return TimelineCalendarCell(date: day, number: String(calendar.component(.day, from: day)), label: formatter.string(from: day))
    }
    let result = TimelineCalendarMonth(cells: cells, weekdays: weekdays, year: year, title: title)
    key = nextKey; value = result; rebuildCount += 1
    return result
  }
}

/// An inline calendar keeps the same square outline language without system popover chrome.
public struct TimelineDayControls: View {
  let navigation: TimelineDayNavigation
  let strings: TimelineStrings
  let choose: (Date) -> Void
  let today: () -> Void
  let step: ((Int) -> Void)?
  let readMonth: (Date) async throws -> Set<Date>
  let initialRecords: Set<Date>?
  let gridWidth: Double
  @State private var calendarOpen: Bool
  @State private var month: Date
  @State private var records: Set<Date> = []
  @State private var recordsFailed = false
  @State private var monthCache = TimelineCalendarMonthCache()
  @Environment(\.colorScheme) private var scheme
  @Environment(\.displayScale) private var scale
  public init(navigation: TimelineDayNavigation, strings: TimelineStrings, calendarOpen: Bool = false,
    records: Set<Date>? = nil, gridWidth: Double = 280, choose: @escaping (Date) -> Void = { _ in }, today: @escaping () -> Void = {}, step: ((Int) -> Void)? = nil,
    readMonth: @escaping (Date) async throws -> Set<Date> = { _ in [] }) {
    self.navigation = navigation; self.strings = strings; self.choose = choose; self.today = today; self.step = step
    self.readMonth = readMonth; initialRecords = records; self.gridWidth = gridWidth
    _calendarOpen = State(initialValue: calendarOpen)
    _month = State(initialValue: navigation.calendar.dateInterval(of: .month, for: navigation.shown)!.start)
  }
  private var palette: TimelinePalette { TimelinePalette(dark: scheme == .dark) }
  private var stroke: Double { TimelineGridLayout(columnCount: navigation.columnCount, width: gridWidth, displayScale: scale).highlightStroke }
  private var calendar: Calendar { navigation.calendar }
  private func dateText(_ date: Date, template: String = "yMMMMd") -> String {
    let formatter = DateFormatter(); formatter.locale = Locale(identifier: strings.language)
    formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
    formatter.setLocalizedDateFormatFromTemplate(template)
    return formatter.string(from: date)
  }
  private func label(_ key: TimelineLabel, _ date: Date) -> String {
    String(format: strings.text(key), locale: Locale(identifier: strings.language), dateText(date))
  }
  private func arrow(right: Bool, label: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
    Button(action: action) { PixelArrow(right: right, ink: palette.ink).frame(width: 28, height: 32) }
      .buttonStyle(PixelButtonStyle(ink: palette.ink, stroke: stroke))
      .disabled(!enabled).opacity(enabled ? 1 : 0.25).accessibilityLabel(Text(verbatim: label))
  }
  public var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 4) {
        let previous = calendar.date(byAdding: .day, value: -1, to: navigation.shown)!
        let next = calendar.date(byAdding: .day, value: 1, to: navigation.shown)!
        arrow(right: false, label: label(.previousDay, previous)) {
          if let step { step(-1) } else { choose(previous) }
        }
        Button {
          if !calendarOpen { month = calendar.dateInterval(of: .month, for: navigation.shown)!.start }
          calendarOpen.toggle()
        } label: {
          TimelineHeadline(sentence: dateText(navigation.shown, template: "yMMMd"), height: 14, wordSize: 14, ink: palette.ink)
            .padding(.horizontal, 6).frame(minHeight: 32)
        }.buttonStyle(PixelButtonStyle(ink: palette.ink, stroke: stroke, selected: calendarOpen))
          .accessibilityLabel(Text(verbatim: label(.chooseDate, navigation.shown)))
          .accessibilityValue(Text(verbatim: strings.text(calendarOpen ? .expanded : .collapsed)))
        arrow(right: true, label: label(.nextDay, next), enabled: navigation.canGoNext) {
          if let step { step(1) } else { choose(next) }
        }
        Spacer(minLength: 0)
        if !navigation.isToday {
          Button(action: today) { Text(verbatim: strings.text(.today)).font(.system(size: 14)).padding(.horizontal, 6).frame(height: 32) }
            .buttonStyle(PixelButtonStyle(ink: palette.ink, stroke: stroke, selected: true))
            .accessibilityLabel(Text(verbatim: strings.text(.today) + ": " + dateText(navigation.today)))
        }
      }
      if calendarOpen {
        calendarPanel
          .task(id: month) {
            records = []; recordsFailed = false
            if let initialRecords { records = initialRecords; return }
            do {
              let value = try await readMonth(month)
              guard !Task.isCancelled else { return }
              records = value
            } catch { if !Task.isCancelled { recordsFailed = true } }
          }
      }
    }.foregroundStyle(palette.ink).background(palette.paper)
  }
  private var calendarPanel: some View {
    let cached = monthCache.month(containing: month, calendar: calendar, locale: Locale(identifier: strings.language))
    return VStack(spacing: 8) {
      HStack(spacing: 0) {
        monthArrow(component: .year, amount: -1, key: .previousYear)
        Spacer(minLength: 0)
        TimelineHeadline(sentence: cached.year, height: 14, wordSize: 14, ink: palette.ink)
        Spacer(minLength: 0)
        monthArrow(component: .year, amount: 1, key: .nextYear)
      }
      HStack(spacing: 0) {
        monthArrow(component: .month, amount: -1, key: .previousMonth)
        Spacer(minLength: 0)
        TimelineHeadline(sentence: cached.title, height: 14, wordSize: 14, ink: palette.ink)
        Spacer(minLength: 0)
        monthArrow(component: .month, amount: 1, key: .nextMonth)
      }
      HStack(spacing: 0) {
        ForEach(0..<7) { offset in
          Text(verbatim: cached.weekdays[offset]).font(.system(size: 12)).frame(width: 40, height: 24)
        }
      }.accessibilityHidden(true)
      let dates = cached.cells
      VStack(spacing: 0) {
        ForEach(0..<(dates.count / 7), id: \.self) { row in
          HStack(spacing: 0) {
            ForEach(0..<7) { column in
              if let cell = dates[row * 7 + column] { dayCell(cell) }
              else { Color.clear.frame(width: 40, height: 32).accessibilityHidden(true) }
            }
          }
        }
      }
      if recordsFailed { Text(verbatim: strings.text(.calendarFailed)).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true) }
    }.frame(width: 280).padding(8)
      .overlay { Rectangle().strokeBorder(palette.ink, lineWidth: stroke, antialiased: false).allowsHitTesting(false) }
  }
  private func monthArrow(component: Calendar.Component, amount: Int, key: TimelineLabel) -> some View {
    let target = calendar.date(byAdding: component, value: amount, to: month)!
    // A year jump into the current year lands on its latest available month.
    let currentMonth = calendar.dateInterval(of: .month, for: navigation.today)!.start
    let sameYear = calendar.isDate(target, equalTo: navigation.today, toGranularity: .year)
    let destination = component == .year && sameYear && target > currentMonth ? currentMonth : target
    return arrow(right: amount > 0, label: label(key, destination), enabled: destination <= currentMonth) { month = destination }
  }
  private func dayCell(_ cell: TimelineCalendarCell) -> some View {
    let date = cell.date
    let selected = calendar.isDate(date, inSameDayAs: navigation.shown)
    let enabled = navigation.canSelect(date)
    let recorded = (initialRecords ?? records).contains(calendar.startOfDay(for: date))
    return Button { calendarOpen = false; choose(date) } label: {
      TimelineBitmapNumber(text: cell.number, height: 14, ink: palette.ink)
        .opacity(enabled ? (recorded ? 1 : 0.55) : 0.15)
        .frame(width: 40, height: 32)
        .overlay(alignment: .bottom) {
          if calendar.isDate(date, inSameDayAs: navigation.today) { Rectangle().fill(palette.now).frame(width: 3, height: 3).padding(.bottom, 3) }
        }
    }.buttonStyle(PixelButtonStyle(ink: palette.ink, stroke: stroke, selected: selected))
      .disabled(!enabled).accessibilityLabel(Text(verbatim: cell.label))
      .accessibilityAddTraits(selected ? [.isSelected] : [])
  }
}

/// A local monitor never takes focus and leaves text editing and modified arrows to their owners.
struct TimelineDayKeys: NSViewRepresentable {
  let step: (Int) -> Void
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    context.coordinator.view = view
    context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak coordinator = context.coordinator] event in
      guard let coordinator, let window = coordinator.view?.window, event.window === window else { return event }
      let modified = !event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
      guard let amount = TimelineDayNavigation.keyStep(code: event.keyCode, typing: window.firstResponder is NSText || window.firstResponder is NSTextField,
        dayVisible: true, modified: modified) else { return event }
      coordinator.step(amount); return nil
    }
    return view
  }
  func updateNSView(_ nsView: NSView, context: Context) { context.coordinator.step = step }
  static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
    if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }; coordinator.monitor = nil
  }
  final class Coordinator {
    weak var view: NSView?
    var monitor: Any?
    var step: (Int) -> Void = { _ in }
  }
}
