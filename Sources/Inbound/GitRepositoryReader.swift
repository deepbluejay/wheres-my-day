import Core
import Darwin
import Foundation

public enum GitReadError: Error { case failed, timedOut, malformed, mainThread, cancelled }

private final class GitReadPermission {
  let allows: () -> Bool
  let cancellation: GitTaskCancellation?
  init(_ allows: @escaping () -> Bool, cancellation: GitTaskCancellation?) { self.allows = allows; self.cancellation = cancellation }
}
private final class GitChildCancellation {
  private let lock = NSLock()
  private var cancelled = false
  func cancel() { lock.lock(); cancelled = true; lock.unlock() }
  func isCancelled() -> Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}
private final class GitReadProgress {
  private let lock = NSLock()
  private var last = ProcessInfo.processInfo.systemUptime
  private var consuming = false
  private var expired = false
  func beginConsumption() { lock.lock(); consuming = true; lock.unlock() }
  func endConsumption() { lock.lock(); last = ProcessInfo.processInfo.systemUptime; consuming = false; lock.unlock() }
  func timedOut(after timeout: TimeInterval) -> Bool {
    lock.lock(); defer { lock.unlock() }
    if !consuming && ProcessInfo.processInfo.systemUptime - last >= timeout { expired = true }
    return expired
  }
}

/// Runs only on maintenance workers. No shell, user environment, network or repository writes.
public final class GitRepositoryReader {
  public let timeout: TimeInterval
  private let processLock = NSLock()
  private var processes: [Int32: Process] = [:]
  private var cancellationGeneration = 0
  private let permissionKey = "ActivityProbe.GitPermission." + UUID().uuidString
  var beforePreparedChunk: ((Int) throws -> Void)?
  var afterPreparedUnit: ((String) throws -> Void)?
  public init(timeout: TimeInterval = 30) { self.timeout = timeout }
  var activeProcessIDs: [Int32] {
    processLock.lock(); defer { processLock.unlock() }; return Array(processes.keys)
  }
  var runningProcessIDs: [Int32] {
    processLock.lock(); defer { processLock.unlock() }
    return processes.values.filter { $0.isRunning }.map { $0.processIdentifier }
  }
  var taskCancellation: GitTaskCancellation? {
    (Thread.current.threadDictionary[permissionKey] as? GitReadPermission)?.cancellation
  }
  public func withCancellation<T>(cancellation: GitTaskCancellation? = nil, shouldContinue: @escaping () -> Bool, _ body: () throws -> T) rethrows -> T {
    let previous = Thread.current.threadDictionary[permissionKey]
    Thread.current.threadDictionary[permissionKey] = GitReadPermission(shouldContinue,
      cancellation: cancellation ?? (previous as? GitReadPermission)?.cancellation)
    defer {
      if let previous { Thread.current.threadDictionary[permissionKey] = previous }
      else { Thread.current.threadDictionary.removeObject(forKey: permissionKey) }
    }
    return try body()
  }
  func checkReadCancellation() throws {
    guard (Thread.current.threadDictionary[permissionKey] as? GitReadPermission)?.allows() != false else {
      throw GitReadError.cancelled
    }
  }
  /// Only processes launched by this reader are signalled, and every one is reaped.
  public func cancel() {
    processLock.lock()
    cancellationGeneration += 1
    let active = Array(processes.values)
    processLock.unlock()
    for process in active {
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
      process.waitUntilExit()
    }
  }
  public static func validHash(_ value: String) -> Bool {
    [40, 64].contains(value.utf8.count) && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }
  public func run(at path: String, _ arguments: [String], input: URL? = nil,
    consume: (Data) throws -> Void) throws {
    guard !Thread.isMainThread else { throw GitReadError.mainThread }
    let permission = Thread.current.threadDictionary[permissionKey] as? GitReadPermission
    guard permission?.allows() != false else { throw GitReadError.cancelled }
    processLock.lock(); let generation = cancellationGeneration; processLock.unlock()
    // Built-ins only: aliases and remote/credential commands have no collection entry point.
    guard let command = arguments.first,
      ["rev-parse", "symbolic-ref", "for-each-ref", "worktree", "merge-base", "show", "diff-tree", "cat-file", "rev-list"].contains(command)
    else { throw GitReadError.failed }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.environment = ["PATH": "/usr/bin:/bin", "HOME": "/var/empty", "XDG_CONFIG_HOME": "/var/empty",
      "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null",
      "GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0", "GIT_ASKPASS": "/usr/bin/false",
      "SSH_ASKPASS": "/usr/bin/false", "GIT_NO_LAZY_FETCH": "1", "GIT_NO_REPLACE_OBJECTS": "1",
      "GIT_ATTR_NOSYSTEM": "1", "GIT_ALLOW_PROTOCOL": "", "LC_ALL": "C"]
    process.arguments = ["--no-pager", "--no-optional-locks", "-c", "core.fsmonitor=false",
      "-c", "core.hooksPath=/dev/null", "-c", "core.attributesFile=/dev/null", "-c", "gc.auto=0",
      "-c", "maintenance.auto=false", "-c", "log.showSignature=false",
      "-c", "gpg.program=/usr/bin/false", "-c", "gpg.openpgp.program=/usr/bin/false",
      "-c", "gpg.x509.program=/usr/bin/false", "-c", "gpg.ssh.program=/usr/bin/false",
      "-c", "core.sshCommand=/usr/bin/false", "-c", "core.gitProxy=/usr/bin/false",
      "-c", "core.alternateRefsCommand=/usr/bin/false", "-c", "credential.helper=",
      "-c", "core.pager=cat", "-c", "diff.external=/usr/bin/false", "-c", "i18n.logOutputEncoding=UTF-8", "-c", "protocol.allow=never", "-C", path] + arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    let stdin = try input.map { try FileHandle(forReadingFrom: $0) }
    defer { try? stdin?.close() }
    process.standardInput = stdin ?? FileHandle.nullDevice
    processLock.lock()
    do {
      guard generation == cancellationGeneration else { throw GitReadError.cancelled }
      try process.run()
      processes[process.processIdentifier] = process
      processLock.unlock()
    } catch { processLock.unlock(); throw error }
    defer {
      processLock.lock(); processes.removeValue(forKey: process.processIdentifier); processLock.unlock()
    }
    let cancellation = GitChildCancellation()
    let progress = GitReadProgress()
    func cancelled() -> Bool {
      processLock.lock(); let changed = generation != cancellationGeneration; processLock.unlock()
      return changed || cancellation.isCancelled() || permission?.allows() == false
    }
    let watchdog = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
    watchdog.schedule(deadline: .now() + min(timeout, 0.05), repeating: 0.05)
    watchdog.setEventHandler {
      if permission?.allows() == false {
        cancellation.cancel()
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
      } else if progress.timedOut(after: self.timeout), process.isRunning {
        kill(process.processIdentifier, SIGKILL)
      }
    }
    watchdog.resume()
    defer { watchdog.cancel(); try? output.fileHandleForReading.close() }
    do {
      while try autoreleasepool(invoking: { () throws -> Bool in
        guard !cancelled() else { throw GitReadError.cancelled }
        guard let chunk = try output.fileHandleForReading.read(upToCount: 65536), !chunk.isEmpty else { return false }
        progress.beginConsumption()
        defer { progress.endConsumption() }
        guard !cancelled() else { throw GitReadError.cancelled }
        try self.withCancellation(shouldContinue: { !cancelled() && !progress.timedOut(after: self.timeout) }) {
          try consume(chunk)
        }
        return true
      }) {}
    } catch {
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
      process.waitUntilExit()
      throw error
    }
    process.waitUntilExit()
    guard !cancelled() else { throw GitReadError.cancelled }
    guard !progress.timedOut(after: timeout) else { throw GitReadError.timedOut }
    guard process.terminationStatus == 0 else { throw GitReadError.failed }
  }
  public func tokens(at path: String, _ arguments: [String], separator: UInt8 = 0, input: URL? = nil,
    visit: (String) throws -> Void) throws {
    var token = Data()
    try run(at: path, arguments, input: input) { chunk in
      for byte in chunk {
        if byte == separator {
          try visit(String(decoding: token, as: UTF8.self)); token.removeAll(keepingCapacity: true)
        } else {
          guard token.count < 65536 else { throw GitReadError.malformed }
          token.append(byte)
        }
      }
    }
    if !token.isEmpty { try visit(String(decoding: token, as: UTF8.self)) }
  }
  private func value(at path: String, _ arguments: [String]) throws -> String {
    var bytes = Data()
    try run(at: path, arguments) {
      guard bytes.count + $0.count <= 65536 else { throw GitReadError.malformed }
      bytes.append($0)
    }
    return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .newlines)
  }
  public func locate(_ folder: String) throws -> GitRepositoryLocation {
    try directoryLocation(folder, includeBranch: true)
  }
  public func directoryLocation(_ folder: String, includeBranch: Bool = false) throws -> GitRepositoryLocation {
    let common = try value(at: folder, ["rev-parse", "--git-common-dir"])
    let base = URL(fileURLWithPath: folder, isDirectory: true)
    let directory = common.hasPrefix("/") ? URL(fileURLWithPath: common) : base.appendingPathComponent(common)
    let top = try value(at: folder, ["rev-parse", "--show-toplevel"])
    let head = (try? value(at: folder, ["rev-parse", "--verify", "HEAD"])) ?? ""
    let branch = includeBranch ? ((try? value(at: folder, ["symbolic-ref", "--quiet", "--short", "HEAD"])) ?? "") : ""
    return GitRepositoryLocation(commonDirectory: try CanonicalPath.resolve(directory).path,
      topLevel: try CanonicalPath.resolve(URL(fileURLWithPath: top)).path, branch: branch, head: head)
  }
  public func refs(at common: String, contains: String? = nil, visit: (String, String) throws -> Void) throws {
    var args = ["for-each-ref", "--format=%(objectname)%09%(refname)"]
    if let contains { args.append("--contains=" + contains) }
    try tokens(at: common, args, separator: 10) { line in
      let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
      guard parts.count == 2, Self.validHash(String(parts[0])) else { throw GitReadError.malformed }
      try visit(String(parts[1]), String(parts[0]))
    }
  }
  public func worktreeHeads(at common: String, contains: String? = nil, visit: (String, String) throws -> Void) throws {
    var folder = ""
    try tokens(at: common, ["worktree", "list", "--porcelain", "-z"]) { token in
      if token.hasPrefix("worktree ") { folder = String(token.dropFirst(9)) }
      if token.hasPrefix("HEAD ") {
        let head = String(token.dropFirst(5))
        guard Self.validHash(head), !head.allSatisfy({ $0 == "0" }) else { return }
        if let contains {
          do { try run(at: common, ["merge-base", "--is-ancestor", contains, head]) { _ in } }
          catch GitReadError.failed { return }
        }
        try visit("worktree:" + folder + ":HEAD", head)
      }
    }
  }
  public func commit(at common: String, hash: String) throws -> GitCommitRecord {
    guard Self.validHash(hash) else { throw GitReadError.malformed }
    var fields: [String] = []
    try tokens(at: common, ["show", "--no-show-signature", "--no-textconv", "--no-ext-diff", "-s",
      "--format=%H%x00%at%x00%ct%x00%an%x00%ae%x00%B%x00", hash, "--"]) { fields.append($0) }
    guard fields.count == 7, fields[6] == "\n", fields[0] == hash, let author = Int(fields[1]), let commit = Int(fields[2]) else { throw GitReadError.malformed }
    return GitCommitRecord(hash: hash, authorTime: author, commitTime: commit, author: fields[3], email: fields[4], message: fields[5])
  }
  public func files(at common: String, hash: String, visit: (GitChangedFile) throws -> Void) throws {
    guard Self.validHash(hash) else { throw GitReadError.malformed }
    var rename: (Int?, Int?)?
    var old: String?
    // Compare explicitly with the first parent; -m would also emit the other parents' files.
    let parent = try? value(at: common, ["rev-parse", "--verify", hash + "^1"])
    let revisions = parent.map { [$0, hash] } ?? ["--root", hash]
    try tokens(at: common, ["diff-tree", "-r", "--no-commit-id", "--numstat", "-z", "-M",
      "--no-textconv", "--no-ext-diff"] + revisions + ["--"]) { token in
      if let counts = rename {
        if let before = old {
          try visit(GitChangedFile(oldPath: before, path: token, added: counts.0, deleted: counts.1))
          rename = nil; old = nil
        } else { old = token }
        return
      }
      let fields = token.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
      guard fields.count == 3 else { throw GitReadError.malformed }
      let a = Int(fields[0]), d = Int(fields[1])
      guard (a != nil && d != nil) || (fields[0] == "-" && fields[1] == "-") else { throw GitReadError.malformed }
      if fields[2].isEmpty { rename = (a, d) }
      else { try visit(GitChangedFile(path: String(fields[2]), added: a, deleted: d)) }
    }
    guard rename == nil else { throw GitReadError.malformed }
  }
}
