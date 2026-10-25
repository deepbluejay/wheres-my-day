import Core
import Foundation

/// Account choices come from SIWC's models endpoint, never from the bundled Codex catalog.
public protocol ChatGPTModels {
  func models(token: ChatGPTAccessToken) throws -> [ChatModel]
}

public struct ChatGPTAccountModels: ChatGPTModels {
  private let endpoint: URL
  private let makeHTTP: () -> ChatGPTStreamingHTTP
  public init() {
    endpoint = URL(string: "https://api.openai.com/v1/models")!
    makeHTTP = { URLSessionChatGPTStreamingHTTP() }
  }
  /// Only an invented loopback server may replace the production endpoint.
  init(loopback: URL, makeHTTP: @escaping () -> ChatGPTStreamingHTTP = { URLSessionChatGPTStreamingHTTP() }) {
    precondition(loopback.scheme == "http" && loopback.host == "127.0.0.1")
    endpoint = loopback; self.makeHTTP = makeHTTP
  }
  public func models(token: ChatGPTAccessToken) throws -> [ChatModel] {
    var request = URLRequest(url: endpoint, timeoutInterval: 15)
    request.httpMethod = "GET"
    request.setValue("Bearer " + token.value, forHTTPHeaderField: "Authorization")
    let response: ChatGPTStreamedResponse
    do { response = try makeHTTP().stream(request, deadline: 15, limit: 1024 * 1024) }
    catch { throw ConversationError.unavailable }
    guard response.status == 200 else {
      let error = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
      var details = error?["error"] as? [String: Any] ?? [:]
      details["httpStatusCode"] = response.status
      if let failure = CodexPlanFailure.parse(details) { throw failure }
      throw ConversationError.unavailable
    }
    guard let object = try JSONSerialization.jsonObject(with: response.body) as? [String: Any],
      let entries = object["models"] as? [[String: Any]], entries.count <= 1000 else { throw ConversationError.incompatible }
    var seen = Set<String>()
    return try entries.filter { $0["visibility"] as? String == "list" }.map { entry in
      guard let slug = entry["slug"] as? String, ChatSelection.isValidModel(slug), seen.insert(slug).inserted,
        let name = entry["display_name"] as? String, !name.isEmpty, name.utf8.count <= 256 else { throw ConversationError.incompatible }
      // The Responses reasoning guide documents medium as the default. Codex metadata replaces this
      // conservative single choice when present; Luna keeps the product's documented low default.
      return ChatModel(id: slug, reasoningLevels: slug == SummaryPolicy.model ? ["low", "medium", "high"] : ["medium"], displayName: name)
    }
  }
}
