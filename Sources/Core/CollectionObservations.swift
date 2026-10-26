import Foundation

/// Each actual observation has its own identity; accounting still has one row per second.
public struct ActivityObservation: Equatable, Codable {
  public var id: String
  public var sample: TimeSample
  public var applicationPrivacyIdentity: String? = nil
  public init(id: String = UUID().uuidString, sample: TimeSample) {
    self.id = id; self.sample = sample
    applicationPrivacyIdentity = sample.applicationPrivacyIdentity ?? ApplicationPrivacyIdentity.originalDigest(sample.bundleID)
  }
  public func redacted() -> ActivityObservation {
    var copy = self
    copy.sample.applicationPrivacyIdentity = applicationPrivacyIdentity
    copy.id = Redaction.applyKnownSecrets(id).text
    copy.sample.accessibility = sample.accessibility.map { Redaction.apply($0).text }
    copy.sample.app = Redaction.apply(sample.app).text
    copy.sample.bundleID = Redaction.applyKnownSecrets(sample.bundleID).text
    copy.sample.window = sample.excluded ? "" : Redaction.apply(sample.window).text
    copy.sample.documentKey = sample.excluded ? "" : Redaction.apply(sample.documentKey).text
    if sample.excluded { copy.sample.inputEvents = []; copy.sample.clearMetadata() }
    copy.sample.document = sample.excluded ? nil : sample.document.map { Redaction.apply($0).text }
    copy.sample.browserAddress = sample.excluded ? nil : sample.browserAddress.map { Redaction.apply($0).text }
    return copy
  }
}
public struct OCRCandidate: Equatable, Codable {
  public var text: String
  public var confidence: Float
  public init(text: String, confidence: Float) { self.text = text; self.confidence = confidence }
}
/// Vision normalized coordinates, with the origin at the lower left.
public struct OCRBounds: Equatable, Codable {
  public var x: Double, y: Double, width: Double, height: Double
  public init(x: Double, y: Double, width: Double, height: Double) {
    self.x = x; self.y = y; self.width = width; self.height = height
  }
}
public struct OCRObservation: Equatable, Codable {
  public var bounds: OCRBounds
  public var candidates: [OCRCandidate]
  public init(bounds: OCRBounds, candidates: [OCRCandidate]) { self.bounds = bounds; self.candidates = candidates }
}
public struct ScreenTextPayload: Equatable, Codable {
  public var text: String
  public var observations: [OCRObservation]
  public var languages: [String]
  public var languageStatus: String
  public var engine: String
  public var document: String?
  public var browserAddress: String?
  public var window: WindowIdentity?
  /// Whole masked hypothesis ranks when a block mask changes line boundaries.
  public var blockHypotheses: [String]? = nil
  public init(text: String, observations: [OCRObservation] = [], languages: [String] = [],
    languageStatus: String = "unavailable", engine: String = "unknown", document: String? = nil,
    browserAddress: String? = nil, window: WindowIdentity? = nil) {
    self.text = text; self.observations = observations; self.languages = languages
    self.languageStatus = languageStatus; self.engine = engine
    self.document = document; self.browserAddress = browserAddress; self.window = window
  }
  public var estimatedBytes: Int {
    let strings = [text, engine, languageStatus] + languages + [document, browserAddress].compactMap { $0 } + (blockHypotheses ?? [])
    return 512 + strings.reduce(0) { $0 + $1.utf8.count }
      + observations.reduce(0) { $0 + 128 + $1.candidates.reduce(0) { $0 + 32 + $1.text.utf8.count } }
  }
  public func redacted() -> ScreenTextPayload {
    var copy = self
    copy.text = Redaction.apply(text).text
    copy.document = document.map { Redaction.apply($0).text }
    copy.browserAddress = browserAddress.map { Redaction.apply($0).text }
    copy.engine = Redaction.apply(engine).text
    copy.languageStatus = Redaction.apply(languageStatus).text
    copy.languages = languages.map { Redaction.apply($0).text }
    copy.blockHypotheses = blockHypotheses?.map { Redaction.apply($0).text }
    // Mask each hypothesis as a whole block, including cross-line secrets. If block masking
    // changes line boundaries, retain the full masked rank and mark its individual strings.
    let ranks = observations.map { $0.candidates.count }.max() ?? 0
    var wholeRanks: [String] = [], changedBoundaries = false
    for rank in 0..<ranks {
      let indices = observations.indices.filter { observations[$0].candidates.count > rank }
      let joined = indices.map { observations[$0].candidates[rank].text }.joined(separator: "\n")
      let masked = Redaction.apply(joined).text
      let lines = masked.components(separatedBy: "\n")
      wholeRanks.append(masked)
      if joined != masked && lines.count != indices.count { changedBoundaries = true }
      for (offset, index) in indices.enumerated() {
        let original = observations[index].candidates[rank].text
        copy.observations[index].candidates[rank].text = joined == masked
          ? Redaction.apply(original).text
          : (lines.count == indices.count ? lines[offset] : Redaction.apply("[redacted]").text)
      }
    }
    if changedBoundaries { copy.blockHypotheses = wholeRanks }
    return copy
  }
}
public protocol StructuredScreenCaptureWriter {
  func appendScreenCapture(payload: ScreenTextPayload, at time: Int, source: String,
    documentKey: String, project: String, probe: AXProbeLink?) throws -> ScreenCaptureResult
}
public extension SourceReading {
  func map<T>(_ transform: (Value) -> T) -> SourceReading<T> {
    switch self { case .value(let value): return .value(transform(value)); case .absent(let reason): return .absent(reason) }
  }
}
public struct OCRRecognitionPlan: Equatable {
  public var languages: [String]
  public var status: String
  public let usesLanguageCorrection = false
  public let automaticallyDetectsLanguage = true
  public init(supported: [String]?) {
    // Vision language discovery can fail. An empty list delegates language selection to the
    // engine with automatic detection, rather than claiming an English-only fallback.
    languages = supported ?? []
    status = supported == nil ? "discovery_failed_automatic" : "supported_automatic"
  }
}

/// Native adapters carry OCR observations; older test/source adapters keep their text contract.
public protocol StructuredAXProbeScreenSource: AXProbeScreenSource {
  func captureStructured(window: WindowIdentity, probe: AXProbeRequest,
    permitted: @escaping (CaptureCheck) -> Bool, probePermitted: @escaping () -> Bool,
    probeBegin: @escaping () -> AXProbeStatus?, probeEnd: @escaping (AXProbeResult) -> Void,
    probeWatchdogOCR: @escaping (AXProbePair, Bool) -> Void, probeRefused: @escaping () -> Void,
    probeCompletion: @escaping (AXProbePair) -> Void, completion: @escaping (SourceReading<ScreenTextPayload>) -> Void)
}
extension AXProbeScreenSource {
  public func capturePayload(window: WindowIdentity, probe: AXProbeRequest,
    permitted: @escaping (CaptureCheck) -> Bool, probePermitted: @escaping () -> Bool,
    probeBegin: @escaping () -> AXProbeStatus?, probeEnd: @escaping (AXProbeResult) -> Void,
    probeWatchdogOCR: @escaping (AXProbePair, Bool) -> Void, probeRefused: @escaping () -> Void,
    probeCompletion: @escaping (AXProbePair) -> Void, completion: @escaping (SourceReading<ScreenTextPayload>) -> Void) {
    if let structured = self as? StructuredAXProbeScreenSource {
      structured.captureStructured(window: window, probe: probe, permitted: permitted,
        probePermitted: probePermitted, probeBegin: probeBegin, probeEnd: probeEnd,
        probeWatchdogOCR: probeWatchdogOCR, probeRefused: probeRefused, probeCompletion: probeCompletion, completion: completion)
    } else {
      captureText(window: window, probe: probe, permitted: permitted, probePermitted: probePermitted,
        probeBegin: probeBegin, probeEnd: probeEnd, probeWatchdogOCR: probeWatchdogOCR,
        probeRefused: probeRefused, probeCompletion: probeCompletion) { completion($0.map { ScreenTextPayload(text: $0) }) }
    }
  }
}

public extension TimeSample {
  mutating func clearMetadata() {
    window = ""; documentKey = ""; document = nil; browserAddress = nil
    windowIdentity = nil; processID = nil; isBrowser = nil; isBrowserKnown = nil
    accessibility = nil; observedAt = nil
  }
}
