import AppKit
import ApplicationServices
import Core
import Foundation

private func nativeAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
  AXUIElementSetMessagingTimeout(element, 1.0)
  var value: CFTypeRef?
  guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
  return value
}
private func focusedWindow(_ pid: Int32) -> AXUIElement? {
  guard let value = nativeAttribute(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute),
    CFGetTypeID(value) == AXUIElementGetTypeID()
  else { return nil }
  return (value as! AXUIElement)
}
struct FrontWindowBoundary {
  var application: () -> FrontObservation
  var listed: (Int32) -> (String, UInt32?)
  var trusted: () -> Bool
  var focused: (Int32) -> Any?
  var attribute: (Any, String) -> Any?
  var browser: (String) -> Bool?
  var uptime: () -> Double
  var wallTime: () -> Double
  var work: (@escaping () -> Void) -> Void
  static var native: FrontWindowBoundary {
    let queue = DispatchQueue(label: "ActivityProbe.Inbound.FrontWindow")
    return FrontWindowBoundary(application: {
      guard let app = NSWorkspace.shared.frontmostApplication else { return FrontObservation() }
      return FrontObservation(bundleID: app.bundleIdentifier ?? "", app: app.localizedName ?? "",
        isBrowserKnown: false, processID: app.processIdentifier)
    }, listed: { pid in
      let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
      let window = windows.first { ($0[kCGWindowLayer as String] as? Int) == 0 && ($0[kCGWindowOwnerPID as String] as? Int32) == pid }
      return (window?[kCGWindowName as String] as? String ?? "", (window?[kCGWindowNumber as String] as? NSNumber)?.uint32Value)
    }, trusted: { AXIsProcessTrusted() }, focused: { focusedWindow($0) }, attribute: { element, name in
      nativeAttribute(element as! AXUIElement, name)
    }, browser: { MacFrontWindowSource.isBrowser($0) }, uptime: { ProcessInfo.processInfo.systemUptime },
    wallTime: { Date().timeIntervalSince1970 }, work: { queue.async(execute: $0) })
  }
  func string(_ element: Any, _ name: String) -> String? {
    let value = attribute(element, name)
    return (value as? String) ?? (value as? URL)?.absoluteString
  }
  func webAddress(_ window: Any) -> (address: String?, finished: Bool) {
    var queue: [(Any, Int)] = [(window, 0)]
    let deadline = uptime() + 0.5
    var visited = 0
    while !queue.isEmpty, visited < 300, uptime() < deadline {
      let (element, depth) = queue.removeFirst(); visited += 1
      if string(element, kAXRoleAttribute) == "AXWebArea", let url = string(element, "AXURL") { return (url, true) }
      if depth < 10, let children = attribute(element, kAXChildrenAttribute) as? [Any] {
        queue.append(contentsOf: children.map { ($0, depth + 1) })
      }
    }
    return (nil, queue.isEmpty)
  }
}

// Lock owns cached/completed observations and worker state; AX work runs off the caller thread.
public final class MacFrontWindowSource: FrontWindowSource {
  private let boundary: FrontWindowBoundary
  private var generation = 0
  private let lock = NSLock()
  private var busy = false
  private struct Cache {
    var identity: WindowIdentity
    var observation: FrontObservation
    var serverTitle: String
    var time: TimeInterval
    var addressFinished: Bool
  }
  private var cached: Cache?
  private var completed: [FrontObservation] = []
  private var browsers: [String: Bool] = [:]
  public convenience init() { self.init(boundary: .native) }
  init(boundary: FrontWindowBoundary) { self.boundary = boundary }
  public func invalidateMetadata() {
    lock.lock(); defer { lock.unlock() }
    generation += 1; cached = nil; completed.removeAll()
  }
  public func frontApplication() -> FrontObservation {
    if !Thread.isMainThread { return DispatchQueue.main.sync { self.frontApplication() } }
    return boundary.application()
  }
  public func details(for application: FrontObservation) -> FrontObservation {
    if !Thread.isMainThread { return DispatchQueue.main.sync { self.details(for: application) } }
    let pid = application.processID
    let (title, id) = boundary.listed(pid)
    var result = application
    result.title = title
    result.window = id.map { WindowIdentity(processID: pid, windowID: $0) }
    guard boundary.trusted() else {
      result.accessibility = .permission
      return result
    }
    guard let identity = result.window else {
      result.accessibility = .unavailable
      return result
    }
    lock.lock()
    defer { lock.unlock() }
    result.isBrowser = browsers[application.bundleID] ?? false
    result.isBrowserKnown = browsers[application.bundleID] != nil
    let prior = cached?.identity == identity ? cached : nil
    let serverTitle = result.title
    if let prior, prior.serverTitle == serverTitle,
      boundary.uptime() - prior.time < Double(RecorderTiming.accessibilityCacheSeconds)
    {
      result = prior.observation
    } else {
      result.accessibility = .unavailable
    }
    if !busy && (prior == nil || prior!.serverTitle != serverTitle
      || boundary.uptime() - prior!.time >= Double(RecorderTiming.accessibilityCacheSeconds)) {
      busy = true
      let initial = result
      let browserAnswer = browsers[application.bundleID]
      // AX questions run off the caller's thread and publish a named cache under lock.
      let generation = self.generation
      boundary.work {
        var addressFinished = false
        var answer = initial
        answer.observedAt = self.boundary.wallTime()
        let isBrowser = browserAnswer ?? self.boundary.browser(application.bundleID)
        answer.isBrowser = isBrowser ?? false
        answer.isBrowserKnown = isBrowser != nil
        if let window = self.boundary.focused(pid), self.boundary.string(window, kAXRoleAttribute) == "AXWindow" {
          answer.title = self.boundary.string(window, kAXTitleAttribute) ?? serverTitle
          answer.document = self.boundary.string(window, kAXDocumentAttribute)
          let walk = self.boundary.webAddress(window)
          answer.browserAddress = walk.address
          addressFinished = walk.finished
          answer.accessibility = nil
        } else {
          answer.accessibility = .unavailable
        }
        self.lock.lock()
        guard self.generation == generation else { self.busy = false; self.lock.unlock(); return }
        self.browsers[application.bundleID] = isBrowser
        self.cached = Cache(
          identity: identity, observation: answer, serverTitle: serverTitle,
          time: self.boundary.uptime(), addressFinished: addressFinished)
        self.completed.append(answer)
        self.busy = false
        self.lock.unlock()
      }
    }
    return result
  }
  public func takeCompletedDetails() -> [FrontObservation] {
    lock.lock(); defer { lock.unlock() }
    let result = completed; completed.removeAll(); return result
  }
  fileprivate static func isBrowser(_ bundleID: String) -> Bool {
    ["http", "https"].contains { scheme in
      NSWorkspace.shared.urlsForApplications(toOpen: URL(string: scheme + "://invented.invalid")!)
        .contains { Bundle(url: $0)?.bundleIdentifier?.lowercased() == bundleID.lowercased() }
    }
  }
}
