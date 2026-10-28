import Core
import Darwin
import Foundation
@testable import Inbound
@testable import Shell
@testable import Storage
import XCTest

extension GitCollectionTests {
  private static func cpuSeconds(_ who: Int32) -> Double {
    var usage = rusage()
    getrusage(who, &usage)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
  }

  /// Owner-scale first start, measured only with ACTIVITYPROBE_OWNER_SCALE=1. Invented
  /// Claude logs: 163 sources (one with 6,147 events) holding 106,313 timestamped cwd
  /// events over 26 invented repositories, plus 2,000 extra files: 2,163 checkpoints,
  /// stripped of the Git fields as at main-15 adoption. Maintenance ticks repeat until the
  /// Git queue reads nothing new, then the recorder restarts once.
  func testOwnerScaleFirstStartCost() throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["ACTIVITYPROBE_OWNER_SCALE"] == "1")
    let logs = root.appendingPathComponent(AgentLogTool.claude.defaultHomeName).appendingPathComponent(AgentLogTool.claude.logsFolder)
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    let repositories = try (0..<26).map { index -> URL in
      let folder = root.appendingPathComponent("invented-owner-repo-\(index)")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try git(["init", "-b", "main"], in: folder)
      try commit("Invented change \(index)", in: folder)
      return folder
    }
    let base = now - 2_000_000
    var sizes = [6147] + Array(repeating: 0, count: 162)
    let remaining = 106_313 - 6147
    for index in 1..<163 { sizes[index] = remaining / 162 + (index <= remaining % 162 ? 1 : 0) }
    var offset = 0
    for (source, size) in sizes.enumerated() {
      var bytes = Data()
      for index in 0..<size {
        let record: [String: Any] = ["type": "assistant", "timestamp": base + offset + index, "sessionId": "invented-owner-\(source)-\(index / 500)",
          "cwd": repositories[(source + index / 400) % 26].path, "message": ["role": "assistant", "content": "Invented activity"]]
        bytes += try JSONSerialization.data(withJSONObject: record) + Data([10])
      }
      offset += size
      try bytes.write(to: logs.appendingPathComponent("invented-owner-\(source).jsonl"))
    }
    for extra in 0..<2000 {
      let record: [String: Any] = ["type": "assistant", "sessionId": "invented-owner-extra-\(extra)", "message": ["role": "assistant", "content": "Invented"]]
      try (JSONSerialization.data(withJSONObject: record) + Data([10])).write(to: logs.appendingPathComponent("invented-owner-extra-\(extra).jsonl"))
    }
    let reader = ClaudeAgentLogReader(userHome: root.path, processes: InventedProcesses(), appDataDirectory: root)
    let ingestStart = ProcessInfo.processInfo.systemUptime
    let plain = AgentLogTask(reader: reader, storage: store)
    try work { try plain.scan(at: self.now) }
    try store.connection.run("UPDATE log_positions SET state=json_remove(state,'$.cwdObservedAt','$.cwdSession','$.gitOwnershipAuthority')")
    let ingest = ProcessInfo.processInfo.systemUptime - ingestStart
    XCTAssertEqual(try count("agent_log_events", "timestamp_known=1"), 106_313 + 0)
    XCTAssertEqual(try count("log_positions"), 2163)

    func measure(_ label: String, firstTick: Int) throws {
      let logsTask = AgentLogTask(reader: reader, storage: store, git: task)
      let cpu = Self.cpuSeconds(RUSAGE_SELF), children = Self.cpuSeconds(RUSAGE_CHILDREN)
      let began = ProcessInfo.processInfo.systemUptime
      var ticks = 0, lastRows = -1, scanErrors = 0
      while ticks < 8 {
        let time = firstTick + ticks * 300
        // A scan with a failed file throws; the file is retried at the next tick.
        do { try work { try logsTask.scan(at: time) } } catch { scanErrors += 1 }
        task.backfill(at: time)
        task.waitForBackfill()
        ticks += 1
        if task.backfillRows == lastRows { break }
        lastRows = task.backfillRows
      }
      let wall = ProcessInfo.processInfo.systemUptime - began
      let used = Self.cpuSeconds(RUSAGE_SELF) - cpu, git = Self.cpuSeconds(RUSAGE_CHILDREN) - children
      print("GIT-OWNER-SCALE \(label) ticks=\(ticks) wall=\(wall) cpu=\(used) gitChildCpu=\(git) cpuPercent=\(100 * (used + git) / wall) rows=\(task.backfillRows) offers=\(task.backfillOffers) abortedPasses=\(task.backfillFailures) scanErrors=\(scanErrors) fileFailures=\(logsTask.health.fileFailures) folders=\(try count("git_working_folders")) linkedRepos=\(try count("git_repositories"))")
    }
    print("GIT-OWNER-SCALE ingestWithoutGit=\(ingest)")
    try measure("first-start", firstTick: now + 300)
    task.stop()
    let done = DispatchSemaphore(value: 0); task.finish { done.signal() }; done.wait()
    task = nil; store = nil
    store = try ActivityStorage(url: root.appendingPathComponent("invented.sqlite"), appDataDirectory: root, databaseScope: .directory(root))
    task = GitCollectionTask(storage: store, secureInput: { false }, scratchDirectory: root)
    try measure("restart", firstTick: now + 6000)
  }
}
