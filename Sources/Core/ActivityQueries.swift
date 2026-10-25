import Foundation

/// Every multi-read answer observes one committed privacy/settings snapshot.
public protocol ActivityQueryStorage: TimelineStorageReader {
  func withQuerySnapshot<T>(_ body: () throws -> T) throws -> T
}

public enum ActivityQueryError: String, Error { case invalidArguments, unavailable, refused }

public struct ActivityQueryRow: Encodable, Equatable {
  public var range: TimeRange
  public var state: String
  public var name: String?
  public var description: String?
  public var project: String?
  public var minutes: Int { (range.end - range.start) / 60 }
  public func encode(to encoder: Encoder) throws {
    var box = encoder.container(keyedBy: Keys.self)
    try box.encode(range, forKey: .range); try box.encode(state, forKey: .state)
    try box.encodeIfPresent(name, forKey: .name); try box.encodeIfPresent(description, forKey: .description)
    try box.encodeIfPresent(project, forKey: .project); try box.encode(minutes, forKey: .minutes)
  }
  private enum Keys: String, CodingKey { case range, state, name, description, project, minutes }
}

public struct ActivityQueryAnswer: Encodable, Equatable {
  public var range: TimeRange
  public var dayStartHour: Int
  public var timeZone: String
  public var rows: [ActivityQueryRow]
  public var minutesByState: [String: Int]
  /// Search totals count only the matching rows, so they never stand in for the timeline's figures.
  public var countsMatchesOnly = false
  public var totalMinutes: Int { minutesByState.values.reduce(0, +) }
  /// The timeline's own figures (work, other, distraction, uninterpreted), zeros included,
  /// so a model reads the number the person sees instead of adding states itself.
  public var minutesByTimelineKind: [String: Int] {
    var result = Dictionary(uniqueKeysWithValues: TimelineGridKind.allCases.map { ($0.rawValue, 0) })
    for (state, minutes) in minutesByState {
      let source = state == "uninterpreted" ? SummaryMinuteKind.unsummarized : SummaryMinuteKind(rawValue: state)
      if let kind = source.flatMap(TimelineGridKind.of) { result[kind.rawValue, default: 0] += minutes }
    }
    return result
  }
  public func encode(to encoder: Encoder) throws {
    var box = encoder.container(keyedBy: Keys.self)
    try box.encode(range, forKey: .range); try box.encode(dayStartHour, forKey: .dayStartHour)
    try box.encode(timeZone, forKey: .timeZone); try box.encode(rows, forKey: .rows)
    try box.encode(minutesByState, forKey: .minutesByState)
    if !countsMatchesOnly { try box.encode(minutesByTimelineKind, forKey: .minutesByTimelineKind) }
    try box.encode(totalMinutes, forKey: .totalMinutes)
  }
  private enum Keys: String, CodingKey { case range, dayStartHour, timeZone, rows, minutesByState, minutesByTimelineKind, totalMinutes }
}

/// Summaries and timeline states only. Evidence text has no read port here.
public final class ActivityQueries {
  public static let maximumRangeSeconds = 14 * 86400
  private let storage: ActivityQueryStorage
  private let calendar: Calendar
  private let now: () -> Int
  private let ownBundleID: String
  public init(storage: ActivityQueryStorage, calendar: Calendar = .current,
    ownBundleID: String = "dev.local.ActivityProbe", now: @escaping () -> Int = { Int(Date().timeIntervalSince1970) }) {
    self.storage = storage; self.calendar = calendar; self.ownBundleID = ownBundleID.lowercased(); self.now = now
  }
  public func recentWork(in range: TimeRange) throws -> ActivityQueryAnswer {
    var result = try read(range); result.rows.reverse(); return result
  }
  public func whatWasIDoing(at time: Int, minutes: Int = 20) throws -> ActivityQueryAnswer {
    guard Self.validTime(time), (1...120).contains(minutes) else { throw ActivityQueryError.invalidArguments }
    return try read(TimeRange(time - minutes * 60, time + minutes * 60))
  }
  public func search(_ words: String, in range: TimeRange) throws -> ActivityQueryAnswer {
    let terms = words.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    guard !terms.isEmpty, words.utf8.count <= 256 else { throw ActivityQueryError.invalidArguments }
    var result = try read(range)
    result.rows = result.rows.reversed().filter { row in
      guard row.state != "private" else { return false }
      let text = [row.name, row.description, row.project].compactMap { $0 }.joined(separator: " ").lowercased()
      return terms.allSatisfy { text.contains($0) }
    }
    result.minutesByState = Self.totals(result.rows); result.countsMatchesOnly = true
    return result
  }
  public func timeTotals(in range: TimeRange) throws -> ActivityQueryAnswer {
    var result = try read(range); result.rows = []; return result
  }
  public func daySummary(containing time: Int) throws -> ActivityQueryAnswer {
    guard Self.validTime(time) else { throw ActivityQueryError.invalidArguments }
    return try boundary {
      try storage.withQuerySnapshot {
        let settings = try storage.settings()
        let range = try TimelineDay.range(containing: time, dayStartHour: settings.dayStartHour, calendar: calendar)
        return try project(range, settings: settings)
      }
    }
  }
  private static func validTime(_ time: Int) -> Bool { (-62135596800...253402300799).contains(time) }
  private func boundary<T>(_ body: () throws -> T) throws -> T {
    do { return try body() }
    catch let error as ActivityQueryError { throw error }
    catch { throw ActivityQueryError.unavailable }
  }
  private func read(_ range: TimeRange) throws -> ActivityQueryAnswer {
    try boundary { try storage.withQuerySnapshot { try project(range, settings: storage.settings()) } }
  }
  private func project(_ requested: TimeRange, settings: StorageSettings) throws -> ActivityQueryAnswer {
    guard Self.validTime(requested.start), Self.validTime(requested.end), requested.start < requested.end,
      requested.end - requested.start <= Self.maximumRangeSeconds, Self.validTime(now()) else {
      throw ActivityQueryError.invalidArguments
    }
    func floorMinute(_ value: Int) -> Int { value - ((value % 60 + 60) % 60) }
    let startFloor = floorMinute(requested.start)
    let start = startFloor == requested.start ? startFloor : startFloor + 60
    let end = max(start, min(floorMinute(requested.end), floorMinute(now())))
    let range = TimeRange(start, end)
    guard start < end else {
      return ActivityQueryAnswer(range: requested, dayStartHour: settings.dayStartHour, timeZone: calendar.timeZone.identifier,
        rows: [], minutesByState: [:])
    }
    let minutes = try SummaryTimeline.minutes(in: range, storage: storage)
    let intervals = try storage.intervals(in: range)
    let forgotten = try storage.forgottenRanges(in: range)
    let samples = try storage.samples(in: range)
    let excluded = Set(settings.excludedApps.map { $0.lowercased() }).union([ownBundleID])
    // Excluded, own-app and partly private minutes keep the timeline's kind so every answer
    // counts the same minutes as the timeline; only their names and text stay out.
    var hiddenMinutes = Set(samples.filter { $0.excluded || excluded.contains($0.bundleID.lowercased()) }
      .map { floorMinute($0.ts) })
    for interval in intervals where interval.state == .private {
      for minute in stride(from: max(start, floorMinute(interval.range.start)), to: min(end, interval.range.end), by: 60) {
        hiddenMinutes.insert(minute)
      }
    }
    var rows: [ActivityQueryRow] = []
    for minute in stride(from: start, to: end, by: 60) {
      guard !forgotten.contains(where: { $0.start < minute + 60 && $0.end > minute }),
        let kind = minutes[minute], kind != .rest else { continue }
      let state = kind == .blank || kind == .unsummarized ? "uninterpreted" : kind.rawValue
      let interval = state == "private" || hiddenMinutes.contains(minute) ? nil : intervals.first {
        $0.state == .named && $0.range.start <= minute && $0.range.end >= minute + 60
      }
      let row = ActivityQueryRow(range: TimeRange(minute, minute + 60), state: state,
        name: interval.map { Redaction.apply($0.name).text },
        description: interval.map { Redaction.apply($0.description).text },
        project: interval.map { Redaction.apply($0.project).text })
      if let last = rows.last, last.range.end == minute, last.state == row.state,
        last.name == row.name, last.description == row.description, last.project == row.project {
        rows[rows.count - 1].range.end = minute + 60
      } else { rows.append(row) }
    }
    return ActivityQueryAnswer(range: requested, dayStartHour: settings.dayStartHour, timeZone: calendar.timeZone.identifier,
      rows: rows, minutesByState: Self.totals(rows))
  }
  private static func totals(_ rows: [ActivityQueryRow]) -> [String: Int] {
    rows.reduce(into: [:]) { $0[$1.state, default: 0] += $1.minutes }
  }
}
