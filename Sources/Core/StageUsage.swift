import Foundation

/// Thread CPU time and item counts of each background stage, shown by `status`. It only
/// records: nothing reads these numbers to cap, slow or stop any work.
public final class StageUsage {
  public static let shared = StageUsage()
  public struct Stage: Codable, Equatable {
    /// From the end of the previous maintenance tick to the end of the latest one.
    public var lastCPUNanoseconds: UInt64 = 0
    public var lastRuns = 0
    public var last: [String: Int] = [:]
    /// Since the recorder started.
    public var totalCPUNanoseconds: UInt64 = 0
    public var totalRuns = 0
    public var total: [String: Int] = [:]
    public init() {}
  }
  public struct Snapshot: Codable, Equatable {
    public var time: Int
    public var stages: [String: Stage]
    /// Event counts since the recorder started; nil in a file written before they existed.
    public var counts: [String: Int]?
    public init(time: Int, stages: [String: Stage], counts: [String: Int]? = nil) {
      self.time = time; self.stages = stages; self.counts = counts
    }
  }
  private let lock = NSLock()
  private var stages: [String: Stage] = [:]
  private var current: [String: Stage] = [:]
  private var counts: [String: Int] = [:]
  public init() {}
  public static func threadCPU() -> UInt64 { clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) }
  /// Records the calling thread's CPU time for `body`, which may fill in its item counts.
  public func measure<T>(_ name: String, _ body: (inout [String: Int]) throws -> T) rethrows -> T {
    let start = Self.threadCPU()
    var items: [String: Int] = [:]
    defer { record(name, cpuNanoseconds: Self.threadCPU() &- start, items: items) }
    return try body(&items)
  }
  public func record(_ name: String, cpuNanoseconds: UInt64, items: [String: Int] = [:]) {
    lock.lock(); defer { lock.unlock() }
    var run = current[name] ?? Stage(), stage = stages[name] ?? Stage()
    run.lastCPUNanoseconds &+= cpuNanoseconds; run.lastRuns += 1
    stage.totalCPUNanoseconds &+= cpuNanoseconds; stage.totalRuns += 1
    for (item, count) in items {
      run.last[item, default: 0] += count; stage.total[item, default: 0] += count
    }
    current[name] = run; stages[name] = stage
  }
  public func count(_ name: String) {
    lock.lock(); counts[name, default: 0] += 1; lock.unlock()
  }
  /// Ends a maintenance tick: what each stage did since the previous one becomes its last.
  public func roll(at time: Int) -> Snapshot {
    lock.lock(); defer { lock.unlock() }
    for name in stages.keys {
      let run = current[name] ?? Stage()
      stages[name]!.lastCPUNanoseconds = run.lastCPUNanoseconds
      stages[name]!.lastRuns = run.lastRuns
      stages[name]!.last = run.last
    }
    current = [:]
    return Snapshot(time: time, stages: stages, counts: counts)
  }
}

/// How the front application read went, so a macOS change to the front-process call shows in
/// `status`. Counts only.
public enum FrontApplicationCount: String, CaseIterable {
  /// Settled checks of the front-process call against NSWorkspace, and those that disagreed.
  case comparisons = "front_comparisons"
  case disagreements = "front_disagreements"
  /// Gate calls answered on the main thread instead, by cause.
  case missingSymbol = "front_fallback_missing_symbol"
  case error = "front_fallback_error"
  case noIdentity = "front_fallback_no_identity"
  case changed = "front_fallback_changed_during_lookup"
  /// 1 once persistent disagreement turned the call off.
  case disabled = "front_fast_path_disabled"
}
