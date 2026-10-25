import Core
import Foundation
import Inbound
import XCTest
@testable import Storage

final class AXProbeFinishTests: XCTestCase {
  private func fixture(_ body: (ActivityStorage, ActivityStorage, AXProbeRequest) throws -> Void) throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("invented-ax-finish-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("invented.sqlite")
    let store = try ActivityStorage(url: url, appDataDirectory: root, role: .recorder, databaseScope: .directory(root))
    let writer = try ActivityStorage(url: url, appDataDirectory: root, databaseScope: .directory(root))
    XCTAssertEqual(try store.connection.integer("PRAGMA busy_timeout"), 0)
    let now = Int(Date().timeIntervalSince1970)
    let run = try store.enableAXProbe(at: now)
    let request = AXProbeRequest(run: run, time: now,
      window: WindowIdentity(processID: 99, windowID: 1), bundleID: "invented.editor", isBrowser: false)
    try body(store, writer, request)
  }
  private func waitUntilIdle(_ worker: MacAXProbeWorker) {
    let deadline = Date().addingTimeInterval(1)
    while worker.isBusy && Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
    XCTAssertFalse(worker.isBusy)
  }
  func testActualWorkerReturnsAfterBusyFinishAndMaintenanceRecoversWithoutBegin() throws {
    try fixture { store, writer, request in
      let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
      let done = expectation(description: "returned worker")
      let worker = MacAXProbeWorker(preflight: { true }, read: { _, _ in
        entered.signal(); release.wait(); return AXProbeResult(status: .deadline)
      })
      var ends = 0
      worker.acquire(request, permitted: { true }, begin: {
        do { return try store.beginAXProbe(request, at: request.time) } catch { XCTFail(); return .cancelled }
      }, end: { result in
        ends += 1; store.finishAXProbe(request, result: result, at: request.time)
      }) { result in XCTAssertEqual(result.status, .deadline); done.fulfill() }
      XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
      try writer.connection.transaction {
        release.signal(); wait(for: [done], timeout: 1)
        XCTAssertThrowsError(try store.retryAXProbeFinishes())
      }
      waitUntilIdle(worker)
      try store.retryAXProbeFinishes()
      XCTAssertEqual(ends, 1)
      XCTAssertEqual(try store.connection.integer("SELECT cancelled FROM ax_probe_runs"), 0)
      XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM ax_probe_runs WHERE active_attempt!=''"), 0)
      XCTAssertEqual(try store.connection.integer("SELECT total FROM ax_probe_flow WHERE event='finishStorageFailures'"), 2)
      XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM ax_probe_pid"), 0)
    }
  }
  func testActualStuckWorkerWatchdogRetriesFromMaintenanceAndNeverReplacesWorker() throws {
    try fixture { store, writer, request in
      let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
      let done = expectation(description: "watchdog")
      let worker = MacAXProbeWorker(preflight: { true }, read: { _, _ in
        entered.signal(); release.wait(); return AXProbeResult(status: .completed)
      }, watchdogSeconds: 0.05)
      var ends = 0
      worker.acquire(request, permitted: { true }, begin: {
        do { return try store.beginAXProbe(request, at: request.time) } catch { XCTFail(); return .cancelled }
      }, end: { result in
        ends += 1; store.finishAXProbe(request, result: result, at: request.time)
      }) { result in XCTAssertEqual(result.status, .watchdog); done.fulfill() }
      XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
      try writer.connection.transaction { wait(for: [done], timeout: 5) }
      XCTAssertTrue(worker.isBusy)
      try store.retryAXProbeFinishes()
      XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM ax_probe_runs WHERE reason='watchdog' AND active_attempt!=''"), 1)
      let refused = expectation(description: "disabled without replacement")
      worker.acquire(request, permitted: { true }) { result in
        XCTAssertEqual(result.status, .cancelled); refused.fulfill()
      }
      wait(for: [refused], timeout: 1)
      release.signal(); waitUntilIdle(worker)
      XCTAssertEqual(ends, 1)
      XCTAssertEqual(try store.connection.integer("SELECT total FROM ax_probe_flow WHERE event='watchdog'"), 1)
    }
  }
}
