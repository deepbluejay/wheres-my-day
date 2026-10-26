import Core
import Foundation

/// Any caller thread. The lock owns flight/completion; callbacks run after unlocking, never under the lock.
public typealias ScreenTextFlights = ScreenCaptureFlights<String>
public final class ScreenCaptureFlights<Value> {
  private let lock = NSLock()
  private var flight = CaptureFlight()
  private var completion: ((SourceReading<Value>) -> Void)?
  public init() {}
  public func begin(at time: TimeInterval, completion next: @escaping (SourceReading<Value>) -> Void) -> Int? {
    lock.lock()
    let token = flight.begin(at: time)
    let displaced = token == nil ? nil : completion
    if token != nil { completion = next }
    lock.unlock()
    if token == nil { next(.absent(.busy)) }
    // Replacement is counted immediately even if the abandoned OS task never returns.
    displaced?(.absent(.superseded))
    return token
  }
  public func finish(_ token: Int, result: SourceReading<Value>) {
    lock.lock()
    let current = flight.finish(token)
    let delivered = current ? completion : nil
    if current { completion = nil }
    lock.unlock()
    // A replaced flight already delivered its loss; a late result must not deliver it twice.
    delivered?(result)
  }
}
