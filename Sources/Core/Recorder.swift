import Foundation

public enum RecorderTiming {
  public static let sampleSeconds = 1
  public static let batchSeconds = 5
  public static let captureSeconds = 15
  public static let requestGraceSeconds = 1
  public static let captureTimeoutSeconds = 30
  public static let accessibilityCacheSeconds = 3
  public static let displayRefreshSeconds = 3
  public static let maintenanceSeconds = 300
  public static let lineMemorySeconds = 3600
  // Chosen bounds, not measured limits. Overflow drops the newest item and increments health counters.
  public static let pendingSeconds = 3600
  public static let pendingCaptures = 240
}

public enum RecorderSource: String, CaseIterable { case input, accessibility, screen, secureInput, displayAssertions }
public enum SourceAbsence: String {
  case permission, unavailable, busy, policyRefused, failed, settingsUnreadable, superseded
}
public enum SourceReading<Value> {
  case value(Value)
  case absent(SourceAbsence)
  public var value: Value? {
    if case .value(let value) = self { return value }
    return nil
  }
}

public struct WindowIdentity: Hashable, Codable {
  public var processID: Int32
  public var windowID: UInt32
  public init(processID: Int32, windowID: UInt32) {
    self.processID = processID
    self.windowID = windowID
  }
}

public struct FrontObservation {
  public var bundleID: String
  public var app: String
  public var processID: Int32
  public var title: String
  public var document: String?
  public var browserAddress: String?
  public var isBrowser: Bool
  public var isBrowserKnown: Bool
  public var window: WindowIdentity?
  public var observedAt: Double?
  public var accessibility: SourceAbsence?
  public init(
    bundleID: String = "", app: String = "", title: String = "", document: String? = nil,
    browserAddress: String? = nil, isBrowser: Bool = false, isBrowserKnown: Bool = true, window: WindowIdentity? = nil,
    accessibility: SourceAbsence? = nil, processID: Int32? = nil, observedAt: Double? = nil
  ) {
    self.bundleID = bundleID
    self.app = app
    self.title = title
    self.document = document
    self.browserAddress = browserAddress
    self.isBrowser = isBrowser
    self.isBrowserKnown = isBrowserKnown
    self.window = window
    self.observedAt = observedAt
    self.accessibility = accessibility
    self.processID = processID ?? window?.processID ?? 0
  }
}

public enum InputEventKind: String, Codable { case key, keyUp, click, mouseUp, modifiers, scroll, move, drag }
public struct InputObservation: Equatable, Codable {
  public var kind: InputEventKind
  public var timestamp: Double
  public var monotonicNanoseconds: UInt64?
  public var sourcePID: Int64?
  public var button: Int?
  public var scrollX: Int64?
  public var scrollY: Int64?
  public var scrollZ: Int64?
  public var continuousScroll: Bool?
  public init(kind: InputEventKind, timestamp: Double, sourcePID: Int64? = nil,
    button: Int? = nil, scrollX: Int64? = nil, scrollY: Int64? = nil, scrollZ: Int64? = nil,
    continuousScroll: Bool? = nil, monotonicNanoseconds: UInt64? = nil) {
    self.kind = kind; self.timestamp = timestamp; self.sourcePID = sourcePID
    self.button = button; self.scrollX = scrollX; self.scrollY = scrollY
    self.scrollZ = scrollZ; self.continuousScroll = continuousScroll; self.monotonicNanoseconds = monotonicNanoseconds
  }
  public var programMade: Bool? { sourcePID.map { $0 != 0 } }
}
public struct InputCounts: Equatable {
  public var keys = 0
  public var clicks = 0
  public var scrolls = 0
  public var moved = false
  public var synthetic = 0
  public var movements = 0
  public var events: [InputObservation] = []
  public var detailedEventOverflow = 0
  private var personActivity = false
  public init(keys: Int = 0, clicks: Int = 0, scrolls: Int = 0, moved: Bool = false, synthetic: Int = 0) {
    self.keys = keys
    self.clicks = clicks
    self.scrolls = scrolls
    self.moved = moved
    self.synthetic = synthetic
  }
  public mutating func add(_ other: InputCounts) {
    keys += other.keys
    clicks += other.clicks
    scrolls += other.scrolls
    moved = moved || other.moved
    synthetic += other.synthetic
    movements += other.movements
    events += other.events
    detailedEventOverflow += other.detailedEventOverflow
    personActivity = personActivity || other.byPerson
  }
  public var byPerson: Bool { personActivity || (events.isEmpty && (keys > 0 || clicks > 0 || scrolls > 0 || moved)) }
  public mutating func observe(_ event: InputEventKind, programMade: Bool) {
    observe(InputObservation(kind: event, timestamp: 0, sourcePID: programMade ? 1 : 0))
  }
  public mutating func observe(_ event: InputObservation, retainingAtMost limit: Int? = nil) {
    if let limit, events.count >= limit { detailedEventOverflow += 1 }
    else { events.append(event) }
    if event.programMade == true { synthetic += 1 }
    if event.programMade == false && [.key, .click, .scroll, .move, .drag].contains(event.kind) { personActivity = true }
    switch event.kind {
    case .key: keys += 1
    case .click: clicks += 1
    case .scroll: scrolls += 1
    case .move, .drag: moved = true; movements += 1
    case .keyUp, .mouseUp, .modifiers: break
    }
  }
}

public enum RecorderPolicy {
  public static func recording(_ settings: StorageSettings, at time: Int) -> Bool {
    settings.recordingEnabled && !settings.axProbeReviewActive(at: time)
      && (settings.pausedUntil ?? Int.min) <= time
  }
  public static func excluded(_ front: FrontObservation, settings: StorageSettings) -> Bool {
    settings.excludesApplication(front.bundleID)
  }
  public static func documentKey(_ front: FrontObservation) -> String {
    let document = front.browserAddress ?? front.document
    if let document, let url = URL(string: document) {
      if url.isFileURL { return url.path }
      if let host = url.host, !host.isEmpty {
        var path = url.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return host + (path == "/" ? "" : path)
      }
    }
    return document ?? ""
  }
  public static func sample(
    at time: Int, front: FrontObservation, input: InputCounts,
    keepingAwake: Bool, settings: StorageSettings, ownBundleID: String = ""
  ) -> TimeSample {
    let hidden =
      excluded(front, settings: settings)
      || (!ownBundleID.isEmpty && front.bundleID.lowercased() == ownBundleID.lowercased())
    return TimeSample(
      ts: time, bundleID: front.bundleID, app: front.app,
      window: hidden ? "" : front.title, documentKey: hidden ? "" : documentKey(front),
      keys: input.keys, clicks: input.clicks, scrolls: input.scrolls, moved: input.moved,
      synthetic: input.synthetic, keepingAwake: keepingAwake, excluded: hidden,
      document: hidden ? nil : front.document, browserAddress: hidden ? nil : front.browserAddress,
      inputEvents: input.events, observedAt: hidden ? nil : front.observedAt, windowIdentity: hidden ? nil : front.window,
      processID: hidden ? nil : front.processID, isBrowser: hidden ? nil : front.isBrowser, isBrowserKnown: hidden ? nil : front.isBrowserKnown,
      accessibility: hidden ? nil : front.accessibility?.rawValue)
  }
  public static func captureAllowed(
    front: FrontObservation, input: InputCounts, secureInput: Bool?,
    settings: StorageSettings, ownBundleID: String, at time: Int
  ) -> Bool {
    recording(settings, at: time) && input.byPerson && secureInput == false && front.window != nil
      && front.bundleID.lowercased() != ownBundleID.lowercased() && !excluded(front, settings: settings)
  }
}

public struct CaptureSchedule {
  private var last: [WindowIdentity: Int] = [:]
  public init() {}
  public mutating func reserve(_ window: WindowIdentity, at time: Int) -> Bool {
    last = last.filter { $0.value <= time && time < $0.value + RecorderTiming.captureSeconds }
    guard last[window] == nil else { return false }
    last[window] = time
    return true
  }
}

/// Write-time compatibility state. Capture persistence never depends on these keys.
public struct ScreenKeyMemory: Equatable {
  public private(set) var storedAt: [String: Int] = [:]
  public init() {}
  public var keys: Set<String> { Set(storedAt.keys) }
  public mutating func expire(at time: Int) {
    let (oldest, overflow) = time.subtractingReportingOverflow(RecorderTiming.lineMemorySeconds)
    storedAt = storedAt.filter { (overflow || $0.value > oldest) && $0.value <= time }
  }
  public mutating func rebuild(_ keys: [String: Int], at time: Int) {
    storedAt = keys
    expire(at: time)
  }
  public mutating func add(_ keys: Set<String>, storedAt time: Int, now: Int) {
    for key in keys { storedAt[key] = max(storedAt[key] ?? Int.min, time) }
    expire(at: now)
  }
}

public protocol RecorderClock { var now: Int { get } }
public protocol InputCountSource { func takeInput() -> SourceReading<InputCounts> }
public protocol FrontWindowSource {
  /// Identity only. Do not ask for content before policy permits it.
  func frontApplication() -> FrontObservation
  func details(for application: FrontObservation) -> FrontObservation
  func invalidateMetadata()
  func takeCompletedDetails() -> [FrontObservation]
}
extension FrontWindowSource { public func invalidateMetadata() {}
  public func takeCompletedDetails() -> [FrontObservation] { [] } }
public protocol SecureInputSource { func secureInput() -> SourceReading<Bool> }
public protocol DisplayAwakeSource { func keepingDisplayAwake(processID: Int32) -> SourceReading<Bool> }
public enum CaptureCheck {
  case beforeImage, beforeDelivery
  public func allows(requestedAt: Int, now: Int) -> Bool {
    self != .beforeImage || (now >= requestedAt && now - requestedAt <= RecorderTiming.requestGraceSeconds)
  }
}

public protocol ScreenTextSource {
  func capturePayload(window: WindowIdentity, permitted: @escaping (CaptureCheck) -> Bool,
    completion: @escaping (SourceReading<ScreenTextPayload>) -> Void)
  /// No image leaves this adapter. Completion may run later; the loop must never wait for it.
  func captureText(
    window: WindowIdentity, permitted: @escaping (CaptureCheck) -> Bool,
    completion: @escaping (SourceReading<String>) -> Void)
}
extension ScreenTextSource {
  public func capturePayload(window: WindowIdentity, permitted: @escaping (CaptureCheck) -> Bool,
    completion: @escaping (SourceReading<ScreenTextPayload>) -> Void) {
    captureText(window: window, permitted: permitted) { completion($0.map { ScreenTextPayload(text: $0) }) }
  }
}
public protocol DeletionCounter { func deletionsSoFar() throws -> Int }
public protocol RecorderStorage: SampleWriter, ObservationWriter, ScreenCaptureWriter, StructuredScreenCaptureWriter, EvidenceReader, SettingsStore,
  DeletionCounter, EvidenceRetention
{}

public enum AddressCachePolicy {
  /// A deadline-limited walk is unknown, not a completed miss.
  public static func canReuse(sameTitle: Bool, finished: Bool, age: Double = .infinity) -> Bool {
    sameTitle && finished && age >= 0 && age < Double(RecorderTiming.accessibilityCacheSeconds)
  }
}
