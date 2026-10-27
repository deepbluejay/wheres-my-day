import Core
import Foundation
@testable import Outbound
@testable import Shell
import Storage
import XCTest

final class SettingsTests: XCTestCase {
  var root: URL!
  override func setUpWithError() throws {
    root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ACTIVITYPROBE_TEST_ROOT"] ?? NSTemporaryDirectory())
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("app"), withIntermediateDirectories: true)
  }
  override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
  func storage() throws -> ActivityStorage {
    try ActivityStorage(url: root.appendingPathComponent("invented.sqlite"), appDataDirectory: root, databaseScope: .directory(root))
  }
  // Ideal: changing every offered value persists in the same table, and an empty list stays empty.
  func testRoundTripAndSeedOnlyBeforeFirstSave() throws {
    let store = try storage()
    XCTAssertEqual(try store.settings().excludedApps, StorageSettings.defaultExcludedApps)
    var settings = try store.settings()
    for edit: SettingsEdit in [.recording(false), .pause(900), .retention(screen: 1, prompt: 36500),
      .dayStart(23), .removeApp(StorageSettings.defaultExcludedApps[0]), .addApp("org.example.invented")] {
      settings = try SettingsViewModel(settings: settings, health: TimelineHealth(), ownBundleID: "org.example.self", now: 10).applying(edit)
      try store.saveSettings(settings, at: 10)
      XCTAssertEqual(try storage().settings(), settings)
    }
    settings.excludedApps = []; try store.saveSettings(settings)
    XCTAssertEqual(try storage().settings().excludedApps, [])
  }
  // Ideal: refusal has a typed localizable reason and never changes a saved value.
  func testInvalidEditsAndStorageWritesLeaveSettingsUnchanged() throws {
    let store = try storage(), original = StorageSettings(excludedApps: ["org.example.one"])
    try store.saveSettings(original)
    let model = SettingsViewModel(settings: original, health: TimelineHealth(), ownBundleID: "org.example.self", now: 10)
    for (edit, reason): (SettingsEdit, SettingsValidationError) in [
      (.retention(screen: 0, prompt: 30), .retention), (.retention(screen: 30, prompt: 36501), .retention),
      (.dayStart(-1), .dayStart), (.dayStart(24), .dayStart),
      (.addApp("ORG.EXAMPLE.ONE"), .duplicateApp), (.removeApp("org.example.self"), .ownApp),
      (.addApp("  "), .appIdentity), (.pause(10), .pause)
    ] {
      XCTAssertThrowsError(try model.applying(edit)) { XCTAssertEqual($0 as? SettingsValidationError, reason) }
      XCTAssertEqual(try store.settings(), original)
    }
    for change in 0..<3 {
      var invalid = original
      if change == 0 { invalid.general["dayStartHour"] = "24" }
      if change == 1 { invalid.excludedApps += ["ORG.EXAMPLE.ONE"] }
      if change == 2 { invalid.promptRetentionDays = 0 }
      XCTAssertThrowsError(try store.saveSettings(invalid))
      XCTAssertEqual(try store.settings(), original)
    }
  }
  func testModelStateAndEveryNoticeDestination() {
    var settings = StorageSettings(pausedUntil: 20)
    var model = SettingsViewModel(settings: settings, health: TimelineHealth(), ownBundleID: "org.example.self", now: 10)
    XCTAssertEqual(model.subscription, .notConnected); XCTAssertTrue(model.isPaused)
    XCTAssertEqual(model.dayStartHour, 4)
    XCTAssertEqual(model.exclusions.filter(\.alwaysExcluded).map(\.id), ["org.example.self"])
    settings.subscriptionConnected = true
    var summary = SummaryHealth(); summary.subscriptionConnected = true
    model = SettingsViewModel(settings: settings, health: TimelineHealth(summary: summary), ownBundleID: "org.example.self", now: 20)
    XCTAssertEqual(model.subscription, .connected); XCTAssertFalse(model.isPaused)
    XCTAssertEqual(model.claudeConnection, .notConnected)
    // Summary problems belong to Claude use, which summaries need; ChatGPT use stays connected.
    summary.localPreparationFailed = true
    settings.claudeUse = true
    let problem = SettingsViewModel(settings: settings, health: TimelineHealth(summary: summary), ownBundleID: "org.example.self", now: 0)
    XCTAssertEqual(problem.claudeConnection, .problem); XCTAssertEqual(problem.subscription, .connected)
    for kind in TimelineNoticeKind.allCases {
      let expected: SettingsSection = [.subscription, .summaryFailure, .summaryPreparation, .summaryPaused].contains(kind) ? .claude
        : [.accessibility, .inputMonitoring, .screenRecording].contains(kind) ? .permissions : .security
      XCTAssertEqual(kind.settingsSection, expected)
    }
  }
  @MainActor func testTaskCancellationCannotEnableConsent() async throws {
    let started = expectation(description: "invented connection pending")
    let connector = CancellationTestConnector(started: { started.fulfill() })
    defer { connector.cancel() }
    let store = try storage()
    let controller = try SettingsController(store: store, connector: connector, ownBundleID: "org.example.self")
    let task = Task { await controller.connect() }
    await fulfillment(of: [started], timeout: 10)
    task.cancel()
    await task.value
    XCTAssertFalse(try store.settings().subscriptionConnected)
    XCTAssertEqual(controller.error, .cancelled)
  }

  func testEveryDayStartAndRetentionBoundary() throws {
    let store = try storage()
    var settings = StorageSettings(excludedApps: [])
    for hour in 0...23 {
      settings = try SettingsViewModel(settings: settings, health: TimelineHealth(), ownBundleID: "org.example.self", now: 0).applying(.dayStart(hour))
      try store.saveSettings(settings)
      XCTAssertEqual(try store.settings().general["dayStartHour"], String(hour))
      XCTAssertEqual(try store.settings().dayStartHour, hour)
    }
    for days in [1, 36500] {
      settings = try SettingsViewModel(settings: settings, health: TimelineHealth(), ownBundleID: "org.example.self", now: 0).applying(.retention(screen: days, prompt: days))
      try store.saveSettings(settings)
      XCTAssertEqual(try store.settings().screenRetentionDays, days)
      XCTAssertEqual(try store.settings().promptRetentionDays, days)
    }
  }
  func testDayStartDefaultsForMissingMalformedAndOutOfRangeValues() {
    XCTAssertEqual(StorageSettings().dayStartHour, 4)
    for value in ["", "invalid", "-1", "24", "999999999999999999999999"] {
      let settings = StorageSettings(general: ["dayStartHour": value])
      XCTAssertEqual(settings.dayStartHour, 4)
      XCTAssertEqual(SettingsViewModel(settings: settings, health: TimelineHealth(), ownBundleID: "org.example.self", now: 0).dayStartHour, 4)
    }
  }
  @MainActor func testConsentStaysOffDuringLoginAndEditsSurviveConnection() async throws {
    let started = expectation(description: "injected connection started")
    let connector = CancellationTestConnector(started: { started.fulfill() })
    defer { connector.cancel() }
    let store = try storage(), controller = try SettingsController(store: storage(), connector: connector, ownBundleID: "org.example.self")
    let task = Task { await controller.connect() }
    await fulfillment(of: [started], timeout: 10)
    XCTAssertFalse(try store.settings().subscriptionConnected)
    controller.edit(.recording(false))
    controller.cancelConnection()
    await task.value
    XCTAssertFalse(try store.settings().recordingEnabled)
    XCTAssertFalse(try store.settings().subscriptionConnected)
    XCTAssertEqual(controller.error, .cancelled)
    for kind in TimelineNoticeKind.allCases {
      controller.navigate(from: kind)
      XCTAssertEqual(controller.section, kind.settingsSection)
    }
  }

  func testLegacyImportNormalizesDuplicatesAndInvalidHourWithoutWritingSource() throws {
    let privacy = root.appendingPathComponent("invented-privacy.json"), general = root.appendingPathComponent("invented-general.json")
    let privacyData = Data(#"{"apps":["org.example.one","ORG.EXAMPLE.ONE"],"retentionDays":30}"#.utf8)
    let generalData = Data(#"{"dayStartHour":24}"#.utf8)
    try privacyData.write(to: privacy); try generalData.write(to: general)
    let store = try storage()
    XCTAssertTrue(try store.importOldSettings(privacyFile: privacy, generalFile: general))
    let settings = try store.settings()
    XCTAssertEqual(settings.excludedApps, ["org.example.one"])
    XCTAssertEqual(SettingsViewModel(settings: settings, health: TimelineHealth(), ownBundleID: "org.example.self", now: 0).dayStartHour, 4)
    XCTAssertEqual(try Data(contentsOf: privacy), privacyData)
    XCTAssertEqual(try Data(contentsOf: general), generalData)
  }

  @MainActor func testAppCatalogIsExplicitAndCanBeInvented() async throws {
    struct InventedCatalog: SettingsAppCatalog {
      func apps() -> [SettingsApp] { [SettingsApp(id: "ORG.EXAMPLE.ONE", name: "Example")] }
    }
    let controller = try SettingsController(store: storage(), connector: ImmediateSettingsConnector(), ownBundleID: "org.example.self")
    XCTAssertEqual(controller.apps, [])
    await controller.loadApps(from: InventedCatalog())
    XCTAssertEqual(controller.apps, [SettingsApp(id: "org.example.one", name: "Example")])
    controller.edit(.addApp(controller.apps[0].id))
    XCTAssertTrue(try storage().settings().excludedApps.contains("org.example.one"))
  }

}

// This controller test owns the start/cancel ordering. Subprocess deadlines have separate tests.
private final class CancellationTestConnector: SubscriptionConnector {
  private let condition = NSCondition()
  private var cancelled = false
  private let started: () -> Void
  init(started: @escaping () -> Void) { self.started = started }
  func connect() throws {
    condition.lock()
    started()
    while !cancelled { condition.wait() }
    condition.unlock()
    throw SubscriptionConnectionError.cancelled
  }
  func cancel() { condition.lock(); cancelled = true; condition.broadcast(); condition.unlock() }
}

private final class ImmediateSettingsConnector: SubscriptionConnector {
  func connect() throws {}
  func cancel() {}
}
