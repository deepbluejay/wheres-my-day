import Core
import Foundation
@testable import Outbound
import XCTest

final class ChatGPTModelsTests: XCTestCase {
  func testLoopbackModelsUseSameBearerFilterVisibilityAndKeepServerOrder() throws {
    let server = try FakeOAuthServer(); defer { server.stop() }
    server.models = { authorization in
      if authorization == "Bearer invented-switched" {
        return (200, ["models": [["slug": "gpt-invented-new", "display_name": "Invented new", "visibility": "list"]]])
      }
      return (200, ["models": [
        ["slug": "gpt-invented", "display_name": "Invented first", "visibility": "list"],
        ["slug": "gpt-hidden", "display_name": "Invented hidden", "visibility": "hidden"],
        ["slug": "gpt-5.6-luna", "display_name": "Invented Luna", "visibility": "list"]]])
    }
    let source = ChatGPTAccountModels(loopback: server.url.appendingPathComponent("v1/models"))
    let first = try source.models(token: .init("invented-first", validUntil: Int.max))
    XCTAssertEqual(first.map(\.id), ["gpt-invented", "gpt-5.6-luna"])
    XCTAssertEqual(first.map(\.displayName), ["Invented first", "Invented Luna"])
    XCTAssertEqual(first.last?.reasoningLevels.first, "low")
    let switched = try source.models(token: .init("invented-switched", validUntil: Int.max))
    XCTAssertEqual(switched.map(\.id), ["gpt-invented-new"])
    XCTAssertEqual(switched.first?.reasoningLevels, ["medium"])
    XCTAssertEqual(server.requests.map(\.method), ["GET", "GET"])
    XCTAssertEqual(server.requests.map(\.authorization), ["Bearer invented-first", "Bearer invented-switched"])
  }

  func testModelsHTTPFailuresKeepStructuredCodesAndNeverRetry() throws {
    let server = try FakeOAuthServer(); defer { server.stop() }
    server.models = { _ in (403, ["error": ["code": "subscription_sharing_user_not_eligible", "message": "Invented denial"]]) }
    let source = ChatGPTAccountModels(loopback: server.url.appendingPathComponent("v1/models"))
    XCTAssertThrowsError(try source.models(token: .init("invented", validUntil: Int.max))) {
      XCTAssertEqual($0 as? CodexPlanFailure, .notEligible)
    }
    XCTAssertEqual(server.requests.count, 1)
  }
}
