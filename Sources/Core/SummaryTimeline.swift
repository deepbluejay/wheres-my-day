import Foundation

public protocol SummaryTimelineReader: SampleReader, IntervalReader, ModelCallReader, ForgottenRangeReader {}

public enum SummaryMinuteKind: String, CaseIterable {
  // Pending input is unsummarized; pending quiet/display-on minutes are blank.
  // Both are uninterpreted activity on the timeline, never rest.
  case work, personal, distraction, `private`, rest, unnamed, unsummarized, blank
}

/// This view reads persisted facts without changing or filling the model's intervals.
public enum SummaryTimeline {
  public static func shortBreakCount(in range: TimeRange, samples: [TimeSample], forgotten: [TimeRange]) -> Int {
    // Count silences ended by input or display-on, starting at an input second.
    let active = samples.filter { $0.hasInput || $0.keepingAwake }
    let seconds = Set(active.map(\.ts)).sorted()
    let inputs = Set(active.filter(\.hasInput).map(\.ts))
    return zip(seconds, seconds.dropFirst()).filter { before, after in
      let gap = after - before
      return before >= range.start && after < range.end && inputs.contains(before)
        && gap >= 301 && gap <= 419
        && !forgotten.contains { $0.start <= after && $0.end > before }
    }.count
  }
  public static func unnamedMiddleQuietMinuteCount(in range: TimeRange, storage: SummaryTimelineReader) throws -> Int {
    let kinds = try minutes(in: range, storage: storage)
    let calls = try storage.modelCalls(overlapping: range).filter { !$0.pending && $0.succeeded && $0.tableFacts != nil }
    var quiet = Set<Int>()
    for call in calls where call.range.start < range.end && call.range.end > range.start {
      guard let table = call.tableFacts else { continue }
      let active = Set(table.activeMinutes)
      for span in table.sentRanges {
        let measured = active.filter { $0 >= span.start && $0 < span.end }
        guard let first = measured.min(), let last = measured.max() else { continue }
        for minute in stride(from: first + 60, to: last, by: 60)
          where kinds[minute] == .unnamed && !active.contains(minute) { quiet.insert(minute) }
      }
    }
    return quiet.count
  }
  public static func minutes(in range: TimeRange, storage: SummaryTimelineReader) throws -> [Int: SummaryMinuteKind] {
    guard range.start < range.end else { return [:] }
    func floorMinute(_ ts: Int) -> Int { ts - ((ts % 60 + 60) % 60) }
    let start = floorMinute(range.start), endFloor = floorMinute(range.end)
    let range = TimeRange(start, endFloor == range.end ? endFloor : endFloor + 60)
    // Calls can finish later than the visible range. Read their full spans so a clipped
    // view cannot mistake the middle of a quiet run for its end.
    let completed = try storage.modelCalls(overlapping: range).filter { !$0.pending && $0.succeeded }
    let facts = TimeRange(min(range.start, completed.map(\.range.start).min() ?? range.start) - (RestPolicy.inputAgeSeconds + 1),
      max(range.end, completed.map(\.range.end).max() ?? range.end) + 60)
    let samples = try storage.samples(in: facts)
    let intervals = try storage.intervals(in: facts)
    let forgotten = try storage.forgottenRanges(in: facts)
    let inputs = Set(samples.filter(\.hasInput).map { floorMinute($0.ts) })
    let active = Set(samples.filter { $0.hasInput || $0.keepingAwake }.map { floorMinute($0.ts) })
    var window = Set<Int>()
    for sample in samples where sample.hasInput || sample.keepingAwake {
      let end = sample.ts + (sample.hasInput ? RestPolicy.inputAgeSeconds + 1 : 1)
      for minute in stride(from: floorMinute(sample.ts), to: end, by: 60) { window.insert(minute) }
    }
    func unavailable(_ minute: Int) -> Bool {
      forgotten.contains { $0.start < minute + 60 && $0.end > minute }
        || intervals.contains { $0.state == .private && $0.range.start < minute + 60 && $0.range.end > minute }
    }
    var restTail = Set<Int>()
    var storedRest = Set<Int>()
    for call in completed {
      if let table = call.tableFacts {
        storedRest.formUnion(table.restMinutes)
        continue
      }
      // Imported or older calls have no sent-table facts; keep their legacy reconstruction.
      // A call ending at an hour, request, private or deleted boundary has no rest line.
      var leadsToRest = !window.contains(call.range.end) && !unavailable(call.range.end)
      for minute in stride(from: call.range.end - 60, through: call.range.start, by: -60) {
        if unavailable(minute) { leadsToRest = false }
        else if !window.contains(minute) { leadsToRest = true }
        else if active.contains(minute) { leadsToRest = false }
        else if leadsToRest { restTail.insert(minute) }
      }
    }
    var result: [Int: SummaryMinuteKind] = [:]
    for minute in stride(from: range.start, to: range.end, by: 60) {
      if forgotten.contains(where: { $0.start < minute + 60 && $0.end > minute }) {
        result[minute] = .rest
      } else if let interval = intervals.first(where: { $0.range.start <= minute && $0.range.end >= minute + 60 }) {
        result[minute] = interval.state == .private ? .private
          : interval.kind.flatMap { SummaryMinuteKind(rawValue: $0.rawValue) } ?? .unnamed
      } else if let call = completed.first(where: { $0.range.start <= minute && $0.range.end >= minute + 60 }) {
        let isRest = call.tableFacts != nil ? storedRest.contains(minute) : !window.contains(minute) || restTail.contains(minute)
        result[minute] = isRest ? .rest : .unnamed
      } else if inputs.contains(minute) {
        result[minute] = .unsummarized
      } else {
        result[minute] = window.contains(minute) ? .blank : .rest
      }
    }
    return result
  }
}
