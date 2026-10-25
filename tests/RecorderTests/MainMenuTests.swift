import AppKit
import Core
import Foundation
import XCTest
@testable import Shell

/// Stands in for NSApplication so no test replaces the real menu bar.
@MainActor private final class MenuTargetRecorder: MainMenuTarget {
  var mainMenu: NSMenu?
  var windowsMenu: NSMenu?
}

final class MainMenuTests: XCTestCase {
  private struct Row: Equatable {
    let title: String, action: String, key: String, modifiers: NSEvent.ModifierFlags.RawValue
  }
  private func rows(_ menu: NSMenu?) -> [Row] {
    (menu?.items ?? []).map { item in
      item.isSeparatorItem ? Row(title: "-", action: "", key: "", modifiers: 0) :
        Row(title: item.title, action: item.action.map(NSStringFromSelector) ?? "", key: item.keyEquivalent,
          modifiers: item.keyEquivalent.isEmpty ? 0 : item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask).rawValue)
    }
  }
  private func row(_ title: String, _ action: String, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command) -> Row {
    Row(title: title, action: action, key: key, modifiers: key.isEmpty ? 0 : modifiers.rawValue)
  }
  private let separator = Row(title: "-", action: "", key: "", modifiers: 0)

  // Ideal: the standard App, Edit and Window menus with the platform's usual key equivalents.
  @MainActor func testMenuStructureAndKeyEquivalents() {
    let main = AppMainMenu(strings: SettingsStrings(language: "en", resources: nil)) { _ in }.make()
    XCTAssertEqual(main.items.count, 3)
    XCTAssertEqual(rows(main.items[0].submenu), [
      row("About ActivityProbe", "orderFrontStandardAboutPanel:"), separator,
      row("Settings…", "openSettings:", ","), separator,
      row("Hide ActivityProbe", "hide:", "h"), row("Hide Others", "hideOtherApplications:", "h", [.command, .option]),
      row("Show All", "unhideAllApplications:"), separator,
      row("Quit ActivityProbe", "terminate:", "q")])
    XCTAssertEqual(main.items[1].title, "Edit")
    XCTAssertEqual(rows(main.items[1].submenu), [
      row("Undo", "undo:", "z"), row("Redo", "redo:", "Z", [.command, .shift]), separator,
      row("Cut", "cut:", "x"), row("Copy", "copy:", "c"), row("Paste", "paste:", "v"), row("Select All", "selectAll:", "a")])
    XCTAssertEqual(main.items[2].title, "Window")
    XCTAssertEqual(rows(main.items[2].submenu), [
      row("Minimize", "performMiniaturize:", "m"), row("Close", "performClose:", "w"), separator,
      row("Bring All to Front", "arrangeInFront:")])
  }

  // Ideal: only Settings has a target; every other item goes along the responder chain to whoever handles it.
  @MainActor func testActionsReachTheStandardResponders() throws {
    let menu = AppMainMenu(strings: SettingsStrings(language: "en", resources: nil)) { _ in }
    let main = menu.make()
    let items = main.items.flatMap { $0.submenu?.items ?? [] }.filter { !$0.isSeparatorItem }
    for item in items where item.action != #selector(AppMainMenu.openSettings(_:)) {
      XCTAssertNil(item.target, item.title)
    }
    let settings = try XCTUnwrap(items.first { $0.action == #selector(AppMainMenu.openSettings(_:)) })
    XCTAssertTrue(settings.target === menu)
    // Every text field edits through a text view (the field editor), which answers these.
    for title in ["Cut", "Copy", "Paste", "Select All"] {
      let action = try XCTUnwrap(items.first { $0.title == title }?.action)
      XCTAssertTrue(NSTextView.instancesRespond(to: action), title)
    }
    // The window answers Undo and Redo with the first responder's undo manager.
    for title in ["Undo", "Redo", "Minimize", "Close"] {
      XCTAssertTrue(NSWindow.instancesRespond(to: try XCTUnwrap(items.first { $0.title == title }?.action)), title)
    }
    for title in ["About ActivityProbe", "Hide ActivityProbe", "Hide Others", "Show All", "Bring All to Front", "Quit ActivityProbe"] {
      XCTAssertTrue(NSApplication.instancesRespond(to: try XCTUnwrap(items.first { $0.title == title }?.action)), title)
    }
  }

  // Ideal: typing in the conversation input can be undone, and text replaced from outside leaves nothing to undo.
  @MainActor func testConversationInputUndo() {
    let coordinator = ConversationControlText.Coordinator()
    let editor = ConversationControlText.editor(multiline: true, coordinator: coordinator)
    XCTAssertTrue(editor.allowsUndo)
    XCTAssertTrue(editor.undoManager === coordinator.history)
    editor.insertText("invented question", replacementRange: NSRange(location: NSNotFound, length: 0))
    editor.breakUndoCoalescing()
    XCTAssertTrue(coordinator.history.canUndo)
    coordinator.history.undo()
    XCTAssertEqual(editor.string, "")
    editor.insertText("invented draft", replacementRange: NSRange(location: NSNotFound, length: 0))
    coordinator.replace(editor, with: "")
    XCTAssertEqual(editor.string, "")
    XCTAssertFalse(coordinator.history.canUndo)
    XCTAssertFalse(coordinator.history.canRedo)
    editor.isEditable = false
    XCTAssertNil(coordinator.undoManager(for: editor), "A locked input offers no undo")
    XCTAssertNil(editor.undoManager)
    editor.isEditable = true
    XCTAssertTrue(editor.undoManager === coordinator.history)
  }

  // Ideal: Settings opens the same destination as the status item's Settings line, and Quit is the Dock's terminate.
  @MainActor func testSettingsAndQuitRouteToTheExistingPaths() throws {
    var opened: [AppWindowTarget] = []
    let menu = AppMainMenu(strings: SettingsStrings(language: "en", resources: nil)) { opened.append($0) }
    let items = menu.make().items[0].submenu?.items ?? []
    let settings = try XCTUnwrap(items.first { $0.keyEquivalent == "," })
    _ = (settings.target as? NSObject)?.perform(settings.action, with: settings)
    var statusOpened: [AppWindowTarget] = []
    let status = RecorderMenuController(snapshot: { .init(state: .recording) }, strings: SettingsStrings(language: "en", resources: nil)) {
      statusOpened.append($0)
    }
    let statusSettings = try XCTUnwrap(status.makeMenu(.init(state: .recording)).items.last)
    _ = status.perform(statusSettings.action, with: statusSettings)
    XCTAssertEqual(opened, [.settings(.recording)])
    XCTAssertEqual(opened, statusOpened)
    let quit = try XCTUnwrap(items.first { $0.keyEquivalent == "q" })
    XCTAssertEqual(quit.action, #selector(NSApplication.terminate(_:)))
    XCTAssertNil(quit.target)
    // The Dock's Quit and this item both end in applicationWillTerminate, whose cleanup runs once.
    var cleanups = 0
    let host = AppWindowHost(strings: AppWindowStrings(language: "en", resources: nil)) { throw AppCommandError.arguments }
    host.terminating = { cleanups += 1 }
    host.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
    XCTAssertEqual(cleanups, 1)
  }

  // Ideal: the Window menu is the app's windows menu; background modes never ask for the application.
  @MainActor func testInstallOnlyInTheDockProcess() {
    let menu = AppMainMenu(strings: SettingsStrings(language: "en", resources: nil)) { _ in }
    menu.install(for: .background, on: { XCTFail("Background must not build a menu"); return MenuTargetRecorder() })
    let target = MenuTargetRecorder()
    menu.install(for: .dock, on: { target })
    XCTAssertEqual(target.mainMenu?.items.map { $0.submenu?.title ?? "" }, ["ActivityProbe", "Edit", "Window"])
    XCTAssertTrue(target.windowsMenu === target.mainMenu?.items.last?.submenu)
  }

  // Ideal: every title goes through the string catalog, with a translation in all nine languages.
  @MainActor func testTitlesComeFromTheCatalogInEveryLanguage() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let data = try Data(contentsOf: root.appendingPathComponent("Resources/Localizable.xcstrings"))
    let catalog = try XCTUnwrap((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["strings"] as? [String: [String: Any]])
    let languages = ["ko", "ja", "zh-Hans", "zh-Hant", "de", "fr", "es", "ru"]
    var korean: [String: String] = [:]
    for label in AppMenuLabel.allCases {
      let entry = try XCTUnwrap(catalog[label.rawValue], label.rawValue)
      XCTAssertEqual(entry["extractionState"] as? String, "manual")
      let localizations = try XCTUnwrap(entry["localizations"] as? [String: [String: Any]])
      for language in languages {
        let value = (localizations[language]?["stringUnit"] as? [String: String])?["value"] ?? ""
        XCTAssertFalse(value.isEmpty, label.rawValue + " " + language)
        if language == "ko" { korean[label.rawValue] = value }
      }
    }
    // A compiled table in an invented resource folder: every visible title is looked up, none is literal.
    let resources = FileManager.default.temporaryDirectory.appendingPathComponent("ap-main-menu-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: resources) }
    let table = resources.appendingPathComponent("ko.lproj")
    try FileManager.default.createDirectory(at: table, withIntermediateDirectories: true)
    try PropertyListSerialization.data(fromPropertyList: korean, format: .binary, options: 0)
      .write(to: table.appendingPathComponent("Localizable.strings"))
    let main = AppMainMenu(strings: SettingsStrings(language: "ko", resources: resources)) { _ in }.make()
    let titles = main.items.dropFirst().map(\.title) + main.items.flatMap { $0.submenu?.items ?? [] }.filter { !$0.isSeparatorItem }.map(\.title)
    XCTAssertEqual(Set(titles), Set(korean.values))
    XCTAssertEqual(titles.count, AppMenuLabel.allCases.count)
  }
}
