import Core
import Foundation
import Outbound
@testable import Shell
import Storage
import XCTest

final class SettingsConcurrencyTests: XCTestCase {
  var root: URL!
  override func setUpWithError() throws {
    root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ACTIVITYPROBE_TEST_ROOT"] ?? NSTemporaryDirectory())
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }
  override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
  func store() throws -> ActivityStorage { try ActivityStorage(url: root.appendingPathComponent("invented.sqlite"), appDataDirectory: root, databaseScope: .directory(root)) }

  @MainActor func testEquivalentDatabaseSpellingsShareOneSettingsController() throws {
    let first = try store()
    let sensitive = try XCTUnwrap(root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames)
    let spelling = sensitive ? "invented.sqlite" : "INVENTED.SQLITE"
    let other = try ActivityStorage(url: root.appendingPathComponent(spelling), appDataDirectory: root, databaseScope: .directory(root))
    let a = try SettingsController.forDatabase(store: first, connector: ImmediateConnection(), ownBundleID: "org.example.self")
    let b = try SettingsController.forDatabase(store: other, connector: ImmediateConnection(), ownBundleID: "org.example.self")
    XCTAssertTrue(a === b)
    let separate = try ActivityStorage(url: root.appendingPathComponent("separate.sqlite"), appDataDirectory: root, databaseScope: .directory(root))
    let c = try SettingsController.forDatabase(store: separate, connector: ImmediateConnection(), ownBundleID: "org.example.self")
    XCTAssertFalse(a === c)
  }

  @MainActor func testUnrelatedEditsNeverRestoreConsentOrLoseExternalChanges() throws {
    for edit: SettingsEdit in [.dayStart(9), .recording(false), .addApp("org.example.local"), .retention(screen: 14, prompt: 21)] {
      let db = try store(), external = try store()
      try db.saveFixtureSettings(StorageSettings(excludedApps: [], subscriptionConnected: true))
      let wrapped = InterleavedSettings(db)
      let controller = try SettingsController(store: wrapped, connector: ImmediateConnection(), ownBundleID: "org.example.self")
      wrapped.interleave = {
        var latest = try external.settings()
        latest.subscriptionConnected = false
        latest.excludedApps.append("org.example.external")
        if case .retention = edit {} else { latest.screenRetentionDays = 77; latest.promptRetentionDays = 88 }
        try external.saveFixtureSettings(latest)
      }
      controller.edit(edit)
      let result = try external.settings()
      XCTAssertFalse(result.subscriptionConnected)
      XCTAssertTrue(result.excludedApps.contains("org.example.external"))
      if case .retention = edit { XCTAssertEqual(result.screenRetentionDays, 14); XCTAssertEqual(result.promptRetentionDays, 21) }
      else { XCTAssertEqual(result.screenRetentionDays, 77); XCTAssertEqual(result.promptRetentionDays, 88) }
      if case .dayStart = edit { XCTAssertEqual(result.general["dayStartHour"], "9") }
    }
  }
  @MainActor func testLaterDisconnectWinsAcrossControllersEvenWhenAlreadyOff() async throws {
    for initiallyConnected in [true, false] {
      let db = try store(); try db.saveFixtureSettings(StorageSettings(subscriptionConnected: initiallyConnected))
      let started = expectation(description: "invented login pending")
      let gate = GatedConnection(started: { started.fulfill() }, completion: {})
      let a = try SettingsController(store: db, connector: gate, ownBundleID: "org.example.self")
      let b = try SettingsController(store: store(), connector: ImmediateConnection(), ownBundleID: "org.example.self")
      let pending = Task { await a.connect() }
      await fulfillment(of: [started], timeout: 10)
      b.disconnect(); gate.finish(); await pending.value
      XCTAssertFalse(try db.settings().subscriptionConnected)
      XCTAssertFalse(a.settings.subscriptionConnected)
      await a.connect()
      XCTAssertTrue(try db.settings().subscriptionConnected)
    }
  }
  func testSupersededMessageCoversNewConnectAndDisconnect() throws {
    for operation: SettingsPatch in [.beginConnection, .disconnect] {
      let db = try store()
      let older = try db.patchSettings(.beginConnection)
      let newer = try store().patchSettings(operation)
      XCTAssertThrowsError(try db.patchSettings(.completeConnection(generation: older.connectionGeneration))) {
        XCTAssertEqual($0 as? SettingsValidationError, .connectionSuperseded)
        XCTAssertEqual(SettingsMessage(error: $0).rawValue,
          "A newer connection or disconnect replaced this attempt. Connect again to allow access.")
      }
      XCTAssertFalse(try db.settings().subscriptionConnected)
      if case .beginConnection = operation {
        XCTAssertTrue(try db.patchSettings(.completeConnection(generation: newer.connectionGeneration)).subscriptionConnected)
      }
    }
  }
  // Ideal: a delayed login error remains at its source while navigation and edits stay put.
  @MainActor func testDelayedConnectionFailureKeepsSubscriptionDestination() async throws {
    let db = try store()
    let started = expectation(description: "invented login pending")
    let gate = GatedConnection(started: { started.fulfill() }, completion: { throw SubscriptionConnectionError.failed })
    let controller = try SettingsController(store: db, connector: gate, ownBundleID: "org.example.self")
    let task = Task { await controller.connect() }
    await fulfillment(of: [started], timeout: 5)
    controller.edit(.dayStart(9)); gate.finish(); await task.value
    XCTAssertEqual(controller.error, .connection)
    XCTAssertEqual(controller.errorSection, .subscription)
    XCTAssertEqual(controller.section, .dayStart)
    XCTAssertEqual(try db.settings().general["dayStartHour"], "9")
    XCTAssertFalse(try db.settings().subscriptionConnected)
  }
  @MainActor func testNavigationReloadsOtherClientsRecordingExclusionsAndRetention() throws {
    let a = try SettingsController(store: store(), connector: ImmediateConnection(), ownBundleID: "org.example.self")
    let b = try SettingsController(store: store(), connector: ImmediateConnection(), ownBundleID: "org.example.self")
    a.edit(.recording(false)); a.edit(.addApp("org.example.external")); a.edit(.retention(screen: 14, prompt: 21))
    b.navigate(from: .subscription)
    XCTAssertFalse(b.model.settings.recordingEnabled)
    XCTAssertTrue(b.model.exclusions.contains { $0.id == "org.example.external" })
    XCTAssertEqual(b.settings.screenRetentionDays, 14); XCTAssertEqual(b.settings.promptRetentionDays, 21)
  }
}

private final class InterleavedSettings: SettingsEditingStore {
  let db: ActivityStorage
  var interleave: (() throws -> Void)?
  init(_ db: ActivityStorage) { self.db = db }
  func settings() throws -> StorageSettings {
    let old = try db.settings()
    if let action = interleave { interleave = nil; try action() }
    return old
  }
  var settingsIdentity: String { db.settingsIdentity }
  func patchSettings(_ patch: SettingsPatch) throws -> StorageSettings {
    if let action = interleave { interleave = nil; try action() }
    return try db.patchSettings(patch)
  }
  func saveSettings(_ value: StorageSettings) throws { try db.saveSettings(value) }
}
private final class ImmediateConnection: SubscriptionConnector {
  func connect() throws {}
  func cancel() {}
}
private final class GatedConnection: SubscriptionConnector {
  private let condition = NSCondition()
  private var done = false
  private let started: () -> Void
  private let completion: () throws -> Void
  init(started: @escaping () -> Void, completion: @escaping () throws -> Void) { self.started = started; self.completion = completion }
  func connect() throws {
    condition.lock(); if !done { started() }; while !done { condition.wait() }; condition.unlock()
    try completion()
  }
  func finish() { condition.lock(); done = true; condition.broadcast(); condition.unlock() }
  func cancel() { finish() }
}
