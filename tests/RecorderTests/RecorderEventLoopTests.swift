import AppKit
import Foundation
import XCTest
@testable import Shell

/// Stands in for NSApplication: records calls and lets a test act while the loop "runs".
/// A modal session takes a stop for itself and ends before the next turn; `turns` are those turns.
@MainActor private final class EventApplication: RecorderEventApplication {
  var events: [String] = []
  var whileRunning: () -> Void = {}
  var modal = false, modalEnding = false, stopRequested = false
  var turns: [() -> Void] = []
  func setActivationPolicy(_ activationPolicy: NSApplication.ActivationPolicy) -> Bool {
    events.append(activationPolicy == .prohibited ? "prohibited" : "other(\(activationPolicy.rawValue))"); return true
  }
  func run() {
    events.append("run"); whileRunning()
    while !stopRequested {
      if modalEnding { modal = false; modalEnding = false; events.append("modal ended") }
      guard !turns.isEmpty else { events.append("hung"); break }
      turns.removeFirst()()
    }
    stopRequested = false
    events.append("returned")
  }
  func stop(_ sender: Any?) { events.append("stop"); if modal { modalEnding = true } else { stopRequested = true } }
  func wake() { events.append("wake") }
  func endModal() { if modal { events.append("abort modal"); modalEnding = true } }
}

final class RecorderEventLoopTests: XCTestCase {
  private let core = AEEventClass(kCoreEventClass)
  // Ideal: reopen and a dropped file ask for the window; a quit for a logout, restart or shutdown ends the
  // session; every other event, a quit without a session reason included, is dropped.
  // The launch's own open-application must not open a window at every login.
  func testAppleEventRouting() {
    for id in [kAEReopenApplication, kAEOpenDocuments] {
      XCTAssertEqual(RecorderAppleEvent.route(eventClass: core, eventID: AEEventID(id)), .open)
      XCTAssertEqual(RecorderAppleEvent.route(eventClass: core, eventID: AEEventID(id), quitReason: OSType(kAEShutDown)), .open)
    }
    for id in [kAEOpenApplication, kAEPrintDocuments, kAEOpenContents, kAEShowPreferences, kAEQuitApplication, RecorderAppleEvent.code("obit")] {
      XCTAssertEqual(RecorderAppleEvent.route(eventClass: core, eventID: AEEventID(id)), .ignore)
    }
    XCTAssertEqual(RecorderAppleEvent.route(eventClass: RecorderAppleEvent.code("GURL"), eventID: RecorderAppleEvent.code("GURL")), .ignore)
    XCTAssertEqual(RecorderAppleEvent.route(eventClass: AEEventClass(kAEInternetSuite), eventID: AEEventID(kAEReopenApplication)), .ignore)
    let quit = AEEventID(kAEQuitApplication)
    for reason in [kAELogOut, kAEReallyLogOut, kAERestart, kAEShutDown, kAEQuitAll] {
      XCTAssertEqual(RecorderAppleEvent.route(eventClass: core, eventID: quit, quitReason: OSType(reason)), .endSession)
      XCTAssertEqual(RecorderAppleEvent.route(eventClass: AEEventClass(kAEInternetSuite), eventID: quit, quitReason: OSType(reason)), .ignore)
      XCTAssertEqual(RecorderAppleEvent.route(eventClass: core, eventID: AEEventID(kAEOpenApplication), quitReason: OSType(reason)), .ignore)
    }
    // The dialog requests go to loginwindow, not to apps; an unknown reason is a plain quit.
    for reason in [OSType(kAEShowRestartDialog), OSType(kAEShowShutdownDialog), RecorderAppleEvent.code("zzzz"), 0] {
      XCTAssertEqual(RecorderAppleEvent.route(eventClass: core, eventID: quit, quitReason: reason), .ignore)
    }
  }
  // Ideal: the reason is found whether the sender put it in an attribute or a parameter, in either type.
  func testQuitReasonIsRead() {
    func quit() -> NSAppleEventDescriptor {
      NSAppleEventDescriptor(eventClass: core, eventID: AEEventID(kAEQuitApplication), targetDescriptor: nil,
        returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
    }
    XCTAssertNil(RecorderEventLoop.quitReason(quit()))
    let keyword = AEKeyword(kAEQuitReason)
    for reason in [kAELogOut, kAEReallyLogOut, kAERestart, kAEShutDown, kAEQuitAll].map({ OSType($0) }) {
      let attribute = quit(); attribute.setAttribute(NSAppleEventDescriptor(enumCode: reason), forKeyword: keyword)
      XCTAssertEqual(RecorderEventLoop.quitReason(attribute), reason)
      let parameter = quit(); parameter.setParam(NSAppleEventDescriptor(typeCode: reason), forKeyword: keyword)
      XCTAssertEqual(RecorderEventLoop.quitReason(parameter), reason)
    }
  }
  // Ideal: every event AppKit can answer with a window, alert or panel is taken by name.
  func testEveryAppKitDefaultIsTaken() {
    let taken = Set(RecorderAppleEvent.taken.map { "\($0.eventClass)/\($0.eventID)" })
    var expected = [kAEOpenApplication, kAEReopenApplication, kAEOpenDocuments, kAEPrintDocuments, kAEOpenContents,
      kAEShowPreferences, kAEQuitApplication].map { "\(core)/\(AEEventID($0))" }
    expected += ["\(RecorderAppleEvent.code("GURL"))/\(RecorderAppleEvent.code("GURL"))"]
    XCTAssertEqual(taken, Set(expected))
    XCTAssertEqual(RecorderAppleEvent.code("odoc"), AEEventID(kAEOpenDocuments))
  }
  // Ideal: the recorder can never be activated, so the prohibited policy comes before the event loop.
  // Opens start a window launch and nothing else; a stop ends the loop once.
  @MainActor func testLoopIsHiddenAndOnlyForwards() {
    let app = EventApplication()
    var opens = 0, time: TimeInterval = 0
    let loop = RecorderEventLoop(open: { opens += 1 }, now: { time }, retry: { app.turns.append($0) })
    app.whileRunning = {
      loop.handle(eventClass: self.core, eventID: AEEventID(kAEReopenApplication)); time += 2
      loop.handle(eventClass: self.core, eventID: AEEventID(kAEOpenApplication)); time += 2
      loop.handle(eventClass: self.core, eventID: AEEventID(kAEOpenDocuments)); time += 2
      loop.handle(eventClass: self.core, eventID: AEEventID(kAEReopenApplication)); time += 2
      loop.handle(eventClass: self.core, eventID: AEEventID(kAEPrintDocuments)); time += 2
      XCTAssertEqual(app.events, ["prohibited", "run"], "Opens make no AppKit call of their own")
      loop.stop()
      loop.handle(eventClass: self.core, eventID: AEEventID(kAEReopenApplication))
      loop.stop()
    }
    loop.run(application: { app })
    XCTAssertEqual(opens, 3, "No window launch after the recorder stopped")
    XCTAssertEqual(app.events, ["prohibited", "run", "stop", "wake", "returned"])
  }
  // Ideal: a stop during a modal session (an AppKit panel, or any nested loop) still ends the loop, exactly once.
  @MainActor func testStopDuringModalReturnsOnce() {
    let app = EventApplication()
    let loop = RecorderEventLoop(open: {}, retry: { app.turns.append($0) })
    app.whileRunning = { app.modal = true; loop.stop(); loop.stop() }
    loop.run(application: { app })
    XCTAssertEqual(app.events, ["prohibited", "run", "abort modal", "stop", "wake", "modal ended", "stop", "wake", "returned"])
    XCTAssertEqual(app.events.filter { $0 == "returned" }.count, 1)
    XCTAssertEqual(app.turns.count, 1)
    app.turns.removeFirst()()
    XCTAssertEqual(app.events.last, "returned", "The last retry finds the loop gone and asks nothing")
    XCTAssertTrue(app.turns.isEmpty)
  }
  // Ideal: a run that ends without our stop runs again; only our stop ends the recorder.
  @MainActor func testOnlyOurStopEndsTheLoop() {
    let app = EventApplication()
    let loop = RecorderEventLoop(open: {}, retry: { app.turns.append($0) })
    var runs = 0
    app.whileRunning = {
      runs += 1
      if runs == 1 { app.stopRequested = true } else { loop.stop() }
    }
    loop.run(application: { app })
    XCTAssertEqual(runs, 2)
    XCTAssertEqual(app.events.filter { $0 == "returned" }.count, 2)
  }
  // Ideal: a quit Apple event without a session reason, from any sender, never stops recording.
  @MainActor func testQuitWithoutSessionReasonNeverStopsRecording() {
    let app = EventApplication()
    var opens = 0, ends = 0
    let loop = RecorderEventLoop(open: { opens += 1 }, retry: { app.turns.append($0) })
    loop.endSession = { ends += 1 }
    app.whileRunning = {
      for reason in [nil, OSType(kAEShowRestartDialog), RecorderAppleEvent.code("zzzz")] {
        loop.handle(eventClass: self.core, eventID: AEEventID(kAEQuitApplication), quitReason: reason)
      }
      XCTAssertEqual(app.events, ["prohibited", "run"], "Quit asks AppKit for nothing")
      app.turns.append { loop.stop() }
    }
    loop.run(application: { app })
    XCTAssertEqual(opens, 0)
    XCTAssertEqual(ends, 0)
    XCTAssertEqual(app.events, ["prohibited", "run", "stop", "wake", "returned"])
  }
  // Ideal: a session-end quit asks for the recorder's own stop (flush, then the loop ends), once per
  // event and never after the loop stopped; it opens nothing and asks AppKit for nothing itself.
  @MainActor func testSessionEndQuitRunsTheRecorderStop() throws {
    for reason in [kAELogOut, kAEReallyLogOut, kAERestart, kAEShutDown, kAEQuitAll].map({ OSType($0) }) {
      let app = EventApplication()
      var opens = 0, ends = 0
      let loop = RecorderEventLoop(open: { opens += 1 }, retry: { app.turns.append($0) })
      loop.endSession = { ends += 1; app.turns.append { loop.stop() } }
      app.whileRunning = {
        loop.handle(eventClass: self.core, eventID: AEEventID(kAEQuitApplication), quitReason: reason)
        XCTAssertEqual(app.events, ["prohibited", "run"], "The stop drains first; the loop ends after it")
      }
      loop.run(application: { app })
      loop.handle(eventClass: core, eventID: AEEventID(kAEQuitApplication), quitReason: reason)
      XCTAssertEqual(ends, 1, "No stop request after the loop ended")
      XCTAssertEqual(opens, 0)
      XCTAssertEqual(app.events, ["prohibited", "run", "stop", "wake", "returned"])
    }
  }
  // Ideal: a session-end quit takes the same stop as SIGTERM, settings and `stop`, and every stop exits 0,
  // so launchd never starts recording again during a logout; a cancelled logout stays stopped until login.
  func testSessionEndStopExitsZeroLikeEveryStop() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let entry = try String(contentsOf: root.appendingPathComponent("Sources/Shell/ActivityProbeEntry.swift"), encoding: .utf8)
    XCTAssertTrue(entry.contains("{ events.endSession = stop }"), "A session-end quit takes the SIGTERM stop")
    XCTAssertTrue(entry.contains("source.setEventHandler(handler: stop)"))
    XCTAssertTrue(entry.contains("loop.recordingDisabled = stop\n"))
    let run = try XCTUnwrap(entry.range(of: "MainActor.assumeIsolated { events.run() } }"))
    let after = entry[run.upperBound...].split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty && !$0.hasPrefix("//") }
    XCTAssertEqual(after.first, "return 0", "Nothing after the loop chooses another exit status")
    for name in ["RecorderEventLoop.swift", "ActivityProbeEntry.swift"] {
      let source = try String(contentsOf: root.appendingPathComponent("Sources/Shell/\(name)"), encoding: .utf8)
      XCTAssertFalse(source.contains("EX_TEMPFAIL"), name)
      XCTAssertFalse(source.contains("exitStatus"), name)
    }
  }
  // Ideal: handlers go in when AppKit says it will finish launching (after its own defaults, before any
  // queued event), once, and come out when the loop ends. If that notification never comes (the
  // application already finished launching), the first main-queue turn sets them once instead.
  @MainActor func testHandlersInstallAtWillFinishLaunchingOnce() {
    let app = EventApplication(), center = NotificationCenter()
    var fallback: [@MainActor () -> Void] = []
    let loop = RecorderEventLoop(open: {}, retry: { app.turns.append($0) }, soon: { fallback.append($0) }, center: center)
    app.whileRunning = {
      XCTAssertFalse(loop.installed, "Nothing before AppKit's launch")
      XCTAssertEqual(fallback.count, 1, "The fallback is queued, not run")
      center.post(name: NSApplication.didFinishLaunchingNotification, object: nil)
      XCTAssertFalse(loop.installed)
      center.post(name: NSApplication.willFinishLaunchingNotification, object: nil)
      XCTAssertTrue(loop.installed)
      XCTAssertEqual(loop.installs, 1)
      fallback.removeFirst()()
      XCTAssertEqual(loop.installs, 1, "The fallback after the notification sets nothing again")
      center.post(name: NSApplication.willFinishLaunchingNotification, object: nil)
      XCTAssertEqual(loop.installs, 1, "The observer fired once and is gone")
      loop.stop()
    }
    loop.run(application: { app })
    XCTAssertFalse(loop.installed, "Removed when the loop ends")
    center.post(name: NSApplication.willFinishLaunchingNotification, object: nil)
    XCTAssertFalse(loop.installed, "The observer is gone")
    let early = RecorderEventLoop(open: {}, retry: { _ in }, soon: { fallback.append($0) }, center: center)
    let quiet = EventApplication()
    quiet.whileRunning = { early.stop() }
    early.run(application: { quiet })
    center.post(name: NSApplication.willFinishLaunchingNotification, object: nil)
    fallback.forEach { $0() }; fallback.removeAll()
    XCTAssertFalse(early.installed, "A loop that never saw the launch leaves no observer behind")
    XCTAssertEqual(early.installs, 0, "A late fallback installs nothing after the loop ended")
  }
  // Ideal: with no launch notification, the fallback alone sets the handlers once. If the notification
  // still comes later, AppKit has just put its defaults back, so the handlers are set again over them.
  @MainActor func testFallbackInstallsWithoutTheLaunchNotification() {
    let app = EventApplication(), center = NotificationCenter()
    var fallback: [@MainActor () -> Void] = []
    let loop = RecorderEventLoop(open: {}, retry: { app.turns.append($0) }, soon: { fallback.append($0) }, center: center)
    app.whileRunning = {
      XCTAssertFalse(loop.installed)
      fallback.removeFirst()()
      XCTAssertTrue(loop.installed)
      XCTAssertEqual(loop.installs, 1)
      loop.stop()
    }
    loop.run(application: { app })
    XCTAssertFalse(loop.installed, "Removed when the loop ends")
    XCTAssertTrue(fallback.isEmpty)
    let second = EventApplication()
    let late = RecorderEventLoop(open: {}, retry: { second.turns.append($0) }, soon: { fallback.append($0) }, center: center)
    second.whileRunning = {
      fallback.removeFirst()()
      center.post(name: NSApplication.willFinishLaunchingNotification, object: nil)
      XCTAssertEqual(late.installs, 2, "The notification replaces AppKit's defaults again")
      center.post(name: NSApplication.willFinishLaunchingNotification, object: nil)
      XCTAssertEqual(late.installs, 2)
      late.stop()
    }
    late.run(application: { second })
    XCTAssertFalse(late.installed)
  }
  // Ideal: a burst of opens starts at most one window launch per second.
  @MainActor func testOpensAreRateLimited() {
    var opens: [TimeInterval] = [], time: TimeInterval = 0
    let loop = RecorderEventLoop(open: { opens.append(time) }, now: { time })
    for at in [0, 0.2, 0.9, 1.0, 1.5, 3.0, 3.99] as [TimeInterval] {
      time = at; loop.handle(eventClass: core, eventID: AEEventID(kAEReopenApplication))
    }
    XCTAssertEqual(opens, [0, 1.0, 3.0])
  }
  // Ideal: isolated and test recorders keep the plain run loop: no application object, no opens.
  @MainActor func testIsolatedRecorderKeepsThePlainLoop() {
    var events: [String] = []
    var loop: RecorderEventLoop?
    loop = RecorderEventLoop(open: nil, plain: (run: {
      events.append("run")
      loop?.handle(eventClass: self.core, eventID: AEEventID(kAEReopenApplication))
      loop?.stop(); loop?.stop()
    }, stop: { events.append("stop") }))
    loop?.run(application: { XCTFail("No application object"); return EventApplication() })
    XCTAssertEqual(events, ["run", "stop"])
    let early = RecorderEventLoop(open: nil, plain: (run: { events.append("early run") }, stop: { events.append("early stop") }))
    early.stop(); early.run()
    XCTAssertEqual(events, ["run", "stop"], "A stop before run means the plain loop never starts")
  }
  // Ideal: a stop that comes before the loop (a disabled recording at start) means the loop never runs.
  @MainActor func testStopBeforeRunNeverRuns() {
    let app = EventApplication()
    let loop = RecorderEventLoop(open: { XCTFail("No open before the loop") })
    loop.stop()
    loop.run(application: { app })
    XCTAssertEqual(app.events, [])
  }
  // Ideal: a reopen line reaches the running window process as a Dock click; the menu line opens nothing.
  @MainActor func testReopenLineReachesTheWindowProcess() {
    var creations = 0
    let host = AppWindowHost(strings: AppWindowStrings(language: "en", resources: nil)) {
      creations += 1; throw AppCommandError.arguments
    }
    AppWindowEntry.receive("menu-bar", host: host)
    XCTAssertEqual(creations, 0)
    AppWindowEntry.receive(AppWindowReopen.line, host: host)
    XCTAssertEqual(creations, 1, "No window yet, so the reopen opens the timeline")
    AppWindowEntry.receive("timeline", host: host)
    XCTAssertEqual(creations, 2)
    XCTAssertEqual(RecorderWindowLauncher.arguments(target: nil), ["menu-bar"])
    XCTAssertEqual(AppWindowReopen.arguments, [AppWindowReopen.line])
  }
  // Ideal: the recorder's event loop file holds no window, menu, status item, Dock or activation call.
  func testRecorderLoopShowsNothing() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let source = try String(contentsOf: root.appendingPathComponent("Sources/Shell/RecorderEventLoop.swift"), encoding: .utf8)
    for name in ["NSWindow", "NSMenu", "NSStatus", "activate(", ".regular", ".accessory", "orderFront", "AppWindowHost", "unhide"] {
      XCTAssertFalse(source.contains(name), "RecorderEventLoop mentions \(name)")
    }
    let entry = try String(contentsOf: root.appendingPathComponent("Sources/Shell/ActivityProbeEntry.swift"), encoding: .utf8)
    XCTAssertFalse(entry.contains("CFRunLoopRun()"), "The recorder runs only the hidden event loop")
    XCTAssertTrue(entry.contains("RecorderWindowLauncher.launch(paths: paths, arguments: AppWindowReopen.arguments"))
  }
}
