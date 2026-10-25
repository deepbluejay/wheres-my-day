import Foundation

public enum AXProbeResources {
  // Operational memory limits, independent of role, visibility or application.
  public static let stringUTF16 = 4 * 1024 * 1024
  public static let rangeUTF16 = 16 * 1024
  public static let chunkBytes = 64 * 1024
  public static let attemptBytes = 64 * 1024 * 1024
  public static let queueBytes = 128 * 1024 * 1024
  public static func bytes(_ pair: AXProbePair) -> Int {
    var bytes = pair.ocr.utf8.count + pair.ax.text.utf8.count + 4096
    for node in pair.ax.nodes ?? [] {
      bytes += 1024 + (node.role?.utf8.count ?? 0) + (node.subrole?.utf8.count ?? 0) + (node.bundleID?.utf8.count ?? 0)
      for attribute in node.attributes { bytes += attribute.text.utf8.count + attribute.attribute.utf8.count + 128 }
    }
    return bytes
  }
}

public struct AXProbeReceipt {
  public let runID: String
  public let attemptID: String
  public let time: Int
  public init(_ pair: AXProbePair) { runID = pair.runID; attemptID = pair.attemptID; time = pair.time }
}

/// Owns raw payloads from delivery through persistence. Main-thread callers exchange receipts only.
/// Reservations include the currently executing job and waiting-for-OCR jobs, not just queued jobs.
public final class AXProbePipeline {
  private struct Job { var pair: AXProbePair; let bytes: Int; let gate: () -> Bool }
  private let lock = NSLock()
  private let queue = DispatchQueue(label: "ActivityProbe.AXProbe.Payload", qos: .utility)
  private var jobs: [String: Job] = [:]
  private var reserved = 0
  private let capacity: Int
  private let write: (AXProbePair, Int?, Int, @escaping () -> Bool) throws -> Void
  private let dropped: (AXProbeReceipt) -> Void
  private let failed: (AXProbeReceipt) -> Void
  public init(capacity: Int = AXProbeResources.queueBytes,
    write: @escaping (AXProbePair, Int?, Int, @escaping () -> Bool) throws -> Void,
    dropped: @escaping (AXProbeReceipt) -> Void,
    failed: @escaping (AXProbeReceipt) -> Void = { _ in }) {
    self.capacity = capacity; self.write = write; self.dropped = dropped; self.failed = failed
  }
  public var reservedBytes: Int { lock.lock(); defer { lock.unlock() }; return reserved }
  public func offer(_ pair: AXProbePair, permitted: @escaping () -> Bool) -> AXProbeReceipt? {
    let bytes = AXProbeResources.bytes(pair), receipt = AXProbeReceipt(pair)
    lock.lock()
    guard bytes <= AXProbeResources.attemptBytes, bytes <= capacity - reserved,
      pair.ax.status != .overload_dropped, pair.ax.counts["overload_dropped"] != 1 else {
      lock.unlock(); queue.async { self.dropped(receipt) }; return nil
    }
    guard jobs[receipt.attemptID] == nil else { lock.unlock(); return nil }
    reserved += bytes; jobs[receipt.attemptID] = Job(pair: pair, bytes: bytes, gate: permitted)
    lock.unlock(); return receipt
  }
  public func refuseOCR(_ receipt: AXProbeReceipt, reason: AXProbeOCRRefusal) {
    lock.lock(); defer { lock.unlock() }
    guard var job = jobs[receipt.attemptID], job.pair.ocr_refusal_reason == nil else { return }
    job.pair.ocr_refusal_reason = reason; job.pair.ocrStatus = "policy_refused"; job.pair.ocr = ""
    jobs[receipt.attemptID] = job
  }
  public func discard(_ receipt: AXProbeReceipt) {
    lock.lock(); let job = jobs.removeValue(forKey: receipt.attemptID)
    reserved -= job?.bytes ?? 0; lock.unlock()
  }
  public func discardWaiting() {
    lock.lock(); reserved -= jobs.values.reduce(0) { $0 + $1.bytes }; jobs.removeAll(); lock.unlock()
  }
  public func commit(_ receipt: AXProbeReceipt, evidenceID: Int?, at now: Int) {
    lock.lock(); let job = jobs.removeValue(forKey: receipt.attemptID); lock.unlock()
    guard let job else { return }
    queue.async {
      defer { self.lock.lock(); self.reserved -= job.bytes; self.lock.unlock() }
      do { try self.write(job.pair, evidenceID, now, job.gate) }
      catch { self.failed(receipt) }
    }
  }
  public func drain(_ completion: @escaping () -> Void) { queue.async(execute: completion) }
}
