import ApplicationServices
import Carbon
import Core
import Foundation

private func inputCallback(
  proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
  refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
  if let refcon {
    Unmanaged<MacInputSource>.fromOpaque(refcon).takeUnretainedValue().receive(type: type, event: event)
  }
  return Unmanaged.passUnretained(event)
}

// Tap callbacks and input drains share lock; lifecycle starts on the main thread.
public final class MacInputSource: InputCountSource {
  private var tap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?
  private var runLoop: CFRunLoop?
  private let lock = NSLock()
  private var counts = InputCounts()
  public init() {}
  /// Start on the main thread. Only the later process switch calls this. Preflight never asks for permission.
  public func start() -> Bool {
    precondition(Thread.isMainThread)
    lock.lock()
    defer { lock.unlock() }
    guard tap == nil else { return true }
    guard CGPreflightListenEventAccess() else { return false }
    let events: [CGEventType] = [
      .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown,
      .scrollWheel, .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
    ]
    let mask = events.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
    guard
      let created = CGEvent.tapCreate(
        tap: .cgSessionEventTap, place: .headInsertEventTap,
        options: .listenOnly, eventsOfInterest: mask, callback: inputCallback,
        userInfo: Unmanaged.passUnretained(self).toOpaque())
    else { return false }
    tap = created
    runLoop = CFRunLoopGetCurrent()
    runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
    CFRunLoopAddSource(runLoop, runLoopSource, .commonModes)
    CGEvent.tapEnable(tap: created, enable: true)
    return true
  }
  public func stop() {
    lock.lock()
    defer { lock.unlock() }
    if let tap {
      CGEvent.tapEnable(tap: tap, enable: false)
      CFMachPortInvalidate(tap)
    }
    if let runLoopSource { CFRunLoopRemoveSource(runLoop, runLoopSource, .commonModes) }
    runLoopSource = nil
    tap = nil
    runLoop = nil
  }
  deinit { stop() }
  fileprivate func receive(type: CGEventType, event: CGEvent) {
    lock.lock()
    defer { lock.unlock() }
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
      return
    }
    let kind: InputEventKind
    switch type {
    case .keyDown: kind = .key
    case .leftMouseDown, .rightMouseDown, .otherMouseDown: kind = .click
    case .scrollWheel: kind = .scroll
    case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: kind = .move
    default: return
    }
    counts.observe(kind, programMade: event.getIntegerValueField(.eventSourceUnixProcessID) != 0)
  }
  public func takeInput() -> SourceReading<InputCounts> {
    lock.lock()
    defer { lock.unlock() }
    let value = counts
    counts = InputCounts()
    guard CGPreflightListenEventAccess() else { return .absent(.permission) }
    guard let tap else { return .absent(.unavailable) }
    if !CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: true) }
    guard CGEvent.tapIsEnabled(tap: tap) else { return .absent(.unavailable) }
    return .value(value)
  }
}

public struct MacSecureInputSource: SecureInputSource {
  public init() {}
  public func secureInput() -> SourceReading<Bool> { .value(IsSecureEventInputEnabled()) }
}
