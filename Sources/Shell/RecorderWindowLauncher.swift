import Core
import Darwin
import Foundation
import Outbound

public enum RecorderWindowLauncher {
  public static func arguments(target: AppWindowTarget?) -> [String] {
    switch target {
    case nil: return ["menu-bar"]
    case .timeline: return ["timeline"]
    case .conversation: return ["agent-window"]
    case .settings(let section): return ["settings", section.rawValue]
    }
  }
  /// Summaries no longer run a CLI, so a recorder needs no agent lookup: an isolated one is told only its folders.
  static func recorderLaunch(paths: AppPaths, isolated: Bool) throws -> [String] {
    guard isolated else { return ["collect"] }
    guard case .directory(let root, _) = paths.databaseScope else { throw AppCommandError.arguments }
    return ["collect", "--isolated-root", root.path, "--app-data", paths.appData.path]
  }
  /// The menu snapshot calls this on the main thread; it starts the recorder without waiting for it.
  static func resumeRecorder(paths: AppPaths, isolated: Bool, environment: [String: String],
    service: ([String]) throws -> Int32 = LaunchAgentCommand.runService,
    start: ((_ arguments: [String], _ environment: [String: String]) throws -> Void)? = nil) throws {
    // A stopped login job remains registered. Wake it so launchd still supervises later crashes.
    let defaultDatabase = paths.appData.appendingPathComponent("activity.sqlite")
    if !isolated, (try? FileLocation.same(paths.database, defaultDatabase)) == true,
      (try? service(["kickstart", "gui/\(getuid())/" + RecorderLaunchAgent.label])) == 0 { return }
    let begin = { (arguments: [String], values: [String: String]) throws in
      if let start { try start(arguments, values) } else { try launch(paths: paths, arguments: arguments, environment: values) }
    }
    try begin(try recorderLaunch(paths: paths, isolated: isolated), environment)
  }
  /// A nil target starts only the menu host. Explicit targets reuse the existing window channel.
  public static func launch(paths: AppPaths, target: AppWindowTarget?, environment: [String: String]) throws {
    try launch(paths: paths, arguments: arguments(target: target), environment: environment)
  }
  static func launch(paths: AppPaths, arguments: [String], environment: [String: String]) throws {
    // A separate group survives launchd cleaning up the recorder's group on clean stop.
    // It also avoids inheriting the recorder's ignored stop signals or open descriptors.
    var attributes: posix_spawnattr_t?, actions: posix_spawn_file_actions_t?
    guard posix_spawnattr_init(&attributes) == 0 else { throw AppCommandError.recorder }
    defer { posix_spawnattr_destroy(&attributes) }
    guard posix_spawn_file_actions_init(&actions) == 0 else { throw AppCommandError.recorder }
    defer { posix_spawn_file_actions_destroy(&actions) }
    var defaults = sigset_t(); sigemptyset(&defaults); sigaddset(&defaults, SIGTERM); sigaddset(&defaults, SIGINT)
    guard posix_spawnattr_setpgroup(&attributes, 0) == 0,
      posix_spawnattr_setsigdefault(&attributes, &defaults) == 0,
      posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0 else { throw AppCommandError.recorder }
    for descriptor: Int32 in [0, 1, 2] {
      guard posix_spawn_file_actions_addopen(&actions, descriptor, "/dev/null", descriptor == 0 ? O_RDONLY : O_WRONLY, 0) == 0 else { throw AppCommandError.recorder }
    }
    var values = environment; values["ACTIVITYPROBE_DB"] = paths.database.path
    var argv = ([paths.appBinary.path] + arguments).map { strdup($0) } + [nil]
    var envp = values.map { strdup($0.key + "=" + $0.value) } + [nil]
    defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
    var pid: pid_t = 0
    let result = paths.appBinary.path.withCString { executable in
      argv.withUnsafeMutableBufferPointer { arguments in
        envp.withUnsafeMutableBufferPointer { environment in
          posix_spawn(&pid, executable, &actions, &attributes, arguments.baseAddress!, environment.baseAddress!)
        }
      }
    }
    guard result == 0 else { throw AppCommandError.recorder }
    let childPID = pid
    let reaper = DispatchSource.makeProcessSource(identifier: childPID, eventMask: .exit, queue: .global(qos: .utility))
    reaper.setEventHandler {
      var status: Int32 = 0
      while waitpid(childPID, &status, 0) < 0 && errno == EINTR {}
      reaper.cancel(); reaper.setEventHandler(handler: nil)
    }
    reaper.resume()
  }
}
