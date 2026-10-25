import Foundation

/// Explicit maintenance entry, separate from connection, recorder and settings startup.
public enum AgentCleanupCommand {
  public static func run(_ arguments: [String]) -> Int32 {
    guard let script = Bundle.module.url(forResource: "agent_cleanup", withExtension: "py", subdirectory: "AgentCleanup") else {
      print("cleanup_resource_missing")
      return 2
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    // Python's isolated mode disables user imports and startup customizations. No agent runs.
    process.arguments = ["python3", "-I", script.path] + arguments
    process.environment = ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"]
    do {
      try process.run()
      process.waitUntilExit()
      return process.terminationReason == .exit ? process.terminationStatus : 2
    } catch {
      print("cleanup_python_unavailable")
      return 2
    }
  }
}
