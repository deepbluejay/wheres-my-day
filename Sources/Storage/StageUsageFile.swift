import Core
import Foundation

/// Per-stage CPU and item counts sit beside the database, like the collection health
/// counts: numbers and stage names only, rewritten once per maintenance tick and, while a
/// stage runs long, at most once per StageUsage.progressInterval.
extension ActivityStorage {
  private var stageUsageLeaf: String { url.lastPathComponent + ".stage-usage" }
  public func saveStageUsage(_ snapshot: StageUsage.Snapshot) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    try atomicCollectionWrite(encoder.encode(snapshot), leaf: stageUsageLeaf, directory: OperationalDirectory(url.deletingLastPathComponent()))
  }
  public func stageUsage() throws -> StageUsage.Snapshot? {
    guard let data = try OperationalDirectory(url.deletingLastPathComponent()).readStrict(stageUsageLeaf) else { return nil }
    return try JSONDecoder().decode(StageUsage.Snapshot.self, from: data)
  }
  /// `stage_<name>_last_cpu_ms` covers the latest maintenance tick; `_total_` the time since
  /// the recorder started, as do the `front_` counts. `_running_` is a run not finished yet,
  /// as of its latest checkpoint, and is in neither.
  public func stageUsageStatus() -> String {
    let read: StageUsage.Snapshot?
    do { read = try stageUsage() } catch { return "stage_usage_unreadable=1" }
    let counts = read?.counts ?? [:]
    let front = FrontApplicationCount.allCases.map { "\($0.rawValue)=\(counts[$0.rawValue] ?? 0)" }
    guard let snapshot = read else { return (["stage_usage_at=0"] + front).joined(separator: " ") }
    var output = ["stage_usage_at=\(snapshot.time)"] + front
    for name in snapshot.stages.keys.sorted() {
      let stage = snapshot.stages[name]!
      output.append("stage_\(name)_last_cpu_ms=\(stage.lastCPUNanoseconds / 1_000_000) stage_\(name)_last_runs=\(stage.lastRuns)")
      for item in Set(stage.last.keys).union(stage.total.keys).sorted() {
        output.append("stage_\(name)_last_\(item)=\(stage.last[item] ?? 0)")
      }
      output.append("stage_\(name)_total_cpu_ms=\(stage.totalCPUNanoseconds / 1_000_000) stage_\(name)_total_runs=\(stage.totalRuns)")
      for item in stage.total.keys.sorted() { output.append("stage_\(name)_total_\(item)=\(stage.total[item]!)") }
      if let running = stage.running {
        output.append("stage_\(name)_running_cpu_ms=\(running.cpuNanoseconds / 1_000_000) stage_\(name)_running_since=\(running.since) stage_\(name)_running_at=\(running.at)")
        for item in running.items.keys.sorted() { output.append("stage_\(name)_running_\(item)=\(running.items[item]!)") }
      }
    }
    return output.joined(separator: " ")
  }
}
