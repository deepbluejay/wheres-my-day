import Core
import Darwin
import Foundation
import Storage

public enum RecorderLaunchAgent {
  public static let label = "dev.local.ActivityProbe.recorder"
  /// launchd sends SIGKILL this many seconds after SIGTERM. The recorder's stop first drains maintenance,
  /// and RecorderControl.stop gives that same drain 60 s, so launchd allows it no less.
  public static let exitTimeOut = 60
  /// SuccessfulExit=false restarts a crash, while a settings-driven clean stop stays stopped.
  public static func propertyList(executable: URL) throws -> Data {
    guard executable.path.hasPrefix("/"), !executable.path.contains("\n") else { throw AppCommandError.arguments }
    let value: [String: Any] = [
      "Label": label, "ProgramArguments": [executable.path, "collect"],
      "RunAtLoad": true, "KeepAlive": ["SuccessfulExit": false],
      "ThrottleInterval": 30, "ExitTimeOut": exitTimeOut, "LimitLoadToSessionType": "Aqua", "ProcessType": "Interactive",
      "EnvironmentVariables": ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"]
    ]
    return try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
  }
}

public struct LaunchAgentServiceResult {
  public let status: Int32
  public let error: String
  public init(_ status: Int32, error: String = "") { self.status = status; self.error = error }
}

public enum LaunchAgentCommand {
  public static let help = "Usage: launch-agent print <absolute-executable> | install <absolute-executable> --live-switch | uninstall --live-switch"
  /// How long install waits for a booted-out job to leave and for bootstrap to succeed.
  /// It outlasts the old job's kill deadline, with a margin for bootstrap retries once it is gone.
  static let settleBound = TimeInterval(RecorderLaunchAgent.exitTimeOut) + 10
  static let pollInterval: TimeInterval = 0.25
  public static func run(_ arguments: [String], userHome: URL,
    service: ([String]) throws -> LaunchAgentServiceResult = runServiceResult,
    clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    pause: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) -> AppCommandResult {
    if arguments == ["--help"] { return AppCommandResult(0, help) }
    do {
      if arguments.count == 2, arguments[0] == "print" {
        guard arguments[1].hasPrefix("/") else { throw AppCommandError.arguments }
        return AppCommandResult(0, String(decoding: try RecorderLaunchAgent.propertyList(executable: URL(fileURLWithPath: arguments[1])), as: UTF8.self))
      }
      guard ["install", "uninstall"].contains(arguments.first ?? "") else { throw AppCommandError.arguments }
      // This check precedes all filesystem and service-manager access.
      guard arguments.last == "--live-switch" else { return AppCommandResult(2, "live_switch_required") }
      let install = arguments[0] == "install"
      guard install ? arguments.count == 3 && arguments[1].hasPrefix("/") : arguments.count == 2 else { throw AppCommandError.arguments }
      let data = install ? try RecorderLaunchAgent.propertyList(executable: URL(fileURLWithPath: arguments[1])) : nil
      precondition(TestPathGuard.permits(userHome.appendingPathComponent("Library/Application Support/ActivityProbe")),
        "Tests must never install real LaunchAgents")
      let folder = userHome.appendingPathComponent("Library/LaunchAgents")
      if install { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
      let directory = FileManager.default.fileExists(atPath: folder.path) ? try OperationalDirectory(folder) : nil
      let leaf = RecorderLaunchAgent.label + ".plist"
      try directory?.validate(leaf)
      let file = folder.appendingPathComponent(leaf)
      let domain = "gui/\(getuid())", target = domain + "/" + RecorderLaunchAgent.label
      // A loaded label and its plist can outlive each other. Reconcile the job first.
      var absent = false
      if try service(["bootout", target]).status != 0 {
        let result = try service(["print", target])
        guard result.status != 0, provesAbsent(result.error) else { throw AppCommandError.recorder }
        absent = true
      }
      let deadline = clock() + settleBound
      func unlinkOld() throws {
        if let directory, try directory.exists(leaf) {
          guard unlinkat(directory.descriptor, leaf, 0) == 0 else { throw AppCommandError.recorder }
        }
      }
      guard let data else { try unlinkOld(); return AppCommandResult(0, "launch_agent_uninstalled") }
      // The old job is booted out or proven absent and nothing will bootstrap it, so a failed write says so.
      do {
        try unlinkOld()
        guard let directory else { throw AppCommandError.recorder }
        let fd = try directory.open(leaf, flags: O_WRONLY | O_CREAT | O_EXCL)!
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do { try handle.write(contentsOf: data); try handle.close() } catch {
          try? handle.close(); unlinkat(directory.descriptor, leaf, 0); throw error
        }
      } catch { return AppCommandResult(1, "launch_agent_refused job_not_loaded") }
      func provenAbsent() -> Bool {
        guard let result = try? service(["print", target]) else { return false }
        return result.status != 0 && provesAbsent(result.error)
      }
      // bootout returns before the old job has exited, and bootstrap fails while it is torn down.
      while true {
        if !absent { absent = provenAbsent() }
        if absent {
          if (try? service(["bootstrap", domain, file.path]))?.status == 0 { return AppCommandResult(0, "launch_agent_installed") }
          absent = false
        }
        guard clock() < deadline else { break }
        pause(pollInterval)
      }
      // The new plist stays so the next login loads it; the line says whether the job is proven unloaded.
      return AppCommandResult(1, "launch_agent_refused " + (provenAbsent() ? "job_not_loaded" : "job_state_unknown") + " plist_kept")
    } catch { return AppCommandResult(1, "launch_agent_refused") }
  }
  /// launchctl print may put "Bad request." before the not-found sentence; any other line refuses.
  static func provesAbsent(_ error: String) -> Bool {
    let absent = "Could not find service \"\(RecorderLaunchAgent.label)\" in domain for user gui: \(getuid())"
    let lines = error.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    return lines.filter { $0 == absent }.count == 1 && lines.count <= 2 && lines.allSatisfy { $0 == absent || $0 == "Bad request." }
  }
  public static func runService(_ arguments: [String]) throws -> Int32 {
    try runServiceResult(arguments).status
  }
  public static func runServiceResult(_ arguments: [String]) throws -> LaunchAgentServiceResult {
    let child = Process(); child.executableURL = URL(fileURLWithPath: "/bin/launchctl"); child.arguments = arguments
    let errors = Pipe()
    child.standardOutput = FileHandle.nullDevice; child.standardError = errors
    try child.run()
    let error = errors.fileHandleForReading.readDataToEndOfFile()
    child.waitUntilExit()
    return LaunchAgentServiceResult(child.terminationStatus, error: String(decoding: error, as: UTF8.self))
  }
}
