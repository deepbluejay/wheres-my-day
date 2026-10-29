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
/// The front process and its launch: the serial number is never reused, unlike the pid.
struct FrontProcess: Equatable {
  let pid: Int32
  let serial: UInt64
}
enum FrontProcessFailure: Error { case missingSymbol, error }
/// The Process Manager front-process call needs no run loop, so it can be made off the main
/// thread. Swift hides it as deprecated; it is looked up once.
private enum NativeFrontProcess {
  private typealias Front = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>) -> OSErr
  private typealias PID = @convention(c) (UnsafePointer<ProcessSerialNumber>, UnsafeMutablePointer<pid_t>) -> OSStatus
  private static let calls: (Front, PID)? = {
    guard let library = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY),
      let front = dlsym(library, "GetFrontProcess"), let pid = dlsym(library, "GetProcessPID") else { return nil }
    return (unsafeBitCast(front, to: Front.self), unsafeBitCast(pid, to: PID.self))
  }()
  static func current() -> Result<FrontProcess, FrontProcessFailure> {
    guard let (front, pidOf) = calls else { return .failure(.missingSymbol) }
    var serial = ProcessSerialNumber(), pid: pid_t = 0
    guard front(&serial) == noErr, pidOf(&serial, &pid) == noErr, pid > 0 else { return .failure(.error) }
    return .success(FrontProcess(pid: pid, serial: UInt64(serial.highLongOfPSN) << 32 | UInt64(serial.lowLongOfPSN)))
  }
}
/// The deprecated call could one day keep answering with a stale or fixed process, which no
/// lookup failure would show. Once the front has been settled (no activation) for
/// `settledSeconds`, at most once per `checkSeconds`, its pid is compared on the main thread
/// with NSWorkspace's. While the person switches less than `settledSeconds` apart, a check
/// also runs after `switchesPerCheck` activations, under the same interval, so a wrong call
/// is caught during switching too. That check runs in the activation handler, when
/// NSWorkspace has just named the activated application: an honest call named it before the
/// activation was delivered, while a stuck, late or lagging one does not name it yet.
/// `disagreementLimit` in a row (over 10 s apart) is no race, so the call is not used again
/// in this process. Neither is it after as many among the last `activationWindow` checks on
/// activation, however long ago those were (minutes or hours): a count of checks, not a time
/// span. A wrong call agrees there by chance when the person returns to the app it names, and
/// a settled check agrees with a late one. An honest call disagrees there only when another
/// activation is already queued behind the one being handled (an app handing focus on within
/// NSWorkspace's delivery lag), so such a disagreement is held for `raceSeconds`: delivering
/// an activation of the pid the call named withdraws it, and otherwise it counts at the next
/// activation or check after that. Read only: nothing is focused or posted.
enum FrontProcessGuard {
  static let settledSeconds = 3.0
  static let checkSeconds = 5.0
  static let switchesPerCheck = 2
  static let disagreementLimit = 3
  /// Queued activations arrive back to back, so this covers delivery lags and main-thread stalls.
  static let raceSeconds = 0.25
  /// The bits of `MacFrontWindowSource.activationResults`.
  static let activationWindow = UInt8.bitWidth
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
  var frontProcess: () -> Result<FrontProcess, FrontProcessFailure> = { .failure(.missingSymbol) }
  /// The identity `application` gives for this process; nil when it cannot be resolved.
  var runningApplication: (Int32) -> FrontObservation? = { _ in nil }
  /// NSWorkspace's front pid, read on the main thread only.
  var workspaceProcess: () -> Int32? = { nil }
  var main: (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }
  /// Calls the handler with the activated pid on each application activation; returns the
  /// call that stops it.
  var activations: (@escaping (Int32?) -> Void) -> () -> Void = { _ in {} }
  /// Record only (`status`): nothing reads these counts back.
  var count: (FrontApplicationCount) -> Void = { _ in }
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
    wallTime: { Date().timeIntervalSince1970 }, work: { queue.async(execute: $0) },
    frontProcess: { NativeFrontProcess.current() }, runningApplication: { pid in
      // NSRunningApplication returns its properties atomically on any thread.
      guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
      return FrontObservation(bundleID: app.bundleIdentifier ?? "", app: app.localizedName ?? "",
        isBrowserKnown: false, processID: app.processIdentifier)
    }, workspaceProcess: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
    activations: { handler in
      let center = NSWorkspace.shared.notificationCenter
      let token = center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil) { note in
        handler((note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier)
      }
      return { center.removeObserver(token) }
    }, count: { StageUsage.shared.count($0.rawValue) })
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
  private var front: (process: FrontProcess, observation: FrontObservation)?
  private var settledSince: Double
  private var switches = 0
  private var lastCheck = -Double.infinity
  private var checking = false
  private var disagreements = 0
  /// The latest checks on activation, newest in the low bit: 1 when it disagreed.
  private var activationResults: UInt8 = 0
  /// A disagreement on activation not counted yet: the pid the call named, and when.
  private var held: (pid: Int32, at: Double)?
  private var frontProcessOff = false
  private var stopActivations: () -> Void = {}
  public convenience init() { self.init(boundary: .native) }
  init(boundary: FrontWindowBoundary) {
    self.boundary = boundary
    settledSince = boundary.uptime()
    // NSWorkspace delivers activations on the main thread, so the check runs there at once.
    stopActivations = boundary.activations { [weak self] activated in
      guard let self else { return }
      let now = self.boundary.uptime()
      self.lock.lock()
      let resolved = self.resolveHeld(now, activated: activated)
      self.settledSince = now; self.switches += 1
      let due = !self.checking && !self.frontProcessOff && self.switches >= FrontProcessGuard.switchesPerCheck
        && now - self.lastCheck >= FrontProcessGuard.checkSeconds
      if due { self.checking = true; self.lastCheck = now; self.switches = 0 }
      self.lock.unlock()
      self.report(resolved)
      if due {
        if Thread.isMainThread { self.compareFront(settled: false) } else {
          self.boundary.main { [weak self] in self?.compareFront(settled: false) }
        }
      }
    }
  }
  deinit { stopActivations() }
  public func invalidateMetadata() {
    lock.lock(); defer { lock.unlock() }
    generation += 1; cached = nil; completed.removeAll()
  }
  /// The probe gate asks on every AX call. The front process is read on the calling thread;
  /// its identity is looked up once per launch. Otherwise the main thread answers, as before.
  /// A settled front schedules the occasional check against NSWorkspace (FrontProcessGuard);
  /// the check after switches runs on activation instead.
  public func frontApplication() -> FrontObservation {
    lock.lock(); let off = frontProcessOff; lock.unlock()
    if !off {
      let process: FrontProcess
      switch boundary.frontProcess() {
      case .success(let read): process = read
      case .failure(.missingSymbol): boundary.count(.missingSymbol); return mainApplication()
      case .failure(.error): boundary.count(.error); return mainApplication()
      }
      let now = boundary.uptime()
      lock.lock()
      let known = front?.process == process ? front?.observation : nil
      let check = !checking && now - lastCheck >= FrontProcessGuard.checkSeconds
        && now - settledSince >= FrontProcessGuard.settledSeconds
      if check { checking = true; lastCheck = now; switches = 0 }
      lock.unlock()
      if check { boundary.main { [weak self] in self?.compareFront(settled: true) } }
      if let known { return known }
      // Still the same launch in front after the lookup, so the identity is that process's.
      guard let observation = boundary.runningApplication(process.pid), observation.processID == process.pid else {
        boundary.count(.noIdentity); return mainApplication()
      }
      guard (try? boundary.frontProcess().get()) == process else { boundary.count(.changed); return mainApplication() }
      lock.lock(); front = (process, observation); lock.unlock()
      return observation
    }
    return mainApplication()
  }
  private func mainApplication() -> FrontObservation {
    if !Thread.isMainThread { return DispatchQueue.main.sync { self.boundary.application() } }
    return boundary.application()
  }
  /// Runs on the main thread, where activations are delivered, so none lands during it. A
  /// check asked for by a settled front still needs it settled; one on activation does not,
  /// and its disagreement is held, not counted yet (FrontProcessGuard).
  private func compareFront(settled: Bool) {
    let now = boundary.uptime()
    lock.lock(); let ready = !settled || now - settledSince >= FrontProcessGuard.settledSeconds; lock.unlock()
    let process = ready ? try? boundary.frontProcess().get() : nil
    let workspace = process == nil ? nil : boundary.workspaceProcess()
    lock.lock()
    checking = false
    let resolved = resolveHeld(now, activated: nil)
    guard let process, let workspace else { lock.unlock(); report(resolved); return }
    let agrees = process.pid == workspace
    let hold = !agrees && !settled && !frontProcessOff
    var disable = false
    if hold { held = (process.pid, now) } else { disable = record(agrees: agrees, onActivation: !settled) }
    lock.unlock()
    report(resolved)
    boundary.count(.comparisons)
    if !agrees && !hold { boundary.count(.disagreements) }
    if disable { boundary.count(.disabled) }
  }
  /// Under the lock. A held disagreement is withdrawn when the activation of the pid the call
  /// named is delivered within `raceSeconds`: the call was only ahead of NSWorkspace. After
  /// that it counts. Returns whether it counted, and whether that turned the call off.
  private func resolveHeld(_ now: Double, activated: Int32?) -> (counted: Bool, disable: Bool) {
    guard let pending = held else { return (false, false) }
    if now - pending.at <= FrontProcessGuard.raceSeconds {
      if activated == pending.pid { held = nil }
      return (false, false)
    }
    held = nil
    return (true, record(agrees: false, onActivation: true))
  }
  /// Under the lock: the streak, the window of checks on activation, and the turn-off.
  private func record(agrees: Bool, onActivation: Bool) -> Bool {
    disagreements = agrees ? 0 : disagreements + 1
    if onActivation { activationResults = activationResults << 1 | (agrees ? 0 : 1) }
    let disable = !frontProcessOff && (disagreements >= FrontProcessGuard.disagreementLimit
      || activationResults.nonzeroBitCount >= FrontProcessGuard.disagreementLimit)
    if disable { frontProcessOff = true; front = nil; held = nil }
    return disable
  }
  private func report(_ resolved: (counted: Bool, disable: Bool)) {
    if resolved.counted { boundary.count(.disagreements) }
    if resolved.disable { boundary.count(.disabled) }
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
