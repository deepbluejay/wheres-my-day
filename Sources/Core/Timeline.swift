import Foundation

public protocol TimelineStorageReader: SummaryTimelineReader {
  func settings() throws -> StorageSettings
}

public enum TimelineGridKind: String, CaseIterable {
  case work, other, distraction
  /// Recorded activity awaiting interpretation; the shell draws only an outline.
  case uninterpreted

  public static func of(_ minute: SummaryMinuteKind) -> Self? {
    switch minute {
    case .work: return .work
    case .distraction: return .distraction
    case .personal, .private, .unnamed: return .other
    case .unsummarized, .blank: return .uninterpreted
    case .rest: return nil
    }
  }
}

public struct TimelineGridSlot: Equatable {
  public let kind: TimelineGridKind?
  /// Index of the contiguous piece owning this minute.
  public let entryIndex: Int?
  public init(kind: TimelineGridKind?, entryIndex: Int?) {
    precondition(kind != nil || entryIndex == nil)
    self.kind = kind; self.entryIndex = entryIndex
  }
}

public struct TimelineColumn: Equatable {
  public let range: TimeRange
  public let minutesByKind: [TimelineGridKind: Int]
  /// Ten one-minute slots, bottom first in time order. Empty minutes have no kind or line.
  public let slots: [TimelineGridSlot]
  public var squares: [TimelineGridKind?] { slots.map(\.kind) }
}

public struct TimelineEntry: Equatable {
  public var range: TimeRange
  public let state: SummaryMinuteKind
  public let name: String?
  public var kind: TimelineGridKind { TimelineGridKind.of(state)! }
  public var minutes: Int
  public init(range: TimeRange, state: SummaryMinuteKind, name: String?, minutes: Int) {
    self.range = range; self.state = state; self.name = name; self.minutes = minutes
  }
}

/// A day-wide read projection. Pieces retain their original states and grid membership.
public struct TimelineGroup: Equatable {
  public let name: String?
  public let state: SummaryMinuteKind
  public let kind: TimelineGridKind
  public var entryIndices: [Int]
  public var range: TimeRange
  public var minutes: Int
}

public struct TimelineScaleMark: Equatable {
  public let column: Int
  public let hour: Int
  public init(column: Int, hour: Int) { self.column = column; self.hour = hour }
}

public enum TimelineDayError: Error { case invalidDayStartHour, unavailableDate }

/// Local activity only. Figures, lines and one-minute squares share the same source minutes.
public struct TimelineDay: Equatable {
  public static let columnSeconds = 600
  public static let rows = 10
  public static let defaultDayStartHour = 4
  public let range: TimeRange
  public let columns: [TimelineColumn]
  public let entries: [TimelineEntry]
  public let groups: [TimelineGroup]
  public let nowColumn: Int?
  public let scale: [TimelineScaleMark]
  public var notices: [TimelineNotice]
  public var minutesByKind: [TimelineGridKind: Int] {
    columns.reduce(into: [:]) { result, column in
      for (kind, minutes) in column.minutesByKind { result[kind, default: 0] += minutes }
    }
  }
  /// Total recorded activity, including private and uninterpreted minutes, never rest.
  /// The shell puts this exact number into its localized sentence and large-number layout.
  public var totalMinutes: Int { minutesByKind.values.reduce(0, +) }

  public static func range(containing time: Int, dayStartHour: Int, calendar: Calendar) throws -> TimeRange {
    guard (0...23).contains(dayStartHour) else { throw TimelineDayError.invalidDayStartHour }
    let date = Date(timeIntervalSince1970: Double(time))
    var midnight = calendar.startOfDay(for: date)
    var start = try boundary(on: midnight, hour: dayStartHour, calendar: calendar)
    if date < start {
      guard let previous = calendar.date(byAdding: .day, value: -1, to: midnight) else { throw TimelineDayError.unavailableDate }
      midnight = calendar.startOfDay(for: previous)
      start = try boundary(on: midnight, hour: dayStartHour, calendar: calendar)
    }
    guard let next = calendar.date(byAdding: .day, value: 1, to: midnight) else { throw TimelineDayError.unavailableDate }
    let end = try boundary(on: next, hour: dayStartHour, calendar: calendar)
    return TimeRange(Int(start.timeIntervalSince1970), Int(end.timeIntervalSince1970))
  }

  /// The selected calendar date names the day that starts on that date, even before its boundary hour.
  public static func range(on date: Date, dayStartHour: Int, calendar: Calendar) throws -> TimeRange {
    guard (0...23).contains(dayStartHour) else { throw TimelineDayError.invalidDayStartHour }
    let start = try boundary(on: date, hour: dayStartHour, calendar: calendar)
    guard let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))
    else { throw TimelineDayError.unavailableDate }
    let end = try boundary(on: next, hour: dayStartHour, calendar: calendar)
    return TimeRange(Int(start.timeIntervalSince1970), Int(end.timeIntervalSince1970))
  }

  private static func boundary(on date: Date, hour: Int, calendar: Calendar) throws -> Date {
    if let value = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: date,
      matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward),
      calendar.isDate(value, inSameDayAs: date) { return value }

    // Foundation can skip the whole date for a boundary inside a half-hour forward jump.
    // Locate the first valid second after that missing clock time within this date instead.
    guard let span = calendar.dateInterval(of: .day, for: date) else { throw TimelineDayError.unavailableDate }
    var low = Int(span.start.timeIntervalSince1970), high = Int(span.end.timeIntervalSince1970)
    while low < high {
      let middle = low + (high - low) / 2
      if calendar.component(.hour, from: Date(timeIntervalSince1970: Double(middle))) < hour { low = middle + 1 }
      else { high = middle }
    }
    guard low < Int(span.end.timeIntervalSince1970) else { throw TimelineDayError.unavailableDate }
    return Date(timeIntervalSince1970: Double(low))
  }

  /// One interval read covers the month, including activity after midnight belonging to its final day.
  public static func recordedDays(inMonth month: Date, dayStartHour: Int, calendar: Calendar,
    storage: TimelineStorageReader) throws -> Set<Date> {
    guard let span = calendar.dateInterval(of: .month, for: month) else { throw TimelineDayError.unavailableDate }
    let start = try range(on: span.start, dayStartHour: dayStartHour, calendar: calendar).start
    let end = try range(on: span.end, dayStartHour: dayStartHour, calendar: calendar).start
    let intervals = try storage.intervals(in: TimeRange(start, end))
    guard let dates = calendar.range(of: .day, in: .month, for: month) else { throw TimelineDayError.unavailableDate }
    var days = Set<Date>()
    for offset in 0..<dates.count {
      guard let value = calendar.date(byAdding: .day, value: offset, to: span.start) else { throw TimelineDayError.unavailableDate }
      let date = calendar.startOfDay(for: value)
      let day = try range(on: date, dayStartHour: dayStartHour, calendar: calendar)
      if intervals.contains(where: { $0.range.start < day.end && $0.range.end > day.start }) { days.insert(date) }
    }
    return days
  }

  public static func read(containing time: Int, now: Int, calendar: Calendar, storage: TimelineStorageReader,
    health: TimelineHealth = TimelineHealth()) throws -> Self {
    let settings = try storage.settings()
    let day = try range(containing: time, dayStartHour: settings.dayStartHour, calendar: calendar)
    let end = min(day.end, max(day.start, floorMinute(now)))
    let visible = TimeRange(day.start, end)
    let minutes = try SummaryTimeline.minutes(in: visible, storage: storage)
    let intervals = visible.start < visible.end ? try storage.intervals(in: visible) : []
    var result = make(range: day, minutes: minutes, intervals: intervals, now: now, calendar: calendar)
    result.notices = TimelineNotices.make(settings: settings, health: health)
    return result
  }

  /// Range boundaries must be minute aligned. The unfinished current minute waits for the next read.
  public static func make(range: TimeRange, minutes: [Int: SummaryMinuteKind], intervals: [NamedInterval],
    now: Int, calendar: Calendar) -> Self {
    precondition(range.start <= range.end && range.start % 60 == 0 && range.end % 60 == 0)
    let count = (range.end - range.start + columnSeconds - 1) / columnSeconds
    var slots = Array(repeating: Array<TimelineGridKind?>(repeating: nil, count: rows), count: count)
    var entries: [TimelineEntry] = []
    let end = min(range.end, max(range.start, floorMinute(now)))
    for minute in stride(from: range.start, to: end, by: 60) {
      guard let source = minutes[minute], let kind = TimelineGridKind.of(source) else { continue }
      // Input and quiet pending minutes are one uninterpreted activity in the list.
      let state: SummaryMinuteKind = source == .blank ? .unsummarized : source
      let column = (minute - range.start) / columnSeconds
      slots[column][(minute - range.start) % columnSeconds / 60] = kind
      // Adjacent equal pieces join even across model call boundaries.
      let index = intervals.firstIndex {
        $0.range.start <= minute && $0.range.end >= minute + 60
          && ($0.state == .private ? state == .private : $0.kind?.rawValue == state.rawValue)
      }
      let name = state == .private ? nil : index.map { intervals[$0].name }.flatMap { $0.isEmpty ? nil : $0 }
      if let last = entries.last, last.range.end == minute, last.state == state,
        last.name == name {
        entries[entries.count - 1].range.end = minute + 60
        entries[entries.count - 1].minutes += 1
      } else {
        entries.append(TimelineEntry(range: TimeRange(minute, minute + 60), state: state, name: name, minutes: 1))
      }
    }
    let groups = group(entries)
    var membership: [Int: Int] = [:]
    for (index, line) in entries.enumerated() {
      for minute in stride(from: line.range.start, to: line.range.end, by: 60) {
        membership[minute] = index
      }
    }
    let columns = slots.enumerated().map { index, squares in
      let start = range.start + index * columnSeconds
      let totals = squares.compactMap { $0 }.reduce(into: [TimelineGridKind: Int]()) { $0[$1, default: 0] += 1 }
      let gridSlots = squares.enumerated().map { minute, kind in
        TimelineGridSlot(kind: kind, entryIndex: kind == nil ? nil : membership[start + minute * 60])
      }
      return TimelineColumn(range: TimeRange(start, min(range.end, start + columnSeconds)), minutesByKind: totals, slots: gridSlots)
    }
    let scale = columns.enumerated().compactMap { index, column -> TimelineScaleMark? in
      let clock = calendar.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: Double(column.range.start)))
      guard clock.minute == 0, let hour = clock.hour, hour % 2 == 0 else { return nil }
      return TimelineScaleMark(column: index, hour: hour)
    }
    let nowColumn = now >= range.start && now < range.end ? (now - range.start) / columnSeconds : nil
    return Self(range: range, columns: columns, entries: entries, groups: groups, nowColumn: nowColumn, scale: scale, notices: [])
  }

  private static func group(_ entries: [TimelineEntry]) -> [TimelineGroup] {
    struct Key: Hashable {
      let name: String?
      let state: SummaryMinuteKind
      let kind: TimelineGridKind
    }
    var positions: [Key: Int] = [:]
    var groups: [TimelineGroup] = []
    // Entries arrive chronologically, so insertion order is first-start order.
    for (index, entry) in entries.enumerated() {
      let name = entry.name.flatMap { $0.isEmpty ? nil : $0 }
      let key = Key(name: name, state: entry.state, kind: entry.kind)
      if let position = positions[key] {
        groups[position].entryIndices.append(index)
        groups[position].range.end = entry.range.end
        groups[position].minutes += entry.minutes
      } else {
        positions[key] = groups.count
        groups.append(TimelineGroup(name: name, state: entry.state, kind: entry.kind,
          entryIndices: [index], range: entry.range, minutes: entry.minutes))
      }
    }
    return groups
  }

  private static func floorMinute(_ time: Int) -> Int { time - ((time % 60 + 60) % 60) }
}
