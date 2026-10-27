import Core
import Darwin
import Foundation

final class ConversationCancellation {
  private let lock = NSLock()
  private var value = false
  func cancel() { lock.lock(); value = true; lock.unlock() }
  var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// Owns a process group from spawn until reap. No shell, inherited descriptors or stderr text.
enum ConversationProcess {
  static let lineLimit = LinePipe.defaultLineLimit
  static func exchange(executable: URL, arguments: [String], environment: [String: String], cwd: URL,
    timeout: TimeInterval, cancellation: ConversationCancellation, cleanupLease: URL? = nil, cleanupHome: CodexProcessHome? = nil,
    requireSuccessfulExit: Bool = false, exitErrors: [Int32: ConversationError] = [:], inputLineLimit: Int = LinePipe.defaultLineLimit, service: (((Data) throws -> Void) throws -> Void)? = nil, isReady: (() -> Bool)? = nil, initial: [Data] = [],
    receive: (Data, (Data) throws -> Void) throws -> Bool) throws {
    guard executable.path.hasPrefix("/"), !cancellation.cancelled else { throw ConversationError.cancelled }
    let input = Pipe(), output = Pipe()
    var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
    guard posix_spawn_file_actions_init(&actions) == 0, posix_spawnattr_init(&attributes) == 0 else {
      throw ConversationError.unavailable
    }
    defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
    var setup: [Int32] = [
      posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)),
      posix_spawnattr_setpgroup(&attributes, 0),
      posix_spawn_file_actions_adddup2(&actions, input.fileHandleForReading.fileDescriptor, STDIN_FILENO),
      posix_spawn_file_actions_adddup2(&actions, output.fileHandleForWriting.fileDescriptor, STDOUT_FILENO),
      posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0),
    ]
    if let cleanupHome {
      setup.append(posix_spawn_file_actions_adddup2(&actions, cleanupHome.lockHandle.fileDescriptor, 198))
    }
    if #available(macOS 26.0, *) { setup.append(posix_spawn_file_actions_addchdir(&actions, cwd.path)) }
    else { setup.append(posix_spawn_file_actions_addchdir_np(&actions, cwd.path)) }
    guard setup.allSatisfy({ $0 == 0 }) else { throw ConversationError.unavailable }
    let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
    let envp = environment.sorted { $0.key < $1.key }.map { strdup($0.key + "=" + $0.value) } + [nil]
    defer { for pointer in argv + envp { if let pointer { free(pointer) } } }
    var pid: pid_t = 0
    let status = argv.withUnsafeBufferPointer { args in envp.withUnsafeBufferPointer { vars in
      posix_spawn(&pid, executable.path, &actions, &attributes,
        UnsafeMutablePointer(mutating: args.baseAddress!), UnsafeMutablePointer(mutating: vars.baseAddress!))
    } }
    guard status == 0 else { throw ConversationError.unavailable }
    var lifetime: ConversationLifetime?
    defer {
      // Keep the group leader unreaped until after teardown, so its PID cannot be reused.
      lifetime?.stop()
      kill(-pid, SIGKILL)
      var status: Int32 = 0
      while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
      try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close()
    }
    lifetime = try ConversationLifetime(group: pid, lease: cleanupLease, home: cleanupHome)
    try? input.fileHandleForReading.close(); try? output.fileHandleForWriting.close()
    let pipe = try LinePipe(input: output.fileHandleForReading, output: input.fileHandleForWriting, outgoingLimit: inputLineLimit)
    let started = ProcessInfo.processInfo.systemUptime
    let deadline = started + timeout
    do {
      for bytes in initial { try pipe.send(bytes) }
      while let line = try pipe.readLine(deadline: isReady?() == false ? min(deadline, started + 60) : deadline,
        cancelled: { cancellation.cancelled }, service: { try service?(pipe.send) }) {
        if try receive(line, pipe.send) { return }
      }
    } catch let error as LinePipeError {
      switch error {
      case .cancelled: throw ConversationError.cancelled
      case .timeout: throw ConversationError.timeout
      case .lineLimit, .outputLimit: throw ConversationError.outputLimit
      case .incompleteLine: throw ConversationError.incompatible
      case .io: throw ConversationError.unavailable
      }
    }
    if requireSuccessfulExit {
      while true {
        guard !cancellation.cancelled else { throw ConversationError.cancelled }
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw ConversationError.timeout }
        var info = siginfo_t()
        guard waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 else {
          throw ConversationError.unavailable
        }
        if info.si_pid == pid {
          guard info.si_code == CLD_EXITED, info.si_status == 0 else {
            throw info.si_code == CLD_EXITED ? exitErrors[info.si_status] ?? ConversationError.unavailable : ConversationError.unavailable
          }
          break
        }
        usleep(10_000)
      }
    } else { _ = try receive(Data(), pipe.send) }
  }

  /// `exitErrors` names what a documented nonzero exit means, such as a status check's "not logged in".
  static func metadata(executable: URL, arguments: [String], environment: [String: String], cwd: URL,
    cancellation: ConversationCancellation = ConversationCancellation(), exitErrors: [Int32: ConversationError] = [:]) throws -> String {
    var result = Data()
    try exchange(executable: executable, arguments: arguments, environment: environment, cwd: cwd, timeout: 8,
      cancellation: cancellation, requireSuccessfulExit: true, exitErrors: exitErrors) { line, _ in
      guard result.count + line.count < lineLimit else { throw ConversationError.outputLimit }
      result.append(line); result.append(10); return false
    }
    return String(decoding: result, as: UTF8.self)
  }
}

/// EOF from the host also tears down the group after an abrupt host exit. Arguments are
/// literal host-owned paths; the fixed non-login script never receives conversation text.
private final class ConversationLifetime {
  let input = Pipe()
  let watcher = Process()
  private var stopped = false
  init(group: pid_t, lease: URL?, home: CodexProcessHome?) throws {
    _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETFD, FD_CLOEXEC)
    watcher.executableURL = URL(fileURLWithPath: "/bin/sh")
    watcher.arguments = ["-c", "IFS= read -r ap_watch; /bin/kill -KILL -- \"-$1\" 2>/dev/null; if [ -n \"$2\" ]; then /bin/rm -f -- \"$2\"; /bin/rmdir -- \"$3\" 2>/dev/null; fi; if [ -n \"$4\" ]; then /bin/rm -rf -- \"$4\" 2>/dev/null; fi",
      "activityprobe-query-lifetime", String(group), lease?.path ?? "", lease?.deletingLastPathComponent().path ?? "", home?.url.path ?? ""]
    watcher.environment = ["PATH": "/usr/bin:/bin"]
    watcher.standardInput = input; watcher.standardOutput = FileHandle.nullDevice; watcher.standardError = home?.lockHandle ?? FileHandle.nullDevice
    do { try watcher.run() } catch { throw ConversationError.unavailable }
    try? input.fileHandleForReading.close()
  }
  func stop() {
    guard !stopped else { return }; stopped = true
    try? input.fileHandleForWriting.close()
    var status: Int32 = 0
    while waitpid(watcher.processIdentifier, &status, 0) < 0 && errno == EINTR {}
  }
  deinit { stop() }
}
