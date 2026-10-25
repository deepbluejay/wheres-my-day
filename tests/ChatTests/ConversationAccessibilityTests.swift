import AppKit
import Core
import SwiftUI
@testable import Shell
@testable import Outbound
import XCTest

/// Inspect the hosted accessibility hierarchy, including SwiftUI's virtual elements.
@MainActor enum ConversationAccessibilityOracle {
  static let interactive: Set<NSAccessibility.Role> = [.button, .checkBox, .radioButton, .textField, .textArea, .popUpButton, .menuButton, .menuItem, .disclosureTriangle, .comboBox, .slider, .incrementor, .colorWell, .link]
  struct Control { let role: NSAccessibility.Role; let name: String; let help: String; let source: String }
  static func controls(_ root: Any) -> [Control] {
    var seen: [ObjectIdentifier: AnyObject] = [:], result: [Control] = []
    func walk(_ node: Any) {
      guard let element = node as? NSAccessibilityProtocol else { return }
      let identity = ObjectIdentifier(element as AnyObject)
      guard seen[identity] == nil else { return }
      seen[identity] = element as AnyObject
      if let role = element.accessibilityRole(), interactive.contains(role) {
        result.append(.init(role: role, name: [element.accessibilityLabel(), element.accessibilityTitle()].compactMap { $0 }.first { !$0.isEmpty } ?? "", help: element.accessibilityHelp() ?? "", source: String(describing: type(of: node)) + " parent=" + (element.accessibilityParent().map { String(describing: type(of: $0)) } ?? "none")))
      }
      for child in element.accessibilityChildren() ?? [] { walk(child) }
      // Offscreen SwiftUI roots omit their platform containers from AXChildren.
      // Walk those containers as well, then follow their real accessibility descendants.
      if let view = node as? NSView { for child in view.subviews { walk(child) } }
      if let picker = node as? NSPopUpButton { for item in picker.menu?.items ?? [] { walk(item) } }
    }
    walk(root); return result
  }
  static func verifyRequests(_ host: NSView, references: [String], file: StaticString = #filePath, line: UInt = #line) {
    var seen: [ObjectIdentifier: AnyObject] = [:], found: Set<String> = []
    func walk(_ node: Any) {
      guard let element = node as? NSAccessibilityProtocol else { return }
      let id = ObjectIdentifier(element as AnyObject)
      guard seen[id] == nil else { return }; seen[id] = element as AnyObject
      if let label = element.accessibilityLabel(), references.contains(label), element.accessibilityRole() == .group {
        found.insert(label)
        let children = controls(element)
        XCTAssertFalse(children.isEmpty, "The labelled request must contain its controls", file: file, line: line)
        for child in children { XCTAssertTrue(child.name.hasPrefix(label + ": "), "Every request control needs its visible request reference: \(child.name)", file: file, line: line) }
      }
      for child in element.accessibilityChildren() ?? [] { walk(child) }
      if let view = node as? NSView { for child in view.subviews { walk(child) } }
    }
    walk(host)
    XCTAssertEqual(found, Set(references), "Each request needs a labelled accessibility container", file: file, line: line)
  }
  static func populate(_ form: ConversationQuestions, state: ConversationQuestionState) {
    for field in form.fields { state.values[field.id] = "Invented response" }
  }
  static var layouts = 0, totalControls = 0, maximumScalars = 0, maximumBytes = 0
  static func violations(_ host: NSView) -> [String] {
    let controls = controls(host)
    var failures: [String] = []
    if controls.isEmpty { failures.append("Must inspect actual controls") }
    for control in controls {
      if control.name.isEmpty { failures.append("Missing name for \(control.role), \(control.source)") }
      if control.name.unicodeScalars.count > 240 { failures.append("Name exceeds 240 scalars") }
      if control.name.utf8.count > 960 { failures.append("Name exceeds 960 bytes") }
      if control.name.range(of: #"\[[^\[\]]+\]$"#, options: .regularExpression) == nil { failures.append("Missing distinguishing reference") }
      if control.help.isEmpty { failures.append("Missing accessible help") }
    }
    if Set(controls.map(\.name)).count != controls.count { failures.append("All page controls need distinct names") }
    return failures
  }
  static func verify(_ host: NSView, file: StaticString = #filePath, line: UInt = #line) {
    for failure in violations(host) { XCTFail(failure, file: file, line: line) }
    let controls = controls(host)
    layouts += 1; totalControls += controls.count
    maximumScalars = max(maximumScalars, controls.map { $0.name.unicodeScalars.count }.max() ?? 0)
    maximumBytes = max(maximumBytes, controls.map { $0.name.utf8.count }.max() ?? 0)
  }
}

final class ConversationAccessibilityTests: XCTestCase {
  @MainActor func testAccessibilityMutationWitness() throws {
    for fixture in DecisionFixture.inventory(long: true).filter({ ["claude-questions-2", "codex-questions-1"].contains($0.name) }) {
      let (request, broker) = try fixture.capture()
      withExtendedLifetime(broker) {
        let state = ConversationQuestionState()
        if let form = ConversationQuestions(request: request) { ConversationAccessibilityOracle.populate(form, state: state) }
        let host = ConversationOffscreenRender.requestHost(request, strings: .init(language: "en"), width: 360, state: state)
        ConversationAccessibilityOracle.verify(host)
        state.expanded = true; state.changesExpanded = true
        let expanded = ConversationOffscreenRender.requestHost(request, strings: .init(language: "en"), width: 360, state: state)
        ConversationAccessibilityOracle.verify(expanded)
      }
    }
  }
  @MainActor func testTreePropertyRejectsAnUnlistedControlThatBypassesThePolicy() throws {
    let (request, broker) = try XCTUnwrap(DecisionFixture.inventory(long: false).first).capture()
    withExtendedLifetime(broker) {
      let host = ConversationOffscreenRender.requestHost(request, strings: .init(language: "en"), width: 360, state: ConversationQuestionState())
      ConversationAccessibilityOracle.verify(host)
      let bypass = NSButton(title: String(repeating: "Invented", count: 200), target: nil, action: nil)
      host.addSubview(bypass)
      defer { bypass.removeFromSuperview() }
      XCTAssertTrue(ConversationAccessibilityOracle.violations(host).contains("Name exceeds 240 scalars"))
      bypass.title = "Unlisted control"
      XCTAssertTrue(ConversationAccessibilityOracle.violations(host).contains("Missing distinguishing reference"))
    }
  }
}

extension ConversationAccessibilityTests {
  @MainActor func testConversationControlsAndRecoveryAcrossLanguagesAndWidths() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let resources = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: resources) }
    let compiler = Process(); compiler.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    compiler.arguments = [root.appendingPathComponent("tools/strings.py").path, "compile", resources.path]
    try compiler.run(); compiler.waitUntilExit(); XCTAssertEqual(compiler.terminationStatus, 0)
    for language in ["en", "ko", "ja", "zh-Hans", "zh-Hant", "de", "fr", "es", "ru"] {
      let strings = ConversationStrings(language: language, resources: resources)
      if language != "en" { XCTAssertNotEqual(strings.text(.historyLimit), ChatLabel.historyLimit.rawValue) }
      for provider in ChatProvider.allCases {
        for width in [360.0, 760.0] {
          for mode in 0..<5 {
            var presentation = ConversationPresentation(); presentation.begin("Invented prompt")
            if mode != 0 { presentation.finish() }
            var recovered = false
            let model = String(repeating: "m", count: 120) + "A"
            let selection = ChatSelection(provider: provider, model: model, reasoning: "low")
            let page = ConversationPage(presentation: presentation, strings: strings, provider: provider, selection: mode == 4 ? nil : selection,
              catalog: [.init(id: model, reasoningLevels: ["low", "high"]), .init(id: String(model.dropLast()) + "B", reasoningLevels: ["low"])],
              connected: mode != 1, skipApprovals: false, error: mode == 2 ? .catalogFailed : mode == 3 ? .historyLimit : nil,
              width: width, new: { recovered = true })
            let host = NSHostingView(rootView: page.fixedSize(horizontal: false, vertical: true))
            host.frame = NSRect(x: 0, y: 0, width: width, height: host.fittingSize.height); host.layoutSubtreeIfNeeded()
            ConversationAccessibilityOracle.verify(host)
            if mode == 3 {
              let buttons = DecisionOracle.buttons(host)
              XCTAssertFalse(buttons.contains { $0.title == strings.text(.retry) })
              let recovery = try XCTUnwrap(buttons.first { $0.accessibilityLabel()?.hasSuffix("[history-recovery]") == true })
              XCTAssertEqual(recovery.title, strings.text(.newConversation)); XCTAssertTrue(recovery.isEnabled)
              recovery.performClick(nil); XCTAssertTrue(recovered)
            }
            if mode == 0 {
              let stop = try XCTUnwrap(DecisionOracle.buttons(host).first { $0.title == strings.text(.stop) })
              XCTAssertEqual(stop.keyEquivalent, "\u{1b}"); XCTAssertTrue(stop.keyEquivalentModifierMask.isEmpty)
              let send = try XCTUnwrap(DecisionOracle.buttons(host).first { $0.title == strings.text(.send) })
              XCTAssertEqual(send.keyEquivalent, "\r"); XCTAssertEqual(send.keyEquivalentModifierMask, .command)
            }
          }
          for request in [false, true] {
            let host = NSHostingView(rootView: ConversationRevealControl(strings: strings, request: request, action: {}).frame(width: width))
            host.frame = NSRect(x: 0, y: 0, width: width, height: host.fittingSize.height); host.layoutSubtreeIfNeeded()
            ConversationAccessibilityOracle.verify(host)
          }
        }
      }
    }
  }
  @MainActor func testNativeOptionsPreserveExactAnswersAndAccessibleDetails() throws {
    for fixture in DecisionFixture.inventory(long: true).filter({ ["claude-questions-tail", "codex-questions-tail"].contains($0.name) }) {
      let (request, broker) = try fixture.capture()
      try withExtendedLifetime(broker) {
        let form = try XCTUnwrap(ConversationQuestions(request: request)), state = ConversationQuestionState()
        let host = ConversationOffscreenRender.requestHost(request, strings: .init(language: "en"), width: 360, state: state)
        ConversationAccessibilityOracle.verify(host)
        for (fieldIndex, field) in form.fields.enumerated() {
          let buttons = DecisionOracle.buttons(host).filter { $0.accessibilityLabel()?.contains("[f") == true && $0.accessibilityHelp()?.contains(field.label) == true }
          let first = try XCTUnwrap(buttons.first { $0.accessibilityLabel()?.hasSuffix(".o1]") == true && $0.accessibilityHelp()?.contains(field.options[0]) == true && ($0.accessibilityLabel()?.contains("[f\(fieldIndex + 1).") == true) })
          XCTAssertTrue(first.title.contains(".o1]")); XCTAssertTrue(first.accessibilityHelp()?.contains(field.optionScopes[0]) == true)
          first.performClick(nil)
          XCTAssertEqual(state.values[field.id], field.options[0])
          if field.multiSelect {
            let second = try XCTUnwrap(buttons.first { $0.accessibilityLabel()?.hasSuffix(".o2]") == true })
            second.performClick(nil)
            XCTAssertEqual(state.values[field.id], field.options[0] + "\n" + field.options[1])
          }
          XCTAssertLessThan(fieldIndex, 3)
        }
        let json = try XCTUnwrap(form.response(state: state))
        XCTAssertTrue(request.answer(responseJSON: json))
        var replies: [Data] = []; try broker.flush { replies.append($0) }; try broker.flush { replies.append($0) }
        XCTAssertEqual(replies.count, 1)
      }
    }
  }
}

// Complete pages must distinguish native callbacks even when their command text matches.
extension ConversationAccessibilityTests {
  @MainActor private func pageHost(_ presentation: ConversationPresentation, strings: ConversationStrings, provider: ChatProvider = .codex, width: Double = 760, revealReference: String? = nil, answer: @escaping (ConversationApproval, String) -> Void = { _, _ in }) -> NSView {
    let page = ConversationPage(presentation: presentation, strings: strings, provider: provider,
      selection: .init(provider: provider, model: "invented", reasoning: "low"), catalog: [.init(id: "invented", reasoningLevels: ["low"])],
      connected: true, skipApprovals: false, width: width, answer: answer)
    let host = NSHostingView(rootView: page.fixedSize(horizontal: false, vertical: true).overlay(alignment: .bottom) {
      if let revealReference { ConversationRevealControl(strings: strings, request: true, requestReference: revealReference, action: {}) }
    })
    host.frame = NSRect(x: 0, y: 0, width: width, height: host.fittingSize.height); host.layoutSubtreeIfNeeded()
    return host
  }
  @MainActor func testWholePageRequestIdentityMutationWitness() throws {
    var presentation = ConversationPresentation(); presentation.begin("Invented prompt")
    var requests: [ConversationApproval] = []
    let broker = ConversationApprovals(timeout: 60) { if case .approval(let request) = $0 { requests.append(request) } }
    for index in 1...2 {
      _ = try broker.codex(["id": index, "method": "item/commandExecution/requestApproval", "params": ["threadId": "root", "turnId": "turn",
        "itemId": "invented-item-\(index)", "command": "printf invented", "cwd": "/invented/target-\(index)", "availableDecisions": ["accept", "decline"]]], thread: "root", turn: "turn")
    }
    try withExtendedLifetime(broker) {
      for request in requests { presentation.receive(.approval(request)) }
      let host = pageHost(presentation, strings: .init(language: "en"), answer: { request, choice in XCTAssertTrue(request.answer(choiceID: choice)) })
      let buttons = DecisionOracle.buttons(host)
      let disclosures = buttons.filter { $0.title.contains("Full details") }
      let allows = buttons.filter { $0.title.contains("Allow once") }
      XCTAssertEqual(disclosures.count, 2); XCTAssertEqual(allows.count, 2)
      XCTAssertEqual(Set(disclosures.compactMap { $0.accessibilityLabel() }).count, 2)
      XCTAssertEqual(Set(allows.compactMap { $0.accessibilityLabel() }).count, 2)
      ConversationAccessibilityOracle.verify(host)
      ConversationAccessibilityOracle.verifyRequests(host, references: ["Request 1", "Request 2"])
      // Retain real parent objects while checking the native controls' request ancestry.
      for button in disclosures + allows {
        var parents: [ObjectIdentifier: AnyObject] = [:], labels: [String] = []
        var parent = button.cell?.accessibilityParent() ?? button.accessibilityParent()
        while let element = parent as? NSAccessibilityProtocol {
          let id = ObjectIdentifier(element as AnyObject)
          if parents[id] != nil { break }; parents[id] = element as AnyObject
          if let label = element.accessibilityLabel() { labels.append(label) }
          parent = element.accessibilityParent()
        }
        let reference = try XCTUnwrap(button.accessibilityLabel()?.components(separatedBy: ": ").first)
        XCTAssertTrue(labels.contains(reference), "Native controls must have a labelled request ancestor")
      }
      try XCTUnwrap(allows.first { $0.accessibilityLabel()?.hasPrefix("Request 2: ") == true }).performClick(nil)
      XCTAssertEqual(requests[0].outcome, .pending); XCTAssertEqual(requests[1].outcome, .answered("approve"))
      var replies: [Data] = []; try broker.flush { replies.append($0) }; try broker.flush { replies.append($0) }
      XCTAssertEqual(replies.count, 1)
      let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(replies.first)) as? [String: Any])
      XCTAssertEqual(reply["id"] as? Int, 2)
      XCTAssertEqual((reply["result"] as? [String: Any])?["decision"] as? String, "accept")
      presentation.receive(.text("Invented output")); presentation.notice(.approvalStopped)
      XCTAssertEqual(presentation.rows.compactMap(\.requestNumber), [1, 2])
      let updated = pageHost(presentation, strings: .init(language: "en"))
      ConversationAccessibilityOracle.verify(updated)
      ConversationAccessibilityOracle.verifyRequests(updated, references: ["Request 1", "Request 2"])
    }
  }
}

extension ConversationAccessibilityTests {
  @MainActor func testWholeConversationPagesOverTheInventory() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let resources = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: resources) }
    let compiler = Process(); compiler.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    compiler.arguments = [root.appendingPathComponent("tools/strings.py").path, "compile", resources.path]
    try compiler.run(); compiler.waitUntilExit(); XCTAssertEqual(compiler.terminationStatus, 0)
    var pages = 0, controls = 0, maxScalars = 0, maxBytes = 0
    for long in [false, true] {
      let inventory = DecisionFixture.inventory(long: long)
      for provider in ChatProvider.allCases {
        let fixtures = inventory.filter { $0.claude == (provider == .claude) }
        for start in stride(from: 0, to: fixtures.count, by: 6) {
          let batch = Array(fixtures[start..<min(start + 6, fixtures.count)])
          print("REQUEST_PAGE_BATCH provider=\(provider.rawValue) long=\(long) start=\(start)"); fflush(stdout)
          for language in ["en", "ko", "ja", "zh-Hans", "zh-Hant", "de", "fr", "es", "ru"] {
            let strings = ConversationStrings(language: language, resources: resources)
            if language != "en" { XCTAssertNotEqual(strings.text(.requestReference), ChatLabel.requestReference.rawValue) }
            for width in [360.0, 760.0] {
              try autoreleasepool {
                var presentation = ConversationPresentation(); presentation.begin("Invented prompt")
                var brokers: [ConversationApprovals] = []
                // Identical command text, separate native callback targets, plus retained history.
                let command = try XCTUnwrap(fixtures.first { $0.name == (provider == .claude ? "claude-bash" : "codex-command") })
                let historicalCommand = try XCTUnwrap(inventory.first { $0.name == (provider == .claude ? "codex-command" : "claude-bash") })
                for index in 0..<4 {
                  if index == 2 { presentation.boundary(provider) }
                  let source = index < 2 ? historicalCommand : command
                  var fields = source.fields
                  if !source.claude { fields["cwd"] = "/invented/target-\(index)"; fields["itemId"] = "invented-item-\(index)" }
                  else { fields["tool_use_id"] = "invented-tool-\(index)" }
                  let fixture = DecisionFixture(name: source.name, method: source.method, fields: fields, claude: source.claude)
                  let (request, broker) = try fixture.capture(); brokers.append(broker)
                  if index == 0 { XCTAssertTrue(request.answer(choiceID: "deny")) }
                  if index == 1 { request.invalidate() }
                  presentation.receive(.approval(request))
                }
                for fixture in batch {
                  let (request, broker) = try fixture.capture(); brokers.append(broker)
                  presentation.receive(.approval(request))
                }
                for row in presentation.rows {
                  if let form = row.form, let state = row.formState {
                    ConversationAccessibilityOracle.populate(form, state: state)
                  }
                  // Historical disclosures and both file disclosure states remain in the page.
                  row.formState?.expanded = row.id % 2 == 0
                  row.formState?.changesExpanded = row.id % 2 == 0
                }
                withExtendedLifetime(brokers) {
                  let host = pageHost(presentation, strings: strings, provider: provider, width: width, revealReference: strings.requestReference(4))
                  ConversationAccessibilityOracle.verify(host)
                  ConversationAccessibilityOracle.verifyRequests(host, references: (1...presentation.requests.count).map(strings.requestReference))
                  let found = ConversationAccessibilityOracle.controls(host)
                  pages += 1; controls += found.count
                  maxScalars = max(maxScalars, found.map { $0.name.unicodeScalars.count }.max() ?? 0)
                  maxBytes = max(maxBytes, found.map { $0.name.utf8.count }.max() ?? 0)
                }
              }
              // Let SwiftUI release detached hosting graphs between synthetic pages.
              RunLoop.current.run(until: Date().addingTimeInterval(0.001))
            }
          }
        }
      }
    }
    print("REQUEST_PAGE_ACCESSIBILITY pages=\(pages) controls=\(controls) max_scalars=\(maxScalars) max_bytes=\(maxBytes)")
  }
}

extension ConversationAccessibilityTests {
  func testRequestReferenceHasItsOwnNameBudget() {
    let value = String(repeating: "🧪", count: 500)
    let full = ConversationControlName(action: value, context: value, detail: value, identity: String(repeating: "i", count: 28))
    let scoped = full.inRequest("Request 9223372036854775807")
    XCTAssertTrue(scoped.name.hasPrefix("Request 9223372036854775807: "))
    XCTAssertTrue(scoped.name.hasSuffix(full.reference))
    XCTAssertLessThanOrEqual(scoped.name.unicodeScalars.count, 240)
    XCTAssertLessThanOrEqual(scoped.name.utf8.count, 960)
    XCTAssertEqual(scoped.help, full.help)
  }
}
