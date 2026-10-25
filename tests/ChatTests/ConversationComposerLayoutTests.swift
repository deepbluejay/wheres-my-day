import AppKit
import Core
@testable import Shell
import SwiftUI
import XCTest

final class ConversationComposerLayoutTests: XCTestCase {
  @MainActor func testSendUsesTrailingEdgeForIdleAndRunningInBothLayoutDirections() throws {
    for direction in [LayoutDirection.leftToRight, .rightToLeft] {
      for width in [360.0, 760] {
        for running in [false, true] {
          var presentation = ConversationPresentation()
          if running { presentation.begin("Invented question") }
          let strings = ConversationStrings(language: "en")
          let page = ConversationPage(presentation: presentation, strings: strings, provider: .codex,
            selection: .init(provider: .codex, model: "invented", reasoning: "low"),
            catalog: [.init(id: "invented", reasoningLevels: ["low"])], connected: true, skipApprovals: false,
            width: width, showHeader: false, scrolls: true, initialDraft: "Invented draft")
          let host = NSHostingView(rootView: page.environment(\.layoutDirection, direction).frame(width: width, height: 620))
          host.frame = NSRect(x: 0, y: 0, width: width, height: 620)
          settle(host)
          let views = descendants(host)
          let send = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.accessibilityLabel()?.hasSuffix("[Send]") == true })
          let editor = try XCTUnwrap(views.compactMap { $0 as? NSTextView }.first)
          let input = try XCTUnwrap(editor.enclosingScrollView)
          let sendFrame = send.convert(send.bounds, to: host)
          let inputFrame = input.convert(input.bounds, to: host)
          if direction == .leftToRight { XCTAssertEqual(sendFrame.maxX, inputFrame.maxX, accuracy: 1) }
          else { XCTAssertEqual(sendFrame.minX, inputFrame.minX, accuracy: 1) }
          XCTAssertEqual(send.keyEquivalent, "\r")
          XCTAssertEqual(send.keyEquivalentModifierMask, .command)
          XCTAssertEqual(send.isEnabled, !running)
          XCTAssertNil(host.window)
        }
      }
    }
  }
  @MainActor func testRealWindowFrameAt480PointsKeepsComposerVisible() throws {
    for state in ["empty", "draft", "running", "warning"] {
      var presentation = ConversationPresentation()
      if state == "running" || state == "warning" { presentation.begin("Invented question") }
      let content = AppWindowFrame(strings: .init(language: "en"), settingsVisible: false, panelOpen: true,
        layout: AppWindowLayout(), toggle: {}, settings: {}, back: {}, new: {}, close: {}, resize: { _, _ in }) { width in
          Color.clear.frame(width: width)
        } panel: { width in
          ConversationPage(presentation: presentation, strings: .init(language: "en"), provider: .codex,
            selection: .init(provider: .codex, model: "invented", reasoning: "low"),
            catalog: [.init(id: "invented", reasoningLevels: ["low"])], connected: true, skipApprovals: state == "warning",
            width: width, showHeader: false, scrolls: true,
            initialDraft: state == "draft" ? Array(repeating: "Invented line", count: 8).joined(separator: "\n") : "")
        }
      let host = NSHostingView(rootView: content.frame(width: 729, height: 480))
      host.frame = NSRect(x: 0, y: 0, width: 729, height: 480)
      settle(host)
      let editor = try XCTUnwrap(descendants(host).compactMap { $0 as? NSTextView }.first)
      let input = try XCTUnwrap(editor.enclosingScrollView)
      let messages = try XCTUnwrap(descendants(host).compactMap { $0 as? NSScrollView }.first { $0 !== input })
      let messageFrame = messages.convert(messages.bounds, to: host)
      XCTAssertEqual(messageFrame.minY, state == "warning" ? 126 : 92, accuracy: 1)
      XCTAssertGreaterThanOrEqual(messageFrame.height, 120)
      let inputFrame = input.convert(input.bounds, to: host)
      XCTAssertGreaterThanOrEqual(inputFrame.height, 27)
      XCTAssertGreaterThan(inputFrame.minY, messageFrame.maxY)
      let send = try XCTUnwrap(descendants(host).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel()?.hasSuffix("[Send]") == true })
      XCTAssertLessThan(send.convert(send.bounds, to: host).maxY, 480)
      XCTAssertNil(host.window)
    }
  }
  @MainActor func testSkippedApprovalsWarningStaysOutsideMessageScroll() throws {
    let strings = ConversationStrings(language: "en")
    let fullWarning = strings.text(.skip) + " " + strings.text(.risk)
    for width in [360.0, 480, 760] {
      for height in [388.0, 820] {
        for running in [false, true] {
          for showHeader in [false, true] {
            let host = host(width: width, height: height, turns: 30, running: running, skip: true, showHeader: showHeader)
            let editor = try XCTUnwrap(descendants(host).compactMap { $0 as? NSTextView }.first)
            let input = try XCTUnwrap(editor.enclosingScrollView)
            let messages = try XCTUnwrap(descendants(host).compactMap { $0 as? NSScrollView }.first { $0 !== input })
            let messageFrame = messages.convert(messages.bounds, to: host)
            let compact = descendants(host).compactMap { $0 as? NSTextField }.filter { $0.stringValue == strings.text(.skip) }
            if height == 388 {
              let warning = try XCTUnwrap(compact.first)
              XCTAssertEqual(compact.count, 1)
              XCTAssertFalse(warning.isDescendant(of: try XCTUnwrap(messages.documentView)))
              XCTAssertFalse(warning.isHiddenOrHasHiddenAncestor)
              let frame = warning.convert(warning.bounds, to: host)
              XCTAssertGreaterThanOrEqual(frame.minY, 0)
              XCTAssertEqual(frame.height, 22, accuracy: 1)
              XCTAssertEqual(messageFrame.minY - frame.maxY, 6, accuracy: 1)
              XCTAssertEqual(warning.maximumNumberOfLines, 1)
              XCTAssertEqual(warning.lineBreakMode, .byTruncatingTail)
              XCTAssertEqual(warning.font, .systemFont(ofSize: 14, weight: .semibold))
              XCTAssertEqual(warning.accessibilityLabel(), fullWarning)
              let provider = try XCTUnwrap(descendants(host).compactMap { $0 as? NSPopUpButton }.first)
              XCTAssertTrue(provider.isDescendant(of: messages))
            } else {
              XCTAssertTrue(compact.isEmpty)
              let provider = try XCTUnwrap(descendants(host).compactMap { $0 as? NSPopUpButton }.first)
              XCTAssertFalse(provider.isDescendant(of: messages), "The full warning shares the pinned header")
            }
            XCTAssertGreaterThanOrEqual(messageFrame.height, 120)
            let inputFrame = input.convert(input.bounds, to: host)
            XCTAssertGreaterThanOrEqual(inputFrame.height, 27)
            XCTAssertGreaterThan(inputFrame.minY, messageFrame.maxY)
            let send = try XCTUnwrap(descendants(host).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel()?.hasSuffix("[Send]") == true })
            XCTAssertLessThan(send.convert(send.bounds, to: host).maxY, height)
            XCTAssertNil(host.window)
          }
        }
      }
    }
  }
  @MainActor func testMinimumWindowKeepsMessagesAndComposerReachable() throws {
    // A 480pt window leaves 388pt below its 45pt toolbar and 47pt chat heading.
    let panelHeight = 480.0 - 45 - 47
    for width in [360.0, 480, 760] {
      for showHeader in [false, true] {
        for state in ["empty", "draft", "running", "warning"] {
          let host = host(width: width, height: panelHeight, error: .catalogFailed,
            running: state == "running" || state == "warning", skip: state == "warning", showHeader: showHeader)
          let editor = try XCTUnwrap(descendants(host).compactMap { $0 as? NSTextView }.first)
          let input = try XCTUnwrap(editor.enclosingScrollView)
          if state == "draft" {
            editor.string = Array(repeating: "Invented line", count: 8).joined(separator: "\n")
            editor.delegate?.textDidChange?(Notification(name: NSText.didChangeNotification, object: editor))
            settle(host)
            XCTAssertGreaterThan(editor.frame.height, input.contentSize.height)
          }
          let scrolls = descendants(host).compactMap { $0 as? NSScrollView }.filter { $0 !== input }
            .sorted { $0.convert($0.bounds, to: host).minY < $1.convert($1.bounds, to: host).minY }
          XCTAssertEqual(scrolls.count, 1)
          let messages = try XCTUnwrap(scrolls.last)
          let messageFrame = messages.convert(messages.bounds, to: host)
          let inputFrame = input.convert(input.bounds, to: host)
          XCTAssertGreaterThanOrEqual(messageFrame.height, 120, "\(width), \(state), header \(showHeader)")
          XCTAssertGreaterThanOrEqual(inputFrame.height, 27)
          XCTAssertGreaterThan(inputFrame.minY, messageFrame.maxY)
          XCTAssertLessThan(inputFrame.maxY, panelHeight)
          let send = try XCTUnwrap(descendants(host).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel()?.hasSuffix("[Send]") == true })
          XCTAssertLessThan(send.convert(send.bounds, to: host).maxY, panelHeight)
          XCTAssertNil(host.window)
          let provider = try XCTUnwrap(descendants(host).compactMap { $0 as? NSPopUpButton }.first)
          XCTAssertTrue(provider.isDescendant(of: messages), "Compact controls share the scrollable message document")
        }
      }
    }
  }
  @MainActor private func host(width: Double, height: Double, turns: Int = 0, error: ChatLabel? = nil, running: Bool = false, skip: Bool = false, showHeader: Bool = true) -> NSHostingView<some View> {
    var presentation = ConversationPresentation()
    for _ in 0..<turns {
      presentation.begin("Invented question")
      presentation.receive(.text(String(repeating: "Invented response. ", count: 12)))
      presentation.finish()
    }
    if running { presentation.begin("Invented running question") }
    let page = ConversationPage(presentation: presentation, strings: .init(language: "en"), provider: .codex,
      selection: .init(provider: .codex, model: "invented", reasoning: "low"),
      catalog: [.init(id: "invented", reasoningLevels: ["low"])], connected: true, skipApprovals: skip,
      error: error, width: width, showHeader: showHeader, scrolls: true)
    let host = NSHostingView(rootView: page.frame(width: width, height: height))
    host.frame = NSRect(x: 0, y: 0, width: width, height: height)
    settle(host)
    return host
  }
  @MainActor private func settle(_ host: NSView) {
    for _ in 0..<3 {
      host.layoutSubtreeIfNeeded()
      RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
  }
  @MainActor private func descendants(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(descendants)
  }
  @MainActor func testComposerStaysBelowScrollingMessagesAtPanelBottom() throws {
    for width in [360.0, 480, 760] {
      for height in [620.0, 820] {
        var baseline: CGRect?
        for turns in [0, 1, 30] {
          let host = host(width: width, height: height, turns: turns, error: .catalogFailed)
          XCTAssertNil(host.window)
          let views = descendants(host)
          let editor = try XCTUnwrap(views.compactMap { $0 as? NSTextView }.first)
          let input = try XCTUnwrap(editor.enclosingScrollView)
          let messages = try XCTUnwrap(views.compactMap { $0 as? NSScrollView }.filter { $0 !== input }.max { $0.frame.height < $1.frame.height })
          let inputFrame = input.convert(input.bounds, to: host)
          let messageFrame = messages.convert(messages.bounds, to: host)
          XCTAssertTrue(host.isFlipped)
          XCTAssertLessThan(messageFrame.maxY, inputFrame.minY)
          XCTAssertGreaterThan(messageFrame.height, 100)
          let send = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.accessibilityLabel()?.hasSuffix("[Send]") == true })
          let sendFrame = send.convert(send.bounds, to: host)
          XCTAssertLessThan(height - sendFrame.maxY, 60)
          XCTAssertGreaterThanOrEqual(height - sendFrame.maxY, 20)
          if let baseline { XCTAssertEqual(inputFrame, baseline) }
          else { baseline = inputFrame }
          if turns < 2 {
            let retry = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.accessibilityLabel()?.hasSuffix("[Retry]") == true })
            XCTAssertTrue(retry.isDescendant(of: messages))
          }
          XCTAssertEqual(send.keyEquivalent, "\r")
          XCTAssertEqual(send.keyEquivalentModifierMask, .command)
        }
      }
    }
  }
  @MainActor func testLongPanelRendersLatestOutputWithoutMovingHeaderOrComposer() throws {
    var presentation = ConversationPresentation()
    for index in 0..<30 {
      presentation.begin("Invented question \(index + 1)")
      presentation.receive(.text(String(repeating: "Invented answer. ", count: 30)))
      presentation.finish()
    }
    func bitmap(bottom: Bool) throws -> NSBitmapImageRep {
      let data = try XCTUnwrap(ConversationOffscreenRender.png(presentation: presentation,
        strings: .init(language: "en"), width: 760, viewportHeight: 820, bottom: bottom))
      return try XCTUnwrap(NSBitmapImageRep(data: data))
    }
    let top = try bitmap(bottom: false), bottom = try bitmap(bottom: true)
    XCTAssertEqual(top.pixelsWide, bottom.pixelsWide)
    XCTAssertEqual(top.pixelsHigh, bottom.pixelsHigh)
    let scale = Double(top.pixelsWide) / 760
    var middleDiffers = false
    var headerInk = 0, composerInk = 0
    for y in 0..<top.pixelsHigh {
      for x in 0..<top.pixelsWide {
        let topColor = top.colorAt(x: x, y: y)
        let same = topColor == bottom.colorAt(x: x, y: y)
        if (topColor?.usingColorSpace(.deviceRGB)?.redComponent ?? 1) < 0.5 {
          if Double(y) < 80 * scale { headerInk += 1 }
          if Double(y) > 670 * scale { composerInk += 1 }
        }
        if Double(y) < 180 * scale || Double(y) > 670 * scale {
          XCTAssertTrue(same, "Scrolling must leave the header and composer pinned")
        } else if !same { middleDiffers = true }
      }
    }
    XCTAssertTrue(middleDiffers)
    XCTAssertGreaterThan(headerInk, 100)
    XCTAssertGreaterThan(composerInk, 100)
  }
  @MainActor func testFullWarningRendersPinnedAt820Points() throws {
    var presentation = ConversationPresentation()
    for _ in 0..<30 {
      presentation.begin("Invented question")
      presentation.receive(.text(String(repeating: "Invented answer. ", count: 30)))
      presentation.finish()
    }
    for width in [360.0, 480, 760] {
      let host = host(width: width, height: 820, turns: 30, skip: true)
      let messages = try XCTUnwrap(descendants(host).compactMap { $0 as? NSScrollView }.first { !($0.documentView is NSTextView) })
      let headerBottom = messages.convert(messages.bounds, to: host).minY
      func bitmap(skip: Bool, bottom: Bool) throws -> NSBitmapImageRep {
        let data = try XCTUnwrap(ConversationOffscreenRender.png(presentation: presentation, strings: .init(language: "en"),
          skipApprovals: skip, width: width, viewportHeight: 820, bottom: bottom))
        return try XCTUnwrap(NSBitmapImageRep(data: data))
      }
      let top = try bitmap(skip: true, bottom: false), bottom = try bitmap(skip: true, bottom: true)
      let ordinary = try bitmap(skip: false, bottom: false)
      let scale = Double(top.pixelsHigh) / 820
      var warningPixels = 0
      // The full warning is the final header block, above its rule and 12pt bottom padding.
      for y in Int((headerBottom - 90) * scale)..<Int((headerBottom - 14) * scale) {
        for x in 0..<top.pixelsWide {
          let a = try XCTUnwrap(top.colorAt(x: x, y: y)), b = try XCTUnwrap(bottom.colorAt(x: x, y: y))
          XCTAssertEqual(a, b, "Both warning sentences must stay pinned while messages move")
          if a != ordinary.colorAt(x: x, y: y), a.redComponent < 0.5 { warningPixels += 1 }
        }
      }
      XCTAssertGreaterThan(warningPixels, 100)
    }
  }
  @MainActor func testComposerGrowsToEightLinesThenScrollsInside() throws {
    let host = host(width: 480, height: 820)
    let editor = try XCTUnwrap(descendants(host).compactMap { $0 as? NSTextView }.first)
    let input = try XCTUnwrap(editor.enclosingScrollView)
    let emptyHeight = input.frame.height
    XCTAssertEqual(editor.frame.height, input.contentSize.height, accuracy: 0.01)
    XCTAssertTrue(input.verticalScroller?.isHiddenOrHasHiddenAncestor ?? true)
    func type(_ text: String) {
      editor.string = text
      editor.delegate?.textDidChange?(Notification(name: NSText.didChangeNotification, object: editor))
      settle(host)
    }
    type("Invented first line\nInvented second line\nInvented third line")
    let threeLines = input.frame.height
    XCTAssertGreaterThan(threeLines, emptyHeight)
    type(Array(repeating: "Invented line", count: 8).joined(separator: "\n"))
    let eightLines = input.frame.height
    XCTAssertGreaterThan(eightLines, threeLines)
    type(Array(repeating: "Invented line", count: 30).joined(separator: "\n"))
    XCTAssertEqual(input.frame.height, eightLines, accuracy: 1)
    XCTAssertGreaterThan(editor.frame.height, input.contentSize.height)
    XCTAssertTrue(input.hasVerticalScroller)
    type("")
    XCTAssertEqual(input.frame.height, emptyHeight, accuracy: 1)
  }
  @MainActor func testComposerScrollsOnlyPastItsCap() throws {
    for dark in [false, true] {
      for scale in [1.0, 2] {
        let page = ConversationPage(presentation: .init(), strings: .init(language: "en"), provider: .codex,
          selection: .init(provider: .codex, model: "invented", reasoning: "low"),
          catalog: [.init(id: "invented", reasoningLevels: ["low"])], connected: true,
          skipApprovals: false, width: 480, scrolls: true)
          .environment(\.colorScheme, dark ? .dark : .light).environment(\.displayScale, scale)
          .frame(width: 480, height: 1000)
        let host = NSHostingView(rootView: page)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(x: 0, y: 0, width: 480, height: 1000)
        settle(host)
        let editor = try XCTUnwrap(descendants(host).compactMap { $0 as? NSTextView }.first)
        let input = try XCTUnwrap(editor.enclosingScrollView)
        // The explicit per-view overlay style does not depend on the system scroller preference.
        XCTAssertTrue(input.autohidesScrollers)
        XCTAssertEqual(input.scrollerStyle, .overlay)
        XCTAssertFalse(input.isHiddenOrHasHiddenAncestor)
        for lines in [0, 1, 8, 30, 8, 1, 0] {
          editor.string = Array(repeating: "Invented line", count: lines).joined(separator: "\n")
          editor.delegate?.textDidChange?(Notification(name: NSText.didChangeNotification, object: editor))
          settle(host)
          if lines <= 8 {
            XCTAssertEqual(editor.frame.height, input.contentSize.height, accuracy: 0.01, "\(lines) lines, \(scale)x, dark \(dark)")
            XCTAssertEqual(input.contentView.bounds.minY, 0, accuracy: 0.01)
            XCTAssertTrue(input.verticalScroller?.isHiddenOrHasHiddenAncestor ?? true)
          } else {
            XCTAssertGreaterThan(editor.frame.height, input.contentSize.height)
            XCTAssertTrue(input.hasVerticalScroller)
            let end = editor.frame.height - input.contentSize.height
            input.contentView.scroll(to: NSPoint(x: 0, y: end))
            input.reflectScrolledClipView(input.contentView)
            XCTAssertEqual(input.contentView.bounds.minY, end, accuracy: 0.01)
          }
          XCTAssertNil(host.window)
        }
      }
    }
  }
  @MainActor func testRequestEditorsKeepTheirScrollingBehavior() throws {
    for multiline in [false, true] {
      let control = ConversationControlText(name: .init(action: "Invented field", identity: "invented"),
        text: .constant("Invented text"), multiline: multiline)
      let host = NSHostingView(rootView: control.frame(width: 300, height: multiline ? 58 : 34))
      host.frame = NSRect(x: 0, y: 0, width: 300, height: multiline ? 58 : 34)
      settle(host)
      let input = try XCTUnwrap(descendants(host).compactMap { $0 as? NSScrollView }.first)
      XCTAssertTrue(input.hasVerticalScroller)
      XCTAssertFalse(input.autohidesScrollers)
      XCTAssertNil(host.window)
    }
  }
}

@MainActor private final class LiveConversationLayout: ObservableObject {
  @Published var presentation = ConversationPresentation()
  func append() {
    presentation.begin("Invented question")
    presentation.receive(.text(String(repeating: "Invented answer. ", count: 30)))
    presentation.finish()
  }
}
private struct LiveConversationLayoutPage: View {
  @ObservedObject var model: LiveConversationLayout
  var body: some View {
    ConversationPage(presentation: model.presentation, strings: .init(language: "en"), provider: .codex,
      selection: .init(provider: .codex, model: "invented", reasoning: "low"),
      catalog: [.init(id: "invented", reasoningLevels: ["low"])], connected: true,
      skipApprovals: false, width: 480, scrolls: true).frame(width: 480, height: 820)
  }
}
extension ConversationComposerLayoutTests {
  @MainActor func testNewMessagesFollowBottomAndPreserveReadingPosition() throws {
    let model = LiveConversationLayout()
    let host = NSHostingView(rootView: LiveConversationLayoutPage(model: model))
    host.frame = NSRect(x: 0, y: 0, width: 480, height: 820)
    settle(host)
    let scroll = try XCTUnwrap(descendants(host).compactMap { $0 as? NSScrollView }.filter {
      !($0.documentView is NSTextView)
    }.max { $0.frame.height < $1.frame.height })
    let document = try XCTUnwrap(scroll.documentView)
    XCTAssertTrue(document.isFlipped)
    for _ in 0..<20 { model.append() }
    settle(host)
    guard document.frame.height > scroll.contentSize.height else {
      throw XCTSkip("Windowless SwiftUI scroll document has no overflow geometry; live latest-text visibility requires a window and is not proven here.")
    }
    XCTAssertGreaterThanOrEqual(document.frame.height - scroll.contentView.bounds.maxY, -2)
    XCTAssertLessThanOrEqual(document.frame.height - scroll.contentView.bounds.maxY, 2)
    scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
    settle(host)
    model.append(); settle(host)
    XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 1)
    let reveal = try XCTUnwrap(descendants(host).compactMap { $0 as? NSButton }.first {
      $0.accessibilityLabel()?.hasSuffix("[reveal]") == true
    })
    reveal.performClick(nil); settle(host)
    XCTAssertGreaterThanOrEqual(document.frame.height - scroll.contentView.bounds.maxY, -2)
    XCTAssertLessThanOrEqual(document.frame.height - scroll.contentView.bounds.maxY, 2)
  }
}
