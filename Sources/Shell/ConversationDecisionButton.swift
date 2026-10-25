import AppKit
import SwiftUI

/// A native control keeps its visible reference, assigned name and reply identity inspectable together.
struct ConversationDecisionButton: NSViewRepresentable {
  @Environment(\.conversationRequestReference) private var requestReference
  let choice: ConversationDecisionContent.Choice
  let action: () -> Void
  func makeCoordinator() -> Coordinator { Coordinator(action) }
  func makeNSView(context: Context) -> NSButton {
    let button = NSButton(title: "", target: context.coordinator, action: #selector(Coordinator.invoke))
    button.isBordered = false; button.alignment = .left; button.font = .systemFont(ofSize: 14)
    button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    button.cell?.lineBreakMode = .byTruncatingTail
    return button
  }
  func updateNSView(_ button: NSButton, context: Context) {
    context.coordinator.action = action
    button.title = choice.reference + " " + choice.label
    button.attributedTitle = NSAttributedString(string: button.title, attributes: [.underlineStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: NSColor.labelColor, .font: NSFont.systemFont(ofSize: 14)])
    button.identifier = .init("decision." + choice.id)
    choice.controlName.inRequest(requestReference).assign(to: button)
    button.toolTip = choice.title + "\n" + choice.scope
    // These controls never become the default response or receive a digit shortcut.
    button.keyEquivalent = ""
  }
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> CGSize? {
    CGSize(width: proposal.width ?? min(nsView.intrinsicContentSize.width, 600), height: 24)
  }
  final class Coordinator: NSObject {
    var action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func invoke() { action() }
  }
}
