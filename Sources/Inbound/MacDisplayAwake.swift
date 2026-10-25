import AppKit
import Core
import Darwin
import Foundation
import IOKit.pwr_mgt

// lock owns the cache; the worker queue reads OS assertions off the main thread.
public final class MacDisplayAwakeSource: DisplayAwakeSource {
  private let queue = DispatchQueue(label: "ActivityProbe.Inbound.DisplayAssertions")
  private let lock = NSLock()
  private var owners = SourceReading<Set<Int32>>.absent(.unavailable)
  private var lastRefresh: TimeInterval?
  private var busy = false
  public init() {}
  public func keepingDisplayAwake(processID: Int32) -> SourceReading<Bool> {
    lock.lock()
    defer { lock.unlock() }
    let now = ProcessInfo.processInfo.systemUptime
    if !busy && (lastRefresh == nil || now - lastRefresh! >= Double(RecorderTiming.displayRefreshSeconds)) {
      busy = true
      lastRefresh = now
      queue.async {
        let answer = Self.readOwners()
        self.lock.lock()
        self.owners = answer
        self.busy = false
        self.lock.unlock()
      }
    }
    switch owners {
    case .value(let owners): return .value(owners.contains(processID))
    case .absent(let reason): return .absent(reason)
    }
  }
  private static func readOwners() -> SourceReading<Set<Int32>> {
    var raw: Unmanaged<CFDictionary>?
    let status = IOPMCopyAssertionsByProcess(&raw)
    let dictionary = raw?.takeRetainedValue() as? [NSNumber: [[String: Any]]] ?? [:]
    guard status == kIOReturnSuccess else { return .absent(.unavailable) }
    let assertions = dictionary.flatMap { pid, values in
      values.map { value in
        DisplayAssertion(
          pid: pid.int32Value, type: value[kIOPMAssertionTypeKey as String] as? String ?? "",
          enabled: (value[kIOPMAssertionLevelKey as String] as? NSNumber)?.intValue == Int(kIOPMAssertionLevelOn),
          onBehalfOf: (value["AssertionOnBehalfOfPID"] as? NSNumber)?.int32Value)
      }
    }
    let apps = NSWorkspace.shared.runningApplications.compactMap { app -> DisplayApp? in
      guard let path = app.bundleURL?.resolvingSymlinksInPath().path else { return nil }
      return DisplayApp(pid: app.processIdentifier, path: path)
    }
    let owners = assertions.compactMap { assertion -> Int32? in
      guard assertion.enabled,
        ["PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion"].contains(assertion.type)
      else { return nil }
      return DisplayAssertionPolicy.owner(of: assertion.onBehalfOf ?? assertion.pid, apps: apps, process: Self.process)
    }
    return .value(Set(owners))
  }
  private static func process(_ pid: Int32) -> DisplayProcess? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
    return DisplayProcess(
      parent: Int32(info.pbi_ppid),
      path: URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath().path)
  }
}
