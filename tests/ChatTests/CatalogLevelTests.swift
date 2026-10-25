import Core
import Foundation
@testable import Outbound
@testable import Shell
import XCTest

/// Vendors add reasoning levels before this app has labels for them; one new level must not empty the list.
final class CatalogLevelTests: XCTestCase {
  private func entry(_ model: String, _ levels: [String]) -> [String: Any] {
    ["id": model, "model": model, "hidden": false, "description": "Invented description",
     "supportedReasoningEfforts": levels.map { ["reasoningEffort": $0, "description": "Invented level"] }]
  }
  private func page(_ data: [[String: Any]]) throws -> [ChatModel] {
    var seen = Set<String>()
    return try CodexConversationAgent.catalogPage(data, seen: &seen)
  }

  func testUnknownLevelsAreLeftOutInVendorOrder() throws {
    let models = try page([entry("invented-a", ["ultra", "high", "invented-level", "low", "xhigh"]), entry("invented-b", ["ultra", "invented-level"])])
    XCTAssertEqual(models, [ChatModel(id: "invented-a", reasoningLevels: ["high", "low", "xhigh"])])
  }

  func testCatalogShapedLikeTheCurrentReplyKeepsEveryModel() throws {
    let wide = ["low", "medium", "high", "xhigh", "max", "ultra"], narrow = ["low", "medium", "high", "xhigh", "max"]
    let data = (1...5).map { entry("invented-wide-\($0)", wide) } + (1...2).map { entry("invented-narrow-\($0)", narrow) }
    let models = try page(data)
    XCTAssertEqual(models.count, 7)
    XCTAssertTrue(models.allSatisfy { $0.reasoningLevels == narrow })
    XCTAssertEqual(models.map(\.id), data.map { $0["model"] as? String })
  }

  func testMalformedRepliesAreStillRefused() {
    var duplicateModel = [entry("invented-a", ["low"]), entry("invented-a", ["high"])]
    let malformed: [[[String: Any]]] = [
      [entry("invented-a", [])],
      [entry("invented-a", ["low", "low"])],
      [entry("invented-a", ["ultra", "ultra"])],
      [["model": "invented-a", "supportedReasoningEfforts": [["reasoningEffort": "low"], ["reasoningEffort": 3]]]],
      [["model": "invented-a"]],
      [["supportedReasoningEfforts": [["reasoningEffort": "low"]]]],
      [entry("invented a\n", ["low"])],
      duplicateModel,
    ]
    for (index, data) in malformed.enumerated() {
      XCTAssertThrowsError(try page(data), "case \(index)") { XCTAssertEqual($0 as? ConversationError, .incompatible) }
    }
    duplicateModel[1]["hidden"] = true
    XCTAssertEqual(try page(duplicateModel).map(\.id), ["invented-a"])
  }

  @MainActor func testSavedSelectionWhoseLevelWasDroppedRecovers() async throws {
    let cases: [(saved: ChatSelection, expected: ChatSelection)] = [
      // The level is still known to the app but this model stopped offering it.
      (.init(provider: .codex, model: "invented-b", reasoning: "max"), .init(provider: .codex, model: "invented-b", reasoning: "medium")),
      // The level is no longer known to the app at all.
      (.init(provider: .codex, model: "invented-b", reasoning: "invented-level"), .init(provider: .codex, model: "invented-b", reasoning: "medium")),
      // The model itself is gone.
      (.init(provider: .codex, model: "invented-gone", reasoning: "low"), .init(provider: .codex, model: "invented-a", reasoning: "low")),
      // Untouched when still offered.
      (.init(provider: .codex, model: "invented-b", reasoning: "high"), .init(provider: .codex, model: "invented-b", reasoning: "high")),
    ]
    for (saved, expected) in cases {
      let store = LevelSettings(); store.value.subscriptionConnected = true
      store.value.general["chat.selection"] = String(decoding: try JSONEncoder().encode(saved), as: UTF8.self)
      let controller = try ConversationController(store: store, makeAgent: { _, _ in LevelAgent() })
      await controller.loadCatalog()
      XCTAssertNil(controller.error, "\(saved)")
      XCTAssertEqual(controller.catalog.map(\.reasoningLevels), [["low"], ["medium", "high"]])
      XCTAssertEqual(controller.selection, expected, "\(saved)")
      XCTAssertEqual(store.value.chatSelection, expected, "\(saved)")
      XCTAssertTrue(controller.send("Invented question"), "\(saved)")
    }
  }

  @MainActor func testStoredClaudeChoiceWithUnknownLevelStaysWithClaude() async throws {
    let store = LevelSettings(); store.value.general["chat.claude.connected"] = "1"
    let saved = ChatSelection(provider: .claude, model: "invented-b", reasoning: "invented-level")
    store.value.general["chat.selection"] = String(decoding: try JSONEncoder().encode(saved), as: UTF8.self)
    XCTAssertNil(store.value.chatSelection)
    var requested: [ChatProvider] = []
    let controller = try ConversationController(store: store, makeAgent: { selection, _ in requested.append(selection.provider); return LevelAgent() })
    XCTAssertEqual(controller.provider, .claude)
    XCTAssertNil(controller.selection)
    await controller.loadCatalog()
    let expected = ChatSelection(provider: .claude, model: "invented-b", reasoning: "medium")
    XCTAssertEqual(requested, [.claude])
    XCTAssertNil(controller.error)
    XCTAssertEqual(controller.selection, expected)
    XCTAssertEqual(store.value.chatSelection, expected)
  }
}

/// An agent of either provider may report a level the app has no label for.
private final class LevelAgent: ConversationAgent {
  let provider = ChatProvider.codex
  func models() throws -> [ChatModel] {
    [.init(id: "invented-a", reasoningLevels: ["low", "ultra"]), .init(id: "invented-b", reasoningLevels: ["ultra", "medium", "high"]),
     .init(id: "invented-c", reasoningLevels: ["ultra"])]
  }
  func converse(messages: [ConversationMessage], selection: ChatSelection) -> AsyncThrowingStream<ConversationEvent, Error> {
    AsyncThrowingStream { $0.yield(.completed); $0.finish() }
  }
}

private final class LevelSettings: SettingsEditingStore {
  var value = StorageSettings()
  var settingsIdentity: String { "invented-levels" }
  func settings() throws -> StorageSettings { value }
  func patchSettings(_ patch: SettingsPatch) throws -> StorageSettings {
    if case .chatSelection(let selection) = patch {
      value.general["chat.selection"] = String(decoding: try JSONEncoder().encode(selection), as: UTF8.self)
    }
    return value
  }
  func saveSettings(_ value: StorageSettings) throws { self.value = value }
}
