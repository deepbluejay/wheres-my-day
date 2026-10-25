import AppKit
import Core
import Foundation
import Storage

public enum RecorderMenuState: String, CaseIterable {
  case recording, paused, off
  var key: String {
    switch self { case .recording: return "Recording activity"; case .paused: return "Paused"; case .off: return "Off" }
  }
}
public struct RecorderMenuSnapshot {
  public let state: RecorderMenuState
  public init(settings: StorageSettings?, running: Bool, suspended: Bool = false, now: Int) {
    if !running || settings?.recordingEnabled != true { state = .off }
    else if suspended || (settings?.pausedUntil ?? 0) > now { state = .paused }
    else { state = .recording }
  }
  public init(state: RecorderMenuState) { self.state = state }
}

/// An explicit enable can race a recorder that is still draining a previous stop.
/// Wait for that lifetime lock to disappear, then start once. Stop cancels an unserved request.
struct RecorderResumeRequest {
  private(set) var pending = false
  private var nextAttempt: TimeInterval = 0
  mutating func request() { pending = true; nextAttempt = 0 }
  mutating func update(enabled: Bool, running: Bool, now: TimeInterval, start: () throws -> Void) rethrows {
    guard enabled else { pending = false; return }
    guard pending, !running, now >= nextAttempt else { return }
    nextAttempt = now + 30
    try start(); pending = false
  }
}

/// The window process owns the status item, including when the recorder or window is closed.
/// Construction, menu inspection and rendering create no real status item. Only install does.
final class RecorderMenuController: NSObject, NSMenuDelegate {
  private let snapshot: () -> RecorderMenuSnapshot
  private let open: (AppWindowTarget) -> Void
  private let strings: SettingsStrings
  private var item: NSStatusItem?
  private var timer: Timer?
  init(snapshot: @escaping () -> RecorderMenuSnapshot, strings: SettingsStrings = SettingsStrings(language: AppWindowStrings.preferredLanguage()),
    open: @escaping (AppWindowTarget) -> Void) {
    self.snapshot = snapshot; self.strings = strings; self.open = open
  }
  func install() {
    precondition(Thread.isMainThread)
    guard item == nil else { return }
    item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    refresh()
    let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    self.timer = timer
    // Tracking mode must not freeze either the icon or the recorder while a menu is open.
    RunLoop.main.add(timer, forMode: .common)
  }
  func remove() {
    timer?.invalidate(); timer = nil
    if let item { NSStatusBar.system.removeStatusItem(item) }; item = nil
  }
  deinit { timer?.invalidate() }
  func menuNeedsUpdate(_ menu: NSMenu) { update(menu, snapshot: snapshot()) }
  private func refresh() {
    let value = snapshot(), title = "ActivityProbe: " + strings.text(key: value.state.key)
    item?.button?.image = RecorderMenuDrawing.icon(value.state)
    item?.button?.setAccessibilityLabel(title)
    item?.button?.toolTip = title
    if let menu = item?.menu { update(menu, snapshot: value) }
    else { item?.menu = makeMenu(value) }
  }
  func makeMenu(_ value: RecorderMenuSnapshot) -> NSMenu {
    let menu = NSMenu(); menu.autoenablesItems = false; menu.delegate = self
    let state = NSMenuItem(title: "", action: nil, keyEquivalent: ""); state.isEnabled = false
    menu.addItem(state)
    let window = NSMenuItem(title: strings.text(key: "Open window"), action: #selector(openWindow), keyEquivalent: "")
    window.target = self; window.setAccessibilityLabel(window.title); menu.addItem(window)
    let settings = NSMenuItem(title: strings.text(.title), action: #selector(openSettings), keyEquivalent: "")
    settings.target = self; settings.setAccessibilityLabel(settings.title); menu.addItem(settings)
    update(menu, snapshot: value); return menu
  }
  private func update(_ menu: NSMenu, snapshot: RecorderMenuSnapshot) {
    menu.items[0].title = strings.text(key: snapshot.state.key)
    menu.items[0].setAccessibilityLabel(menu.items[0].title)
  }
  @objc private func openWindow() { open(.timeline) }
  @objc private func openSettings() { open(.settings(.recording)) }
}

public enum RecorderMenuDrawing {
  /// Shape alone carries the state, independent of color and appearance.
  public static func icon(_ state: RecorderMenuState) -> NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
      NSColor.labelColor.set()
      let ring = NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 14, height: 14)); ring.lineWidth = 1.5; ring.stroke()
      switch state {
      case .recording: NSBezierPath(ovalIn: NSRect(x: 5, y: 5, width: 8, height: 8)).fill()
      case .paused:
        NSBezierPath(rect: NSRect(x: 6, y: 5, width: 2, height: 8)).fill()
        NSBezierPath(rect: NSRect(x: 10, y: 5, width: 2, height: 8)).fill()
      case .off:
        let slash = NSBezierPath(); slash.move(to: NSPoint(x: 5, y: 5)); slash.line(to: NSPoint(x: 13, y: 13))
        slash.lineWidth = 1.5; slash.stroke()
      }
      return true
    }
    image.isTemplate = true; return image
  }
  /// Offscreen representation of the same three native menu titles and status glyph.
  @MainActor public static func png(state: RecorderMenuState, strings: SettingsStrings, dark: Bool) -> Data? {
    let controller = RecorderMenuController(snapshot: { RecorderMenuSnapshot(state: state) }, strings: strings, open: { _ in })
    let menu = controller.makeMenu(RecorderMenuSnapshot(state: state))
    let font = NSFont.menuFont(ofSize: 14)
    let titles = menu.items.map(\.title)
    let width = max(220, titles.map { ($0 as NSString).size(withAttributes: [.font: font]).width + 64 }.max() ?? 220)
    let view = MenuRenderView(frame: NSRect(x: 0, y: 0, width: width, height: 132), titles: titles, state: state)
    view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    return bitmap.representation(using: .png, properties: [:])
  }
}
private final class MenuRenderView: NSView {
  let titles: [String]
  let state: RecorderMenuState
  init(frame: NSRect, titles: [String], state: RecorderMenuState) {
    self.titles = titles; self.state = state; super.init(frame: frame)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func draw(_ dirtyRect: NSRect) {
    NSColor.windowBackgroundColor.setFill(); bounds.fill()
    RecorderMenuDrawing.icon(state).draw(in: NSRect(x: bounds.width - 30, y: 106, width: 18, height: 18))
    NSColor.separatorColor.setFill(); NSRect(x: 0, y: 100, width: bounds.width, height: 1).fill()
    for (index, title) in titles.enumerated() {
      (title as NSString).draw(at: NSPoint(x: 20, y: 73 - CGFloat(index) * 28), withAttributes: [
        .font: NSFont.menuFont(ofSize: 14), .foregroundColor: index == 0 ? NSColor.secondaryLabelColor : NSColor.labelColor])
    }
  }
}
