import Core
import Foundation

/// The shell formats values already counted by Core; it never reads storage.
public struct TimelinePresentation {
  public let day: TimelineDay
  public let strings: TimelineStrings
  public let calendar: Calendar
  public let isToday: Bool
  let entryByCell: [[Int?]]
  let groupByEntry: [Int?]
  let cellsByEntry: [Set<TimelineGridCell>]
  let cellsByGroup: [Set<TimelineGridCell>]

  public init(day: TimelineDay, language: String, resources: URL? = Bundle.main.resourceURL,
    calendar: Calendar = .current, isToday: Bool = true) {
    self.day = day
    self.strings = TimelineStrings(language: language, resources: resources)
    self.calendar = calendar; self.isToday = isToday
    entryByCell = day.columns.map { $0.slots.map(\.entryIndex) }
    var groups = Array<Int?>(repeating: nil, count: day.entries.count)
    for (group, value) in day.groups.enumerated() {
      for entry in value.entryIndices { groups[entry] = group }
    }
    groupByEntry = groups
    var pieces = Array(repeating: Set<TimelineGridCell>(), count: day.entries.count)
    var groupCells = Array(repeating: Set<TimelineGridCell>(), count: day.groups.count)
    for (column, value) in day.columns.enumerated() {
      for (minute, slot) in value.slots.enumerated() {
        guard let entry = slot.entryIndex else { continue }
        let cell = TimelineGridCell(column: column, minute: minute)
        pieces[entry].insert(cell)
        if let group = groups[entry] { groupCells[group].insert(cell) }
      }
    }
    cellsByEntry = pieces
    cellsByGroup = groupCells
  }

  public var headlineDuration: String {
    let total = day.totalMinutes
    if total < 60 { return minutes(total) }
    if total % 60 == 0 { return strings.format(.hours, total / 60) }
    return strings.format(.hoursMinutes, total / 60, total % 60)
  }
  public var headline: String {
    String(format: strings.text(isToday ? .headline : .pastHeadline), locale: Locale(identifier: strings.language), headlineDuration)
  }
  public var headlineAccessibility: String {
    if isToday { return headline }
    let formatter = DateFormatter(); formatter.locale = Locale(identifier: strings.language); formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone; formatter.setLocalizedDateFormatFromTemplate("yMMMMd")
    let date = formatter.string(from: Date(timeIntervalSince1970: Double(day.range.start)))
    return String(format: strings.text(.datedHeadline), locale: Locale(identifier: strings.language), date, headlineDuration)
  }
  public var notices: [TimelineNotice] { day.notices }
  public var recordedKinds: [TimelineGridKind] {
    let totals = day.minutesByKind
    return TimelineGridKind.allCases.filter { totals[$0, default: 0] > 0 }
  }
  public func minutes(_ count: Int) -> String { strings.format(.minutes, count) }
  public func kind(_ kind: TimelineGridKind) -> String {
    let label: TimelineLabel
    switch kind {
    case .work: label = .work
    case .other: label = .other
    case .distraction: label = .distraction
    case .uninterpreted: label = .uninterpreted
    }
    return strings.text(label)
  }
  public func name(_ entry: TimelineEntry) -> String {
    switch entry.state {
    case .private: return strings.text(.privateActivity)
    case .unsummarized, .blank: return strings.text(.uninterpreted)
    default: return entry.name.flatMap { $0.isEmpty ? nil : $0 } ?? strings.text(.unnamed)
    }
  }
  public func timeRange(_ entry: TimelineEntry) -> String {
    func clock(_ time: Int) -> String {
      let parts = calendar.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: Double(time)))
      return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
    return clock(entry.range.start) + "–" + clock(entry.range.end)
  }
  public func detail(_ entry: TimelineEntry) -> String {
    var parts = [timeRange(entry), minutes(entry.minutes)]
    if entry.kind != .uninterpreted { parts.insert(kind(entry.kind), at: 0) }
    return parts.joined(separator: " · ")
  }
  public func hoverDetail(_ entry: TimelineEntry) -> String {
    // Kind has its own fixed-width field above; this line preserves every number.
    let parts = [timeRange(entry), minutes(entry.minutes)]
    return parts.joined(separator: " · ")
  }
  public func name(_ group: TimelineGroup) -> String { name(day.entries[group.entryIndices[0]]) }
  public func detail(_ group: TimelineGroup) -> String {
    let span = TimelineEntry(range: group.range, state: group.state, name: group.name, minutes: group.minutes)
    return [kind(group.kind), minutes(group.minutes), strings.format(.pieces, group.entryIndices.count), timeRange(span)]
      .joined(separator: " · ")
  }
  public func notice(_ notice: TimelineNotice) -> String {
    let label: TimelineLabel
    switch notice.kind {
    case .accessibility: label = .accessibility
    case .inputMonitoring: label = .inputMonitoring
    case .screenRecording: label = .screenRecording
    case .subscription: label = .subscription
    case .fileVaultOff: label = .fileVaultOff
    case .fileVaultUnknown: label = .fileVaultUnknown
    case .backupExclusion: label = .backupExclusion
    case .summaryFailure: label = .summaryFailure
    case .summaryPreparation: label = .summaryPreparation
    case .summaryPaused: label = .summaryPaused
    }
    return strings.text(label)
  }
}

public enum TimelineSquareStyle: Equatable {
  case ink, grey, yellow, outline, blank
  public static func of(_ kind: TimelineGridKind?) -> Self {
    switch kind {
    case .work: return .ink
    case .other: return .grey
    case .distraction: return .yellow
    case .uninterpreted: return .outline
    case nil: return .blank
    }
  }
}

public struct TimelineGridLayout {
  public let rows: [Range<Int>]
  public let squarePitch: Double
  public let squareSide: Double
  public let displayScale: Double
  public let listHighlightStroke: Double
  public var outlineStroke: Double { max(1 / displayScale, squareSide < 3.5 ? 0.5 : 1) }
  public var columnHeight: Double { (squarePitch * Double(TimelineDay.rows) * displayScale).rounded(.up) / displayScale }
  public var nowMarkerY: Double { ((columnHeight + 3) * displayScale).rounded() / displayScale }
  public func origin(at index: Int) -> Double {
    (Double(index) * squarePitch * displayScale).rounded(.down) / displayScale
  }
  var scaleDigitCell: Double { TimelineDigits.cellSize(height: 10.5, scale: displayScale) }
  var scaleDigitWidth: Double { 11 * scaleDigitCell }
  var scaleStripHeight: Double { 7 * scaleDigitCell + 4 }
  func scaleLabelX(at index: Int, width: Double) -> Double {
    max(0, min(width - scaleDigitWidth, origin(at: index)))
  }
  public init(columnCount: Int, width: Double, displayScale: Double = 2) {
    precondition(displayScale > 0 && displayScale.isFinite)
    self.displayScale = displayScale
    func fittedPitch(_ count: Int) -> Double {
      max(2, (width / Double(max(1, count)) * 2).rounded(.down) / 2)
    }
    let minPitch = 3 + 1 / displayScale
    // The supported timeline window floor is 360pt (320pt content after insets).
    // Keep the floor in one row until it no longer fits within supported widths.
    rows = columnCount > 72 && minPitch * Double(columnCount) > width
      ? [0..<72, 72..<columnCount] : [0..<columnCount]
    let longest = max(1, rows.map(\.count).max() ?? 1)
    squarePitch = max(minPitch, fittedPitch(longest))
    // Leave a full device pixel even when snapping adjacent origins shortens their step.
    func side(_ pitch: Double) -> Double {
      min(((pitch - 0.5) * displayScale).rounded(.down),
        (pitch * displayScale).rounded(.down) - 1) / displayScale
    }
    squareSide = side(squarePitch)
    // Preserve the list border from the original half-width grid, independent of band wrapping.
    let previousSide = side(max(minPitch, fittedPitch(columnCount) / 2))
    listHighlightStroke = max(1 / displayScale, previousSide < 3.5 ? 0.5 : 1) + 1 / displayScale
  }
}

/// English keys and compiled language bundles match the app's existing catalog lookup.
public enum TimelineLabel: String, CaseIterable {
  case pastHeadline, datedHeadline, today, previousDay, nextDay, chooseDate, previousMonth, nextMonth, previousYear, nextYear, calendarFailed
  case headline, hours, hoursMinutes, minutes, pieces, work, other, distraction, uninterpreted
  case privateActivity, unnamed, settings, grid, expanded, collapsed
  case accessibility, inputMonitoring, screenRecording, subscription
  case fileVaultOff, fileVaultUnknown, backupExclusion, summaryFailure, summaryPreparation, summaryPaused

  public var key: String {
    switch self {
    case .expanded: return "Expanded"
    case .collapsed: return "Collapsed"
    case .datedHeadline: return "Recorded on %@: %@."
    case .pastHeadline: return "Recorded that day: %@."
    case .today: return "Today"
    case .previousDay: return "Previous day: %@"
    case .nextDay: return "Next day: %@"
    case .chooseDate: return "Choose date: %@"
    case .previousMonth: return "Previous month: %@"
    case .nextMonth: return "Next month: %@"
    case .previousYear: return "Previous year: %@"
    case .nextYear: return "Next year: %@"
    case .calendarFailed: return "Recorded days could not be read. Retry by reopening the calendar."
    case .headline: return "Recorded today: %@."
    case .hours: return "%lld h"
    case .hoursMinutes: return "%lld h %lld min"
    case .minutes: return "%lld min"
    case .pieces: return "Pieces: %lld"
    case .work: return "Work"
    case .other: return "Other"
    case .distraction: return "Distraction"
    case .uninterpreted: return "Not yet interpreted"
    case .privateActivity: return "Private"
    case .unnamed: return "Unnamed activity"
    case .settings: return "Go to settings"
    case .grid: return "One square is one minute; time runs bottom to top in each column."
    case .accessibility: return "Accessibility permission is missing."
    case .inputMonitoring: return "Input Monitoring permission is missing."
    case .screenRecording: return "Screen Recording permission is missing."
    case .subscription: return "Connect your subscription to summarize activity."
    case .fileVaultOff: return "FileVault is off."
    case .fileVaultUnknown: return "FileVault status could not be checked."
    case .backupExclusion: return "Activity storage could not be excluded from backups."
    case .summaryFailure: return "Some activity could not be summarized."
    case .summaryPreparation: return "The summary connection could not be prepared."
    case .summaryPaused: return "Summaries are paused. Settings shows why."
    }
  }
}

public struct TimelineStrings {
  public let language: String
  private let bundle: Bundle?
  public init(language: String, resources: URL?) {
    self.language = language
    bundle = resources.flatMap { Bundle(path: $0.appendingPathComponent(language + ".lproj").path) }
  }
  public func text(_ label: TimelineLabel) -> String {
    bundle?.localizedString(forKey: label.key, value: label.key, table: "Localizable") ?? label.key
  }
  public func format(_ label: TimelineLabel, _ values: Int...) -> String {
    String(format: text(label), locale: Locale(identifier: language), arguments: values.map { Int64($0) })
  }
}
