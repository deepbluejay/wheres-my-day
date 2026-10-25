import Core
import Darwin
import Foundation

/// Only these fresh, marked homes may be handed to the crash watcher or stale sweep.
final class CodexProcessHome {
  static let maximumRunTime: TimeInterval = 600
  static let staleAge = maximumRunTime + 300
  private static let marker = "activityprobe-owned-home"
  private static let signature = Data("ActivityProbe Codex process home v1\n".utf8)
  let url: URL
  let lockHandle: FileHandle
  init(root: URL) throws {
    Self.sweep(root: root)
    url = root.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let descriptor = Darwin.open(url.appendingPathComponent(Self.marker).path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { try? FileManager.default.removeItem(at: url); throw ConversationError.unavailable }
    lockHandle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    do {
      guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw ConversationError.unavailable }
      try lockHandle.write(contentsOf: Self.signature)
    } catch { try? FileManager.default.removeItem(at: url); throw ConversationError.unavailable }
  }
  deinit { try? FileManager.default.removeItem(at: url) }

  /// A held file lock survives in the group and watcher, so even an overlong running home is skipped.
  static func sweep(root: URL, now: TimeInterval = Date().timeIntervalSince1970) {
    guard let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
    for entry in entries where UUID(uuidString: entry.lastPathComponent) != nil {
      let directory = Darwin.open(entry.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      guard directory >= 0 else { continue }
      defer { Darwin.close(directory) }
      var info = stat()
      guard fstat(directory, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o777 == 0o700,
        now - Double(info.st_birthtimespec.tv_sec) > staleAge else { continue }
      let descriptor = openat(directory, marker, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
      guard descriptor >= 0 else { continue }
      defer { Darwin.close(descriptor) }
      var file = stat()
      guard fstat(descriptor, &file) == 0, file.st_mode & S_IFMT == S_IFREG, file.st_uid == getuid(),
        file.st_nlink == 1, file.st_size == signature.count, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { continue }
      var bytes = [UInt8](repeating: 0, count: signature.count)
      guard read(descriptor, &bytes, bytes.count) == bytes.count, Data(bytes) == signature else { continue }
      var current = stat()
      guard lstat(entry.path, &current) == 0, current.st_dev == info.st_dev, current.st_ino == info.st_ino else { continue }
      try? FileManager.default.removeItem(at: entry)
    }
  }
}
