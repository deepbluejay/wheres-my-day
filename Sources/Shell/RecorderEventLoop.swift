import AppKit

/// What the recorder does with an Apple event. Pure, so routing is tested without AppKit.
enum RecorderAppleEvent: Equatable {
  /// Finder, the Dock, Spotlight or Launchpad opened the running app (reopen), or a file was dropped
  /// on it: ask for the window. Documents are never read.
  case open
  /// loginwindow asks every app to quit before a logout, restart or shutdown and waits for it, so this
  /// quit runs the same stop as SIGTERM and exits 0 like every stop. launchd does not start it again, so
  /// a cancelled logout leaves recording off until the next login.
  case endSession
  /// Answered and dropped. Open-application is one: a running app never gets it from an open, only
  /// AppKit's own launch event, and startup already starts the menu. A quit without a session reason
  /// is another: a script, Activity Monitor or another app must not end recording.
  case ignore
  /// The quit reasons loginwindow sets when the session ends.
  static let sessionEndReasons: [OSType] = [kAELogOut, kAEReallyLogOut, kAERestart, kAEShutDown, kAEQuitAll].map { OSType($0) }
  static func route(eventClass: AEEventClass, eventID: AEEventID, quitReason: OSType? = nil) -> RecorderAppleEvent {
    guard eventClass == AEEventClass(kCoreEventClass) else { return .ignore }
    switch eventID {
    case AEEventID(kAEReopenApplication), AEEventID(kAEOpenDocuments): return .open
    case AEEventID(kAEQuitApplication):
      guard let quitReason, sessionEndReasons.contains(quitReason) else { return .ignore }
      return .endSession
    default: return .ignore
    }
  }
  /// AppKit answers some events with a window, alert or panel. While it finishes launching a hidden
  /// application installs oapp, rapp, odoc, pdoc, ocon and quit; pref and GURL follow a delegate.
  /// Each is replaced by name. An event with no handler is refused by the Apple Event Manager, with no UI.
  static let taken: [(eventClass: AEEventClass, eventID: AEEventID)] =
    [kAEOpenApplication, kAEReopenApplication, kAEOpenDocuments, kAEPrintDocuments, kAEOpenContents,
      kAEShowPreferences, kAEQuitApplication].map { (AEEventClass(kCoreEventClass), AEEventID($0)) }
      + [(code("GURL"), code("GURL"))]
  static func code(_ text: StaticString) -> UInt32 {
    text.withUTF8Buffer { $0.reduce(UInt32(0)) { $0 << 8 | UInt32($1) } }
  }
}

/// The few calls the recorder makes on the application object.
@MainActor protocol RecorderEventApplication: ActivationPolicyTarget {
  func run()
  func stop(_ sender: Any?)
  /// `stop` takes effect only after the next event, which an idle recorder may never get.
  func wake()
  /// A modal session takes `stop` for itself and leaves `run` going.
  func endModal()
}

extension NSApplication: RecorderEventApplication {
  func wake() {
    guard let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
      windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) else { return }
    postEvent(event, atStart: false)
  }
  func endModal() { if modalWindow != nil { abortModal() } }
}

/// LaunchServices knows the recorder through its capture APIs and gives an open of the app to the
/// instance that registered first, usually the recorder. Without an AppKit event loop that open
/// fails, so the recorder runs one with the prohibited policy: no Dock icon, menu, window or
/// activation. Sampling, signals and stop keep their main run loop sources and timers.
/// Without `open` (isolated and test recorders) it keeps the plain run loop and never registers.
@MainActor final class RecorderEventLoop: NSObject {
  private let open: (() -> Void)?
  /// Called for a session-end quit; set by the recorder entry once its stop exists.
  var endSession: (() -> Void)?
  private let now: () -> TimeInterval
  private let retry: (@escaping @MainActor () -> Void) -> Void
  private let soon: (@escaping @MainActor () -> Void) -> Void
  private let plain: (run: () -> Void, stop: () -> Void)
  private let center: NotificationCenter
  private var launching: NSObjectProtocol?
  private(set) var installed = false
  /// How many times the handlers were set; tests check that each path sets them once.
  private(set) var installs = 0
  private var application: RecorderEventApplication?
  private var stopped = false, running = false
  private var lastOpen: TimeInterval?

  init(open: (() -> Void)?, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    retry: @escaping (@escaping @MainActor () -> Void) -> Void = { work in
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { MainActor.assumeIsolated { work() } }
    },
    soon: @escaping (@escaping @MainActor () -> Void) -> Void = { work in
      DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
    },
    plain: (run: () -> Void, stop: () -> Void) = ({ CFRunLoopRun() }, { CFRunLoopStop(CFRunLoopGetMain()) }),
    center: NotificationCenter = .default) {
    self.open = open; self.now = now; self.retry = retry; self.soon = soon; self.plain = plain; self.center = center
  }

  func run(application: @MainActor () -> RecorderEventApplication = { NSApplication.shared }) {
    guard !stopped else { return }
    guard open != nil else { running = true; plain.run(); running = false; return }
    let application = application()
    self.application = application
    application.setActivationPolicy(.prohibited)
    // AppKit installs its own handlers before it posts this, inside run; ours replace them before
    // any queued event is dispatched.
    launching = center.addObserver(forName: NSApplication.willFinishLaunchingNotification, object: nil, queue: nil) { [weak self] _ in
      MainActor.assumeIsolated { self?.install(afterAppKit: true) }
    }
    // If the application already finished launching, that notification never comes; the first
    // main-queue turn inside run sets the handlers instead.
    soon { [weak self] in self?.install(afterAppKit: false) }
    running = true
    // Something other than our stop can end run; only our stop ends the recorder.
    while !stopped { application.run() }
    running = false
    uninstall()
  }
  /// Ends `run` once, whatever modal state AppKit is in. Safe before `run`, which then never starts.
  func stop() {
    guard !stopped else { return }
    stopped = true
    if open == nil { if running { plain.stop() } } else { end() }
  }
  private func end() {
    guard running, let application else { return }
    application.endModal(); application.stop(nil); application.wake()
    // A modal session can take this stop as its own; ask again until run returns.
    retry { [weak self] in self?.end() }
  }
  func handle(eventClass: AEEventClass, eventID: AEEventID, quitReason: OSType? = nil) {
    guard !stopped else { return }
    switch RecorderAppleEvent.route(eventClass: eventClass, eventID: eventID, quitReason: quitReason) {
    case .open: break
    case .endSession: endSession?(); return
    case .ignore: return
    }
    guard let open else { return }
    // A burst of opens (a double click, a script) starts one window launch per second.
    let time = now()
    if let lastOpen, time - lastOpen < 1 { return }
    lastOpen = time
    open()
  }
  @objc private func handle(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
    handle(eventClass: event.eventClass, eventID: event.eventID, quitReason: Self.quitReason(event))
  }
  /// The reason is read as an attribute, as apps usually do; the header documents it as a parameter. Either counts.
  nonisolated static func quitReason(_ event: NSAppleEventDescriptor) -> OSType? {
    let keyword = AEKeyword(kAEQuitReason)
    guard let reason = event.attributeDescriptor(forKeyword: keyword) ?? event.paramDescriptor(forKeyword: keyword) else { return nil }
    let code = reason.enumCodeValue != 0 ? reason.enumCodeValue : reason.typeCodeValue
    return code != 0 ? code : nil
  }
  /// The launch notification always sets the handlers, because AppKit's defaults went in just before it.
  /// The fallback sets them only if nothing has, and leaves the observer for that case.
  private func install(afterAppKit: Bool) {
    if afterAppKit, let launching { center.removeObserver(launching); self.launching = nil }
    guard !stopped, afterAppKit || !installed else { return }
    installed = true; installs += 1
    for event in RecorderAppleEvent.taken {
      NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handle(_:reply:)),
        forEventClass: event.eventClass, andEventID: event.eventID)
    }
  }
  private func uninstall() {
    if let launching { center.removeObserver(launching); self.launching = nil }
    guard installed else { return }
    installed = false
    for event in RecorderAppleEvent.taken {
      NSAppleEventManager.shared().removeEventHandler(forEventClass: event.eventClass, andEventID: event.eventID)
    }
  }
}
