import Core
import Foundation
import XCTest

final class RecorderPolicyTests: XCTestCase {
  let window = WindowIdentity(processID: 10, windowID: 20)
  func testEachInputKindAndProgramInput() {
    for event in [InputEventKind.key, .click, .scroll, .move] {
      var human = InputCounts()
      human.observe(event, programMade: false)
      XCTAssertTrue(human.byPerson)
      XCTAssertEqual(human.synthetic, 0)
      var program = InputCounts()
      program.observe(event, programMade: true)
      XCTAssertFalse(program.byPerson)
      XCTAssertEqual(program.synthetic, 1)
    }
    var both = InputCounts()
    both.observe(.key, programMade: true)
    both.observe(.click, programMade: false)
    XCTAssertTrue(both.byPerson)
    XCTAssertEqual(both.keys, 1)
    XCTAssertEqual(both.clicks, 1)
  }
  func testSampleKeepsOnlyExcludedAppName() {
    let front = FrontObservation(
      bundleID: "INVENTED.PRIVATE", app: "Invented private app",
      title: "Invented private title", document: "file:///invented/private", window: window)
    let row = RecorderPolicy.sample(
      at: 61, front: front, input: InputCounts(keys: 2, synthetic: 3),
      keepingAwake: true, settings: StorageSettings(excludedApps: ["invented.private"]))
    XCTAssertEqual(row.app, front.app)
    XCTAssertTrue(row.excluded)
    XCTAssertEqual(row.window, "")
    XCTAssertEqual(row.documentKey, "")
    XCTAssertEqual(row.keys, 2)
    XCTAssertEqual(row.synthetic, 3)
    XCTAssertTrue(row.keepingAwake)
    let own = RecorderPolicy.sample(
      at: 61, front: front, input: InputCounts(), keepingAwake: false,
      settings: StorageSettings(excludedApps: []), ownBundleID: "invented.private")
    XCTAssertTrue(own.excluded)
    XCTAssertEqual(own.window, "")
  }
  func testCaptureEveryGateDirectly() {
    let front = FrontObservation(bundleID: "invented.app", app: "Invented app", window: window)
    let settings = StorageSettings(excludedApps: [])
    func allowed(
      _ f: FrontObservation = front, _ i: InputCounts = InputCounts(keys: 1),
      _ secure: Bool? = false, _ s: StorageSettings = settings, _ own: String = "invented.own"
    ) -> Bool {
      RecorderPolicy.captureAllowed(
        front: f, input: i, secureInput: secure,
        settings: s, ownBundleID: own, at: 100)
    }
    XCTAssertTrue(allowed())
    XCTAssertFalse(allowed(front, InputCounts()))
    XCTAssertFalse(allowed(front, InputCounts(synthetic: 5)))
    XCTAssertFalse(allowed(front, InputCounts(keys: 1), true))
    XCTAssertFalse(allowed(front, InputCounts(keys: 1), nil))
    XCTAssertFalse(
      allowed(
        front, InputCounts(keys: 1), false,
        StorageSettings(excludedApps: ["invented.app"])))
    XCTAssertFalse(allowed(front, InputCounts(keys: 1), false, settings, "INVENTED.APP"))
    XCTAssertFalse(allowed(FrontObservation(bundleID: "invented.app")))
    XCTAssertFalse(allowed(front, InputCounts(keys: 1), false, StorageSettings(recordingEnabled: false)))
    XCTAssertFalse(allowed(front, InputCounts(keys: 1), false, StorageSettings(pausedUntil: 101)))
    XCTAssertTrue(allowed(front, InputCounts(keys: 1), false, StorageSettings(pausedUntil: 100)))
  }
  func testDocumentKeyUsesObservedAddressIndependentlyOfBrowserHint() {
    var front = FrontObservation(title: "Invented title", document: "file:///invented/folder/item")
    XCTAssertEqual(RecorderPolicy.documentKey(front), "/invented/folder/item")
    front.browserAddress = "https://invented.example/page///?password=invented#fragment"
    XCTAssertEqual(RecorderPolicy.documentKey(front), "invented.example/page")
    front.isBrowser = true
    XCTAssertEqual(RecorderPolicy.documentKey(front), "invented.example/page")
    front.document = nil
    front.browserAddress = nil
    XCTAssertEqual(RecorderPolicy.documentKey(front), "")
    front.title = ""
    XCTAssertEqual(RecorderPolicy.documentKey(front), "")
  }
  func testImageRequestGraceBoundary() {
    XCTAssertTrue(CaptureCheck.beforeImage.allows(requestedAt: 100, now: 100))
    XCTAssertTrue(CaptureCheck.beforeImage.allows(requestedAt: 100, now: 101))
    XCTAssertFalse(CaptureCheck.beforeImage.allows(requestedAt: 100, now: 102))
    XCTAssertFalse(CaptureCheck.beforeImage.allows(requestedAt: 100, now: 99))
    XCTAssertTrue(CaptureCheck.beforeDelivery.allows(requestedAt: 100, now: 105))
  }
  func testCaptureWindowCooldownAtExactBoundary() {
    var schedule = CaptureSchedule()
    XCTAssertTrue(schedule.reserve(window, at: 100))
    XCTAssertFalse(schedule.reserve(window, at: 114))
    XCTAssertTrue(schedule.reserve(WindowIdentity(processID: 10, windowID: 21), at: 101))
    XCTAssertTrue(schedule.reserve(window, at: 99))
    XCTAssertFalse(schedule.reserve(window, at: 113))
    XCTAssertTrue(schedule.reserve(window, at: 114))
  }
  func testCaptureFlightExpiresAndOldCompletionCannotReleaseNewFlight() throws {
    var flight = CaptureFlight()
    let first = try XCTUnwrap(flight.begin(at: 100))
    XCTAssertNil(flight.begin(at: 130))
    let second = try XCTUnwrap(flight.begin(at: 130.1))
    XCTAssertFalse(flight.finish(first))
    XCTAssertNil(flight.begin(at: 140))
    XCTAssertTrue(flight.finish(second))
    XCTAssertNotNil(flight.begin(at: 141))
  }
  func testRestPolicyBoundary() {
    XCTAssertTrue(RestPolicy.recordsSecond(at: 300, lastInput: 0, keepingAwake: false))
    XCTAssertFalse(RestPolicy.recordsSecond(at: 301, lastInput: 0, keepingAwake: false))
    XCTAssertFalse(RestPolicy.recordsSecond(at: 1, lastInput: nil, keepingAwake: false))
    XCTAssertTrue(RestPolicy.recordsSecond(at: 1200, lastInput: nil, keepingAwake: true))
  }
  func testKeyExpiryRebuildAndLatestTimestamp() {
    var memory = ScreenKeyMemory()
    memory.rebuild(["older": 1, "newer": 2, "future": 3602], at: 3601)
    XCTAssertEqual(memory.storedAt, ["newer": 2])
    memory.expire(at: 3602)
    XCTAssertEqual(memory.keys, [])
    memory.add(["line"], storedAt: 100, now: 100)
    memory.add(["line"], storedAt: 90, now: 100)
    XCTAssertEqual(memory.storedAt, ["line": 100])
    memory.expire(at: 3699)
    XCTAssertEqual(memory.keys, ["line"])
    memory.expire(at: 3700)
    XCTAssertEqual(memory.keys, [])
  }
  func testNoveltyReplayHandlesMinimumTimestampWithoutOverflow() {
    var memory = ScreenKeyMemory()
    memory.add(["invented"], storedAt: Int.min, now: Int.min)
    memory.expire(at: Int.min + 3599)
    XCTAssertEqual(memory.keys, ["invented"])
    memory.expire(at: Int.min + 3600)
    XCTAssertEqual(memory.keys, [])
  }
  func testRepeatedLineWithinCaptureIsRetained() {
    let text = "Invented line 1!\nInvented line 2?\nOther line"
    XCTAssertEqual(ScreenTextPayload(text: text).redacted().text, text)
  }
  func testNoveltyReadViewSelectsRepeatedLineOnce() {
    let selected = ScreenLines.select(maskedText: "Invented line 1!\nInvented line 2?\nOther line", knownKeys: [])
    XCTAssertEqual(selected.lines, ["Invented line 1!", "Other line"])
    XCTAssertEqual(selected.keys, ["Inventedline", "Otherline"])
    XCTAssertEqual(ScreenLineKey.fromMaskedLine("Value + ①, 123!"), "Value+")
    XCTAssertEqual(ScreenLineKey.fromMaskedLine("Value = 123"), "Value=")
  }
  func testDisplayAssertionOwnershipAndOnlyDisplayTypes() {
    let apps = [DisplayApp(pid: 10, path: "/invented/Main.app")]
    let processes: [Int32: DisplayProcess] = [
      11: DisplayProcess(parent: 10, path: "/invented/Main.app/helper"),
      12: DisplayProcess(parent: 10, path: "/invented/command"),
      13: DisplayProcess(parent: 10, path: "/invented/service.xpc/helper"),
    ]
    func owner(_ pid: Int32) -> Int32? { DisplayAssertionPolicy.owner(of: pid, apps: apps) { processes[$0] } }
    XCTAssertEqual(owner(10), 10)
    XCTAssertEqual(owner(11), 10)
    XCTAssertNil(owner(12))
    XCTAssertEqual(owner(13), 10)
    XCTAssertNil(owner(99))
    func awake(_ type: String, _ enabled: Bool = true, _ behalf: Int32? = nil) -> Bool {
      DisplayAssertionPolicy.keepingAwake(
        10,
        assertions: [DisplayAssertion(pid: 11, type: type, enabled: enabled, onBehalfOf: behalf)],
        apps: apps
      ) { processes[$0] }
    }
    XCTAssertTrue(awake("PreventUserIdleDisplaySleep"))
    XCTAssertTrue(awake("NoDisplaySleepAssertion"))
    XCTAssertFalse(awake("PreventUserIdleSystemSleep"))
    XCTAssertFalse(awake("NoDisplaySleepAssertion", false))
    XCTAssertFalse(awake("NoDisplaySleepAssertion", true, 99))
  }
  func testAmbiguousDisplayAncestorDoesNotStopParentWalk() {
    let apps = [
      DisplayApp(pid: 10, path: "/invented/Main.app"),
      DisplayApp(pid: 20, path: "/invented/Main.app"),
      DisplayApp(pid: 11, path: "/invented/Main.app/Nested.app"),
    ]
    let processes: [Int32: DisplayProcess] = [
      99: DisplayProcess(parent: 11, path: "/invented/service.xpc/helper"),
      11: DisplayProcess(parent: 10, path: "/invented/Main.app/Nested.app/helper"),
    ]
    XCTAssertEqual(DisplayAssertionPolicy.owner(of: 99, apps: apps) { processes[$0] }, 10)
  }

}
