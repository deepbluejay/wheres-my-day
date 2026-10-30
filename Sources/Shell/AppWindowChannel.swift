import CryptoKit
import Core
import Foundation
import Darwin
import Storage

/// Holds the database window lifetime lock and acknowledges explicit open requests after delivery.
final class AppWindowChannel {
  enum Claim: Equatable {
    /// A window was there and showed the place. This process has nothing more to do.
    case delivered
    /// Nobody was there: this process is the window and hears the lines of later commands.
    case owner
    /// No channel: fail closed rather than create a second window.
    case unavailable(String)
  }

  let socket: URL
  private(set) var listener: Int32 = -1
  /// Held from the bind until `close`, or until the kernel ends the process.
  private var life: Int32 = -1
  /// The files this window made, so that closing removes them and never another window's.
  private var made: (socket: ino_t, lock: ino_t) = (0, 0)
  private var source: DispatchSourceRead?
  private var reading: [Int32: DispatchSourceRead] = [:]
  /// Answers nothing more, but holds the lifetime lock until `close` or the end of the process.
  private var refusing = false
  private let state = NSLock()
  private let accepting = DispatchQueue(label: "window.channel")
  private var lockPath: String { socket.path + ".lock" }

  /// One window for one database: a developer's copy does not raise the window of the real one.
  static func socket(paths: AppPaths) throws -> URL {
    let identity = try FileLocation.key(paths.database)
    let name = SHA256.hash(data: Data(identity.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    // A short per-user endpoint also works with long or multibyte home paths.
    // Changing app-data must not create a second owner of the same database.
    return URL(fileURLWithPath: "/tmp/activityprobe-window-\(getuid())").appendingPathComponent("\(name).sock")
  }

  /// No parent is created until every grant, exclusion and operational path has passed.
  static func prepareSocket(paths: AppPaths) throws -> URL {
    try paths.databaseScope.validateAppDataPath(paths.appData)
    try paths.databaseScope.validatePath(paths.database)
    try OperationalDirectory.validatePath(paths.appData)
    try OperationalDirectory.validatePath(paths.database.deletingLastPathComponent())
    try FileManager.default.createDirectory(at: paths.database.deletingLastPathComponent(), withIntermediateDirectories: true)
    let directory = try OperationalDirectory(paths.database.deletingLastPathComponent())
    try directory.validate(paths.database.lastPathComponent)
    return try socket(paths: paths)
  }

  init(socket: URL) { self.socket = socket }

  deinit { close() }

  /// Gives `line` to the window that is open, or makes this process the window. `receive` gets
  /// the lines of later commands on `queue`, and each command is answered after it returns.
  func claim(sending line: String, on queue: DispatchQueue = .main, receive: @escaping (String) -> Void) -> Claim {
    guard var address = Self.address(socket.path) else { return .unavailable("the socket path is too long: \(socket.path)") }
    do {
      try FileManager.default.createDirectory(at: socket.deletingLastPathComponent(), withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      var info = stat()
      guard lstat(socket.deletingLastPathComponent().path, &info) == 0,
        info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
        return .unavailable("window_directory_refused")
      }
    } catch { return .unavailable("window_directory_unavailable") }
    while true {
      // Asking for the window's lock, removing what a dead window left and binding cannot be
      // made one step, so they happen under a lock on the folder itself (no file of its own).
      // It is held for those calls only, never while waiting for anyone.
      guard let folder = folderLock() else { return .unavailable("cannot lock \(socket.deletingLastPathComponent().path): \(Self.reason())") }
      let lock = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
      guard lock >= 0 else {
        let reason = Self.reason()
        Darwin.close(folder)
        return .unavailable("cannot open \(lockPath): \(reason)")
      }
      if Self.again({ flock(lock, LOCK_EX | LOCK_NB) }) == 0 {
        let claim = listen(&address, holding: lock, on: queue, receive: receive)
        Darwin.close(folder)
        return claim
      }
      guard errno == EWOULDBLOCK else {
        let reason = Self.reason()
        Darwin.close(lock); Darwin.close(folder)
        return .unavailable("cannot lock \(lockPath): \(reason)")
      }
      let connection = Self.connected(&address)
      Darwin.close(folder)
      let shown = connection >= 0 && Self.say(line, to: connection)
      if connection >= 0 { Darwin.close(connection) }
      if shown { Darwin.close(lock); return .delivered }
      // A window lives and did not show the place: it is closing, or it is stopped with a full
      // queue. Its lock is free when its process has ended; then the question is asked again.
      _ = Self.again { flock(lock, LOCK_SH) }
      Darwin.close(lock)
    }
  }


  /// Stops listening. A command waiting for an answer, or started after this, opens a new window.
  func close() {
    state.lock()
    let source = self.source, reading = self.reading
    self.source = nil
    self.reading = [:]
    state.unlock()
    guard let source else { return }
    // Under the folder lock, and only what this window made: a file put at the path by another
    // window (after someone removed ours by hand) is that window's.
    if let folder = folderLock() {
      if Self.inode(socket.path) == made.socket { unlink(socket.path) }
      if Self.inode(lockPath) == made.lock { unlink(lockPath) }
      Darwin.close(folder)
    }
    listener = -1
    source.cancel()
    reading.values.forEach { $0.cancel() }
    Darwin.close(life)
    life = -1
  }

  private func listen(_ address: inout sockaddr_un, holding lock: Int32, on queue: DispatchQueue, receive: @escaping (String) -> Void) -> Claim {
    // Nobody holds the lock, so what is at the path belongs to a window that has gone.
    unlink(socket.path)
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
      let reason = Self.reason()
      Darwin.close(lock)
      return .unavailable("no socket: \(reason)")
    }
    // Not inherited: an agent CLI holding it would keep answering "a window is open" after ours closed.
    _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard bound == 0, Darwin.listen(descriptor, SOMAXCONN) == 0 else {
      let reason = Self.reason()
      Darwin.close(descriptor); Darwin.close(lock)
      return .unavailable("cannot listen on \(socket.path): \(reason)")
    }
    chmod(socket.path, 0o600)
    made = (Self.inode(socket.path), Self.inode(lockPath))
    life = lock
    listener = descriptor
    let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: accepting)
    source.setEventHandler { [weak self] in self?.accept(descriptor, on: queue, receive: receive) }
    source.setCancelHandler { Darwin.close(descriptor) }
    state.lock(); self.source = source; state.unlock()
    source.resume()
    return .owner
  }

  /// One command's connection, read by a source of its own: one that connects and says nothing
  /// holds nobody else, and needs no limit.
  private func accept(_ listener: Int32, on queue: DispatchQueue, receive: @escaping (String) -> Void) {
    let descriptor = Self.again { Darwin.accept(listener, nil, nil) }
    guard descriptor >= 0 else { return }
    _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
    _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
    var on: Int32 = 1
    setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    let reader = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: accepting)
    var bytes: [UInt8] = []
    var line: String?
    reader.setEventHandler {
      var buffer = [UInt8](repeating: 0, count: 128)
      let count = read(descriptor, &buffer, buffer.count - bytes.count)
      if count < 0, errno == EINTR || errno == EAGAIN { return }
      if count > 0 { bytes += buffer[0..<count] }
      if let end = bytes.firstIndex(of: 10) { line = String(decoding: bytes[0..<end], as: UTF8.self) }
      // A line, the end of the connection, or more than any place line is long.
      if line != nil || count <= 0 || bytes.count >= buffer.count { reader.cancel() }
    }
    reader.setCancelHandler { [weak self] in
      self?.state.lock(); self?.reading[descriptor] = nil; self?.state.unlock()
      guard let line else { Darwin.close(descriptor); return }
      // The answer is written where the place is shown, after it is: a window that is closing
      // answers nothing, and the command sees the connection end instead of a false "ok".
      queue.async { [weak self] in
        defer { Darwin.close(descriptor) }
        guard let self, self.isOpen else { return }
        receive(line)
        let answer = Array("ok\n".utf8)
        _ = Self.again { write(descriptor, answer, answer.count) }
      }
    }
    state.lock()
    let open = source != nil
    if open { reading[descriptor] = reader }
    state.unlock()
    guard open else { Darwin.close(descriptor); return }
    reader.resume()
  }

  private var isOpen: Bool {
    state.lock(); defer { state.unlock() }
    return source != nil && !refusing
  }

  private func folderLock() -> Int32? {
    let folder = open(socket.deletingLastPathComponent().path, O_RDONLY | O_CLOEXEC)
    guard folder >= 0 else { return nil }
    guard Self.again({ flock(folder, LOCK_EX) }) == 0 else {
      let failure = errno
      Darwin.close(folder)
      errno = failure
      return nil
    }
    return folder
  }

  /// A call interrupted by a signal has not failed: it is made again.
  private static func again<Result: BinaryInteger>(_ call: () -> Result) -> Result {
    while true {
      let result = call()
      if result != -1 || errno != EINTR { return result }
    }
  }

  private static func reason() -> String { String(cString: strerror(errno)) }

  private static func inode(_ path: String) -> ino_t {
    var info = stat()
    return lstat(path, &info) == 0 ? info.st_ino : 0
  }

  private static func address(_ path: String) -> sockaddr_un? {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
    return address
  }

  private static func connected(_ address: inout sockaddr_un) -> Int32 {
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return -1 }
    var on: Int32 = 1
    setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { peer in
        again { connect(descriptor, peer, socklen_t(MemoryLayout<sockaddr_un>.size)) }
      }
    }
    // An interrupted connect goes on by itself; asked again, it says it is already made.
    guard result == 0 || errno == EISCONN else { Darwin.close(descriptor); return -1 }
    return descriptor
  }

  /// Writes the line and waits for the window's answer or the end of the connection.
  private static func say(_ line: String, to descriptor: Int32) -> Bool {
    let bytes = Array((line + "\n").utf8)
    guard again({ write(descriptor, bytes, bytes.count) }) == bytes.count else { return false }
    var answer: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 16)
    while !answer.contains(10) {
      let count = again { read(descriptor, &buffer, buffer.count) }
      guard count > 0 else { return false }
      answer += buffer[0..<count]
    }
    return answer.starts(with: Array("ok\n".utf8))
  }
}
