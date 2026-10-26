import Foundation

public struct TimeRange: Equatable, Codable {
  public var start: Int
  public var end: Int
  public init(_ start: Int, _ end: Int) { self.start = start; self.end = end }
}

public struct TimeSample: Equatable, Codable {
  public var ts: Int
  public var bundleID: String
  public var app: String
  public var window: String
  public var documentKey: String
  public var keys: Int
  public var clicks: Int
  public var scrolls: Int
  public var moved: Bool
  public var synthetic: Int
  public var keepingAwake: Bool
  public var document: String?
  public var browserAddress: String?
  public var inputEvents: [InputObservation]
  public var observedAt: Double?
  public var windowIdentity: WindowIdentity?
  public var processID: Int32?
  public var isBrowser: Bool?
  public var isBrowserKnown: Bool?
  public var accessibility: String?
  public var excluded: Bool
  public var applicationPrivacyIdentity: String? = nil
  public init(ts: Int, bundleID: String = "", app: String = "", window: String = "", documentKey: String = "",
    keys: Int = 0, clicks: Int = 0, scrolls: Int = 0, moved: Bool = false,
    synthetic: Int = 0, keepingAwake: Bool = false, excluded: Bool = false,
    document: String? = nil, browserAddress: String? = nil, inputEvents: [InputObservation] = [], observedAt: Double? = nil, windowIdentity: WindowIdentity? = nil,
    processID: Int32? = nil, isBrowser: Bool? = nil, isBrowserKnown: Bool? = nil, accessibility: String? = nil) {
    self.ts = ts; self.bundleID = bundleID; self.app = app; self.window = window; self.documentKey = documentKey
    self.keys = keys; self.clicks = clicks; self.scrolls = scrolls; self.moved = moved
    self.synthetic = synthetic; self.keepingAwake = keepingAwake; self.excluded = excluded
    self.document = document; self.browserAddress = browserAddress; self.inputEvents = inputEvents; self.observedAt = observedAt
    self.windowIdentity = windowIdentity; self.processID = processID; self.isBrowser = isBrowser
    self.isBrowserKnown = isBrowserKnown; self.accessibility = accessibility
    self.applicationPrivacyIdentity = ApplicationPrivacyIdentity.originalDigest(bundleID)
  }
  public var hasInput: Bool { keys > 0 || clicks > 0 || scrolls > 0 || moved }
}

public enum ActivityKind: String, CaseIterable { case work, personal, distraction }
public enum IntervalState: String { case named, `private` }
public struct NamedInterval: Equatable {
  public var range: TimeRange
  public var name: String
  public var description: String
  public var kind: ActivityKind?
  public var project: String
  public var state: IntervalState
  public init(range: TimeRange, name: String = "", description: String = "", kind: ActivityKind? = nil,
    project: String = "", state: IntervalState = .named) {
    self.range = range; self.name = name; self.description = description; self.kind = kind
    self.project = project; self.state = state
  }
}

public enum EvidenceKind: String, CaseIterable { case screen, prompt }
public struct EvidenceText: Equatable {
  public var ts: Int
  public var kind: EvidenceKind
  public var source: String
  public var sourceID: String?
  // Transient paired copy ids, consumed with the batch rather than stored as prompt text.
  public var sourceAliases: [String]
  public var documentKey: String
  public var project: String
  public var text: String
  public init(ts: Int, kind: EvidenceKind, source: String, sourceID: String? = nil,
    sourceAliases: [String] = [], documentKey: String = "", project: String = "", text: String) {
    self.ts = ts; self.kind = kind; self.source = source; self.sourceID = sourceID
    self.sourceAliases = sourceAliases
    self.documentKey = documentKey; self.project = project; self.text = text
  }
}

/// Keys contain the shape of already-masked text. Masking a raw line here would lose block context.
public enum ScreenLineKey {
  public static func fromMaskedLine(_ line: String) -> String {
    line.filter { !$0.isNumber && !$0.isWhitespace && !$0.isPunctuation }
  }
}

/// Compatibility novelty selection. Persistence keeps every masked line.
public struct ScreenLines: Equatable {
  public var lines: [String]
  public var keys: Set<String>

  /// The caller masks the whole capture first; stored text needs no further masking on rebuild.
  public static func select(maskedText: String, knownKeys: Set<String>) -> ScreenLines {
    var seen = knownKeys
    var lines: [String] = []
    var keys = Set<String>()
    for line in maskedText.components(separatedBy: .newlines) where !line.isEmpty {
      let key = ScreenLineKey.fromMaskedLine(line)
      // Fully masked lines share one key in this compatibility view; raw captures retain every occurrence.
      if seen.insert(key).inserted { lines.append(line); keys.insert(key) }
    }
    return ScreenLines(lines: lines, keys: keys)
  }
}

public struct ScreenCaptureResult: Equatable {
  public var append: AppendResult
  public var addedKeys: Set<String>
  public var evidenceID: Int?
  public init(append: AppendResult, addedKeys: Set<String>, evidenceID: Int? = nil) {
    self.append = append; self.addedKeys = addedKeys; self.evidenceID = evidenceID
  }
}

public struct StorageSettings: Equatable {
  public var excludedApps: [String]
  public var excludedAppPrivacyIdentities: [String: Set<String>] = [:]
  public var subscriptionConnected: Bool
  public var connectionGeneration = ""
  public var recordingEnabled: Bool
  public var pausedUntil: Int?
  public var screenRetentionDays: Int
  public var promptRetentionDays: Int
  public var general: [String: String]
  public init(excludedApps: [String] = StorageSettings.defaultExcludedApps, pausedUntil: Int? = nil,
    recordingEnabled: Bool = true, subscriptionConnected: Bool = false,
    screenRetentionDays: Int = 30, promptRetentionDays: Int = 30, general: [String: String] = [:]) {
    self.excludedApps = excludedApps; self.pausedUntil = pausedUntil; self.recordingEnabled = recordingEnabled
    self.screenRetentionDays = screenRetentionDays; self.promptRetentionDays = promptRetentionDays
    self.subscriptionConnected = subscriptionConnected
    self.general = general
  }
  public static let defaultExcludedApps = [
    "com.1password.1password", "com.agilebits.onepassword7", "com.apple.keychainaccess", "com.bitwarden.desktop",
    "com.apple.passwords", "com.lastpass.lastpass", "com.dashlane.dashlane", "com.kakao.kakaotalkmac",
    "com.tinyspeck.slackmacgap", "com.hnc.discord", "com.apple.mobilesms", "ru.keepcoder.telegram",
    "net.whatsapp.whatsapp", "jp.naver.line.mac",
  ].sorted()
}

public struct LogPosition: Equatable {
  public var path: String
  public var device: Int
  public var inode: Int
  public var offset: Int
  public var state: String
  public var seenAt: Int
  public init(path: String, device: Int, inode: Int, offset: Int, state: String = "", seenAt: Int) {
    self.path = path; self.device = device; self.inode = inode; self.offset = offset
    self.state = state; self.seenAt = seenAt
  }
}

/// Content-free boundaries of the table actually sent, including its observation cutoff.
public struct SummaryCallFacts: Equatable, Codable {
  public var through: Int
  public var sentRanges: [TimeRange]
  public var endsAtRest: Bool
  public var activeMinutes: [Int]
  public var restMinutes: [Int]
  public init(through: Int, sentRanges: [TimeRange], endsAtRest: Bool, activeMinutes: [Int] = []) {
    self.through = through; self.sentRanges = sentRanges; self.endsAtRest = endsAtRest
    self.activeMinutes = Array(Set(activeMinutes)).sorted()
    var rest = [Int](), leadsToRest = endsAtRest
    if let start = sentRanges.first?.start, let end = sentRanges.last?.end {
      let active = Set(activeMinutes)
      for minute in stride(from: end - 60, through: start, by: -60) {
        if !sentRanges.contains(where: { $0.start <= minute && $0.end >= minute + 60 }) {
          rest.append(minute); leadsToRest = true
        } else if active.contains(minute) { leadsToRest = false }
        else if leadsToRest { rest.append(minute) }
      }
    }
    self.restMinutes = rest.sorted()
  }
}

public struct ModelCall: Codable, Equatable {
  public var ts: Int
  public var range: TimeRange
  public var model: String
  public var inputTokens: Int
  public var cachedTokens: Int
  public var outputTokens: Int
  public var succeeded: Bool
  /// Nonterminal accounting never closes an activity range.
  public var pending: Bool
  public var attemptID: String?
  public var tableFacts: SummaryCallFacts?
  public init(ts: Int, range: TimeRange, model: String, inputTokens: Int = 0, cachedTokens: Int = 0,
    outputTokens: Int = 0, succeeded: Bool, tableFacts: SummaryCallFacts? = nil, pending: Bool = false, attemptID: String? = nil) {
    self.ts = ts; self.range = range; self.model = model; self.inputTokens = inputTokens
    self.cachedTokens = cachedTokens; self.outputTokens = outputTokens; self.succeeded = succeeded
    self.tableFacts = tableFacts; self.pending = pending; self.attemptID = attemptID
  }
}

public struct DeletionPreview: Equatable {
  public var range: TimeRange
  public var counts: [String: Int]
  public var confirmation: String
  public var intervalExtent: TimeRange?
  public init(range: TimeRange, counts: [String: Int], confirmation: String, intervalExtent: TimeRange? = nil) {
    self.range = range; self.counts = counts; self.confirmation = confirmation
    self.intervalExtent = intervalExtent
  }
}

public protocol SampleWriter { @discardableResult func appendSamples(_ samples: [TimeSample]) throws -> AppendResult }
public protocol ObservationWriter {
  @discardableResult func appendAccountingSamples(_ samples: [TimeSample]) throws -> AppendResult
  @discardableResult func appendObservations(_ observations: [ActivityObservation]) throws -> AppendResult
}
public protocol SampleReader { func samples(in range: TimeRange) throws -> [TimeSample] }
public protocol IntervalWriter {
  @discardableResult func appendIntervals(_ intervals: [NamedInterval]) throws -> AppendResult
}
public protocol IntervalReader { func intervals(in range: TimeRange) throws -> [NamedInterval] }
public protocol EvidenceWriter {
  /// Identity is (source, sourceID), regardless of kind. Use a source unique to each log file or session.
  @discardableResult func appendEvidence(_ evidence: [EvidenceText]) throws -> AppendResult
}
public protocol ScreenCaptureWriter {
  /// Appends the entire masked capture. knownKeys is retained for source compatibility and does not suppress storage.
  @discardableResult func appendScreenCapture(
    text: String, at time: Int, source: String, documentKey: String, project: String, knownKeys: Set<String>
  ) throws -> ScreenCaptureResult
}
public protocol EvidenceReader {
  func evidence(in range: TimeRange) throws -> [EvidenceText]
  func novelEvidence(in range: TimeRange) throws -> [EvidenceText]
  /// Latest evidence timestamp per shape, strictly newer than now minus one hour and no later than now.
  func recentScreenLineKeys(at now: Int) throws -> [String: Int]
}
public protocol SettingsStore {
  func settings() throws -> StorageSettings
  func saveSettings(_ settings: StorageSettings) throws
}
/// Interactive edits read, validate and commit against the latest settings in one transaction.
public protocol SettingsEditingStore: SettingsStore {
  var settingsIdentity: String { get }
  func patchSettings(_ patch: SettingsPatch) throws -> StorageSettings
}
public protocol LogPositionStore {
  /// Paths are stored exactly as given; reader state must hold nothing maskable.
  func logPosition(path: String) throws -> LogPosition?
  func saveLogPosition(_ position: LogPosition) throws
}
public protocol ModelCallReader {
  /// Calls whose completion timestamps fall in the range.
  func modelCalls(in range: TimeRange) throws -> [ModelCall]
  /// Calls whose activity spans overlap the range, even if they completed later.
  func modelCalls(overlapping range: TimeRange) throws -> [ModelCall]
}
public protocol ModelCallStore: ModelCallReader {
  func recoverModelCalls() throws
  /// A repeated attemptID is one billed call; finalizing its pending state never adds its tokens again.
  @discardableResult func appendModelCall(_ call: ModelCall) throws -> AppendResult
}
extension ModelCallStore { public func recoverModelCalls() throws {} }
public protocol RecordDeletion {
  func previewDeletion(in range: TimeRange, allowOver24Hours: Bool) throws -> DeletionPreview
  /// The caller must obtain human approval; the code proves freshness only.
  func deleteRecords(in range: TimeRange, confirmation: String, allowOver24Hours: Bool) throws -> DeletionResult
}
public struct DeletionResult: Equatable {
  public var preview: DeletionPreview
  /// False means a reader or writer delayed truncation; deletion has still committed.
  public var walTruncated: Bool
  public init(preview: DeletionPreview, walTruncated: Bool) {
    self.preview = preview; self.walTruncated = walTruncated
  }
}
public protocol ForgottenRangeReader { func forgottenRanges(in range: TimeRange) throws -> [TimeRange] }
public protocol EvidenceRetention { @discardableResult func cleanRetention(at now: Int) throws -> Int }

public protocol LogBatchWriter {
  /// Evidence and the next reading position must commit together.
  @discardableResult func appendLogBatch(_ evidence: [EvidenceText], position: LogPosition) throws -> AppendResult
}

public struct AppendResult: Equatable {
  public var stored: Int
  public var refused: Int
  public init(stored: Int = 0, refused: Int = 0) { self.stored = stored; self.refused = refused }
}

extension EvidenceReader {
  public func novelEvidence(in range: TimeRange) throws -> [EvidenceText] { try evidence(in: range) }
}
