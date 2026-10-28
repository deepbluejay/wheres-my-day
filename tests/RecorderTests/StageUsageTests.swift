import Core
import Foundation
@testable import Shell
@testable import Storage
import XCTest

final class StageUsageTests: XCTestCase {
  /// The last figures cover one maintenance tick; the totals keep growing.
  func testStageUsageRollsTheLastTickAndKeepsTotals() {
    let usage = StageUsage()
    usage.record("invented", cpuNanoseconds: 3_000_000, items: ["reads": 2])
    usage.record("invented", cpuNanoseconds: 1_000_000, items: ["reads": 1])
    var stage = usage.roll(at: 10).stages["invented"]!
    XCTAssertEqual(stage.lastCPUNanoseconds, 4_000_000); XCTAssertEqual(stage.lastRuns, 2); XCTAssertEqual(stage.last, ["reads": 3])
    usage.record("invented", cpuNanoseconds: 5_000_000, items: ["skipped": 4])
    stage = usage.roll(at: 20).stages["invented"]!
    XCTAssertEqual(stage.lastCPUNanoseconds, 5_000_000); XCTAssertEqual(stage.lastRuns, 1); XCTAssertEqual(stage.last, ["skipped": 4])
    XCTAssertEqual(stage.totalCPUNanoseconds, 9_000_000); XCTAssertEqual(stage.totalRuns, 3); XCTAssertEqual(stage.total, ["reads": 3, "skipped": 4])
    // A stage that did nothing in a tick shows zero for it.
    stage = usage.roll(at: 30).stages["invented"]!
    XCTAssertEqual(stage.lastRuns, 0); XCTAssertEqual(stage.last, [:]); XCTAssertEqual(stage.totalRuns, 3)
    // Thread CPU is measured around the body.
    _ = usage.measure("spin") { items -> Int in
      items["loops"] = 1
      var value = 0
      for index in 0..<2_000_000 { value &+= index }
      return value
    }
    XCTAssertGreaterThan(usage.roll(at: 40).stages["spin"]!.lastCPUNanoseconds, 0)
  }

  /// Each maintenance tick ends by publishing every stage, retention included, and
  /// `status` shows the published figures.
  func testMaintenanceTickPublishesStageUsageThatStatusShows() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = try ActivityStorage(url: root.appendingPathComponent("invented.sqlite"), appDataDirectory: root, databaseScope: .directory(root))
    let usage = StageUsage()
    let published = expectation(description: "usage published")
    var snapshot: StageUsage.Snapshot?
    let clock = FakeClock(), sources = FakeSources(); sources.clock = clock
    let loop = RecorderLoop(clock: clock, input: sources, front: sources, secure: sources, awake: sources,
      screen: sources, storage: storage, maintenanceStorage: storage, ownBundleID: "invented.own",
      maintenanceTasks: [RecorderMaintenanceTask(name: "invented") { _ in usage.measure("invented_stage") { $0["items"] = 7 } }], usage: usage)
    loop.publishUsage = { snapshot = $0; try? storage.saveStageUsage($0); published.fulfill() }
    loop.requestMaintenance()
    wait(for: [published], timeout: 30)
    loop.stop()
    let stages = try XCTUnwrap(snapshot).stages
    XCTAssertEqual(stages["retention"]?.lastRuns, 1)
    XCTAssertNotNil(stages["retention"]?.last["removed"])
    XCTAssertEqual(stages["invented_stage"]?.last, ["items": 7])
    let status = storage.stageUsageStatus()
    XCTAssertTrue(status.contains("stage_invented_stage_last_items=7"), status)
    XCTAssertTrue(status.contains("stage_retention_last_runs=1"), status)
    XCTAssertTrue(status.contains("stage_retention_total_cpu_ms="), status)
  }
}
