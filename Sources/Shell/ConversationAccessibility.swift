import AppKit
import CryptoKit
import Foundation
import SwiftUI

/// Keep the reference outside shortened prose so equal prefixes remain distinguishable.
struct ConversationControlName {
  let name: String
  private let action: String, context: String, detail: String, identity: String
  let reference: String
  let help: String
  init(action: String, context: String = "", detail: String = "", identity: String, help: String? = nil, requestReference: String = "") {
    self.action = action; self.context = context; self.detail = detail; self.identity = identity
    func concise(_ value: String, _ limit: Int) -> String {
      let scalars = value.unicodeScalars
      guard scalars.count > limit else { return value }
      let leading = (limit - 1) / 2
      return String(String.UnicodeScalarView(scalars.prefix(leading))) + "…" + String(String.UnicodeScalarView(scalars.suffix(limit - 1 - leading)))
    }
    let reference = identity.unicodeScalars.count <= 28 ? identity : SHA256.hash(data: Data(identity.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    self.reference = "[" + reference + "]"
    name = [concise(requestReference, 32), concise(action, 60), concise(context, requestReference.isEmpty ? 60 : 48), concise(detail, requestReference.isEmpty ? 80 : 60), self.reference].filter { !$0.isEmpty }.joined(separator: ": ")
    self.help = help ?? [action, context, detail].filter { !$0.isEmpty }.joined(separator: "\n")
  }
  func inRequest(_ reference: String) -> Self {
    .init(action: action, context: context, detail: detail, identity: identity, help: help, requestReference: reference)
  }
}
private struct ConversationRequestReferenceKey: EnvironmentKey {
  static let defaultValue = ""
}
extension EnvironmentValues {
  var conversationRequestReference: String {
    get { self[ConversationRequestReferenceKey.self] }
    set { self[ConversationRequestReferenceKey.self] = newValue }
  }
}
// Native controls expose the same assigned names both on screen and in offscreen host trees.
extension ConversationControlName {
  func assign(to view: NSView) {
    view.setAccessibilityLabel(name); view.setAccessibilityHelp(help); view.toolTip = help
    if let cell = (view as? NSControl)?.cell {
      cell.setAccessibilityLabel(name); cell.setAccessibilityHelp(help)
    }
  }
}
// Keep the safety warning readable while the full header scrolls away.
struct ConversationCompactSkipNotice: NSViewRepresentable {
  let strings: ConversationStrings
  func makeNSView(context: Context) -> NSTextField {
    let field = NSTextField(labelWithString: "")
    field.font = .systemFont(ofSize: 14, weight: .semibold)
    field.maximumNumberOfLines = 1
    field.lineBreakMode = .byTruncatingTail
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return field
  }
  func updateNSView(_ field: NSTextField, context: Context) {
    field.stringValue = strings.text(.skip)
    field.setAccessibilityLabel(strings.text(.skip) + " " + strings.text(.risk))
  }
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
    CGSize(width: proposal.width ?? nsView.intrinsicContentSize.width, height: 22)
  }
}
struct ConversationControlButton: NSViewRepresentable {
  let title: String
  let name: ConversationControlName
  var expanded: Bool? = nil
  var key: String = ""
  var modifiers: NSEvent.ModifierFlags = []
  let action: () -> Void
  @Environment(\.conversationRequestReference) private var requestReference
  @Environment(\.isEnabled) private var enabled
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> NSButton {
    let button = NSButton(title: title, target: context.coordinator, action: #selector(Coordinator.invoke))
    button.isBordered = false; button.alignment = .left; button.font = .systemFont(ofSize: 14)
    button.cell?.lineBreakMode = .byTruncatingTail
    button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return button
  }
  func updateNSView(_ button: NSButton, context: Context) {
    context.coordinator.action = action
    button.setButtonType(.momentaryPushIn)
    button.title = title
    button.attributedTitle = NSAttributedString(string: title, attributes: [.underlineStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: NSColor.labelColor, .font: NSFont.systemFont(ofSize: 14)])
    name.inRequest(requestReference).assign(to: button); button.isEnabled = enabled
    if let expanded { button.cell?.setAccessibilityRole(.disclosureTriangle); button.cell?.setAccessibilityExpanded(expanded) }
    button.keyEquivalent = key; button.keyEquivalentModifierMask = modifiers
  }
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> CGSize? {
    CGSize(width: min(proposal.width ?? 600, nsView.intrinsicContentSize.width), height: 24)
  }
  final class Coordinator: NSObject {
    var action: () -> Void = {}
    @objc func invoke() { action() }
  }
}
struct ConversationControlPicker: NSViewRepresentable {
  struct Item { let id: String; let title: String; let name: ConversationControlName }
  let name: ConversationControlName
  let items: [Item]
  let selection: String
  let change: (String) -> Void
  @Environment(\.conversationRequestReference) private var requestReference
  @Environment(\.isEnabled) private var enabled
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> NSPopUpButton {
    let button = NSPopUpButton(frame: .zero, pullsDown: false)
    button.isBordered = false; button.font = .systemFont(ofSize: 14)
    button.target = context.coordinator; button.action = #selector(Coordinator.invoke(_:))
    button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return button
  }
  func updateNSView(_ button: NSPopUpButton, context: Context) {
    context.coordinator.change = change
    var entries = items
    if !items.contains(where: { $0.id == selection }), !items.contains(where: { $0.id.isEmpty }) {
      entries.insert(.init(id: "", title: "", name: .init(action: name.help, identity: String(name.reference.dropFirst().dropLast()) + ".empty")), at: 0)
    }
    // Updating selection must not rebuild a menu while the person is navigating it.
    if context.coordinator.entries != entries.map({ [$0.id, $0.title, $0.name.inRequest(requestReference).name, $0.name.help] }) {
      button.removeAllItems()
      for item in entries {
        let menuItem = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
        menuItem.representedObject = item.id
        menuItem.setAccessibilityLabel(item.name.inRequest(requestReference).name); menuItem.setAccessibilityHelp(item.name.help)
        button.menu?.addItem(menuItem)
      }
      context.coordinator.entries = entries.map { [$0.id, $0.title, $0.name.inRequest(requestReference).name, $0.name.help] }
    }
    button.selectItem(at: entries.firstIndex(where: { $0.id == selection }) ?? entries.firstIndex(where: { $0.id.isEmpty }) ?? 0)
    name.inRequest(requestReference).assign(to: button); button.isEnabled = enabled && !items.isEmpty
  }
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
    CGSize(width: min(proposal.width ?? 600, nsView.intrinsicContentSize.width), height: 26)
  }
  final class Coordinator: NSObject {
    var entries: [[String]] = []
    var change: (String) -> Void = { _ in }
    @objc func invoke(_ sender: NSPopUpButton) {
      if let id = sender.selectedItem?.representedObject as? String { change(id) }
    }
  }
}
struct ConversationControlText: NSViewRepresentable {
  let name: ConversationControlName
  @Binding var text: String
  var multiline = false
  var grows = false
  var maximumHeight = Double.greatestFiniteMagnitude
  @Environment(\.conversationRequestReference) private var requestReference
  @Environment(\.isEnabled) private var enabled
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true
    if grows {
      // Keep the composer square, including when the system prefers legacy scroll bars.
      scroll.scrollerStyle = .overlay
      scroll.autohidesScrollers = true
    }
    scroll.documentView = Self.editor(multiline: multiline, coordinator: context.coordinator)
    return scroll
  }
  static func editor(multiline: Bool, coordinator: Coordinator) -> NSTextView {
    let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: multiline ? 58 : 34)); editor.isRichText = false; editor.drawsBackground = false
    editor.font = .systemFont(ofSize: 14); editor.textColor = .labelColor
    editor.textContainerInset = NSSize(width: 0, height: 5)
    editor.isHorizontallyResizable = false; editor.isVerticallyResizable = true
    editor.autoresizingMask = [.width]; editor.minSize = NSSize(width: 0, height: 26)
    editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    editor.textContainer?.widthTracksTextView = true
    editor.allowsUndo = true; editor.delegate = coordinator
    return editor
  }
  func updateNSView(_ scroll: NSScrollView, context: Context) {
    context.coordinator.change = { text = $0 }
    guard let editor = scroll.documentView as? NSTextView else { return }
    if editor.string != text { context.coordinator.replace(editor, with: text) }
    editor.isEditable = enabled; editor.isSelectable = true
    name.inRequest(requestReference).assign(to: editor)
  }
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
    let width = proposal.width ?? 200
    guard grows else { return CGSize(width: width, height: multiline ? 58 : 34) }
    // Measure the binding independently: SwiftUI may ask before updating the native editor.
    let font = NSFont.systemFont(ofSize: 14)
    let storage = NSTextStorage(string: text, attributes: [.font: font])
    let manager = NSLayoutManager()
    let container = NSTextContainer(size: NSSize(width: max(1, width), height: .greatestFiniteMagnitude))
    manager.addTextContainer(container); storage.addLayoutManager(manager)
    manager.ensureLayout(for: container)
    let line = manager.defaultLineHeight(for: font)
    let contentHeight = max(manager.usedRect(for: container).maxY, manager.extraLineFragmentRect.maxY)
    let height = min(max(line + 10, maximumHeight), 8 * line + 10, max(line + 10, contentHeight + 10))
    return CGSize(width: width, height: ceil(height))
  }
  final class Coordinator: NSObject, NSTextViewDelegate {
    var change: (String) -> Void = { _ in }
    /// The input's own history: Edit > Undo reaches it through the first responder and no other field.
    /// A locked input offers none, so Undo cannot change text the person cannot edit.
    let history = UndoManager()
    func undoManager(for view: NSTextView) -> UndoManager? { view.isEditable ? history : nil }
    /// Text set from outside (cleared after send) was not typed here, so Undo must not replay
    /// earlier ranges into it.
    func replace(_ editor: NSTextView, with text: String) {
      editor.breakUndoCoalescing(); editor.string = text; history.removeAllActions()
    }
    func textDidChange(_ notification: Notification) {
      if let editor = notification.object as? NSTextView { change(editor.string) }
    }
  }
}

struct ConversationControlSecret: NSViewRepresentable {
  let name: ConversationControlName
  @Binding var text: String
  @Environment(\.conversationRequestReference) private var requestReference
  @Environment(\.isEnabled) private var enabled
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> NSSecureTextField {
    let field = NSSecureTextField(); field.delegate = context.coordinator
    field.isBordered = false; field.drawsBackground = false; field.font = .systemFont(ofSize: 14)
    return field
  }
  func updateNSView(_ field: NSSecureTextField, context: Context) {
    context.coordinator.change = { text = $0 }
    if field.stringValue != text { field.stringValue = text }
    field.isEnabled = enabled; name.inRequest(requestReference).assign(to: field)
  }
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSecureTextField, context: Context) -> CGSize? {
    CGSize(width: proposal.width ?? 200, height: 34)
  }
  final class Coordinator: NSObject, NSTextFieldDelegate {
    var change: (String) -> Void = { _ in }
    func controlTextDidChange(_ notification: Notification) {
      if let field = notification.object as? NSSecureTextField { change(field.stringValue) }
    }
  }
}

/// Keep request ancestry on the native tree as well as in each control's name.
struct ConversationRequestContainer<Content: View>: NSViewRepresentable {
  let label: String
  let content: Content
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> NSHostingView<AnyView> {
    let host = NSHostingView(rootView: root(context: context))
    host.setAccessibilityElement(true); host.setAccessibilityRole(.group)
    host.setAccessibilityLabel(label)
    return host
  }
  func updateNSView(_ host: NSHostingView<AnyView>, context: Context) {
    host.rootView = root(context: context); host.setAccessibilityLabel(label)
  }
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSHostingView<AnyView>, context: Context) -> CGSize? {
    if context.coordinator.width != proposal.width {
      context.coordinator.width = proposal.width
      nsView.rootView = root(context: context)
    }
    return CGSize(width: proposal.width ?? nsView.fittingSize.width, height: nsView.fittingSize.height)
  }
  private func root(context: Context) -> AnyView {
    let environment = context.environment
    return AnyView(content.font(environment.font)
      .environment(\.colorScheme, environment.colorScheme).environment(\.layoutDirection, environment.layoutDirection)
      .environment(\.locale, environment.locale).environment(\.isEnabled, environment.isEnabled)
      .environment(\.displayScale, environment.displayScale).environment(\.dynamicTypeSize, environment.dynamicTypeSize)
      .frame(width: context.coordinator.width))
  }
  final class Coordinator { var width: CGFloat? }
}
