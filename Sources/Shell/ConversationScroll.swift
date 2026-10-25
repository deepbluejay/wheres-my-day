import Foundation

/// The same policy drives the live viewport and deterministic offscreen regressions.
public struct ConversationScrollState {
  public enum Target: Equatable { case none, bottom, request(String) }
  public private(set) var nearBottom = true
  public private(set) var hasNewOutput = false
  public private(set) var pendingRequest: String?
  private var outputVersion = 0
  private var readingRequest: String?
  public init() {}
  public mutating func observeBottom(distance: Double) { nearBottom = distance <= 80 }
  public mutating func changed(outputVersion: Int, requestID: String?) -> Target {
    let changed = outputVersion != self.outputVersion; self.outputVersion = outputVersion
    if requestID != readingRequest {
      let previous = readingRequest; readingRequest = requestID; pendingRequest = requestID
      if let requestID, nearBottom && previous == nil { pendingRequest = nil; return .request(requestID) }
    }
    guard changed else { return .none }
    if readingRequest != nil { hasNewOutput = true; return .none }
    if nearBottom { hasNewOutput = false; return .bottom }
    hasNewOutput = true; return .none
  }
  public mutating func showLatest() -> Target {
    hasNewOutput = false
    if let pendingRequest { self.pendingRequest = nil; return .request(pendingRequest) }
    nearBottom = true; return .bottom
  }
}
