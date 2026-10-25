import AppKit
import ApplicationServices
import Core
import Foundation

private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
  AXUIElementSetMessagingTimeout(element, 1.0)
  var value: CFTypeRef?
  guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
  return value
}
private func string(_ element: AXUIElement, _ name: String) -> String? {
  let value = attribute(element, name)
  return (value as? String) ?? (value as? URL)?.absoluteString
}
private func focusedWindow(_ pid: Int32) -> AXUIElement? {
  guard let value = attribute(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute),
    CFGetTypeID(value) == AXUIElementGetTypeID()
  else { return nil }
  return (value as! AXUIElement)
}
private func webAddress(_ window: AXUIElement) -> (address: String?, finished: Bool) {
  var queue: [(AXUIElement, Int)] = [(window, 0)]
  let deadline = ProcessInfo.processInfo.systemUptime + 0.5
  var visited = 0
  while !queue.isEmpty, visited < 300, ProcessInfo.processInfo.systemUptime < deadline {
    let (element, depth) = queue.removeFirst()
    visited += 1
    if string(element, kAXRoleAttribute) == "AXWebArea", let url = string(element, "AXURL") { return (url, true) }
    if depth < 10, let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
      queue.append(contentsOf: children.map { ($0, depth + 1) })
    }
  }
  return (nil, queue.isEmpty)
}

// lock owns cache/busy/browser answers; AX work runs on the worker queue.
public final class MacFrontWindowSource: FrontWindowSource {
  private let queue = DispatchQueue(label: "ActivityProbe.Inbound.FrontWindow")
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
  private var browsers: [String: Bool] = [:]
  public init() {}
  public func frontApplication() -> FrontObservation {
    if !Thread.isMainThread { return DispatchQueue.main.sync { self.frontApplication() } }
    guard let app = NSWorkspace.shared.frontmostApplication else { return FrontObservation() }
    return FrontObservation(
      bundleID: app.bundleIdentifier ?? "", app: app.localizedName ?? "",
      isBrowserKnown: false, processID: app.processIdentifier)
  }
  public func details(for application: FrontObservation) -> FrontObservation {
    if !Thread.isMainThread { return DispatchQueue.main.sync { self.details(for: application) } }
    let pid = application.processID
    let listed =
      CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID) as? [[String: Any]] ?? []
    let window = listed.first {
      ($0[kCGWindowLayer as String] as? Int) == 0 && ($0[kCGWindowOwnerPID as String] as? Int32) == pid
    }
    var result = application
    result.title = window?[kCGWindowName as String] as? String ?? ""
    let id = (window?[kCGWindowNumber as String] as? NSNumber)?.uint32Value
    result.window = id.map { WindowIdentity(processID: pid, windowID: $0) }
    guard AXIsProcessTrusted() else {
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
      ProcessInfo.processInfo.systemUptime - prior.time < Double(RecorderTiming.accessibilityCacheSeconds)
    {
      result = prior.observation
    } else {
      result.accessibility = .unavailable
    }
    if !busy {
      busy = true
      let initial = result
      let browserAnswer = browsers[application.bundleID]
      // AX questions run off the caller's thread and publish a named cache under lock.
      queue.async {
        var addressFinished = false
        var answer = initial
        let isBrowser = browserAnswer ?? Self.isBrowser(application.bundleID)
        answer.isBrowser = isBrowser
        answer.isBrowserKnown = true
        if let window = focusedWindow(pid), string(window, kAXRoleAttribute) == "AXWindow" {
          answer.title = string(window, kAXTitleAttribute) ?? serverTitle
          answer.document = string(window, kAXDocumentAttribute)
          if isBrowser {
            if let prior, AddressCachePolicy.canReuse(
              sameTitle: prior.observation.title == answer.title, finished: prior.addressFinished)
            {
              answer.browserAddress = prior.observation.browserAddress
              addressFinished = true
            } else {
              let walk = webAddress(window)
              answer.browserAddress = walk.address
              addressFinished = walk.finished
            }
          }
          answer.accessibility = nil
        } else {
          answer.accessibility = .unavailable
        }
        self.lock.lock()
        self.browsers[application.bundleID] = isBrowser
        self.cached = Cache(
          identity: identity, observation: answer, serverTitle: serverTitle,
          time: ProcessInfo.processInfo.systemUptime, addressFinished: addressFinished)
        self.busy = false
        self.lock.unlock()
      }
    }
    return result
  }
  private static func isBrowser(_ bundleID: String) -> Bool {
    ["http", "https"].contains { scheme in
      NSWorkspace.shared.urlsForApplications(toOpen: URL(string: scheme + "://invented.invalid")!)
        .contains { Bundle(url: $0)?.bundleIdentifier?.lowercased() == bundleID.lowercased() }
    }
  }
}
