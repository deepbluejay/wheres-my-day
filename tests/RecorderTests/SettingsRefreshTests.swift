import Combine
import Core
import Foundation
import Outbound
@testable import Shell
import Storage
import XCTest

final class SettingsRefreshTests: XCTestCase {
  var root: URL!
  override func setUpWithError() throws {
    root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ACTIVITYPROBE_TEST_ROOT"] ?? NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }
  override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
  func store() throws -> ActivityStorage { try ActivityStorage(url: root.appendingPathComponent("invented.sqlite"), appDataDirectory: root, databaseScope: .directory(root)) }
  @MainActor func testPauseExpiryPublishesReschedulesAndDefaultsSecondPauseToFuture() throws {
    let db = try store(), timer = ManualSettingsDeadline()
    var now = 100
    try db.saveSettings(StorageSettings(pausedUntil: 200))
    let c = try SettingsController(store: db, connector: NoConnection(), ownBundleID: "org.example.self", clock: { now }, schedule: timer.schedule)
    var publications = 0
    let observation = c.objectWillChange.sink { publications += 1 }
    defer { observation.cancel() }
    XCTAssertEqual(timer.seconds, 100); XCTAssertEqual(c.model.nextPauseEnd, 200)
    c.edit(.pause(300)); XCTAssertEqual(timer.seconds, 200); XCTAssertEqual(timer.cancellations, 1)
    now = 300; let before = publications; timer.fire()
    XCTAssertGreaterThan(publications, before); XCTAssertFalse(c.model.isPaused)
    XCTAssertEqual(c.model.nextPauseEnd, 3900)
    c.edit(.pause(c.model.nextPauseEnd)); XCTAssertTrue(c.model.isPaused); XCTAssertEqual(timer.seconds, 3600)
    now = 3900; timer.fire(); XCTAssertFalse(c.model.isPaused); XCTAssertEqual(c.model.nextPauseEnd, 7500)
    let reopened = try SettingsController(store: store(), connector: NoConnection(), ownBundleID: "org.example.self", clock: { now }, schedule: timer.schedule)
    XCTAssertEqual(reopened.model.nextPauseEnd, 7500)
    // A changed external deadline is rescheduled by the same refresh used on activation and polling.
    _ = try store().patchSettings(.edit(.pause(4500), ownBundleID: "org.example.self", now: now))
    c.refresh(); XCTAssertEqual(timer.seconds, 600)
  }
  @MainActor func testRetentionDraftConflictNeverOverwritesPairedFields() throws {
    let db = try store()
    let a = try SettingsController(store: db, connector: NoConnection(), ownBundleID: "org.example.self")
    let b = try SettingsController(store: store(), connector: NoConnection(), ownBundleID: "org.example.self")
    var draft = SettingsRetentionDraft(a.settings)
    draft.screen = "17"
    b.edit(.retention(screen: 22, prompt: 33)); a.refresh(); draft.receive(a.settings)
    XCTAssertTrue(draft.conflicting); XCTAssertEqual(draft.screen, "17"); XCTAssertEqual(draft.prompt, "30")
    a.edit(draft.edit)
    XCTAssertEqual(a.error, .retentionConflict)
    XCTAssertEqual(try db.settings().screenRetentionDays, 22); XCTAssertEqual(try db.settings().promptRetentionDays, 33)
    draft = SettingsRetentionDraft(a.settings); draft.prompt = "44"
    // Even a commit after the page's last reload is detected inside the storage transaction.
    b.edit(.retention(screen: 55, prompt: 66)); a.edit(draft.edit)
    XCTAssertEqual(a.error, .retentionConflict); XCTAssertEqual(try db.settings().promptRetentionDays, 66)
    draft.receive(a.settings); XCTAssertTrue(draft.conflicting); XCTAssertEqual(draft.prompt, "44")
    draft = SettingsRetentionDraft(a.settings); draft.screen = "7"; a.edit(draft.edit); draft.receive(a.settings)
    XCTAssertFalse(draft.dirty); XCTAssertFalse(draft.conflicting); XCTAssertEqual(try db.settings().promptRetentionDays, 66)
    b.edit(.retention(screen: 8, prompt: 9)); a.refresh(); draft.receive(a.settings)
    XCTAssertEqual(draft.screen, "8"); XCTAssertEqual(draft.prompt, "9"); XCTAssertFalse(draft.conflicting)
  }
  @MainActor func testExplicitInventedBundleSelectionAndBackupRetryPorts() async throws {
    let chooser = InventedAppChooser()
    let db = try store(), c = try SettingsController(store: db, connector: NoConnection(), ownBundleID: "org.example.self")
    await c.chooseApp(using: chooser)
    XCTAssertEqual(chooser.calls, 1); XCTAssertTrue(try db.settings().excludedApps.contains("org.example.chosen"))
    let bundle = root.appendingPathComponent("nested/Invented.app/Contents")
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    let info = ["CFBundleIdentifier": "org.example.chosen", "CFBundleName": "Invented"]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: bundle.appendingPathComponent("Info.plist"))
    XCTAssertEqual(MacSettingsAppChooser.app(at: bundle.deletingLastPathComponent())?.id, "org.example.chosen")
    var attempts = 0
    let marked = try ActivityStorage(url: root.appendingPathComponent("backup.sqlite"), appDataDirectory: root, excludeFromBackup: { _ in
      attempts += 1; if attempts == 1 { throw SubscriptionConnectionError.failed }
    }, databaseScope: .directory(root))
    XCTAssertEqual(marked.securityHealth.backupExclusionFailure, .backupExclusionFailed)
    c.retryBackup(using: marked); XCTAssertNil(c.health.security.backupExclusionFailure); XCTAssertEqual(attempts, 2)
    let overridden = try ActivityStorage(url: root.appendingPathComponent("override.sqlite"), appDataDirectory: root.appendingPathComponent("other"), excludeFromBackup: { _ in XCTFail("Must not mark an override") }, databaseScope: .directory(root))
    c.retryBackup(using: overridden); XCTAssertEqual(c.health.security.backupExclusionFailure, .backupExclusionSkippedOverride)
  }
}
private final class NoConnection: SubscriptionConnector { func connect() throws {}; func cancel() {} }
@MainActor private final class InventedAppChooser: SettingsAppChooser {
  var calls = 0
  func chooseApp() async -> SettingsApp? { calls += 1; return SettingsApp(id: "org.example.chosen", name: "Invented") }
}
@MainActor private final class ManualSettingsDeadline {
  var seconds: Int?
  var cancellations = 0
  var action: (@MainActor () -> Void)?
  func schedule(_ seconds: Int, action: @escaping @MainActor () -> Void) -> (() -> Void) {
    self.seconds = seconds; self.action = action
    return { self.cancellations += 1; self.action = nil }
  }
  func fire() { let pending = action; action = nil; pending?() }
}
