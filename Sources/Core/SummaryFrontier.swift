import Foundation

/// Which samples a plan must read when history before `settled` is already known.
/// Times only; the plan over these reads equals `SummaryPolicy.plan` over the whole history.
public enum SummaryFrontier {
  /// An input at `t - margin` still keeps `t` active; one earlier ends just before it.
  public static let margin = RestPolicy.inputAgeSeconds
  /// After a stretch ending at or before a minute boundary `a`, `naturallyEnded` and `endsAtRest`
  /// look only at active ranges starting before `a + 60`.
  public static let spill = 60

  public struct Reads: Equatable {
    /// Sample ranges to read, in order and disjoint.
    public var samples: [TimeRange]
    /// History left unread, passed to the plan as completed ranges.
    public var skipped: [TimeRange]
  }

  /// `active`: active seconds before `settled` as last read, or more. `barriers`: today's forgotten and
  /// completed ranges. nil: plan in full.
  public static func reads(active: [TimeRange], barriers: [TimeRange], start: Int, settled: Int, end: Int) -> Reads? {
    func floorMinute(_ ts: Int) -> Int { ts - ((ts % 60 + 60) % 60) }
    func ceilMinute(_ ts: Int) -> Int { let a = floorMinute(ts); return a == ts ? a : a + 60 }
    guard settled % 60 == 0, settled <= end else { return nil }
    let rounded = barriers.map { TimeRange(floorMinute($0.start), ceilMinute($0.end)) }
    guard rounded.allSatisfy({ $0.start <= $0.end }) else { return nil }
    // Active seconds no barrier covers would be stretches; each is read again on every pass.
    let open = subtract(active, merged(rounded.filter { $0.start < $0.end }))
    var windows = merged(open.map { TimeRange(floorMinute($0.start), ceilMinute($0.end)) })
    windows.append(TimeRange(settled, end))
    var kept = [windows[0]]
    for window in windows.dropFirst() {
      let gap = TimeRange(kept[kept.count - 1].end, window.start)
      // The plan must close its call across unread minutes, as a barrier inside does
      // or as an hour without any normalized minute does.
      let closes = gap.end - gap.start >= SummaryPolicy.maximumSeconds
        || rounded.contains { $0.start < gap.end && $0.end > gap.start }
      if gap.start < gap.end && closes { kept.append(window) }
      else { kept[kept.count - 1].end = max(kept[kept.count - 1].end, window.end) }
    }
    var skipped: [TimeRange] = kept[0].start > start ? [TimeRange(start, kept[0].start)] : []
    for (a, b) in zip(kept, kept.dropFirst()) { skipped.append(TimeRange(a.end, b.start)) }
    // Across a gap shorter than spill + margin the reads meet, so every sample there is read.
    let samples = merged(kept.enumerated().map { index, window in
      TimeRange(window.start - margin, index == kept.count - 1 ? end : window.end + spill)
    })
    return Reads(samples: samples, skipped: skipped)
  }
  public static func merged(_ ranges: [TimeRange]) -> [TimeRange] {
    var result: [TimeRange] = []
    for range in ranges.sorted(by: { $0.start < $1.start }) where range.start < range.end {
      if let last = result.last, range.start <= last.end { result[result.count - 1].end = max(last.end, range.end) }
      else { result.append(range) }
    }
    return result
  }
  /// `ranges` minus `covered`; both sorted by start, `covered` merged.
  public static func subtract(_ ranges: [TimeRange], _ covered: [TimeRange]) -> [TimeRange] {
    var result: [TimeRange] = [], first = 0
    for range in ranges {
      while first < covered.count && covered[first].end <= range.start { first += 1 }
      var cursor = range.start, index = first
      while index < covered.count && covered[index].start < range.end {
        if cursor < covered[index].start { result.append(TimeRange(cursor, covered[index].start)) }
        cursor = max(cursor, covered[index].end); index += 1
      }
      if cursor < range.end { result.append(TimeRange(cursor, range.end)) }
    }
    return result
  }
  public static func clipped(_ ranges: [TimeRange], to bound: TimeRange) -> [TimeRange] {
    ranges.compactMap { range in
      let clipped = TimeRange(max(range.start, bound.start), min(range.end, bound.end))
      return clipped.start < clipped.end ? clipped : nil
    }
  }
}
