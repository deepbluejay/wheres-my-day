import Foundation

/// One lifetime receipt shared by discovery, readers and prepared publication.
public final class GitTaskCancellation {
  private let lock = NSRecursiveLock()
  private var stoppedAt: TimeInterval?
  public init() {}
  @discardableResult public func cancel() -> Bool {
    lock.lock(); defer { lock.unlock() }
    guard stoppedAt == nil else { return false }
    stoppedAt = ProcessInfo.processInfo.systemUptime
    return true
  }
  public var isCancelled: Bool {
    lock.lock(); defer { lock.unlock() }; return stoppedAt != nil
  }
  public func check() throws {
    if isCancelled { throw CancellationError() }
  }
  /// Serialize the small final transaction with stop, including SQLite COMMIT.
  public func certify<T>(_ body: () throws -> T) throws -> T {
    lock.lock(); defer { lock.unlock() }
    guard stoppedAt == nil else { throw CancellationError() }
    return try body()
  }
  /// A few already-written chunks can be erased at stop. Larger abandoned work
  /// remains uncertified and is retried at startup or the next scan.
  public func checkCleanup() throws {
    lock.lock(); let time = stoppedAt; lock.unlock()
    if let time, ProcessInfo.processInfo.systemUptime - time >= 0.1 { throw CancellationError() }
  }
}
