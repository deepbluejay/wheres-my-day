import Core
import Outbound

final class FakeConversationTokens: ChatGPTAccessTokens {
  var signedInForPlanUse = true
  var value = "invented-conversation-access"
  var failure: ChatGPTTokenError?
  var rejectionFailure: ChatGPTTokenError?
  var onRejected: (() -> Void)?
  var rejected = 0, limited = 0, notAccepted = 0, refused = 0, notEligible = 0
  var shapes: [String] = []
  func currentAccessToken() throws -> ChatGPTAccessToken {
    if let failure { throw failure }
    return ChatGPTAccessToken(value, validUntil: Int.max)
  }
  func currentAccessToken(requestShape: String) throws -> ChatGPTAccessToken {
    shapes.append(requestShape); return try currentAccessToken()
  }
  func reportRejected(_ token: ChatGPTAccessToken) throws -> ChatGPTAccessToken {
    rejected += 1
    onRejected?()
    if let rejectionFailure { throw rejectionFailure }
    value = "invented-renewed-access"; return ChatGPTAccessToken(value, validUntil: Int.max)
  }
  func reportNotEligible(_ token: ChatGPTAccessToken) { notEligible += 1 }
  func reportUsageLimited(_ token: ChatGPTAccessToken) { limited += 1 }
  func reportNotAccepted(_ token: ChatGPTAccessToken) { notAccepted += 1 }
  func reportRequestRefused(_ token: ChatGPTAccessToken) { refused += 1 }
  func reportSignInRequired() {}
}

struct FakeAccountModels: ChatGPTModels {
  func models(token: ChatGPTAccessToken) throws -> [ChatModel] {
    [ChatModel(id: "gpt-invented", reasoningLevels: ["low", "high"]), ChatModel(id: "gpt-5.6-luna", reasoningLevels: ["low"]), ChatModel(id: "gpt-alternate", reasoningLevels: ["medium"])]
  }
}
