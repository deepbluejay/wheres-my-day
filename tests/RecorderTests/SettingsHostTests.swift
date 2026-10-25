import Core
import Foundation
@testable import Shell
import Storage
import SwiftUI
import XCTest

final class SettingsHostTests: XCTestCase {
  var root: URL!
  override func setUpWithError() throws {
    root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ACTIVITYPROBE_TEST_ROOT"] ?? NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }
  override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
  func store() throws -> ActivityStorage { try ActivityStorage(url: root.appendingPathComponent("invented.sqlite"), appDataDirectory: root, databaseScope: .directory(root)) }
  @MainActor func view(_ controller: SettingsController) -> SettingsView {
    SettingsView(controller: controller, strings: SettingsStrings(language: "en", resources: nil),
      system: NoSystemActions(), appCatalog: NoApps(), appChooser: NoChooser(), backupActions: NoBackup())
  }
  @MainActor func observed(_ view: SettingsView) throws -> SettingsController {
    let wrapper = try XCTUnwrap(Mirror(reflecting: view).children.first { $0.label == "_controller" }?.value as? ObservedObject<SettingsController>)
    return wrapper.wrappedValue
  }
  @MainActor func testViewKeepsSuppliedHostControllerForNoticeRemedyAndLaterHealth() throws {
    let first = try SettingsController(store: store(), connector: NoLogin(), ownBundleID: "org.example.self")
    let host = try SettingsController(store: store(), connector: NoLogin(), ownBundleID: "org.example.self",
      health: TimelineHealth(missingPermissions: [.screenRecording]))
    host.navigate(from: .screenRecording)
    let page = view(host), actual = try observed(page)
    XCTAssertTrue(actual === host)
    XCTAssertEqual(actual.section, .permissions)
    // This same missing-permission set controls the page's status and remedy button.
    XCTAssertEqual(actual.model.health.missingPermissions, [.screenRecording])
    XCTAssertEqual(SettingsStrings(language: "en", resources: nil).systemAction(.screenRecording), "Open System Settings: Screen Recording")
    host.health = TimelineHealth(missingPermissions: [.inputMonitoring])
    XCTAssertEqual(try observed(page).model.health.missingPermissions, [.inputMonitoring])
    withExtendedLifetime(first) {}
  }
  @MainActor func testFactoryChoosesSharedControllerBeforeHostsKeepIt() throws {
    let unrelated = try SettingsController(store: store(), connector: NoLogin(), ownBundleID: "org.example.self")
    let firstHost = try SettingsController.forDatabase(store: store(), connector: NoLogin(), ownBundleID: "org.example.self")
    let secondHost = try SettingsController.forDatabase(store: store(), connector: NoLogin(), ownBundleID: "org.example.self")
    XCTAssertTrue(firstHost === secondHost)
    XCTAssertFalse(firstHost === unrelated)
    secondHost.health = TimelineHealth(missingPermissions: [.screenRecording])
    secondHost.navigate(from: .screenRecording)
    let firstPage = view(firstHost), secondPage = view(secondHost)
    for page in [firstPage, secondPage] {
      let actual = try observed(page)
      XCTAssertTrue(actual === secondHost)
      XCTAssertEqual(actual.section, .permissions)
      XCTAssertEqual(actual.model.health.missingPermissions, [.screenRecording])
    }
    firstHost.health = TimelineHealth(missingPermissions: [.accessibility])
    XCTAssertEqual(try observed(secondPage).model.health.missingPermissions, [.accessibility])
    let otherDB = try ActivityStorage(url: root.appendingPathComponent("other.sqlite"), appDataDirectory: root, databaseScope: .directory(root))
    let other = try SettingsController.forDatabase(store: otherDB, connector: NoLogin(), ownBundleID: "org.example.self")
    XCTAssertFalse(other === firstHost)
  }
  @MainActor func testTwoVisiblePagesShareOnePollUntilTheLastDisappears() async throws {
    let db = try store(), timer = PollDeadline()
    let host = try SettingsController.forDatabase(store: db, connector: NoLogin(), ownBundleID: "org.example.self", pollSchedule: timer.schedule)
    let secondHost = try SettingsController.forDatabase(store: store(), connector: NoLogin(), ownBundleID: "org.example.self")
    let firstEntered = expectation(description: "first visible page")
    let secondEntered = expectation(description: "second visible page")
    let first = Task { firstEntered.fulfill(); await host.observe() }
    let second = Task { secondEntered.fulfill(); await secondHost.observe() }
    await fulfillment(of: [firstEntered, secondEntered], timeout: 5)
    XCTAssertEqual(timer.starts, 1); XCTAssertEqual(timer.seconds, 1)
    _ = try store().patchSettings(.edit(.recording(false), ownBundleID: "org.example.self", now: 100))
    timer.fire()
    XCTAssertFalse(host.settings.recordingEnabled); XCTAssertFalse(secondHost.settings.recordingEnabled)
    XCTAssertEqual(timer.starts, 2)
    first.cancel(); await first.value
    XCTAssertEqual(timer.cancellations, 0)
    second.cancel(); await second.value
    XCTAssertEqual(timer.cancellations, 1)
    let thirdEntered = expectation(description: "reopened page")
    let third = Task { thirdEntered.fulfill(); await host.observe() }
    await fulfillment(of: [thirdEntered], timeout: 5)
    XCTAssertEqual(timer.starts, 3)
    third.cancel(); await third.value
    XCTAssertEqual(timer.cancellations, 2)
    let alreadyCancelled = Task { await host.observe() }
    alreadyCancelled.cancel(); await alreadyCancelled.value
    XCTAssertEqual(timer.starts, 3)
  }

}
private struct NoSystemActions: SettingsSystemActions { func open(_ target: SettingsSystemTarget) { XCTFail("No OS action") } }
private struct NoApps: SettingsAppCatalog { func apps() -> [SettingsApp] { [] } }
private struct NoChooser: SettingsAppChooser { @MainActor func chooseApp() async -> SettingsApp? { XCTFail("No chooser"); return nil } }
private struct NoBackup: SettingsBackupActions { func retryBackupExclusion() -> StorageSecurityHealth { XCTFail("No retry"); return StorageSecurityHealth() } }
private struct NoLogin: SubscriptionConnector { func connect() throws {}; func cancel() {} }

@MainActor private final class PollDeadline {
  var starts = 0
  var cancellations = 0
  var seconds: Int?
  var action: (@MainActor () -> Void)?
  func schedule(_ seconds: Int, action: @escaping @MainActor () -> Void) -> (() -> Void) {
    starts += 1; self.seconds = seconds; self.action = action
    return { self.cancellations += 1; self.action = nil }
  }
  func fire() { let pending = action; action = nil; pending?() }
}
