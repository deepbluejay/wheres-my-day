import Foundation

/// Thread CPU time and item counts of each background stage, shown by `status`. It only
/// records: nothing reads these numbers to cap, slow or stop any work. A finished run counts
/// in `last` and `total`; a run still going shows only in `running`.
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
    /// The run still going, as of its latest checkpoint. Absent between runs.
    public var running: Running?
    public init() {}
  }
  public struct Running: Codable, Equatable {
    public var cpuNanoseconds: UInt64
    public var items: [String: Int]
    /// Wall-clock times of its first and latest checkpoint.
    public var since: Int, at: Int
    public init(cpuNanoseconds: UInt64, items: [String: Int], since: Int, at: Int) {
      self.cpuNanoseconds = cpuNanoseconds; self.items = items; self.since = since; self.at = at
    }
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
  private var rolledAt = 0
  private var progressPublished = Int.min
  /// A checkpoint of a run older than this also publishes, at most this often. The tick's
  /// own publication waits for every task on the maintenance queue, and a stage on that
  /// queue would otherwise never show while it runs.
  public static let progressInterval = 60
  private var progressPublisher: ((Snapshot) -> Void)?
  public init() {}
  public func publishProgress(_ publish: ((Snapshot) -> Void)?) {
    lock.lock(); progressPublisher = publish; lock.unlock()
  }
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
    stage.running = nil
    run.lastCPUNanoseconds &+= cpuNanoseconds; run.lastRuns += 1
    stage.totalCPUNanoseconds &+= cpuNanoseconds; stage.totalRuns += 1
    for (item, count) in items {
      run.last[item, default: 0] += count; stage.total[item, default: 0] += count
    }
    current[name] = run; stages[name] = stage
  }
  /// A run inside `measure` reports what it did so far, as CPU on the measuring thread since
  /// the run began. Its end clears this, and only its end counts in `last` and `total`.
  public func checkpoint(_ name: String, cpuNanoseconds: UInt64, items: [String: Int] = [:], at time: Int = Int(Date().timeIntervalSince1970)) {
    lock.lock()
    var stage = stages[name] ?? Stage()
    let since = stage.running?.since ?? time
    stage.running = Running(cpuNanoseconds: cpuNanoseconds, items: items, since: since, at: time)
    stages[name] = stage
    var due: ((Snapshot) -> Void)?, snapshot: Snapshot?
    if let publish = progressPublisher, time - max(since, progressPublished) >= Self.progressInterval {
      progressPublished = time
      due = publish; snapshot = Snapshot(time: rolledAt, stages: stages, counts: counts)
    }
    lock.unlock()
    if let due, let snapshot { due(snapshot) }
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
    rolledAt = time
    return Snapshot(time: time, stages: stages, counts: counts)
  }
}

/// How the front application read went, so a macOS change to the front-process call shows in
/// `status`. Counts only.
public enum FrontApplicationCount: String, CaseIterable {
  /// Checks of the front-process call against NSWorkspace, and those that disagreed.
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
