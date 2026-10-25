import Foundation

public enum RestPolicy {
  public static let inputAgeSeconds = 300

  public static func recordsSecond(at now: Int, lastInput: Int?, keepingAwake: Bool) -> Bool {
    keepingAwake || lastInput.map { now >= $0 && now - $0 <= inputAgeSeconds } == true
  }
}

/// A stale completion must not release the replacement request's slot.
public struct CaptureFlight {
  private var startedAt: TimeInterval?
  private var token = 0
  public init() {}
  public mutating func begin(at now: TimeInterval) -> Int? {
    if let startedAt, now - startedAt <= Double(RecorderTiming.captureTimeoutSeconds) { return nil }
    token += 1
    startedAt = now
    return token
  }
  public mutating func finish(_ request: Int) -> Bool {
    guard request == token else { return false }
    startedAt = nil
    return true
  }
}
