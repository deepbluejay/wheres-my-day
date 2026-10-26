import Core
import Foundation
import Shell
import XCTest

@testable import Storage

extension RecorderFixTests {
  func testInterruptedAddressWalkCannotBeRememberedAsAMiss() {
    XCTAssertFalse(AddressCachePolicy.canReuse(sameTitle: true, finished: false))
    XCTAssertFalse(AddressCachePolicy.canReuse(sameTitle: true, finished: true))
    XCTAssertTrue(AddressCachePolicy.canReuse(sameTitle: true, finished: true, age: 2.9))
    XCTAssertFalse(AddressCachePolicy.canReuse(sameTitle: true, finished: true, age: 3))
    XCTAssertFalse(AddressCachePolicy.canReuse(sameTitle: false, finished: true))
  }
  func testUnknownInputTicksHaveTheirOwnCountWithoutRows() throws {
    sources.input = .absent(.permission)
    for now in 10000...10400 { tick(now) }
    loop.flush()
    XCTAssertEqual(loop.health.inputUnavailableTicks, 401)
    XCTAssertEqual(loop.health.droppedSeconds, 0)
    XCTAssertEqual(try base.samples(in: all), [])
  }
  func testBackwardClockForgetsLastInputEvenAfterPassingItsOldTime() throws {
    tick(10000)
    sources.input = .value(InputCounts())
    tick(9990)
    tick(10001)
    loop.flush()
    XCTAssertEqual(try base.samples(in: all).map(\.ts), [10000])
  }
  func testSecondTickAfterRestWritesInThatSecond() throws {
    sources.input = .value(InputCounts())
    tick(10000)
    sources.input = .value(InputCounts(keys: 7))
    tick(10000)
    loop.flush()
    XCTAssertEqual(try base.samples(in: all).map(\.ts), [10000])
    XCTAssertEqual(try base.samples(in: all).map(\.keys), [7])
    XCTAssertEqual(loop.health.refusedSeconds, 0)
  }
  func testUnreadableSettingsCountsOnlyRecentKnownInput() throws {
    sources.input = .value(InputCounts())
    store.failSettings = true
    tick(10000)
    XCTAssertEqual(loop.health.droppedSeconds, 0)
    sources.input = .value(InputCounts(keys: 1))
    tick(10001)
    sources.input = .value(InputCounts())
    tick(10301)
    tick(10302)
    XCTAssertEqual(loop.health.droppedSeconds, 2)
  }
  func testCarriedInputDoesNotPermitCaptureAndPauseClearsIt() throws {
    tick(10000)
    sources.input = .value(InputCounts(keys: 7))
    tick(10000)
    sources.input = .value(InputCounts())
    sources.front.window = WindowIdentity(processID: 10, windowID: 22)
    tick(10001)
    XCTAssertEqual(sources.requested.count, 1)
    loop.flush()
    sources.input = .value(InputCounts(keys: 9))
    tick(10001)
    try base.saveSettings(StorageSettings(pausedUntil: 10003))
    sources.input = .value(InputCounts())
    tick(10002)
    tick(10003)
    loop.flush()
    XCTAssertEqual(try base.samples(in: all).map(\.keys), [1, 7, 0])
  }
  func testDeletionClearsDeliveredInboxBeforeItCanBeQueued() throws {
    sources.ignorePermission = true
    sources.deferDelivery = true
    tick(10000)
    sources.delayedDelivery?()
    XCTAssertEqual(loop.pendingCaptureCompletions, 1)
    try delete(TimeRange(10000, 10001))
    sources.input = .value(InputCounts())
    tick(10001)
    loop.flush()
    XCTAssertEqual(loop.pendingCaptureCompletions, 0)
    XCTAssertEqual(loop.health.droppedCaptures, 1)
    XCTAssertEqual(loop.health.refusedCaptures, 0)
  }
  func testUnreadableImageAndDeliverySettingsAreNotPolicyRefusals() throws {
    sources.deferCompletion = true
    tick(10000)
    store.failSettings = true
    sources.delayed?()
    store.failSettings = false
    loop.flush()
    XCTAssertEqual(loop.health.settingsUnreadableCaptures, 1)
    sources.deferCompletion = false
    sources.ignorePermission = true
    sources.deferDelivery = true
    tick(10015)
    store.failSettings = true
    sources.delayedDelivery?()
    store.failSettings = false
    loop.flush()
    XCTAssertEqual(loop.health.settingsUnreadableCaptures, 2)
    XCTAssertEqual(loop.health.policyRefusedCaptures, 0)
  }
  func testBusyScreenClearsWhenFlightEndsUnsuccessfully() throws {
    sources.screen = .absent(.busy)
    tick(10000)
    loop.flush()
    XCTAssertEqual(loop.health.absentSources[.screen], .busy)
    sources.screen = .absent(.superseded)
    tick(10015)
    loop.flush()
    XCTAssertNil(loop.health.absentSources[.screen])
    XCTAssertEqual(loop.health.supersededCaptures, 1)
    XCTAssertEqual(loop.health.policyRefusedCaptures, 0)
  }
  func testRunningMaintenanceDoesNotQueueAnotherList() throws {
    let started = expectation(description: "task started")
    let done = expectation(description: "queue drained")
    let gate = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var starts = 0
    let task = RecorderMaintenanceTask(name: "invented blocked") { _ in
      lock.lock()
      starts += 1
      let first = starts == 1
      lock.unlock()
      if first {
        started.fulfill()
        _ = gate.wait(timeout: .now() + 5)
      }
    }
    loop = makeLoop(tasks: [task])
    tick(10000)
    tick(10300)
    wait(for: [started], timeout: 5)
    tick(10600)
    tick(10900)
    gate.signal()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      lock.lock()
      XCTAssertEqual(starts, 1)
      lock.unlock()
      done.fulfill()
    }
    wait(for: [done], timeout: 5)
  }
  func testMaintenanceRunsAfterBackwardClock() throws {
    let first = expectation(description: "first maintenance")
    let backward = expectation(description: "backward maintenance")
    let task = RecorderMaintenanceTask(name: "invented clock") { time in
      if time == 10300 { first.fulfill() }
      if time == 9990 { backward.fulfill() }
    }
    loop = makeLoop(tasks: [task])
    tick(10000)
    tick(10300)
    wait(for: [first], timeout: 5)
    let settled = expectation(description: "completion published")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
      self.tick(9990)
      settled.fulfill()
    }
    wait(for: [settled, backward], timeout: 5)
  }
}
