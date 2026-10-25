import Core
import Darwin
import Foundation

/// The search path the person's own terminal has.
///
/// A process started at login or from Finder gets the system's bare search path. What the person
/// installed for themselves (a Node version manager, Homebrew, a native installer) is on the path
/// their shell builds in files it reads only when it is a login, interactive shell. So that shell
/// is asked once per process, started the way a terminal starts it.
///
/// The same shell also says where the person keeps Claude Code's settings and login, when they
/// moved it with CLAUDE_CONFIG_DIR, so the app's Claude children find the login the terminal finds.
public enum UserShell {
  static let marker = "__ACTIVITYPROBE_PATH__="
  static let claudeMarker = "__ACTIVITYPROBE_CLAUDE_CONFIG_DIR__="
  static let outputLimit = 1_048_576
  struct Answer: Equatable {
    var path: String?
    var claudeConfigDirectory: String?
    /// The shell exported a relative one, which names another folder for each working folder.
    var claudeConfigRelative = false
  }
  /// Test seams: an invented shell, its limit, or the answers themselves. Under a test runner the
  /// person's real shell is never asked.
  static var shellOverride: String?
  static var limit: TimeInterval = 8
  static var answer: (() -> String?)?
  static var claudeAnswer: (() -> String?)?
  static var claudeKnown: (() -> Bool)?
  private static let lock = NSLock()
  private static var asked = false
  private static var found: Answer?

  /// nil when the shell did not answer (it did not start, printed no marker, or took too long);
  /// the caller then goes on with the path it has. A caller that arrives while the shell is being
  /// asked waits for that one answer instead of asking again.
  public static func path(environment: [String: String]) -> String? {
    lock.lock(); defer { lock.unlock() }
    if let answer { return answer() }
    return shellAnswer(environment: environment)?.path
  }

  /// The CLAUDE_CONFIG_DIR the person's login shell sets, or nil when it sets none, sets a relative
  /// one, or did not answer. Nothing else in this process's environment is consulted.
  public static func claudeConfigDirectory(environment: [String: String]) -> String? {
    lock.lock(); defer { lock.unlock() }
    if answer != nil || claudeAnswer != nil { return claudeAnswer?() }
    return shellAnswer(environment: environment)?.claudeConfigDirectory
  }

  /// False when the app cannot know which Claude folder the terminal uses: the shell did not answer,
  /// or it exported a relative CLAUDE_CONFIG_DIR. The app's children then use the default folder.
  public static func claudeConfigKnown(environment: [String: String]) -> Bool {
    lock.lock(); defer { lock.unlock() }
    if answer != nil || claudeAnswer != nil || claudeKnown != nil { return claudeKnown?() ?? true }
    guard let found = shellAnswer(environment: environment) else { return false }
    return !found.claudeConfigRelative
  }

  /// Called with the lock held.
  private static func shellAnswer(environment: [String: String]) -> Answer? {
    if !asked {
      let shell = shellOverride ?? (TestPathGuard.active ? nil : loginShell())
      found = shell.flatMap { lookup(shell: $0, environment: environment, limit: limit) }
      asked = true
    }
    return found
  }

  /// The next call asks again. Only tests use it.
  static func forget() { lock.lock(); asked = false; found = nil; lock.unlock() }

  static func loginShell() -> String {
    guard let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell else { return "/bin/zsh" }
    let path = String(cString: shell)
    return path.hasPrefix("/") ? path : "/bin/zsh"
  }

  /// Start-up files print things of their own, so the line is told by its marker and the last one wins.
  static func parse(_ output: Data) -> String? { value(marker, in: output) }

  static func parseAnswer(_ output: Data) -> Answer? {
    guard let path = parse(output) else { return nil }
    // CLAUDE_CONFIG_DIR is used as given by the CLI; only an absolute one names the same folder for
    // the app's children as for the terminal.
    let given = value(claudeMarker, in: output)
    let claude = given.flatMap { $0.hasPrefix("/") ? $0 : nil }
    return Answer(path: path, claudeConfigDirectory: claude, claudeConfigRelative: given != nil && claude == nil)
  }

  private static func value(_ marker: String, in output: Data) -> String? {
    let line = String(decoding: output, as: UTF8.self).components(separatedBy: .newlines).last { $0.hasPrefix(marker) }
    let value = line.map { String($0.dropFirst(marker.count)) } ?? ""
    return value.isEmpty ? nil : value
  }

  static func ask(shell: String, environment: [String: String], limit: TimeInterval, beforeLimit: () -> Void = {}) -> String? {
    lookup(shell: shell, environment: environment, limit: limit, beforeLimit: beforeLimit)?.path
  }

  /// csh and tcsh refuse -l next to other options; a name starting with "-" makes them a login shell,
  /// as login(1) starts them.
  static func arguments(shell: String, command: String) -> [String] {
    let name = URL(fileURLWithPath: shell).lastPathComponent
    if ["csh", "tcsh"].contains(name) { return ["-" + name, "-i", "-c", command] }
    return [shell, "-l", "-i", "-c", command]
  }

  static func lookup(shell: String, environment: [String: String], limit: TimeInterval, beforeLimit: () -> Void = {}) -> Answer? {
    let output = Pipe()
    var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
    guard posix_spawn_file_actions_init(&actions) == 0 else { return nil }
    defer { posix_spawn_file_actions_destroy(&actions) }
    guard posix_spawnattr_init(&attributes) == 0 else { return nil }
    defer { posix_spawnattr_destroy(&attributes) }
    // A group of its own, so at the limit the shell and whatever its start-up files wait on end
    // together (an interactive zsh ignores a plain SIGTERM). No other descriptor is inherited.
    // The recorder ignores SIGTERM and SIGINT, and an ignored signal survives exec: without the
    // defaults back, a helper the start-up files leave running could not be stopped normally.
    var defaults = sigset_t(), mask = sigset_t()
    sigemptyset(&defaults); sigaddset(&defaults, SIGTERM); sigaddset(&defaults, SIGINT); sigemptyset(&mask)
    let setup = [
      posix_spawnattr_setflags(&attributes,
        Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT)),
      posix_spawnattr_setpgroup(&attributes, 0),
      posix_spawnattr_setsigdefault(&attributes, &defaults),
      posix_spawnattr_setsigmask(&attributes, &mask),
      posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0),
      posix_spawn_file_actions_adddup2(&actions, output.fileHandleForWriting.fileDescriptor, STDOUT_FILENO),
      posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0),
    ]
    guard setup.allSatisfy({ $0 == 0 }) else { return nil }
    // Login and interactive, as a terminal starts it. The folder comes from printenv, which needs no
    // syntax of a particular shell and sees only an exported value, as the CLI does.
    let arguments = Self.arguments(shell: shell,
      command: "printf '\(marker)%s\\n' \"$PATH\"; /usr/bin/printenv CLAUDE_CONFIG_DIR | /usr/bin/sed 's/^/\(claudeMarker)/'")
    let argv = arguments.map { strdup($0) } + [nil]
    let envp = environment.sorted { $0.key < $1.key }.map { strdup($0.key + "=" + $0.value) } + [nil]
    defer { for pointer in argv + envp { if let pointer { free(pointer) } } }
    var pid: pid_t = 0
    let status = argv.withUnsafeBufferPointer { args in envp.withUnsafeBufferPointer { vars in
      posix_spawn(&pid, shell, &actions, &attributes,
        UnsafeMutablePointer(mutating: args.baseAddress!), UnsafeMutablePointer(mutating: vars.baseAddress!))
    } }
    try? output.fileHandleForWriting.close()
    let handle = output.fileHandleForReading
    defer { try? handle.close() }
    guard status == 0 else { return nil }
    var exited = false
    func running() -> Bool {
      guard !exited else { return false }
      var code: Int32 = 0
      let result = waitpid(pid, &code, WNOHANG)
      if result == pid || (result < 0 && errno == ECHILD) { exited = true }
      return !exited
    }
    // Start-up files can wait for ever, or leave a background child holding the pipe after the
    // shell is gone, so the pipe is polled with a bound and never read to its end.
    beforeLimit()
    let deadline = ProcessInfo.processInfo.systemUptime + limit
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 65_536)
    var ended = false, closed = false
    while !ended, ProcessInfo.processInfo.systemUptime < deadline {
      var waiting = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
      let ready = poll(&waiting, 1, 100)
      if ready > 0 {
        let count = read(handle.fileDescriptor, &buffer, buffer.count)
        if count > 0 {
          data.append(buffer, count: min(count, outputLimit - data.count))
          ended = data.count >= outputLimit
        } else if count == 0 || (errno != EINTR && errno != EAGAIN) {
          ended = true; closed = count == 0
        }
      } else if ready == 0 {
        // Nothing more to read and the shell has exited: what it printed is the answer.
        ended = !running()
      } else if errno != EINTR {
        ended = true
      }
    }
    // A shell that closed the pipe is usually exiting; it may not be reapable yet, and ending its
    // group then would also end helpers its start-up files left behind.
    if closed {
      let settle = ProcessInfo.processInfo.systemUptime + 0.2
      while running(), ProcessInfo.processInfo.systemUptime < settle { usleep(5_000) }
    }
    // Only a shell still running is ended, with its group. What a finished shell left behind (an
    // agent its start-up file started) is the person's and stays; its number may also be reused.
    if running() {
      kill(-pid, SIGTERM)
      let grace = ProcessInfo.processInfo.systemUptime + 0.5
      while running(), ProcessInfo.processInfo.systemUptime < grace { usleep(20_000) }
      if running() { kill(-pid, SIGKILL) }
      var code: Int32 = 0
      if !exited { while waitpid(pid, &code, 0) < 0 && errno == EINTR {} }
    }
    return parseAnswer(data)
  }
}
