import Core
import Foundation

/// Unverified native identities cannot expose output or approvals. Limits are chosen,
/// not measured; expiry uses monotonic time and never extends with more traffic.
struct ConversationProvisionalThreads {
  var timeout: TimeInterval = 5
  var threadLimit = 32
  var eventLimit = 256
  var byteLimit = 1024 * 1024
  private struct Event {
    let sequence: Int
    let value: [String: Any]
    let bytes: Int
  }
  private struct Pending {
    let deadline: TimeInterval
    var events: [Event] = []
    var bytes = 0
  }
  private var pending: [String: Pending] = [:]
  private var order: [String] = []
  private var rejected = Set<String>()
  private var bytes = 0
  private var count = 0
  private var sequence = 0

  var identities: [String] { order }
  func events(for thread: String) -> [[String: Any]] { pending[thread]?.events.map(\.value) ?? [] }

  func isRejected(_ thread: String) -> Bool { rejected.contains(thread) }

  func thread(containing predicate: ([String: Any]) -> Bool) -> String? {
    order.first { pending[$0]!.events.contains { predicate($0.value) } }
  }

  mutating func hold(_ object: [String: Any], thread: String,
    now: TimeInterval = ProcessInfo.processInfo.systemUptime) throws -> Bool {
    guard !thread.isEmpty else { throw ConversationError.incompatible }
    if rejected.contains(thread) { return false }
    let size = try ConversationEncoding.json(object).count
    guard count < eventLimit, size <= byteLimit - bytes,
      pending[thread] != nil || pending.count < threadLimit else { throw ConversationError.outputLimit }
    if pending[thread] == nil {
      pending[thread] = Pending(deadline: now + timeout); order.append(thread)
    }
    sequence += 1
    pending[thread]!.events.append(Event(sequence: sequence, value: object, bytes: size)); pending[thread]!.bytes += size
    bytes += size; count += 1
    return true
  }

  func firstReady(verified: Set<String>, parent: ([String: Any]) -> String? = { value in
    guard value["method"] as? String == "thread/started" else { return nil }
    return ((value["params"] as? [String: Any])?["thread"] as? [String: Any])?["parentThreadId"] as? String
  }) -> String? {
    order.first { id in
      verified.contains(id) || pending[id]!.events.contains { value in
        parent(value.value).map { verified.contains($0) } ?? false
      }
    }
  }

  mutating func take(_ thread: String) -> [[String: Any]] {
    guard let value = pending.removeValue(forKey: thread) else { return [] }
    order.removeAll { $0 == thread }; bytes -= value.bytes; count -= value.events.count
    return value.events.map(\.value)
  }

  // Different native aliases may later prove to be one thread. Keep their
  // original order when the ancestry join makes several queues readable.
  mutating func takeFirst(verified: Set<String>) -> (String, [String: Any])? {
    guard let id = order.filter({ verified.contains($0) }).min(by: {
      pending[$0]!.events[0].sequence < pending[$1]!.events[0].sequence
    }) else { return nil }
    let event = pending[id]!.events.removeFirst()
    pending[id]!.bytes -= event.bytes; bytes -= event.bytes; count -= 1
    if pending[id]!.events.isEmpty { pending.removeValue(forKey: id); order.removeAll { $0 == id } }
    return (id, event.value)
  }

  mutating func expire(now: TimeInterval) throws -> [[String: Any]] {
    var result: [[String: Any]] = []
    for id in order where pending[id]!.deadline <= now {
      result += take(id); try reject(id)
    }
    return result
  }

  mutating func discardAll() throws -> [[String: Any]] {
    var result: [[String: Any]] = []
    for id in order { result += take(id); try reject(id) }
    return result
  }

  private mutating func reject(_ id: String) throws {
    guard rejected.count < 128 else { throw ConversationError.outputLimit }
    rejected.insert(id)
  }
}
