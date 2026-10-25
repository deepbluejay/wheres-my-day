import Core
import Foundation
import Inbound
import XCTest

final class AXProbeWorkerTests: XCTestCase {
  private func waitUntilIdle(_ worker: MacAXProbeWorker) {
    let deadline = Date().addingTimeInterval(1)
    while worker.isBusy && Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
    XCTAssertFalse(worker.isBusy)
  }
  private func request() -> AXProbeRequest {
    AXProbeRequest(run: AXProbeRun(start: Int(Date().timeIntervalSince1970)), time: Int(Date().timeIntervalSince1970),
      window: WindowIdentity(processID: 99, windowID: 1), bundleID: "invented.editor", isBrowser: false)
  }
  func testUnavailablePreflightNeverInvokesProvider() {
    let done = expectation(description: "permission")
    let worker = MacAXProbeWorker(preflight: { false }, read: { _, _ in XCTFail("No provider without permission"); return AXProbeResult() })
    worker.acquire(request(), permitted: { true }) { result in XCTAssertEqual(result.status, .permission); done.fulfill() }
    wait(for: [done], timeout: 1)
  }
  func testHungIPCWatchdogBusyNoReplacementAndLateReplyIgnored() {
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    let watchdog = expectation(description: "watchdog"), busy = expectation(description: "busy")
    let late = expectation(description: "no late delivery"); late.isInverted = true
    let worker = MacAXProbeWorker(preflight: { true }, read: { _, _ in
      entered.signal(); release.wait()
      var result = AXProbeResult(status: .completed); result.text = "Invented late text"; return result
    }, watchdogSeconds: 0.05)
    let request = request(); var deliveries = 0
    worker.acquire(request, permitted: { true }) { result in
      deliveries += 1
      if deliveries > 1 { late.fulfill() }
      XCTAssertEqual(result.status, .watchdog); XCTAssertEqual(result.text, ""); watchdog.fulfill()
    }
    XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
    worker.acquire(request, permitted: { true }) { result in XCTAssertEqual(result.status, .busy); busy.fulfill() }
    wait(for: [watchdog, busy], timeout: 5)
    worker.invalidate() // Returns immediately, without waiting for the blocked provider.
    release.signal()
    wait(for: [late], timeout: 0.1)
    let disabled = expectation(description: "disabled")
    worker.acquire(request, permitted: { true }) { result in XCTAssertEqual(result.status, .cancelled); disabled.fulfill() }
    wait(for: [disabled], timeout: 1)
  }
  func testThreeRealFailuresCoolDownSixtySecondsThenRecoverAndSuccessResets() {
    var clock = 100.0, status = AXProbeStatus.messagingFailure
    let worker = MacAXProbeWorker(preflight: { true }, read: { _, _ in AXProbeResult(status: status) }, monotonic: { clock })
    let request = request()
    func acquire(_ expected: AXProbeStatus) {
      let done = expectation(description: expected.rawValue)
      worker.acquire(request, permitted: { true }) { result in XCTAssertEqual(result.status, expected); done.fulfill() }
      wait(for: [done], timeout: 1); waitUntilIdle(worker)
    }
    for _ in 0..<3 { acquire(.messagingFailure) }
    acquire(.cooldown); clock = 159.999; acquire(.cooldown)
    clock = 160; status = .completed; acquire(.completed)
    status = .messagingFailure
    acquire(.messagingFailure); acquire(.messagingFailure)
    status = .empty; acquire(.empty)
    status = .messagingFailure; acquire(.messagingFailure)
  }
  func testPersistentPolicyOwnsFailureStreakWithoutASecondWorkerCooldown() {
    let worker = MacAXProbeWorker(preflight: { true }, read: { _, _ in AXProbeResult(status: .messagingFailure) })
    let request = request()
    for _ in 0..<6 {
      let done = expectation(description: "persistent policy admits read")
      worker.acquire(request, permitted: { true }, failurePolicyInStore: true) { result in
        XCTAssertEqual(result.status, .messagingFailure); done.fulfill()
      }
      wait(for: [done], timeout: 1); waitUntilIdle(worker)
    }
    let cooldown = expectation(description: "persistent cooldown propagated")
    worker.acquire(request, permitted: { true }, begin: { .cooldown }, failurePolicyInStore: true) { result in
      XCTAssertEqual(result.status, .cooldown); cooldown.fulfill()
    }
    wait(for: [cooldown], timeout: 1); waitUntilIdle(worker)
  }
  func testIPCLimitAndCancellationNeverCreateCooldownOrDisablePID() {
    for status in [AXProbeStatus.ipcLimit, .cancelled, .deadline] {
      let worker = MacAXProbeWorker(preflight: { true }, read: { _, _ in AXProbeResult(status: status) })
      let request = request()
      for _ in 0..<4 {
        let done = expectation(description: "local stop")
        worker.acquire(request, permitted: { true }) { result in XCTAssertEqual(result.status, status); XCTAssertNil(result.error); done.fulfill() }
        wait(for: [done], timeout: 1); waitUntilIdle(worker)
      }
    }
  }

}
