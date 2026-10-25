import AppKit
import ApplicationServices
import Core
import Darwin
import Foundation

public enum AXProbeClock {
  public static func now() -> Double {
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    return Double(mach_continuous_time()) * Double(timebase.numer) / Double(timebase.denom) / 1e9
  }
}

// The boundary guard counts initiated native calls, including each half of a frame read.
// nil means native success; local cancellation/limits never manufacture an AXError.
final class AXProbeIPCBudget {
  private let deadline: Double
  private let permitted: () -> Bool
  private let now: () -> Double
  private let started: () -> Void
  private(set) var calls = 0
  init(deadline: Double, permitted: @escaping () -> Bool, now: @escaping () -> Double,
    started: @escaping () -> Void = {}) {
    self.deadline = deadline; self.permitted = permitted; self.now = now; self.started = started
  }
  func perform(timeout: Double, configure: (Double) -> Int, body: () -> Int) -> AXProbeValue? {
    guard permitted() else { return .stopped(.cancelled) }
    let remaining = min(timeout, deadline - now())
    guard remaining > 0 else { return .stopped(.deadline) }
    let configured = configure(min(0.050, remaining))
    guard configured == 0 else { return .failure(configured) }
    // Configuration is local, but policy/time may change before the IPC itself begins.
    guard permitted() else { return .stopped(.cancelled) }
    guard now() < deadline else { return .stopped(.deadline) }
    calls += 1; started()
    let error = body()
    if [-25205, -25213, -25212, -25208].contains(error) { return .unsupported }
    return error == 0 ? nil : .failure(error)
  }
}

enum AXProbeBatchRetry {
  static func warrants(_ value: AXProbeValue) -> Bool {
    value == .failure(-25200) || value == .failure(-25201) || value == .unsupported
  }
  static func resolve(_ value: AXProbeValue, batchError: AXProbeValue?, retry: () -> AXProbeValue) -> AXProbeValue {
    if let batchError, warrants(batchError) { return retry() }
    if value != .unsupported && warrants(value) { return retry() }
    return value
  }
}

enum AXProbeManualAccessibility {
  static func enable(isSettable: () -> AXProbeValue, set: () -> AXProbeValue) -> AXProbeValue {
    let state = isSettable()
    guard state == .bool(true) else { return state }
    return set()
  }
}

// Native returns are injectable so decoding and CF ownership can be tested without live windows.
struct AXProbeNativeCalls {
  var configure: (AXUIElement, Float) -> AXError = AXUIElementSetMessagingTimeout
  var batch: (AXUIElement, [String]) -> (AXError, CFArray?) = { element, names in
    var value: CFArray?
    let error = AXUIElementCopyMultipleAttributeValues(element, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &value)
    return (error, value)
  }
  var single: (AXUIElement, String) -> (AXError, CFTypeRef?) = { element, name in
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
    return (error, value)
  }
  var page: (AXUIElement, String, Int, Int) -> (AXError, CFArray?) = { element, name, start, count in
    var value: CFArray?
    let error = AXUIElementCopyAttributeValues(element, name as CFString, start, count, &value)
    return (error, value)
  }
  var bundle: (pid_t) -> String = { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier ?? "" }
}

/// References never leave the serial worker. Only the opt-in accessibility attribute is written.
final class MacAXProbeProvider: AXProbeProvider {
  var application: Int { 0 }
  private var nodes: [AXUIElement]
  private var interned: [CFHashCode: [Int]] = [:]
  private var bundles: [pid_t: String] = [:]
  private var cached: [Int: [AXProbeAttribute: AXProbeValue]] = [:]
  private var rawValues: [Int: [AXProbeAttribute: CFTypeRef]] = [:]
  private var childLists: [Int: [String: CFArray]] = [:]
  private lazy var screenFrames: [AXProbeFrame]? = {
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
    var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return nil }
    return displays.prefix(Int(count)).map { display in
      let bounds = CGDisplayBounds(display)
      return AXProbeFrame(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height)
    }
  }()
  private let native: AXProbeNativeCalls
  private let permitted: () -> Bool
  private let progress: AXProbeProgress
  private let budget: AXProbeIPCBudget
  var calls: Int { budget.calls }
  var ipcCount: Int? { calls }
  init(pid: Int32, deadline: Double, permitted: @escaping () -> Bool, progress: AXProbeProgress,
    native: AXProbeNativeCalls = AXProbeNativeCalls(), now: @escaping () -> Double = AXProbeClock.now) {
    self.native = native
    nodes = [AXUIElementCreateApplication(pid)]
    interned[CFHash(nodes[0])] = [0]
    self.permitted = permitted; self.progress = progress
    budget = AXProbeIPCBudget(deadline: deadline, permitted: permitted, now: now, started: progress.readStarted)
  }
  private func intern(_ element: AXUIElement) -> Int {
    let hash = CFHash(element)
    if let existing = interned[hash]?.first(where: { CFEqual(nodes[$0], element) }) { return existing }
    let index = nodes.count
    nodes.append(element); interned[hash, default: []].append(index); return index
  }
  private func ipc(_ element: AXUIElement, timeout: Double, _ body: () -> AXError) -> AXProbeValue? {
    budget.perform(timeout: timeout,
      configure: { Int(native.configure(element, Float($0)).rawValue) },
      body: { Int(body().rawValue) })
  }
  private func copy(_ element: AXUIElement, _ attribute: String, timeout: Double) -> AXProbeValue {
    var raw: CFTypeRef?
    let error = ipc(element, timeout: timeout) { let result = native.single(element, attribute); raw = result.1; return result.0 }
    if let error { return error }
    guard let raw else { return .unsupported }
    return decode(raw)
  }
  private func decode(_ raw: CFTypeRef) -> AXProbeValue {
    if CFGetTypeID(raw) == AXUIElementGetTypeID() { return .node(intern(unsafeBitCast(raw, to: AXUIElement.self))) }
    if CFGetTypeID(raw) == CFStringGetTypeID() {
      let text = unsafeBitCast(raw, to: CFString.self), length = CFStringGetLength(unsafeBitCast(raw, to: CFString.self))
      guard length <= AXProbeResources.stringUTF16 else { return .resourceTruncated(length) }
      return .string(text as String)
    }
    if CFGetTypeID(raw) == CFURLGetTypeID(), let text = CFURLGetString(unsafeBitCast(raw, to: CFURL.self)) {
      let length = CFStringGetLength(text)
      return length > AXProbeResources.stringUTF16 ? .resourceTruncated(length) : .string(text as String)
    }
    if let text = raw as? NSAttributedString {
      guard text.length <= AXProbeResources.stringUTF16 else { return .resourceTruncated(text.length) }
      return .string(text.string)
    }
    if CFGetTypeID(raw) == CFBooleanGetTypeID(), let number = raw as? NSNumber { return .bool(number.boolValue) }
    if CFGetTypeID(raw) == CFNumberGetTypeID(), let number = raw as? NSNumber { return .integer(number.intValue) }
    if CFGetTypeID(raw) == AXValueGetTypeID() {
      let value = unsafeBitCast(raw, to: AXValue.self)
      if AXValueGetType(value) == .axError {
        var error = AXError.success
        if AXValueGetValue(value, .axError, &error) {
          return [-25205, -25213, -25212, -25208].contains(Int(error.rawValue)) ? .unsupported : .failure(Int(error.rawValue))
        }
      }
      if AXValueGetType(value) == .cfRange {
        var range = CFRange()
        if AXValueGetValue(value, .cfRange, &range) { return .range(range.location, range.length) }
      }
    }
    return .unsupported
  }
  func prepare(_ node: Int, timeout: Double) -> AXProbeValue? {
    guard cached[node] == nil else { return nil }
    guard nodes.indices.contains(node) else { return .failure(-25202) }
    let element = nodes[node]
    let attributes: [(AXProbeAttribute, String)] = [
      (.role, "AXRole"), (.subrole, "AXSubrole"), (.hidden, "AXHidden"),
      (.expanded, "AXExpanded"), (.selected, "AXSelected"), (.secure, "AXIsSecure"),
      (.title, "AXTitle"), (.description, "AXDescription"), (.help, "AXHelp"),
      (.placeholder, "AXPlaceholderValue"),
      (.url, "AXURL"), (.document, "AXDocument"), (.characterCount, "AXNumberOfCharacters"),
      (.visibleRange, "AXVisibleCharacterRange")]
    let children = ["AXChildren", "AXContents", "AXRows", "AXColumns", "AXTabs"]
    let names = attributes.map(\.1) + ["AXPosition", "AXSize"] + children
    var raw: CFArray?
    let error = ipc(element, timeout: timeout) {
      let result = native.batch(element, names); raw = result.1; return result.0
    }
    if let error, !AXProbeBatchRetry.warrants(error) { return error }
    let values = (raw as? [AnyObject]) ?? []
    var decoded: [String: AXProbeValue] = [:]
    var retained: [String: CFTypeRef] = [:]
    func diagnostic(_ value: CFTypeRef) -> AXProbeValue {
      guard CFGetTypeID(value) == AXValueGetTypeID(),
        AXValueGetType(unsafeBitCast(value, to: AXValue.self)) == .axError else { return .unsupported }
      return decode(value)
    }
    var position: CGPoint?, size: CGSize?
    for (index, name) in names.enumerated() {
      var value: CFTypeRef? = index < values.count ? values[index] : nil
      var outcome = value.map(diagnostic) ?? error ?? .unsupported
      // Unsupported/no-value attributes are final. Generic batch errors can be retried singly;
      // a cannot-complete response is a real messaging failure and must not be retried.
      outcome = AXProbeBatchRetry.resolve(outcome, batchError: error) {
        value = nil
        let single = ipc(element, timeout: timeout) { let result = native.single(element, name); value = result.1; return result.0 }
        return single ?? value.map(diagnostic) ?? .unsupported
      }
      if case .stopped = outcome { return outcome }
      if outcome == .failure(-25204) { return outcome }
      if let value { retained[name] = value }
      if let value, CFGetTypeID(value) == AXValueGetTypeID() {
        let ax = unsafeBitCast(value, to: AXValue.self)
        if name == "AXPosition" && AXValueGetType(ax) == .cgPoint {
          var point = CGPoint.zero
          if AXValueGetValue(ax, .cgPoint, &point) { position = point }
        }
        if name == "AXSize" && AXValueGetType(ax) == .cgSize {
          var dimensions = CGSize.zero
          if AXValueGetValue(ax, .cgSize, &dimensions) { size = dimensions }
        }
      }
      if children.contains(name), let value, CFGetTypeID(value) == CFArrayGetTypeID() {
        let array = unsafeBitCast(value, to: CFArray.self), count = CFArrayGetCount(array)
        childLists[node, default: [:]][name] = array
        decoded[name] = .integer(count)
      } else { decoded[name] = outcome }
    }
    // Identify protected fields before requesting any value-bearing attribute.
    let secure = ["AXRole", "AXSubrole"].contains { retained[$0].map(decode) == .string("AXSecureTextField") }
      || retained["AXIsSecure"].map(decode) == .bool(true)
    let valueAttributes: [(AXProbeAttribute, String)] = [(.value, "AXValue"), (.selectedText, "AXSelectedText")]
    var valueCache: [AXProbeAttribute: AXProbeValue] = [:]
    if !secure {
      var rawText: CFArray?
      let textError = ipc(element, timeout: timeout) {
        let result = native.batch(element, valueAttributes.map(\.1)); rawText = result.1; return result.0
      }
      if let textError, !AXProbeBatchRetry.warrants(textError) { return textError }
      let texts = (rawText as? [AnyObject]) ?? []
      for (index, item) in valueAttributes.enumerated() {
        var value: CFTypeRef? = index < texts.count ? texts[index] : nil
        let outcome = AXProbeBatchRetry.resolve(value.map(diagnostic) ?? textError ?? .unsupported, batchError: textError) {
          value = nil
          let single = ipc(element, timeout: timeout) {
            let result = native.single(element, item.1); value = result.1; return result.0
          }
          return single ?? value.map(diagnostic) ?? .unsupported
        }
        if case .stopped = outcome { return outcome }
        if outcome == .failure(-25204) { return outcome }
        if let value { retained[item.1] = value }
        valueCache[item.0] = outcome
      }
    }
    rawValues[node] = Dictionary(uniqueKeysWithValues: (attributes + valueAttributes).compactMap { attribute, name in attribute == .secure ? nil : retained[name].map { (attribute, $0) } })
    var cache = Dictionary(uniqueKeysWithValues: attributes.map { ($0.0, decoded[$0.1] ?? .unsupported) })
    cache.merge(valueCache) { _, new in new }
    cache[.secure] = .bool(secure)
    cache[.frame] = position.flatMap { point in size.map { .frame(AXProbeFrame(x: point.x, y: point.y, width: $0.width, height: $0.height)) } } ?? .unsupported
    for name in children { cache[.count(name)] = decoded[name] ?? .unsupported }
    // AXUIElementGetPid reads the local AX reference; it does not message the target process.
    var pid: pid_t = 0
    if AXUIElementGetPid(element, &pid) == .success {
      cache[.pid] = .integer(Int(pid))
      let bundle = bundles[pid] ?? native.bundle(pid)
      bundles[pid] = bundle; cache[.bundleID] = bundle.isEmpty ? .unsupported : .string(bundle)
    }
    cached[node] = cache
    return nil
  }
  var retainedChildSlots: Int { childLists.values.reduce(0) { $0 + $1.values.reduce(0) { $0 + CFArrayGetCount($1) } } }
  func releaseObservation(_ node: Int) {
    rawValues.removeValue(forKey: node)
    childLists.removeValue(forKey: node)
    cached[node] = cached[node]?.filter { if case .count = $0.key { return true }; return $0.key == .secure }
  }
  func releaseNode(_ node: Int) { rawValues.removeValue(forKey: node); cached.removeValue(forKey: node); childLists.removeValue(forKey: node) }
  func read(_ node: Int, _ attribute: AXProbeAttribute, timeout: Double) -> AXProbeValue {
    guard nodes.indices.contains(node) else { return .failure(Int(AXError.invalidUIElement.rawValue)) }
    if cached[node]?[.secure] == .bool(true) {
      switch attribute { case .value, .selectedText, .visibleRange, .substring: return .unsupported; default: break }
    }
    if let raw = rawValues[node]?[attribute] { return decode(raw) }
    if let value = cached[node]?[attribute] { return value }
    if case .page(let name, let start, let count) = attribute, let list = childLists[node]?[name] {
      guard start >= 0, (1...64).contains(count) else { return .unsupported }
      guard start < CFArrayGetCount(list) else { return .nodes([]) }
      var ids: [Int] = []
      for offset in start..<min(CFArrayGetCount(list), start + count) {
        let raw = unsafeBitCast(CFArrayGetValueAtIndex(list, offset), to: CFTypeRef.self)
        if CFGetTypeID(raw) == AXUIElementGetTypeID() { ids.append(intern(unsafeBitCast(raw, to: AXUIElement.self))) }
      }
      return .nodes(ids)
    }
    let element = nodes[node]
    switch attribute {
    case .manualAccessibility:
      guard node == application else { return .unsupported }
      let name = "AXManualAccessibility" as CFString
      return AXProbeManualAccessibility.enable(isSettable: {
        var settable: DarwinBoolean = false
        let error = ipc(element, timeout: timeout) { AXUIElementIsAttributeSettable(element, name, &settable) }
        return error ?? .bool(settable.boolValue)
      }, set: {
        let error = ipc(element, timeout: timeout) { AXUIElementSetAttributeValue(element, name, kCFBooleanTrue) }
        return error ?? .bool(true)
      })
    case .bundleID:
      var pid: pid_t = 0
      let error = ipc(element, timeout: timeout) { AXUIElementGetPid(element, &pid) }
      if let error { return error }
      let bundle = bundles[pid] ?? native.bundle(pid)
      bundles[pid] = bundle
      return bundle.isEmpty ? .unsupported : .string(bundle)
    case .pid:
      var pid: pid_t = 0
      let error = ipc(element, timeout: timeout) { AXUIElementGetPid(element, &pid) }
      return error ?? .integer(Int(pid))
    case .frame:
      var position: CFTypeRef?, size: CFTypeRef?
      var error = ipc(element, timeout: timeout) { AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) }
      if let error { return error }
      guard let position, CFGetTypeID(position) == AXValueGetTypeID() else { return .unsupported }
      error = ipc(element, timeout: timeout) { AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) }
      if let error { return error }
      guard let size, CFGetTypeID(size) == AXValueGetTypeID() else { return .unsupported }
      var point = CGPoint.zero, dimensions = CGSize.zero
      guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
        AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions) else { return .unsupported }
      return .frame(AXProbeFrame(x: point.x, y: point.y, width: dimensions.width, height: dimensions.height))
    case .count(let attribute):
      var count: CFIndex = 0
      let error = ipc(element, timeout: timeout) { AXUIElementGetAttributeValueCount(element, attribute as CFString, &count) }
      return error ?? .integer(count)
    case .page(let attribute, let offset, let count):
      guard offset >= 0, (1...64).contains(count) else { return .unsupported }
      var raw: CFArray?
      let error = ipc(element, timeout: timeout) {
        let result = native.page(element, attribute, offset, count); raw = result.1; return result.0
      }
      if let error { return error }
      guard let values = raw as? [AXUIElement], values.count <= 64 else { return .unsupported }
      return .nodes(values.map(intern))
    case .substring(let start, let count):
      guard start >= 0, count > 0, count <= AXProbeResources.rangeUTF16, start <= Int.max - count else { return .unsupported }
      var range = CFRange(location: start, length: count)
      guard let parameter = AXValueCreate(.cfRange, &range) else { return .unsupported }
      var raw: CFTypeRef?
      let error = ipc(element, timeout: timeout) {
        AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &raw)
      }
      if let error { return error }
      guard let raw, CFGetTypeID(raw) == CFStringGetTypeID() else { return .unsupported }
      let string = unsafeBitCast(raw, to: CFString.self)
      guard CFStringGetLength(string) == count else { return .unsupported }
      // Never convert a split UTF-16 surrogate into a repaired scalar.
      var units = [UInt16](repeating: 0, count: count)
      CFStringGetCharacters(string, CFRange(location: 0, length: count), &units)
      if let last = units.last, (0xD800...0xDBFF).contains(last) { units.removeLast() }
      guard AXProbeUTF16.wellFormed(units) else { return .unsupported }
      return .string(String(decoding: units, as: UTF16.self))
    default:
      let name: String
      switch attribute {
      case .role: name = kAXRoleAttribute
      case .subrole: name = kAXSubroleAttribute
      case .hidden: name = "AXHidden"
      case .expanded: name = kAXExpandedAttribute
      case .selected: name = kAXSelectedAttribute
      case .secure: name = "AXIsSecure"
      case .focusedWindow: name = kAXFocusedWindowAttribute
      case .focusedElement: name = kAXFocusedUIElementAttribute
      case .value: name = kAXValueAttribute
      case .title: name = kAXTitleAttribute
      case .description: name = kAXDescriptionAttribute
      case .help: name = kAXHelpAttribute
      case .placeholder: name = "AXPlaceholderValue"
      case .selectedText: name = kAXSelectedTextAttribute
      case .url: name = kAXURLAttribute
      case .document: name = kAXDocumentAttribute
      case .characterCount: name = kAXNumberOfCharactersAttribute
      case .visibleRange: name = kAXVisibleCharacterRangeAttribute
      default: return .unsupported
      }
      return copy(element, name, timeout: timeout)
    }
  }
  func onScreen(_ frame: AXProbeFrame) -> Bool? {
    screenFrames.map { frames in frames.contains { !frame.intersection($0).isNull } }
  }
  func matchingWindows(_ request: WindowIdentity, frame: AXProbeFrame) -> Bool {
    guard permitted(), let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
    let candidates: [AXProbeWindowCandidate] = windows.compactMap { window in
      guard let pid = window[kCGWindowOwnerPID as String] as? Int32,
        let id = window[kCGWindowNumber as String] as? UInt32,
        let layer = window[kCGWindowLayer as String] as? Int,
        let raw = window[kCGWindowBounds as String] as? [String: Any],
        let bounds = CGRect(dictionaryRepresentation: raw as CFDictionary) else { return nil }
      // CG and AX use global display points, including negative multi-display origins.
      return AXProbeWindowCandidate(identity: WindowIdentity(processID: pid, windowID: id), layer: layer,
        frame: AXProbeFrame(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height))
    }
    return AXProbeWindowMatching.matches(request, frame: frame, candidates: candidates)
  }
}

public final class MacAXProbeWorker {
  private let queue = DispatchQueue(label: "ActivityProbe.AXProbe")
  private let lock = NSLock()
  private var busy = false
  private var busyTicket: UUID?
  private var generation = 0
  private var disabledRuns = Set<String>()
  private var cooldowns: [Int32: Double] = [:]
  private var failures: [Int32: Int] = [:]
  private var seenPIDs = Set<Int32>()
  private var runID: String?
  private let monotonic: () -> Double
  private let watchdogSeconds: Double
  private let preflight: () -> Bool
  private let inventedRead: ((WindowIdentity, @escaping () -> Bool) -> AXProbeResult)?
  public init(preflight: @escaping () -> Bool = { AXIsProcessTrusted() && CGPreflightScreenCaptureAccess() },
    read: ((WindowIdentity, @escaping () -> Bool) -> AXProbeResult)? = nil,
    monotonic: @escaping () -> Double = AXProbeClock.now, watchdogSeconds: Double = 16) {
    self.watchdogSeconds = watchdogSeconds
    self.monotonic = monotonic
    self.preflight = preflight; self.inventedRead = read
  }
  public var isBusy: Bool { lock.lock(); defer { lock.unlock() }; return busy }
  public func invalidate() { lock.lock(); generation += 1; lock.unlock() }
  public func acquire(_ request: AXProbeRequest, permitted: @escaping () -> Bool,
    begin: @escaping () -> AXProbeStatus? = { nil }, end: @escaping (AXProbeResult) -> Void = { _ in },
    failurePolicyInStore: Bool = false, completion: @escaping (AXProbeResult) -> Void) {
    let entered = monotonic()
    lock.lock()
    if runID != request.run.id {
      runID = request.run.id
      cooldowns = [:]; failures = [:]; seenPIDs = []
    }
    let status: AXProbeStatus?
    if disabledRuns.contains(request.run.id) { status = .cancelled }
    else if busy { status = .busy }
    else if !failurePolicyInStore && (cooldowns[request.window.processID] ?? 0) > entered { status = .cooldown }
    else { status = nil }
    if let status { lock.unlock(); completion(AXProbeResult(status: status)); return }
    busy = true
    let ticket = UUID(); busyTicket = ticket
    let firstAttempt = seenPIDs.insert(request.window.processID).inserted
    let token = generation
    lock.unlock()
    let delivery = AXProbeDelivery(completion)
    let valid: () -> Bool = { [weak self] in
      guard let self else { return false }
      self.lock.lock()
      let allowed = self.generation == token && !self.disabledRuns.contains(request.run.id)
      self.lock.unlock()
      return allowed && permitted()
    }
    queue.async { [self] in
      let start = monotonic()
      let progress = AXProbeProgress()
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + watchdogSeconds) { [weak self] in
        guard let self else { return }
        self.lock.lock()
        guard self.busyTicket == ticket else { self.lock.unlock(); return }
        self.disabledRuns.insert(request.run.id); self.generation += 1
        self.lock.unlock()
        let callback = delivery.take()
        var result = AXProbeResult(status: .watchdog); result.start = start; result.end = start + self.watchdogSeconds
        result.truncated = true; result.truncations = ["watchdog": 1]; result.workerWall = self.watchdogSeconds
        result.queueWait = max(0, start - entered)
        progress.copy(into: &result)
        result.firstAttempt = firstAttempt && result.ipc > 0
        Self.recordOS(into: &result)
        end(result); callback?(result)
      }
      var cpuStart = timespec()
      let cpuAvailable = clock_gettime(CLOCK_THREAD_CPUTIME_ID, &cpuStart) == 0
      var result: AXProbeResult
      if !valid() { result = AXProbeResult(status: .cancelled) }
      else if !preflight() { result = AXProbeResult(status: .permission) }
      else if let refusal = begin() { result = AXProbeResult(status: refusal) }
      else if !valid() { result = AXProbeResult(status: .cancelled) }
      else if let inventedRead { result = inventedRead(request.window, valid) }
      else {
        let provider = MacAXProbeProvider(pid: request.window.processID, deadline: AXProbeClock.now() + 15, permitted: valid, progress: progress)
        let extractor = AXProbeExtractor(provider: provider, permitted: valid, now: AXProbeClock.now, progress: progress.update)
        result = extractor.acquire(request.window); result.ipc = provider.calls
      }
      var cpuEnd = timespec()
      if cpuAvailable && clock_gettime(CLOCK_THREAD_CPUTIME_ID, &cpuEnd) == 0 {
        result.cpu = Double(cpuEnd.tv_sec - cpuStart.tv_sec) + Double(cpuEnd.tv_nsec - cpuStart.tv_nsec) / 1e9
      }
      result.firstAttempt = firstAttempt && result.ipc > 0
      if firstAttempt && result.ipc == 0 { lock.lock(); seenPIDs.remove(request.window.processID); lock.unlock() }
      Self.recordOS(into: &result)
      result.queueWait = max(0, start - entered)
      lock.lock()
      // Production uses the persistent store as the sole streak owner, including after restart.
      if !failurePolicyInStore && result.status == .messagingFailure {
        failures[request.window.processID, default: 0] += 1
        result.counts["messaging_failures"] = 1
        if failures[request.window.processID, default: 0] >= 3 {
          cooldowns[request.window.processID] = monotonic() + 60
          failures[request.window.processID] = 0
          result.counts["cooldowns"] = 1
        }
      } else if !failurePolicyInStore && (result.status == .completed || result.status == .empty) { failures[request.window.processID] = 0 }
      lock.unlock()
      if !valid() { result.text = ""; result.nodes = []; result.status = .cancelled }
      result.workerWall = max(0, monotonic() - start)
      let callback = delivery.take()
      if callback != nil { end(result) }
      result.workerWall = max(0, monotonic() - start)
      callback?(result)
      lock.lock(); busy = false; busyTicket = nil; lock.unlock()
    }
  }
  private static func recordOS(into result: inout AXProbeResult) {
    let version = ProcessInfo.processInfo.operatingSystemVersion
    result.osVersion = [version.majorVersion, version.minorVersion, version.patchVersion]
    var build = [CChar](repeating: 0, count: 64), buildSize = 64
    if sysctlbyname("kern.osversion", &build, &buildSize, nil, 0) == 0 {
      result.osBuild = build.prefix { $0 != 0 }.map { Int(UInt8(bitPattern: $0)) }
    }
  }

}
private final class AXProbeDelivery {
  private let lock = NSLock()
  private var completion: ((AXProbeResult) -> Void)?
  init(_ completion: @escaping (AXProbeResult) -> Void) { self.completion = completion }
  func take() -> ((AXProbeResult) -> Void)? {
    lock.lock(); defer { lock.unlock() }
    let callback = completion; completion = nil; return callback
  }
  func finish(_ result: AXProbeResult) { take()?(result) }
}

// Only content-free counters cross the watchdog boundary; no AX reference or string payload does.
final class AXProbeProgress {
  private let lock = NSLock()
  private var ipc = 0, elements = 0, bytes = 0
  private var counts: [String: Int] = [:]
  func readStarted() { lock.lock(); ipc += 1; lock.unlock() }
  func update(_ elements: Int, _ bytes: Int, _ counts: [String: Int]) {
    lock.lock(); self.elements = elements; self.bytes = bytes; self.counts = counts; lock.unlock()
  }
  func copy(into result: inout AXProbeResult) {
    lock.lock(); defer { lock.unlock() }
    result.ipc = ipc; result.elements = elements; result.acquiredBytes = bytes; result.counts = counts
    result.manualAccessibility = ["set", "not_settable", "failed"].first { counts["manual_accessibility_" + $0] == 1 }
    for reason in ["elementLimit", "depthLimit", "deadline", "messagingFailure", "resource_truncated"] where counts["truncation_" + reason] == 1 {
      if result.truncations == nil { result.truncations = [:] }
      result.truncations?[reason] = 1
    }
  }
}
