import Core
import Foundation
import XCTest
@testable import Inbound

private extension SourceReading {
  var absence: SourceAbsence? { if case .absent(let reason) = self { return reason }; return nil }
}
private final class InventedScreenDriver: AXProbeScreenDriver {
  var trusted = true
  var pending: [(requested: (() -> Void)?, returned: (() -> Void)?, completion: (SourceReading<String>) -> Void)] = []
  func preflight() -> Bool { trusted }
  func capture(window: WindowIdentity, permitted: @escaping (CaptureCheck) -> Bool,
    requested: (() -> Void)?, returned: (() -> Void)?, completion: @escaping (SourceReading<String>) -> Void) {
    guard permitted(.beforeImage) else { completion(.absent(.policyRefused)); return }
    pending.append((requested, returned, completion))
    requested?()
  }
}
final class AXProbePairFlightTests: XCTestCase {
  private func request() -> AXProbeRequest {
    AXProbeRequest(run: AXProbeRun(start: Int(Date().timeIntervalSince1970)), time: 100,
      window: WindowIdentity(processID: 99, windowID: 1), bundleID: "invented.editor", isBrowser: false)
  }
  func testArmOrderingsClockCallbacksAndOrdinaryDeliveryNeverWaitsForAX() {
    for axFirst in [true, false] {
      var clock = 100.0, pairs: [AXProbePair] = [], ordinary: [String] = []
      let flight = AXProbePairFlight(request: request(), permitted: { true }, ordinaryPermitted: { true },
        watchdogOCR: { _, _ in XCTFail() }, refused: { XCTFail() }, now: { clock }, completion: { pairs.append($0) })
      flight.imageRequested(); clock = 100.1; flight.imageReturned()
      var ax = AXProbeResult(status: .completed); ax.start = 100; ax.end = 100.2; ax.text = "Invented AX"
      if axFirst { flight.axFinished(ax) }
      clock = 100.4
      ordinary.append("Invented OCR")
      flight.ocrFinished(.value("Invented OCR"))
      XCTAssertEqual(ordinary, ["Invented OCR"])
      if !axFirst { XCTAssertTrue(pairs.isEmpty); flight.axFinished(ax) }
      XCTAssertEqual(pairs.count, 1); XCTAssertEqual(pairs[0].imageRequest, 100)
      XCTAssertEqual(pairs[0].imageReturn, 100.1); XCTAssertEqual(pairs[0].ocrCompletion, 100.4)
      XCTAssertEqual(pairs[0].ocr, ordinary[0])
      flight.axFinished(ax); flight.ocrFinished(.value("Invented duplicate"))
      XCTAssertEqual(pairs.count, 1)
    }
  }
  func testEmptyFailureBusySupersededAndBeforeImageRefusal() {
    let cases: [(SourceReading<String>, String)] = [(.value(""), "empty"), (.absent(.failed), "failed"),
      (.absent(.busy), "busy"), (.absent(.superseded), "superseded")]
    for (reading, status) in cases {
      var pair: AXProbePair?
      let flight = AXProbePairFlight(request: request(), permitted: { true }, ordinaryPermitted: { true },
        watchdogOCR: { _, _ in XCTFail() }, refused: { XCTFail() }, completion: { pair = $0 })
      flight.ocrFinished(reading)
      XCTAssertEqual(pair?.ocrStatus, status); XCTAssertNil(pair?.imageRequest)
    }
    let driver = InventedScreenDriver()
    let ax = expectation(description: "AX survives ordinary before-image refusal")
    let worker = MacAXProbeWorker(preflight: { true }, read: { _, _ in
      var result = AXProbeResult(status: .completed); result.text = "Invented AX"; return result
    })
    let source = MacScreenTextSource(driver: driver, probeWorker: worker)
    var refused = 0, ordinary = 0
    source.captureText(window: request().window, probe: request(), permitted: { _ in false }, probePermitted: { true },
      probeBegin: { nil }, probeEnd: { _ in }, probeWatchdogOCR: { _, _ in XCTFail() },
      probeRefused: { refused += 1 }, probeCompletion: { pair in
        XCTAssertEqual(pair.ax.status, .completed); XCTAssertEqual(pair.ax.text, "Invented AX"); ax.fulfill()
      }, completion: { reading in
        XCTAssertEqual(reading.absence, .policyRefused); ordinary += 1
      })
    wait(for: [ax], timeout: 1)
    XCTAssertEqual(ordinary, 1); XCTAssertEqual(refused, 0); XCTAssertTrue(driver.pending.isEmpty)
  }
  func testDisableAndWatchdogWhileOCRPendingKeepOrdinaryDelivery() {
    for watchdog in [false, true] {
      var allowed = true, refused = 0, diagnostics = 0
      let flight = AXProbePairFlight(request: request(), permitted: { allowed }, ordinaryPermitted: { true },
        watchdogOCR: { pair, accepted in
          XCTAssertTrue(accepted); XCTAssertEqual(pair.ocr, "Invented OCR"); diagnostics += 1
        }, refused: { refused += 1 }, completion: { _ in XCTFail() })
      flight.imageRequested(); flight.imageReturned()
      flight.axFinished(AXProbeResult(status: watchdog ? .watchdog : .completed))
      allowed = false
      var ordinary: String?
      ordinary = "Invented OCR"; flight.ocrFinished(.value(ordinary!))
      XCTAssertEqual(ordinary, "Invented OCR")
      XCTAssertEqual(diagnostics, watchdog ? 1 : 0); XCTAssertEqual(refused, watchdog ? 0 : 1)
    }
  }
  func testNativeAdapterPreflightBusySupersededAndLateRecognitionPreserveProductPath() {
    let driver = InventedScreenDriver(); var clock = 100.0
    let source = MacScreenTextSource(driver: driver, uptime: { clock })
    let window = request().window
    var deliveries: [String] = []
    func capture() { source.captureText(window: window, permitted: { _ in true }) { reading in
      deliveries.append(reading.value ?? reading.absence?.rawValue ?? "unknown")
    } }
    driver.trusted = false; capture(); XCTAssertEqual(deliveries, ["permission"])
    driver.trusted = true; capture(); capture()
    XCTAssertEqual(deliveries, ["permission", "busy"]); XCTAssertEqual(driver.pending.count, 1)
    clock += 31; capture()
    XCTAssertEqual(deliveries, ["permission", "busy", "superseded"])
    driver.pending[0].completion(.value("Invented stale OCR"))
    driver.pending[1].returned?();driver.pending[1].completion(.value("Invented current OCR"))
    XCTAssertEqual(deliveries, ["permission", "busy", "superseded", "Invented current OCR"])
  }
}
