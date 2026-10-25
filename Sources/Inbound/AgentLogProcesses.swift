import Core
import Darwin
import Foundation

public struct AgentLogProcess {
  public let pid: Int32
  public let tool: AgentLogTool
  public init(pid: Int32, tool: AgentLogTool) {
    self.pid = pid
    self.tool = tool
  }
}
public protocol AgentLogProcessSource {
  func processes() throws -> [AgentLogProcess]
  /// Return only this variable's value. A failed/ended process must never return its environment.
  func homeVariable(_ name: String, processID: Int32) throws -> String?
}

/// Byte-level extraction avoids converting secret-shaped neighbours into strings or dictionaries.
public enum NamedProcessVariable {
  public static func value(_ name: String, in block: UnsafeRawBufferPointer) -> String? {
    guard !name.isEmpty, !name.contains("="), !name.utf8.contains(0) else { return nil }
    let prefix = Array((name + "=").utf8)
    var start = 0
    while start < block.count {
      var end = start
      while end < block.count, block[end] != 0 { end += 1 }
      if end - start >= prefix.count,
        prefix.indices.allSatisfy({ block[start + $0] == prefix[$0] })
      {
        return String(bytes: block[(start + prefix.count)..<end], encoding: .utf8)
      }
      start = end + 1
    }
    return nil
  }
  /// KERN_PROCARGS2: argc, executable, padding, argc arguments, then NUL-separated environment entries.
  public static func value(_ name: String, inProcessArguments block: UnsafeRawBufferPointer) -> String? {
    guard block.count >= MemoryLayout<Int32>.size else { return nil }
    let argc = block.loadUnaligned(as: Int32.self)
    guard argc >= 0, argc < block.count else { return nil }
    var index = MemoryLayout<Int32>.size
    while index < block.count, block[index] != 0 { index += 1 }
    while index < block.count, block[index] == 0 { index += 1 }
    for _ in 0..<argc {
      while index < block.count, block[index] != 0 { index += 1 }
      guard index < block.count else { return nil }
      index += 1
    }
    return value(name, in: UnsafeRawBufferPointer(rebasing: block[index...]))
  }
}

/// Called only on the shell's background queue at the later switch. No process arguments are retained.
public struct MacAgentLogProcessSource: AgentLogProcessSource {
  public init() {}
  public func processes() throws -> [AgentLogProcess] {
    let capacity = proc_listallpids(nil, 0)
    guard capacity > 0 else { throw AgentLogReadError.processUnavailable }
    var pids = [Int32](repeating: 0, count: Int(capacity) + 64)
    let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
    guard count >= 0 else { throw AgentLogReadError.processUnavailable }
    return pids.prefix(Int(count)).compactMap { pid in
      var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
      guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
      let executable = URL(fileURLWithPath: String(cString: path)).lastPathComponent
      guard let tool = AgentLogTool(rawValue: executable) else { return nil }
      return AgentLogProcess(pid: pid, tool: tool)
    }
  }
  public func homeVariable(_ name: String, processID: Int32) throws -> String? {
    var limit: Int32 = 0
    var limitSize = MemoryLayout<Int32>.size
    var limitMIB = [CTL_KERN, KERN_ARGMAX]
    guard sysctl(&limitMIB, 2, &limit, &limitSize, nil, 0) == 0, limit > 0 else {
      throw AgentLogReadError.processUnavailable
    }
    // The OS returns a block, not individual variables. Inspect names as bytes, decode only the requested value,
    // and wipe the temporary kernel buffer before release. No argument/environment object escapes this function.
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(limit), alignment: 4)
    buffer.initializeMemory(as: UInt8.self, repeating: 0, count: Int(limit))
    defer {
      memset_s(buffer, Int(limit), 0, Int(limit))
      buffer.deallocate()
    }
    var size = Int(limit)
    var mib = [CTL_KERN, KERN_PROCARGS2, processID]
    guard sysctl(&mib, 3, buffer, &size, nil, 0) == 0 else { throw AgentLogReadError.processUnavailable }
    return NamedProcessVariable.value(name, inProcessArguments: UnsafeRawBufferPointer(start: buffer, count: size))
  }
}
