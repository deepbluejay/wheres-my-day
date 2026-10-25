import AppKit
import Core
import Foundation
import Inbound
import IOKit

public enum RecorderSessionEvent { case sleep, wake, displaySleep, displayWake, lock, unlock }

public struct RecorderSessionSnapshot: Equatable {
  public var locked: Bool
  public var sleeping: Bool
  public var displaySleeping: Bool
  public init(locked: Bool = false, sleeping: Bool = false, displaySleeping: Bool = false) {
    self.locked = locked; self.sleeping = sleeping; self.displaySleeping = displaySleeping
  }
  var suspended: Bool { locked || sleeping || displaySleeping }
  mutating func receive(_ event: RecorderSessionEvent) {
    switch event {
    case .sleep: sleeping = true
    case .wake: sleeping = false
    case .displaySleep: displaySleeping = true
    case .displayWake: displaySleeping = false
    case .lock: locked = true
    case .unlock: locked = false
    }
  }
}

/// Main-thread host. Input counts come only from the source, never from lifecycle events.
public final class RecorderLifecycle {
  public let loop: RecorderLoop
  private let startInput: () -> Void
  private let stopInput: () -> Void
  private let requestSummary: (Int) -> Void
  private let clock: RecorderClock
  private let observeSession: (@escaping (RecorderSessionEvent) -> Void) -> AnyObject?
  private let initialSnapshot: () -> RecorderSessionSnapshot
  private var sessionObserver: AnyObject?
  private var session = RecorderSessionSnapshot()
  private var started = false
  private var stopping = false
  public init(loop: RecorderLoop, clock: RecorderClock, startInput: @escaping () -> Void,
    stopInput: @escaping () -> Void,
    observeSession: @escaping (@escaping (RecorderSessionEvent) -> Void) -> AnyObject? = { _ in nil },
    initialSnapshot: @escaping () -> RecorderSessionSnapshot = { RecorderSessionSnapshot() },
    requestSummary: @escaping (Int) -> Void) {
    self.loop = loop; self.clock = clock; self.startInput = startInput
    self.stopInput = stopInput; self.observeSession = observeSession
    self.initialSnapshot = initialSnapshot; self.requestSummary = requestSummary
  }
  public func start() {
    precondition(Thread.isMainThread)
    guard !started, !stopping else { return }
    sessionObserver = observeSession { [weak self] in self?.receive($0) }
    // Main-thread callbacks cannot interleave this snapshot with input/timer startup.
    session = initialSnapshot()
    started = true
    loop.setSuspended(session.suspended)
    if !session.suspended { startInput() }
    loop.start()
  }
  public func receive(_ event: RecorderSessionEvent) {
    precondition(Thread.isMainThread)
    // The startup snapshot supersedes every notification delivered before it.
    guard started, !stopping else { return }
    let wasSuspended = session.suspended
    session.receive(event)
    let suspended = session.suspended
    guard wasSuspended != suspended else { return }
    if suspended {
      stopInput(); loop.setSuspended(true)
      requestSummary(clock.now); loop.requestMaintenance()
    } else {
      loop.setSuspended(false); startInput()
    }
  }
  public func stop(completion: @escaping (RecorderHealth) -> Void) {
    precondition(Thread.isMainThread)
    guard !stopping else { return }
    stopping = true; stopInput(); loop.stop()
    loop.finishMaintenance { [self] in
      loop.stop()
      completion(loop.health)
    }
  }
}

/// Installed only in explicit recorder mode. No permission requests or activation.
public final class MacRecorderSessionObserver {
  private var workspaceTokens: [NSObjectProtocol] = []
  private var distributedTokens: [NSObjectProtocol] = []
  public init(receive: @escaping (RecorderSessionEvent) -> Void) {
    precondition(Thread.isMainThread)
    let center = NSWorkspace.shared.notificationCenter
    for (name, event) in [(NSWorkspace.willSleepNotification, RecorderSessionEvent.sleep),
      (NSWorkspace.didWakeNotification, .wake), (NSWorkspace.screensDidSleepNotification, .displaySleep),
      (NSWorkspace.screensDidWakeNotification, .displayWake)] {
      workspaceTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in receive(event) })
    }
    for (name, event) in [("com.apple.screenIsLocked", RecorderSessionEvent.lock), ("com.apple.screenIsUnlocked", .unlock)] {
      distributedTokens.append(DistributedNotificationCenter.default().addObserver(
        forName: NSNotification.Name(name), object: nil, queue: .main) { _ in receive(event) })
    }
  }
  public static func snapshot() -> RecorderSessionSnapshot {
    precondition(Thread.isMainThread)
    let session = CGSessionCopyCurrentDictionary() as? [String: Any]
    let domain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    var power: Int?
    if domain != 0 {
      defer { IOObjectRelease(domain) }
      let properties = IORegistryEntryCreateCFProperty(domain, "IOPowerManagement" as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue() as? [String: Any]
      power = (properties?["CurrentPowerState"] as? NSNumber)?.intValue
    }
    return snapshot(locked: session.map { $0["CGSSessionScreenIsLocked"] as? Bool ?? false },
      systemPowerState: power, displaySleeping: CGDisplayIsAsleep(CGMainDisplayID()) != 0)
  }
  // The root domain's ON_STATE is 4. Unknown state stays suspended until a wake notification.
  static func snapshot(locked: Bool?, systemPowerState: Int?, displaySleeping: Bool) -> RecorderSessionSnapshot {
    RecorderSessionSnapshot(locked: locked ?? true, sleeping: systemPowerState != 4, displaySleeping: displaySleeping)
  }
  deinit {
    workspaceTokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    distributedTokens.forEach { DistributedNotificationCenter.default().removeObserver($0) }
  }
}
