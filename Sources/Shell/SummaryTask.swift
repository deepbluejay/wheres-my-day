import Core
import Foundation
import Storage

extension ActivityStorage: SummaryStorage {}

/// Only the maintenance queue runs the service. Health has a separate, short-lived lock.
public final class SummaryTask {
  private let service: SummaryService
  private let start: Int
  private let dayStart: (Int) -> Int
  private let locale: () -> String
  private let publish: (TimeInterval?) throws -> Void
  private let lock = NSLock()
  private var status = SummaryHealth()
  private var pendingRequest: Int?
  public init(storage: SummaryStorage, caller: SummaryCaller, from start: Int,
    dayStart: @escaping (Int) -> Int, locale: @escaping () -> String,
    publish: @escaping (TimeInterval?) throws -> Void = { _ in }) {
    service = SummaryService(storage: storage, caller: caller)
    self.start = start; self.dayStart = dayStart; self.locale = locale; self.publish = publish
  }
  public var health: SummaryHealth {
    lock.lock(); defer { lock.unlock() }; return status
  }
  /// A screen enqueues the request; the next background pass performs it.
  public func request(through time: Int) {
    lock.lock(); pendingRequest = max(pendingRequest ?? time, time); lock.unlock()
  }
  public var maintenanceTask: RecorderMaintenanceTask {
    RecorderMaintenanceTask(name: "summary") { time in
      self.lock.lock(); let request = self.pendingRequest; self.pendingRequest = nil; self.lock.unlock()
      defer { self.lock.lock(); self.status = self.service.health; self.lock.unlock() }
      do { try self.service.summarize(from: self.start, through: min(request ?? time, time),
        dayStart: self.dayStart(time), locale: self.locale(), requested: request != nil, at: time)
      } catch {
        try self.publish(self.service.health.serviceUnavailableUntil)
        throw error
      }
      try self.publish(self.service.health.serviceUnavailableUntil)
    }
  }
}
