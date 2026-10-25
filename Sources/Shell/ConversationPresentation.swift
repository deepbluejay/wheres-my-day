import Core
import Foundation

public enum ConversationToolState: Equatable { case running, done, failed, cancelled }
public struct ConversationRow: Identifiable, Equatable {
  public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id && lhs.kind == rhs.kind && lhs.text == rhs.text && lhs.approval == rhs.approval && lhs.requestNumber == rhs.requestNumber }
  public enum Kind: Equatable { case person, agent, tool(ConversationToolState), approval, boundary(ChatProvider), notice(ChatLabel) }
  public let id: Int
  public var kind: Kind
  public var text: String
  public var approval: ConversationApproval?
  public var requestNumber: Int?
  public var form: ConversationQuestions?
  public var formState: ConversationQuestionState?
}
/// Transient screen state only. Tool activity is part of the current conversation, never a lookup log.
public struct ConversationPresentation {
  public private(set) var rows: [ConversationRow] = []
  public private(set) var isRunning = false
  public private(set) var billing: ConversationBilling?
  public private(set) var outputVersion = 0
  public private(set) var requests: [ConversationApproval] = []
  public var pendingRequestID: String? { requests.last { $0.outcome == .pending }?.id }
  private var tools: [String: Int] = [:]
  public init() {}
  public mutating func begin(_ text: String) {
    outputVersion += 1; rows.append(.init(id: rows.count, kind: .person, text: text)); isRunning = true; tools = [:]; billing = nil
  }
  public mutating func receive(_ event: ConversationEvent) {
    guard isRunning else {
      if case .approval(let request) = event { request.invalidate() }
      return
    }
    outputVersion += 1
    switch event {
    case .started: break
    case .billing(let value): billing = value
    case .text(let text):
      if rows.last?.kind == .agent { rows[rows.count - 1].text += text }
      else { rows.append(.init(id: rows.count, kind: .agent, text: text)) }
    case .toolStarted(let id, let name):
      guard tools[id] == nil else { return }
      tools[id] = rows.count; rows.append(.init(id: rows.count, kind: .tool(.running), text: name))
    case .toolFinished(let id, let failed):
      if let index = tools[id] { rows[index].kind = .tool(failed ? .failed : .done) }
    case .approval(let request):
      requests.append(request)
      rows.append(.init(id: rows.count, kind: .approval, text: "", approval: request, requestNumber: requests.count, form: ConversationQuestions(request: request), formState: ConversationQuestionState()))
    case .approvalResolved: break // The request owns its thread-safe terminal outcome.
    case .completed: finish()
    }
  }
  public mutating func finish() {
    for index in rows.indices {
      if rows[index].kind == .tool(.running) { rows[index].kind = .tool(.cancelled) }
      rows[index].approval?.invalidate()
    }
    isRunning = false
  }
  public mutating func stop() { finish() }
  public mutating func boundary(_ provider: ChatProvider) { rows.append(.init(id: rows.count, kind: .boundary(provider), text: "")); outputVersion += 1 }
  public mutating func notice(_ reason: ChatLabel) { rows.append(.init(id: rows.count, kind: .notice(reason), text: "")); outputVersion += 1 }
}
