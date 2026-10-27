import AppKit
import Core
import Foundation
@testable import Shell
import SwiftUI
import XCTest

final class SettingsPresentationTests: XCTestCase {
  @MainActor func testClaudeShowsLoginSeparatelyFromAppUse() {
    let strings = SettingsStrings(language: "en", resources: nil)
    for enabled in [false, true] {
      let settings = StorageSettings(general: ["chat.claude.connected": enabled ? "1" : "0"])
      let model = SettingsViewModel(settings: settings, health: TimelineHealth(), ownBundleID: "org.example.self", now: 100)
      for (account, text) in [
        (ClaudeLoginSnapshot(state: .loggedIn, email: "person@example.com", plan: "Max"), "person@example.com · Logged in with the Max plan"),
        (ClaudeLoginSnapshot(state: .loggedIn, email: "person@example.com"), "person@example.com · Logged in"),
        (ClaudeLoginSnapshot(state: .loggedIn, plan: "Team"), "Logged in with the Team plan"),
        (ClaudeLoginSnapshot(state: .loggedIn), SettingsLabel.claudeLoggedIn.rawValue),
        (ClaudeLoginSnapshot(state: .loggedOut), "Not logged in")
      ] {
        let page = SettingsPage(model: model, strings: strings, width: 360, claudeLogin: account.state, claudeAccount: account)
        XCTAssertEqual(page.claudeLoginText, text)
        XCTAssertEqual(page.claudeUseState.rawValue, enabled ? "On" : "Off")
        XCTAssertEqual(page.claudeUseAction.rawValue, enabled ? "Turn off" : "Turn on")
      }
    }
    XCTAssertEqual(SettingsLabel.claudeAppUse.rawValue, "Use Claude in this app")
    XCTAssertEqual(SettingsLabel.claudeMacLoginNote.rawValue, "This changes the Claude Code login for the whole Mac.")
    XCTAssertEqual(SettingsLabel.claudeAppUseNote.rawValue,
      "Turning this off keeps your Claude Code login and stops summaries and Claude conversations in this app.")
  }
  private var resources: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Resources/Localizable.xcstrings")
  }
  // Ideal: every settings label and every refusal reason exists in all nine languages.
  func testAllLabelsAndErrorsTranslatedAndBundled() throws {
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: resources)) as? [String: Any])
    let catalog = try XCTUnwrap(object["strings"] as? [String: [String: Any]])
    for key in SettingsLabel.allCases.map(\.rawValue) + SettingsMessage.allCases.map(\.rawValue) {
      let item = try XCTUnwrap(catalog[key], key)
      XCTAssertEqual(item["extractionState"] as? String, "manual", key)
      let translations = try XCTUnwrap(item["localizations"] as? [String: [String: Any]], key)
      for language in ["ko", "ja", "zh-Hans", "zh-Hant", "de", "fr", "es", "ru"] {
        let unit = try XCTUnwrap(translations[language]?["stringUnit"] as? [String: String], key + language)
        XCTAssertFalse(try XCTUnwrap(unit["value"]).isEmpty)
      }
    }
    let consent = try XCTUnwrap(catalog[SettingsLabel.consent.rawValue]?["localizations"] as? [String: [String: Any]])
    XCTAssertEqual((consent["ko"]?["stringUnit"] as? [String: String])?["value"], "에이전트 대화를 읽고 요약합니다.")
    for error in SettingsValidationError.allCases { XCTAssertTrue(SettingsMessage.allCases.contains(SettingsMessage(error: error))) }
  }
  @MainActor func testBackupWarningMatchesEstablishedExclusion() throws {
    for failure: StorageSecurityFailure? in [nil, .backupExclusionFailed, .backupExclusionSkippedOverride] {
      var health = TimelineHealth(); health.security.backupExclusionFailure = failure
      let page = SettingsPage(model: SettingsViewModel(settings: StorageSettings(), health: health,
        ownBundleID: "org.example.self", now: 100), strings: SettingsStrings(language: "en", resources: nil), width: 360)
      XCTAssertEqual(page.backupWarning.rawValue, failure == nil
        ? "Records cannot be restored after disk loss or moving to another Mac."
        : "Records may still be backed up because backup exclusion has not been established.")
      let png = try XCTUnwrap(SettingsOffscreenRender.png(model: page.model, strings: page.strings, width: 360, dark: false))
      XCTAssertGreaterThan(png.count, 1000)
    }
  }
  func testSystemSettingsTargetsAreOnlyExplicitActions() {
    let expected = ["Privacy_Accessibility", "Privacy_ListenEvent", "Privacy_ScreenCapture", "FileVault", "timemachine"]
    for (target, suffix) in zip(SettingsSystemTarget.allCases, expected) {
      XCTAssertTrue(target.url.absoluteString.hasPrefix("x-apple.systempreferences:"))
      XCTAssertTrue(target.url.absoluteString.hasSuffix(suffix))
    }
  }
  func testSystemSettingsAccessibleNamesIdentifyEveryDestination() {
    let strings = SettingsStrings(language: "en", resources: nil)
    let labels = SettingsSystemTarget.allCases.map(strings.systemAction)
    XCTAssertEqual(Set(labels).count, SettingsSystemTarget.allCases.count)
    for (target, label) in zip(SettingsSystemTarget.allCases, labels) {
      XCTAssertTrue(label.hasPrefix("Open System Settings: "))
      XCTAssertTrue(label.contains(target == .fileVault ? "FileVault" : target == .backups ? "backups" : target == .accessibility ? "Accessibility" : target == .inputMonitoring ? "Input Monitoring" : "Screen Recording"))
    }
    XCTAssertEqual(SettingsMessage(error: SubscriptionConnectionError.statusTimeout), .statusTimeout)
  }
  @MainActor func testExpiredPausePickerStartsOneHourInTheFuture() throws {
    let model = SettingsViewModel(settings: StorageSettings(excludedApps: [], pausedUntil: 90),
      health: TimelineHealth(), ownBundleID: "org.example.self", now: 100)
    let host = NSHostingView(rootView: SettingsPage(model: model, strings: SettingsStrings(language: "en", resources: nil), width: 360))
    host.frame = NSRect(x: 0, y: 0, width: 360, height: host.fittingSize.height)
    host.layoutSubtreeIfNeeded()
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    let picker = try XCTUnwrap(descendants(host).compactMap { $0 as? NSDatePicker }.first)
    XCTAssertEqual(picker.dateValue.timeIntervalSince1970, 3700, accuracy: 1)
  }
  @MainActor func testSamePageResetsPickerAfterNaturalExpiryAndASecondPause() throws {
    func page(end: Int, now: Int) -> SettingsPage {
      SettingsPage(model: SettingsViewModel(settings: StorageSettings(excludedApps: [], pausedUntil: end),
        health: TimelineHealth(), ownBundleID: "org.example.self", now: now),
        strings: SettingsStrings(language: "en", resources: nil), width: 360)
    }
    let host = NSHostingView(rootView: page(end: 200, now: 100))
    func layout() { host.frame = NSRect(x: 0, y: 0, width: 360, height: host.fittingSize.height); host.layoutSubtreeIfNeeded() }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    func picker() throws -> NSDatePicker { try XCTUnwrap(descendants(host).compactMap { $0 as? NSDatePicker }.first) }
    layout()
    host.rootView = page(end: 200, now: 200); layout()
    XCTAssertEqual(try picker().dateValue.timeIntervalSince1970, 3800, accuracy: 1)
    host.rootView = page(end: 3800, now: 200); layout()
    host.rootView = page(end: 3800, now: 3800); layout()
    XCTAssertEqual(try picker().dateValue.timeIntervalSince1970, 7400, accuracy: 1)
  }
  @MainActor func testIdleUnpausedPageKeepsItsDefaultInTheFuture() throws {
    func page(now: Int) -> SettingsPage {
      SettingsPage(model: SettingsViewModel(settings: StorageSettings(excludedApps: []), health: TimelineHealth(),
        ownBundleID: "org.example.self", now: now), strings: SettingsStrings(language: "en", resources: nil), width: 360)
    }
    let host = NSHostingView(rootView: page(now: 100))
    func layout() { host.frame = NSRect(x: 0, y: 0, width: 360, height: host.fittingSize.height); host.layoutSubtreeIfNeeded() }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    layout(); host.rootView = page(now: 3700); layout()
    let picker = try XCTUnwrap(descendants(host).compactMap { $0 as? NSDatePicker }.first)
    XCTAssertEqual(picker.dateValue.timeIntervalSince1970, 7300, accuracy: 1)
  }
  @MainActor func testNarrowAndDarkRendersNeedNoActions() throws {
    let model = SettingsViewModel(settings: StorageSettings(excludedApps: ["org.example.invented"]),
      health: TimelineHealth(missingPermissions: [.inputMonitoring]), ownBundleID: "org.example.self", now: 1800000000)
    for dark in [true, false] {
      let data = try XCTUnwrap(SettingsOffscreenRender.png(model: model, strings: SettingsStrings(language: "en", resources: nil), width: 360, dark: dark))
      XCTAssertGreaterThan(data.count, 1000)
      let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
      var placeholders = 0
      for y in 0..<bitmap.pixelsHigh {
        for x in 0..<bitmap.pixelsWide {
          guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
          if color.redComponent > 0.8 && color.greenComponent > 0.6 && color.blueComponent < 0.2 { placeholders += 1 }
        }
      }
      XCTAssertEqual(placeholders, 0, "Native controls must render without unsupported-view placeholders")
    }
  }
}
