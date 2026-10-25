import AppKit
import Core
import Foundation
@testable import Outbound
@testable import Shell
import XCTest

final class ConversationRequestLayoutTests: XCTestCase {
  // Ideal: no supported native request kind can push its answer and deadline out of the viewport.
  @MainActor func testEveryRequestKindKeepsSummaryAndResponsesInFixedViewport() throws {
    let long = String(repeating: "Invented context sentence. ", count: 300)
    XCTAssertEqual(long.utf8.count, 8100)
    let choices: [ConversationApprovalChoice] = [.init(id: "approve", label: "accept", scope: long), .init(id: "deny", label: "decline"), .init(id: "session", label: "acceptForSession", scope: long)]
    let presentations: [(String, ConversationRequestPresentation, String?)] = [
      ("command", .init(action: .command, command: long, reason: long, target: long, scope: long), nil),
      ("files", .init(action: .files, files: (0..<40).map { .init(path: "invented-\($0)", diff: long) }, reason: long, target: long, scope: long), nil),
      ("permission", .init(action: .permissions, reason: long, target: long, scope: long), nil),
      ("question", .init(action: .question, reason: long, target: long), #"{"questions":[{"id":"q","question":"Invented question"}]}"#),
      ("unknown", .init(action: .tool, reason: long, target: long, scope: long), nil)
    ]
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let resources = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: resources) }
    let compiler = Process()
    compiler.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    compiler.arguments = [root.appendingPathComponent("tools/strings.py").path, "compile", resources.path]
    try compiler.run(); compiler.waitUntilExit()
    XCTAssertEqual(compiler.terminationStatus, 0)
    for language in ["en", "ko", "ja", "zh-Hans", "zh-Hant", "de", "fr", "es", "ru"] {
      for width in [760.0, 360.0] {
        for (kind, presentation, schema) in presentations {
          let request = ConversationApproval(method: kind, details: long, choices: choices, presentation: presentation, responseSchema: schema)
          let strings = ConversationStrings(language: language, resources: resources)
          let height = ConversationOffscreenRender.requestHeight(request, strings: strings, width: width)
          print("REQUEST_LAYOUT language=\(language) kind=\(kind) width=\(width) height=\(height)")
          XCTAssertLessThanOrEqual(height, 620, "\(language) \(kind) at \(width): summary, input, deadline and responses must share the viewport")
          XCTAssertNotNil(ConversationOffscreenRender.requestPNG(request, strings: strings, width: width))
        }
      }
    }
    var captured: ConversationApproval?
    let broker = ConversationApprovals(timeout: 60) { if case .approval(let request) = $0 { captured = request } }
    _ = try broker.codex(["id": 1, "method": "mcpServer/elicitation/request", "params": ["threadId": "root", "message": long,
      "requestedSchema": ["type": "object", "properties": ["answer": ["type": "string"]], "required": ["answer"]]]], thread: "root", turn: "turn")
    let request = try XCTUnwrap(captured)
    XCTAssertEqual(request.presentation.target, long)
    for width in [760.0, 360.0] {
      XCTAssertLessThanOrEqual(ConversationOffscreenRender.requestHeight(request, strings: .init(language: "en"), width: width), 620)
    }
  }

}
