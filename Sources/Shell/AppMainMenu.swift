import AppKit
import Core

/// Titles of the window process's main menu. The keys are the English text in the string catalog.
public enum AppMenuLabel: String, CaseIterable {
  case about = "About ActivityProbe"
  case settings = "Settings…"
  case hide = "Hide ActivityProbe"
  case hideOthers = "Hide Others"
  case showAll = "Show All"
  case quit = "Quit ActivityProbe"
  case edit = "Edit"
  case undo = "Undo"
  case redo = "Redo"
  case cut = "Cut"
  case copy = "Copy"
  case paste = "Paste"
  case selectAll = "Select All"
  case window = "Window"
  case minimize = "Minimize"
  case close = "Close"
  case bringAllToFront = "Bring All to Front"
}

/// The two application properties the main menu sets, so tests never replace the real menu bar.
@MainActor public protocol MainMenuTarget: AnyObject {
  var mainMenu: NSMenu? { get set }
  var windowsMenu: NSMenu? { get set }
}

extension NSApplication: MainMenuTarget {}

/// App, Edit and Window menus of the Dock process. Every item except Settings has no target, so
/// AppKit sends it along the responder chain: text fields take the Edit actions, the key window
/// takes Minimize and Close, and NSApplication takes About, Hide, Show All, Bring All to Front and Quit.
/// Quit is the same `terminate(_:)` the Dock sends, so it runs the same cleanup and leaves the recorder.
@MainActor final class AppMainMenu: NSObject {
  /// Same destination as the status item's Settings line.
  static let settingsTarget = AppWindowTarget.settings(.recording)
  private let open: (AppWindowTarget) -> Void
  private let strings: SettingsStrings
  init(strings: SettingsStrings, open: @escaping (AppWindowTarget) -> Void) {
    self.strings = strings; self.open = open
  }

  /// Background modes never ask for the application object, so they cannot build or show a menu.
  func install(for presentation: ProcessPresentation, on application: () -> MainMenuTarget) {
    guard presentation == .dock else { return }
    let target = application(), menu = make()
    target.mainMenu = menu
    target.windowsMenu = menu.items.last?.submenu
  }

  func make() -> NSMenu {
    let main = NSMenu()
    let app = submenu(in: main, title: "ActivityProbe")
    add(.about, #selector(NSApplication.orderFrontStandardAboutPanel(_:)), to: app)
    app.addItem(.separator())
    add(.settings, #selector(openSettings(_:)), ",", to: app).target = self
    app.addItem(.separator())
    add(.hide, #selector(NSApplication.hide(_:)), "h", to: app)
    add(.hideOthers, #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option], to: app)
    add(.showAll, #selector(NSApplication.unhideAllApplications(_:)), to: app)
    app.addItem(.separator())
    add(.quit, #selector(NSApplication.terminate(_:)), "q", to: app)

    let edit = submenu(in: main, title: strings.text(key: AppMenuLabel.edit.rawValue))
    add(.undo, Selector(("undo:")), "z", to: edit)
    add(.redo, Selector(("redo:")), "Z", [.command, .shift], to: edit)
    edit.addItem(.separator())
    add(.cut, #selector(NSText.cut(_:)), "x", to: edit)
    add(.copy, #selector(NSText.copy(_:)), "c", to: edit)
    add(.paste, #selector(NSText.paste(_:)), "v", to: edit)
    add(.selectAll, #selector(NSText.selectAll(_:)), "a", to: edit)

    let window = submenu(in: main, title: strings.text(key: AppMenuLabel.window.rawValue))
    add(.minimize, #selector(NSWindow.performMiniaturize(_:)), "m", to: window)
    add(.close, #selector(NSWindow.performClose(_:)), "w", to: window)
    window.addItem(.separator())
    add(.bringAllToFront, #selector(NSApplication.arrangeInFront(_:)), to: window)
    return main
  }

  @objc func openSettings(_ sender: Any?) { open(Self.settingsTarget) }

  private func submenu(in main: NSMenu, title: String) -> NSMenu {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: ""), menu = NSMenu(title: title)
    item.submenu = menu; main.addItem(item); return menu
  }
  @discardableResult private func add(_ label: AppMenuLabel, _ action: Selector, _ key: String = "",
    _ modifiers: NSEvent.ModifierFlags = .command, to menu: NSMenu) -> NSMenuItem {
    let item = NSMenuItem(title: strings.text(key: label.rawValue), action: action, keyEquivalent: key)
    item.keyEquivalentModifierMask = modifiers
    menu.addItem(item); return item
  }
}
