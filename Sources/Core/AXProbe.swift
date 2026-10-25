import Foundation

public enum AXProbeStatus: String, Codable {
  case pending, completed, empty, permission, browserExcluded, policyRefused, busy, cooldown, pidDisabled
  case identityUnknown, identityChanged, visibilityUnknown, unsupported, messagingFailure, invalidElement
  case deadline, watchdog, cancelled, elementLimit, depthLimit, ipcLimit, byteLimit, oversize
  case overload_dropped, resource_truncated, storage_failed
}
public struct AXProbeRun: Codable, Equatable {
  public var id: String
  public var start: Int
  public init(id: String = UUID().uuidString, start: Int) { self.id = id; self.start = start }
}

public struct AXProbeText: Codable, Equatable {
  public var attribute: String
  public var text: String
  public var length: Int
  public var maskHits: [String: Int]
  public var originalLength: Int? = nil
  public var resourceTruncated: Bool? = nil
  public init(attribute: String, text: String) {
    self.attribute = attribute; self.text = text; length = text.unicodeScalars.count; maskHits = [:]
  }
  public func redacted() -> AXProbeText {
    var copy = self
    copy.text = Redaction.apply(text).text
    copy.length = copy.text.unicodeScalars.count
    // Count newly emitted mask markers, never retain the matched spans.
    for kind in ["secret", "email", "redacted", "phone"] {
      let marker = "[" + kind + "]"
      let added = copy.text.components(separatedBy: marker).count - text.components(separatedBy: marker).count
      if added > 0 { copy.maskHits[kind, default: 0] += added }
    }
    return copy
  }
}
public struct AXProbeNode: Codable, Equatable {
  public var nodeID: Int
  public var role: String?
  public var subrole: String?
  public var depth: Int
  public var pid: Int?
  public var bundleID: String?
  public var insideWindow: Bool?
  public var onScreen: Bool?
  public var hiddenBranch: Bool?
  public var collapsedBranch: Bool?
  public var unselectedBranch: Bool?
  public var nonSelectedTab: Bool?
  public var secure: Bool
  public var readSeconds: Double? = nil
  public var selected: Bool? = nil
  public var attributes: [AXProbeText]
  public init(nodeID: Int, role: String? = nil, subrole: String? = nil, depth: Int = 0,
    pid: Int? = nil, bundleID: String? = nil, insideWindow: Bool? = nil, onScreen: Bool? = nil,
    hiddenBranch: Bool? = nil, collapsedBranch: Bool? = nil, unselectedBranch: Bool? = nil,
    nonSelectedTab: Bool? = nil, secure: Bool = false, attributes: [AXProbeText] = []) {
    self.nodeID = nodeID; self.role = role; self.subrole = subrole; self.depth = depth
    self.pid = pid; self.bundleID = bundleID; self.insideWindow = insideWindow; self.onScreen = onScreen
    self.hiddenBranch = hiddenBranch; self.collapsedBranch = collapsedBranch
    self.unselectedBranch = unselectedBranch; self.nonSelectedTab = nonSelectedTab; self.secure = secure
    self.attributes = attributes
  }
}
public extension StorageSettings {
  var axProbeRun: AXProbeRun? {
    guard let bytes = general["axProbe.run"], general["axProbe.enabled"] == "1" else { return nil }
    return try? JSONDecoder().decode(AXProbeRun.self, from: Data(bytes.utf8))
  }
}
public struct AXProbeRequest {
  public var run: AXProbeRun
  public var attemptID: String
  public var time: Int
  public var window: WindowIdentity
  public var bundleID: String
  public var isBrowser: Bool
  public var isBrowserKnown: Bool
  public init(run: AXProbeRun, attemptID: String = UUID().uuidString, time: Int,
    window: WindowIdentity, bundleID: String, isBrowser: Bool, isBrowserKnown: Bool = true) {
    self.run = run; self.attemptID = attemptID; self.time = time; self.window = window
    self.bundleID = bundleID; self.isBrowser = isBrowser; self.isBrowserKnown = isBrowserKnown
  }
}
public struct AXProbeResult: Codable {
  public var status: AXProbeStatus = .empty
  public var text = ""
  public var start: Double = 0
  public var end: Double = 0
  public var cpu: Double? = nil
  public var queueWait: Double = 0
  public var workerWall: Double = 0
  public var ipc = 0
  public var elements = 0
  public var error: Int? = nil
  public var identity = "unknown"
  public var counts: [String: Int] = [:]
  public var firstAttempt = false
  public var osVersion: [Int] = []
  public var osBuild: [Int] = []
  public var acquiredBytes = 0
  public var truncated = false
  public var nodes: [AXProbeNode]? = nil
  public var nodeReadMicroseconds: [Int]? = nil
  public var nodeReadCount: Int? = nil
  public var manualAccessibility: String? = nil
  public var truncations: [String: Int]? = nil
  public init(status: AXProbeStatus = .empty) { self.status = status }
}
public enum AXProbeOCRRefusal: String, Codable, CaseIterable {
  case no_person_input, key_changed, superseded, busy, dropped, expired, failed, permission, unavailable
  case recording_off, excluded_app, secure_input, own_app, settings_unreadable, capture_generation
}
public struct AXProbePair: Codable {
  public var runID: String
  public var attemptID: String
  public var time: Int
  public var bundleID: String
  // Missing in legacy pairs and when browser metadata has not been observed yet.
  public var isBrowser: Bool? = nil
  public var ax: AXProbeResult
  public var ocr_refusal_reason: AXProbeOCRRefusal? = nil
  public var ocrStatus: String
  public var ocr: String
  public var imageRequest: Double?
  public var imageReturn: Double?
  public var ocrCompletion: Double
  public var ocrBytes = 0
  public var axBytes = 0
  public var ocrScalars = 0
  public var axScalars = 0
  public var ocrCapped = false
  public var axCapped = false
  public init(request: AXProbeRequest, ax: AXProbeResult, ocrStatus: String, ocr: String,
    imageRequest: Double?, imageReturn: Double?, ocrCompletion: Double) {
    self.runID = request.run.id; self.attemptID = request.attemptID; self.time = request.time
    self.bundleID = request.bundleID; self.ax = ax; self.ocrStatus = ocrStatus; self.ocr = ocr
    self.isBrowser = request.isBrowserKnown ? request.isBrowser : nil
    self.imageRequest = imageRequest; self.imageReturn = imageReturn; self.ocrCompletion = ocrCompletion
  }
  public var timingValid: Bool {
    guard let request = imageRequest, let returned = imageReturn, ax.start > 0, ax.end >= ax.start else { return false }
    return abs(ax.start - request) <= 0.100 && max(returned, ax.end) - min(request, ax.start) <= 0.500
  }
  public func redacted() -> AXProbePair {
    var copy = self
    let o = Redaction.apply(ocr).text
    copy.ax.nodes = ax.nodes?.map { node in
      var masked = node
      masked.role = node.role.map { Redaction.apply($0).text }
      masked.subrole = node.subrole.map { Redaction.apply($0).text }
      masked.bundleID = node.bundleID.map { Redaction.apply($0).text }
      masked.attributes = node.attributes.map { attribute in
        var a = attribute.redacted(); a.attribute = Redaction.apply(attribute.attribute).text; return a
      }
      return masked
    }
    let a = Redaction.apply(copy.ax.nodes.map { $0.flatMap { $0.attributes.map(\.text) }.filter { !$0.isEmpty }.joined(separator: "\n") }
      ?? ax.text).text
    copy.ocrBytes = o.utf8.count; copy.axBytes = a.utf8.count
    copy.ocrScalars = o.unicodeScalars.count; copy.axScalars = a.unicodeScalars.count
    copy.ocrCapped = false; copy.axCapped = false
    copy.ocr = o; copy.ax.text = a
    return copy
  }
}
public enum AXProbeEvent: String {
  case eligible, privacyRefused, pendingDropped, settingsUnreadable, supersededOCR, droppedOCR, busyOCR
  case tickLateMilliseconds, scheduledTickGaps, watchdog, censoredMilliseconds
  case finishStorageFailures, recoveredWorkerLease, overload_dropped, messagingFailures, cooldowns
  case ocr_no_person_input, ocr_key_changed, ocr_superseded, ocr_busy, ocr_dropped, ocr_expired
  case ocr_failed, ocr_permission, ocr_unavailable, ocr_recording_off, ocr_excluded_app, ocr_secure_input
  case ocr_own_app, ocr_settings_unreadable, ocr_capture_generation
}
public struct AXProbeLink {
  public var runID: String
  public var attemptID: String
  public init(runID: String, attemptID: String) { self.runID = runID; self.attemptID = attemptID }
}
public protocol AXProbeLinkedScreenWriter: ScreenCaptureWriter {
  func appendScreenCapture(text: String, at time: Int, source: String, documentKey: String,
    project: String, knownKeys: Set<String>, probe: AXProbeLink) throws -> ScreenCaptureResult
}
public protocol AXProbeStore {
  func countAXProbeOverload(_ receipt: AXProbeReceipt) throws
  func recordAXProbePersistenceFailure(_ receipt: AXProbeReceipt) throws
  func recordWatchdogOCR(_ pair: AXProbePair, privacyAccepted: Bool) throws
  func refuseAXProbeOpportunity(runID: String, attemptID: String, reason: AXProbeOCRRefusal?) throws
  func countAXProbeEvent(runID: String, event: AXProbeEvent, amount: Int) throws
  func retryAXProbeFinishes() throws
  func beginAXProbe(_ request: AXProbeRequest, at now: Int) throws -> AXProbeStatus?
  func finishAXProbe(_ request: AXProbeRequest, result: AXProbeResult, at now: Int)
  func axProbeAllowed(_ request: AXProbeRequest, at now: Int) throws -> Bool
  func appendAXProbe(_ pair: AXProbePair, evidenceID: Int?, at now: Int, permitted: () -> Bool) throws -> Bool
}
public extension AXProbeStore {
  func refuseAXProbeOpportunity(runID: String, attemptID: String) throws {
    try refuseAXProbeOpportunity(runID: runID, attemptID: attemptID, reason: nil)
  }
  func recordAXProbePersistenceFailure(_ receipt: AXProbeReceipt) throws {
    try countAXProbeEvent(runID: receipt.runID, event: .finishStorageFailures, amount: 1)
  }
  func countAXProbeOverload(_ receipt: AXProbeReceipt) throws {
    try countAXProbeEvent(runID: receipt.runID, event: .overload_dropped, amount: 1)
  }
}
public protocol AXProbeScreenSource: ScreenTextSource {
  func captureText(window: WindowIdentity, probe: AXProbeRequest,
    permitted: @escaping (CaptureCheck) -> Bool, probePermitted: @escaping () -> Bool,
    probeBegin: @escaping () -> AXProbeStatus?, probeEnd: @escaping (AXProbeResult) -> Void, probeWatchdogOCR: @escaping (AXProbePair, Bool) -> Void, probeRefused: @escaping () -> Void,
    probeCompletion: @escaping (AXProbePair) -> Void, completion: @escaping (SourceReading<String>) -> Void)
  func invalidateProbe()
}

// All provider calls run on one dedicated worker. Node IDs preserve provider element equality.
public struct AXProbeFrame: Equatable {
  public var x: Double, y: Double, width: Double, height: Double
  public init(x: Double, y: Double, width: Double, height: Double) {
    self.x = x; self.y = y; self.width = width; self.height = height
  }
  public var isNull: Bool { width <= 0 || height <= 0 }
  public func intersection(_ other: AXProbeFrame) -> AXProbeFrame {
    let left = max(x, other.x), top = max(y, other.y)
    return AXProbeFrame(x: left, y: top, width: min(x + width, other.x + other.width) - left,
      height: min(y + height, other.y + other.height) - top)
  }
  public func contains(_ other: AXProbeFrame) -> Bool {
    !other.isNull && other.x >= x && other.y >= y && other.x + other.width <= x + width
      && other.y + other.height <= y + height
  }
}
public enum AXProbeAttribute: Hashable {
  case role, subrole, frame, hidden, expanded, selected, secure, focusedWindow, focusedElement, pid
  case value, title, description, help, placeholder, selectedText, url, document
  case manualAccessibility, bundleID, characterCount, visibleRange, substring(Int, Int)
  case count(String), page(String, Int, Int)
}
public enum AXProbeValue: Equatable {
  case string(String), frame(AXProbeFrame), bool(Bool), integer(Int), range(Int, Int), node(Int), nodes([Int])
  case unsupported, failure(Int), stopped(AXProbeStatus), resourceTruncated(Int)
}
public protocol AXProbeProvider: AnyObject {
  var application: Int { get }
  var ipcCount: Int? { get }
  func prepare(_ node: Int, timeout: Double) -> AXProbeValue?
  func releaseObservation(_ node: Int)
  func releaseNode(_ node: Int)
  func read(_ node: Int, _ attribute: AXProbeAttribute, timeout: Double) -> AXProbeValue
  func matchingWindows(_ request: WindowIdentity, frame: AXProbeFrame) -> Bool
  func onScreen(_ frame: AXProbeFrame) -> Bool?
}

public extension AXProbeProvider {
  var ipcCount: Int? { nil }
  func prepare(_ node: Int, timeout: Double) -> AXProbeValue? { nil }
  func releaseObservation(_ node: Int) {}
  func releaseNode(_ node: Int) {}
  func onScreen(_ frame: AXProbeFrame) -> Bool? { nil }
}

/// One full containment walk. Metadata describes risk; it never qualifies text access.
public final class AXProbeExtractor {
  private let provider: AXProbeProvider
  private let permitted: () -> Bool
  private let now: () -> Double
  private let progress: (Int, Int, [String: Int]) -> Void
  private var result = AXProbeResult()
  private var visited = Set<Int>()
  private var deadline: Double = 0
  private var rootReadStart: Double = 0
  private var stopped = false
  private var overloaded = false
  private var retainedCharge = 4096
  public init(provider: AXProbeProvider, permitted: @escaping () -> Bool, now: @escaping () -> Double,
    progress: @escaping (Int, Int, [String: Int]) -> Void = { _, _, _ in }) {
    self.provider = provider; self.permitted = permitted; self.now = now; self.progress = progress
  }
  private func truncate(_ status: AXProbeStatus) {
    result.truncated = true
    if result.truncations?[status.rawValue] == nil { result.truncations?[status.rawValue] = 1 }
    result.counts["truncation_" + status.rawValue] = 1
    progress(result.elements, result.acquiredBytes, result.counts)
  }
  private func resourceTruncation(_ length: Int) {
    truncate(.resource_truncated)
    let sum = result.counts["resource_truncated_original_utf16", default: 0].addingReportingOverflow(length)
    result.counts["resource_truncated_original_utf16"] = sum.overflow ? Int.max : sum.partialValue
    if sum.overflow { result.counts["resource_length_sum_overflow"] = 1 }
  }
  private func stop(_ status: AXProbeStatus) {
    if !stopped { result.status = status }
    if status != .cancelled { truncate(status) }
    stopped = true
  }
  private func read(_ node: Int, _ attribute: AXProbeAttribute) -> AXProbeValue {
    guard !stopped else { return .unsupported }
    guard permitted() else { stop(.cancelled); return .unsupported }
    let remaining = deadline - now()
    guard remaining > 0 else { stop(.deadline); return .unsupported }
    if provider.ipcCount == nil { result.ipc += 1 }
    let value = provider.read(node, attribute, timeout: min(0.050, remaining))
    if let actual = provider.ipcCount { result.ipc = actual }
    inspect(value)
    return value
  }
  private func inspect(_ value: AXProbeValue) {
    if case .stopped(let reason) = value { stop(reason) }
    if case .resourceTruncated(let length) = value {
      resourceTruncation(length)
    }
    if case .failure(let code) = value {
      result.error = code
      if code == -25204 { stop(.messagingFailure) }
      if code == -25202 { result.counts["invalid_element", default: 0] += 1 }
    }
  }
  private func prepare(_ node: Int) {
    guard !stopped else { return }
    guard permitted() else { stop(.cancelled); return }
    guard now() < deadline else { stop(.deadline); return }
    if let error = provider.prepare(node, timeout: min(0.050, deadline - now())) { inspect(error) }
    if let actual = provider.ipcCount { result.ipc = actual }
  }
  private func string(_ node: Int, _ attribute: AXProbeAttribute) -> String? {
    guard case .string(let value) = read(node, attribute) else { return nil }
    if value.utf16.count > AXProbeResources.stringUTF16 {
      resourceTruncation(value.utf16.count)
      return nil
    }
    return value
  }
  private func flag(_ node: Int, _ attribute: AXProbeAttribute) -> Bool? {
    guard case .bool(let value) = read(node, attribute) else { return nil }
    return value
  }
  private func frame(_ node: Int) -> AXProbeFrame? {
    guard case .frame(let frame) = read(node, .frame), frame.x.isFinite, frame.y.isFinite,
      frame.width.isFinite, frame.height.isFinite, !frame.isNull,
      (frame.x + frame.width).isFinite, (frame.y + frame.height).isFinite else { return nil }
    return frame
  }
  private func children(_ node: Int, visit: (Int) -> Void) {
    for name in ["AXChildren", "AXContents", "AXRows", "AXColumns", "AXTabs"] {
      guard !stopped else { break }
      let total = read(node, .count(name))
      guard case .integer(let size) = total, size >= 0 else {
        if total != .unsupported { result.counts["unresolved_children", default: 0] += 1 }
        continue
      }
      let limit = min(size, 50000)
      if size > limit { truncate(.elementLimit) }
      var offset = 0
      while offset < limit && !stopped {
        if result.elements >= 50000 { truncate(.elementLimit); return }
        let take = min(64, limit - offset)
        guard case .nodes(let page) = read(node, .page(name, offset, take)), !page.isEmpty else {
          result.counts["unresolved_children", default: 0] += 1; offset += take; continue
        }
        for child in page.prefix(take) {
          visit(child)
          if stopped { return }
        }
        offset += min(page.count, take)
      }
    }
  }
  private func walk(_ node: Int, depth: Int, window: AXProbeFrame?,
    hidden: Bool? = false, collapsed: Bool? = false, unselected: Bool? = false,
    nonSelectedTab: Bool? = false, underTabGroup: Bool = false) {
    guard !stopped else { return }
    // Repeated references are visited once, including cycles, without discarding siblings.
    guard !visited.contains(node) else { result.counts["repeated_reference", default: 0] += 1; return }
    guard depth <= 256 else { truncate(.depthLimit); return }
    guard result.elements < 50000 else { truncate(.elementLimit); return }
    visited.insert(node)
    result.elements += 1
    let nodeStart = depth == 0 ? rootReadStart : now()
    prepare(node)
    let branch = observe(node, depth: depth, window: window, hidden: hidden, collapsed: collapsed,
      unselected: unselected, nonSelectedTab: nonSelectedTab, underTabGroup: underTabGroup)
    if let last = result.nodes?.indices.last, result.nodes?[last].nodeID == node {
      result.nodes?[last].readSeconds = max(0, now() - nodeStart)
    }
    provider.releaseObservation(node)
    defer { provider.releaseNode(node) }
    progress(result.elements, result.acquiredBytes, result.counts)
    children(node) { child in
      walk(child, depth: depth + 1, window: window, hidden: branch.0, collapsed: branch.1,
        unselected: branch.2, nonSelectedTab: branch.3, underTabGroup: branch.4)
    }
  }
  // Raw strings leave this stack frame before descending, even after an overload release.
  private func observe(_ node: Int, depth: Int, window: AXProbeFrame?, hidden: Bool?, collapsed: Bool?,
    unselected: Bool?, nonSelectedTab: Bool?, underTabGroup: Bool) -> (Bool?, Bool?, Bool?, Bool?, Bool) {
    var metadataLengths: [(String, Int)] = []
    func metadata(_ attribute: AXProbeAttribute, _ name: String) -> String? {
      switch read(node, attribute) {
      case .string(let value):
        let length = value.utf16.count
        if length > AXProbeResources.stringUTF16 {
          resourceTruncation(length); metadataLengths.append((name, length)); return nil
        }
        return value
      case .resourceTruncated(let length): metadataLengths.append((name, length)); return nil
      default: return nil
      }
    }
    let role = metadata(.role, "AXRole"), subrole = metadata(.subrole, "AXSubrole")
    let pid: Int?
    if case .integer(let value) = read(node, .pid) { pid = value } else { pid = nil }
    let bundle = metadata(.bundleID, "AXBundleIdentifier")
    let bounds = frame(node)
    func inherited(_ parent: Bool?, _ local: Bool?) -> Bool? {
      if parent == true || local == true { return true }
      return parent == false && local == false ? false : nil
    }
    let isHidden = inherited(hidden, flag(node, .hidden))
    let isCollapsed = inherited(collapsed, flag(node, .expanded).map { !$0 })
    let selected = flag(node, .selected)
    let isUnselected = inherited(unselected, selected.map { !$0 })
    let tab = ["AXTab", "AXTabPanel", "AXPage"].contains(role ?? "") || (underTabGroup && role == "AXRadioButton")
    let isNonSelectedTab = inherited(nonSelectedTab, tab ? selected.map { !$0 } : false)
    let secure = role == "AXSecureTextField" || subrole == "AXSecureTextField" || flag(node, .secure) == true
    if secure { result.counts["secure_fields", default: 0] += 1 }
    var observation = AXProbeNode(nodeID: node, role: role, subrole: subrole, depth: depth, pid: pid,
      bundleID: bundle, insideWindow: bounds.flatMap { frame in window.map { $0.contains(frame) } }, onScreen: bounds.flatMap { provider.onScreen($0) },
      hiddenBranch: isHidden, collapsedBranch: isCollapsed, unselectedBranch: isUnselected,
      nonSelectedTab: isNonSelectedTab, secure: secure, attributes: [])
    observation.selected = selected
    retainedCharge += 1024 + (role?.utf8.count ?? 0) + (subrole?.utf8.count ?? 0) + (bundle?.utf8.count ?? 0)
    func retain(_ text: String, name: String, originalLength: Int? = nil) {
      guard !overloaded else { return }
      let bytes = text.utf8.count
      if retainedCharge + bytes + 128 + name.utf8.count > AXProbeResources.attemptBytes {
        overloaded = true; result.nodes = []; result.text = ""
        result.counts["overload_dropped"] = 1
        return
      }
      retainedCharge += bytes + 128 + name.utf8.count
      var value = AXProbeText(attribute: name, text: text)
      value.originalLength = originalLength; value.resourceTruncated = originalLength == nil ? nil : true
      observation.attributes.append(value); result.acquiredBytes += bytes
    }
    for (name, length) in metadataLengths { retain("", name: name, originalLength: length) }
    for (attribute, name) in [(AXProbeAttribute.value, "AXValue"), (.title, "AXTitle"),
      (.description, "AXDescription"), (.help, "AXHelp"), (.placeholder, "AXPlaceholderValue"),
      (.selectedText, "AXSelectedText"), (.url, "AXURL"), (.document, "AXDocument")] {
      if secure && (attribute == .value || attribute == .selectedText) { continue }
      switch read(node, attribute) {
      case .string(let text):
        if text.utf16.count > AXProbeResources.stringUTF16 {
          resourceTruncation(text.utf16.count)
          retain("", name: name, originalLength: text.utf16.count)
        } else { retain(text, name: name) }
      case .resourceTruncated(let length): retain("", name: name, originalLength: length)
      default: break
      }
    }
    if !secure, case .range(let start, let length) = read(node, .visibleRange), start >= 0, length >= 0,
      start <= Int.max - length {
      if length > AXProbeResources.stringUTF16 {
        resourceTruncation(length)
        retain("", name: "AXStringForVisibleRange", originalLength: length)
      } else {
        var text = "", offset = 0
        while offset < length && !stopped {
          // Providers trim a trailing split surrogate, and we advance by
          // the returned length so the next request begins at a complete scalar.
          let count = min(AXProbeResources.rangeUTF16, length - offset)
          guard let part = string(node, .substring(start + offset, count)), !part.isEmpty else { break }
          text += part; offset += part.utf16.count
        }
        retain(text, name: "AXStringForVisibleRange")
        if offset < length { result.counts["visible_range_incomplete", default: 0] += 1 }
      }
    }
    if !overloaded {
      result.acquiredBytes += (role?.utf8.count ?? 0) + (subrole?.utf8.count ?? 0) + (bundle?.utf8.count ?? 0)
      if retainedCharge > AXProbeResources.attemptBytes {
        overloaded = true; result.nodes = []; result.counts["overload_dropped"] = 1
      } else { result.nodes?.append(observation) }
    }
    return (isHidden, isCollapsed, isUnselected, isNonSelectedTab, role == "AXTabGroup")
  }
  public func acquire(_ window: WindowIdentity) -> AXProbeResult {
    result.start = now(); deadline = result.start + 15
    result.nodes = []; result.truncations = [:]
    let app = provider.application
    switch read(app, .manualAccessibility) {
    case .bool(true): result.manualAccessibility = "set"
    case .bool(false), .unsupported: result.manualAccessibility = "not_settable"
    default: result.manualAccessibility = "failed"
    }
    if let manual = result.manualAccessibility {
      result.counts["manual_accessibility_" + manual] = 1
      progress(result.elements, result.acquiredBytes, result.counts)
    }
    guard case .node(let focused) = read(app, .focusedWindow) else {
      if !stopped { result.status = .identityUnknown }
      result.end = now(); return result
    }
    rootReadStart = now()
    prepare(focused)
    let bounds = frame(focused)
    result.identity = bounds.map { provider.matchingWindows(window, frame: $0) } == true
      ? "geometry_validated" : "focused_window_unverified"
    walk(focused, depth: 0, window: bounds)
    if !permitted() || result.status == .cancelled {
      result.text = ""; result.nodes = []; result.status = .cancelled
    } else {
      // Node text is the only acquisition copy. Never construct a duplicate parent aggregate.
      if overloaded && !stopped { result.status = .overload_dropped }
      else if !stopped { result.status = result.acquiredBytes > 0 && (result.nodes ?? []).contains { $0.attributes.contains { !$0.text.isEmpty } } ? .completed : .empty }
    }
    result.end = now(); return result
  }
}

public struct AXProbeWindowCandidate {
  public var identity: WindowIdentity
  public var layer: Int
  public var frame: AXProbeFrame
  public init(identity: WindowIdentity, layer: Int, frame: AXProbeFrame) {
    self.identity = identity; self.layer = layer; self.frame = frame
  }
}
public enum AXProbeWindowMatching {
  /// Candidates must already be on-screen. Geometry is approximate evidence, never an exact-ID bridge.
  public static func matches(_ request: WindowIdentity, frame: AXProbeFrame, candidates: [AXProbeWindowCandidate]) -> Bool {
    let matches = candidates.filter { candidate in
      !candidate.frame.isNull && candidate.frame.x.isFinite && candidate.frame.y.isFinite
        && candidate.frame.width.isFinite && candidate.frame.height.isFinite
        && candidate.layer == 0 && candidate.identity.processID == request.processID
        && zip([candidate.frame.x, candidate.frame.y, candidate.frame.width, candidate.frame.height],
          [frame.x, frame.y, frame.width, frame.height]).allSatisfy { abs($0 - $1) <= 2 }
    }
    return matches.count == 1 && matches[0].identity == request
  }
}

public enum AXProbeUTF16 {
  public static func wellFormed(_ units: [UInt16]) -> Bool {
    var offset = 0
    while offset < units.count {
      let value = units[offset]
      if (0xD800...0xDBFF).contains(value) {
        guard offset + 1 < units.count, (0xDC00...0xDFFF).contains(units[offset + 1]) else { return false }
        offset += 2
      } else {
        guard !(0xDC00...0xDFFF).contains(value) else { return false }
        offset += 1
      }
    }
    return true
  }
}
