import ApplicationServices
import Core
import Foundation
import ScreenCaptureKit
import Vision

// Injection keeps native preflight/screenshot/recognition ordering testable without captures or windows.
protocol AXProbeScreenDriver {
  func preflight() -> Bool
  func capture(window: WindowIdentity, permitted: @escaping (CaptureCheck) -> Bool,
    requested: (() -> Void)?, returned: (() -> Void)?, completion: @escaping (SourceReading<String>) -> Void)
}
private struct NativeAXProbeScreenDriver: AXProbeScreenDriver {
  func preflight() -> Bool { CGPreflightScreenCaptureAccess() }
  func capture(window: WindowIdentity, permitted: @escaping (CaptureCheck) -> Bool,
    requested: (() -> Void)?, returned: (() -> Void)?, completion: @escaping (SourceReading<String>) -> Void) {
    Task {
      completion(await MacScreenTextSource.recognize(window: window, permitted: permitted, requested: requested, returned: returned))
    }
  }
}

// Calls may arrive on any thread; ScreenTextFlights owns completions. Recognition runs asynchronously.
public final class MacScreenTextSource: AXProbeScreenSource {
  private let flights = ScreenTextFlights()
  private let probeWorker: MacAXProbeWorker
  private let driver: AXProbeScreenDriver
  private let uptime: () -> Double
  public convenience init() { self.init(driver: NativeAXProbeScreenDriver()) }
  init(driver: AXProbeScreenDriver, probeWorker: MacAXProbeWorker = MacAXProbeWorker(),
    uptime: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
    self.driver = driver; self.probeWorker = probeWorker; self.uptime = uptime
  }
  public func captureText(
    window: WindowIdentity, permitted: @escaping (CaptureCheck) -> Bool,
    completion: @escaping (SourceReading<String>) -> Void
  ) {
    capture(window: window, permitted: permitted, requested: nil, returned: nil, completion: completion)
  }
  public func invalidateProbe() { probeWorker.invalidate() }
  public func captureText(window: WindowIdentity, probe: AXProbeRequest,
    permitted: @escaping (CaptureCheck) -> Bool, probePermitted: @escaping () -> Bool,
    probeBegin: @escaping () -> AXProbeStatus?, probeEnd: @escaping (AXProbeResult) -> Void, probeWatchdogOCR: @escaping (AXProbePair, Bool) -> Void, probeRefused: @escaping () -> Void,
    probeCompletion: @escaping (AXProbePair) -> Void, completion: @escaping (SourceReading<String>) -> Void) {
    let pair = AXProbePairFlight(request: probe, permitted: probePermitted, ordinaryPermitted: { permitted(.beforeDelivery) },
      watchdogOCR: probeWatchdogOCR, refused: probeRefused, completion: probeCompletion)
    pair.axStarted()
    probeWorker.acquire(probe, permitted: probePermitted, begin: probeBegin, end: probeEnd,
      failurePolicyInStore: true, completion: pair.axFinished)
    capture(window: window, permitted: permitted, requested: pair.imageRequested, returned: pair.imageReturned) { reading in
      completion(reading)
      pair.ocrFinished(reading)
    }
  }
  private func capture(window: WindowIdentity, permitted: @escaping (CaptureCheck) -> Bool,
    requested: (() -> Void)?, returned: (() -> Void)?, completion: @escaping (SourceReading<String>) -> Void) {
    guard driver.preflight() else {
      completion(.absent(.permission))
      return
    }
    guard let token = flights.begin(at: uptime(), completion: completion) else { return }
    driver.capture(window: window, permitted: permitted, requested: requested, returned: returned) { result in
      self.flights.finish(token, result: result)
    }
  }
  fileprivate static func recognize(window: WindowIdentity, permitted: (CaptureCheck) -> Bool,
    requested: (() -> Void)?, returned: (() -> Void)?) async
    -> SourceReading<String>
  {
    guard CGPreflightScreenCaptureAccess() else { return .absent(.permission) }
    guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
      let target = content.windows.first(where: {
        $0.windowID == window.windowID && $0.owningApplication?.processID == window.processID
      })
    else { return .absent(.failed) }
    let size = target.frame.size
    guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
      size.width <= 16384, size.height <= 16384
    else { return .absent(.failed) }
    let config = SCStreamConfiguration()
    let scale = min(2.0, 2400.0 / size.width)
    config.width = max(1, Int(size.width * scale))
    config.height = max(1, Int(size.height * scale))
    config.showsCursor = false
    guard permitted(.beforeImage) else { return .absent(.policyRefused) }
    requested?()
    let image: CGImage
    do {
      image = try await SCScreenshotManager.captureImage(
        contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: config)
    } catch { returned?(); return .absent(.failed) }
    returned?()
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = recognitionLanguages(request)
    request.usesLanguageCorrection = true
    guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil else {
      return .absent(.failed)
    }
    let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    return .value(text)
  }
  private static func recognitionLanguages(_ request: VNRecognizeTextRequest) -> [String] {
    let supported = (try? request.supportedRecognitionLanguages()) ?? ["en-US"]
    var picked: [String] = []
    for preferred in Locale.preferredLanguages {
      let base = String(preferred.prefix { $0 != "-" && $0 != "_" })
      if let match = supported.first(where: { $0 == preferred || $0 == base || $0.hasPrefix(base + "-") }),
        !picked.contains(match)
      {
        picked.append(match)
      }
    }
    if supported.contains("en-US"), !picked.contains("en-US") { picked.append("en-US") }
    return picked
  }
}

// Holds only the two in-flight arms; does not delay or modify OCR delivery.
final class AXProbePairFlight {
  private let lock = NSLock()
  private let request: AXProbeRequest
  private let permitted: () -> Bool
  private let refused: () -> Void
  private let ordinaryPermitted: () -> Bool
  private let watchdogOCR: (AXProbePair, Bool) -> Void
  private var completion: ((AXProbePair) -> Void)?
  private var started = false
  private var ax: AXProbeResult?
  private var ocr: SourceReading<String>?
  private var imageRequest: Double?
  private var imageReturn: Double?
  private var ocrEnd = 0.0
  private let now: () -> Double
  init(request: AXProbeRequest, permitted: @escaping () -> Bool, ordinaryPermitted: @escaping () -> Bool,
    watchdogOCR: @escaping (AXProbePair, Bool) -> Void, refused: @escaping () -> Void, now: @escaping () -> Double = AXProbeClock.now, completion: @escaping (AXProbePair) -> Void) {
    self.request = request; self.permitted = permitted; self.refused = refused; self.completion = completion
    self.ordinaryPermitted = ordinaryPermitted; self.watchdogOCR = watchdogOCR; self.now = now
  }
  func axStarted() { lock.lock(); started = true; lock.unlock() }
  func imageRequested() { lock.lock(); imageRequest = now(); lock.unlock() }
  func imageReturned() { lock.lock(); imageReturn = now(); lock.unlock() }
  func axFinished(_ result: AXProbeResult) { lock.lock(); guard completion != nil else { lock.unlock(); return }; ax = result; lock.unlock(); finish() }
  func ocrFinished(_ result: SourceReading<String>) {
    lock.lock(); guard completion != nil else { lock.unlock(); return }; ocr = result; ocrEnd = now()
    if !started && imageRequest == nil && ax == nil {
      let status: AXProbeStatus
      switch result { case .absent(.permission): status = .permission
      case .absent(.busy): status = .busy
      default: status = .unsupported }
      ax = AXProbeResult(status: status)
    }
    lock.unlock(); finish()
  }
  private func finish() {
    lock.lock()
    guard let ax, let ocr, let callback = completion else { lock.unlock(); return }
    completion = nil
    let status: String
    switch ocr { case .value(let text): status = text.isEmpty ? "empty" : "completed"
    case .absent(let reason): status = reason.rawValue }
    let pair = AXProbePair(request: request, ax: ax, ocrStatus: status,
      ocr: ocr.value ?? "",
      imageRequest: imageRequest, imageReturn: imageReturn, ocrCompletion: ocrEnd)
    self.ax = nil; self.ocr = nil
    lock.unlock()
    if ax.status == .watchdog {
      watchdogOCR(pair, ordinaryPermitted())
      return
    }
    if permitted(), ax.status != .cancelled { callback(pair) }
    else { refused() }
  }
}
