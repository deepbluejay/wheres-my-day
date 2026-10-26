import Core
import Foundation
import XCTest
import Shell
@testable import Storage
@testable import Inbound

final class NativeMetadataTests: XCTestCase {
  final class Fixture {
    var time = 100.0
    var url: String?
    var document: String?
    var tasks: [() -> Void] = []
    var queries = 0
    var browser: Bool? = false
    var pid: Int32 = 10
    lazy var source = MacFrontWindowSource(boundary: FrontWindowBoundary(
      application: { FrontObservation(bundleID: "invented.embedded", processID: self.pid) },
      listed: { ("Invented same title", UInt32($0)) }, trusted: { true }, focused: { Int($0) },
      attribute: { element, name in
        let node = element as! Int
        switch name {
        case "AXRole": return node >= 1000 ? "AXWebArea" : "AXWindow"
        case "AXTitle": return "Invented same title"
        case "AXDocument": return self.document
        case "AXChildren": return node < 1000 ? [node + 1000] : []
        case "AXURL": self.queries += 1; return self.url
        default: return nil
        }
      }, browser: { _ in self.browser }, uptime: { self.time }, wallTime: { self.time },
      work: { self.tasks.append($0) }))
    func details() -> FrontObservation { source.details(for: source.frontApplication()) }
    func finish() { let task = tasks.removeFirst(); task() }
  }
  func testSameTitleChangedAddressRefreshesAtExactThreeSeconds() {
    let f = Fixture(); f.url = "https://invented.invalid/first"
    _ = f.details(); f.finish()
    XCTAssertEqual(f.details().browserAddress, f.url)
    f.time = 102.999; f.url = "https://invented.invalid/second"
    XCTAssertEqual(f.details().browserAddress, "https://invented.invalid/first")
    XCTAssertEqual(f.tasks.count, 0)
    f.time = 103; _ = f.details(); XCTAssertEqual(f.tasks.count, 1); f.finish()
    XCTAssertEqual(f.details().browserAddress, f.url); XCTAssertEqual(f.queries, 2)
  }
  func testCompletedMissRefreshesToURLForNonhandlerAndUnknownBrowser() {
    for browser: Bool? in [false, nil] {
      let f = Fixture(); f.browser = browser
      _ = f.details(); f.finish(); XCTAssertNil(f.details().browserAddress)
      f.time = 103; f.url = "https://invented.invalid/late"
      _ = f.details(); f.finish()
      let result = f.details()
      XCTAssertEqual(result.browserAddress, f.url); XCTAssertFalse(result.isBrowser)
      XCTAssertEqual(result.isBrowserKnown, browser != nil)
      XCTAssertEqual(f.queries, 2)
    }
  }
  func testEmbeddedAddressDerivationKeepsObservedFactsAndUnknownHintSeparate() {
    for browser: Bool? in [false, nil, true] {
      let f = Fixture(); f.browser = browser; f.document = "file:///invented/fallback"
      _ = f.details(); f.finish()
      let missing = f.details()
      XCTAssertNil(missing.browserAddress)
      XCTAssertEqual(RecorderPolicy.documentKey(missing), "/invented/fallback")
      XCTAssertEqual(missing.isBrowserKnown, browser != nil)
      f.time = 103; f.url = "https://invented.invalid/embedded/path/?q=1#fragment"
      _ = f.details(); f.finish()
      let observed = f.details()
      XCTAssertEqual(observed.browserAddress, f.url)
      XCTAssertEqual(observed.document, f.document)
      XCTAssertEqual(RecorderPolicy.documentKey(observed), "invented.invalid/embedded/path")
      XCTAssertEqual(observed.isBrowser, browser ?? false)
      XCTAssertEqual(observed.isBrowserKnown, browser != nil)
      XCTAssertNil(observed.accessibility)
      let sample = RecorderPolicy.sample(at: 103, front: observed, input: InputCounts(), keepingAwake: false, settings: StorageSettings(excludedApps: []))
      XCTAssertEqual(sample.documentKey, "invented.invalid/embedded/path")
      XCTAssertEqual(sample.browserAddress, f.url)
      XCTAssertEqual(sample.isBrowserKnown, browser != nil)
    }
  }
  func testLateFocusChangeRetainsCompletedIdentityAndDoesNotReuseAcrossWindows() {
    let f = Fixture(); f.url = "https://invented.invalid/late"
    _ = f.details(); f.pid = 20; _ = f.details()
    XCTAssertEqual(f.tasks.count, 1); f.finish()
    let completion = f.source.takeCompletedDetails()
    XCTAssertEqual(completion.first?.window?.processID, 10)
    XCTAssertEqual(completion.first?.browserAddress, f.url)
    XCTAssertNil(f.details().browserAddress); XCTAssertEqual(f.tasks.count, 1)
    f.finish(); XCTAssertEqual(f.details().window?.processID, 20)
  }
  func testPrivacyInvalidationRejectsOutstandingWorkerAndCachedMetadata() {
    let f = Fixture(); f.url = "https://invented.invalid/private"
    _ = f.details(); f.source.invalidateMetadata(); f.finish()
    XCTAssertEqual(f.source.takeCompletedDetails().count, 0)
    XCTAssertNil(f.details().browserAddress)
  }

  func testExclusionChangeInvalidatesActualAdapterWorkerBeforeLateCompletion() throws {
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ACTIVITYPROBE_TEST_ROOT"] ?? NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let db = try ActivityStorage(url: root.appendingPathComponent("invented.sqlite"), appDataDirectory: root, databaseScope: .directory(root))
    try db.saveSettings(StorageSettings(excludedApps: []))
    let f = Fixture(), clock = FakeClock(), sources = FakeSources()
    clock.now = 100; sources.clock = clock
    let loop = RecorderLoop(clock: clock, input: sources, front: f.source, secure: sources, awake: sources, screen: sources,
      storage: db, maintenanceStorage: db, ownBundleID: "invented.own")
    loop.tick(); XCTAssertEqual(f.tasks.count, 1)
    try db.saveSettings(StorageSettings(excludedApps: ["invented.embedded"]), at: 101)
    clock.now = 101; loop.tick(); f.finish(); loop.flush(); loop.stop()
    XCTAssertEqual(f.source.takeCompletedDetails().count, 0)
    let newest = try XCTUnwrap(db.observations(in: TimeRange(101,102)).first).sample
    XCTAssertTrue(newest.excluded); XCTAssertNil(newest.windowIdentity); XCTAssertNil(newest.processID)
    XCTAssertNil(newest.isBrowser); XCTAssertNil(newest.accessibility); XCTAssertNil(newest.browserAddress)
  }
}
