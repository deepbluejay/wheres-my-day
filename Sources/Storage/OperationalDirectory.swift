import Core
import Darwin
import Foundation

/// Holds an approved directory while accessing command-owned leaves. No user aliases are followed.
public final class OperationalDirectory {
  public let descriptor: Int32
  static func systemURL(_ url: URL) -> URL {
    var path = url.path
    // These two aliases are supplied by macOS, rather than by the operator's directory tree.
    for alias in ["/tmp", "/var"] where path == alias || path.hasPrefix(alias + "/") {
      path = "/private" + path
    }
    return URL(fileURLWithPath: path)
  }
  /// Check missing descendants too, before callers create any directories.
  public static func validatePath(_ url: URL) throws {
    try FileLocation.validate(url)
    let path = Self.systemURL(url).path
    var current = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard current >= 0 else { throw StorageError("Operational directory unavailable") }
    defer { Darwin.close(current) }
    for component in path.split(separator: "/") {
      let next = openat(current, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      if next < 0 {
        // A missing suffix is safe to create only after every existing component was checked.
        guard errno == ENOENT else { throw StorageError("Operational directory refused") }
        var info = stat()
        guard fstatat(current, String(component), &info, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else {
          throw StorageError("Operational directory refused")
        }
        return
      }
      Darwin.close(current); current = next
    }
  }

  public init(_ url: URL) throws {
    try Self.validatePath(url)
    let path = Self.systemURL(url).path
    var current = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard current >= 0 else { throw StorageError("Operational directory unavailable") }
    do {
      for component in path.split(separator: "/") {
        let next = openat(current, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard next >= 0 else { throw StorageError("Operational directory refused") }
        Darwin.close(current); current = next
      }
      descriptor = current
    } catch { Darwin.close(current); throw error }
  }
  deinit { Darwin.close(descriptor) }
  private func name(_ leaf: String) throws {
    guard !leaf.isEmpty, leaf != ".", leaf != "..", !leaf.contains("/") else {
      throw StorageError("Operational leaf refused")
    }
  }
  public func validate(_ leaf: String, allowUnreadableDirectory: Bool = false) throws {
    try name(leaf)
    var info = stat()
    if fstatat(descriptor, leaf, &info, AT_SYMLINK_NOFOLLOW) != 0 {
      guard errno == ENOENT else { throw StorageError("Operational leaf unavailable") }
      return
    }
    if allowUnreadableDirectory, info.st_mode & S_IFMT == S_IFDIR { return }
    guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
      throw StorageError("Operational leaf must be a separate regular file")
    }
  }
  public func exists(_ leaf: String) throws -> Bool {
    try name(leaf)
    var info = stat()
    if fstatat(descriptor, leaf, &info, AT_SYMLINK_NOFOLLOW) == 0 { return true }
    guard errno == ENOENT else { throw StorageError("Operational leaf unavailable") }
    return false
  }
  public func open(_ leaf: String, flags: Int32, missingAllowed: Bool = false) throws -> Int32? {
    try validate(leaf)
    let file = openat(descriptor, leaf, (flags & ~O_TRUNC) | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, S_IRUSR | S_IWUSR)
    if file < 0 {
      if missingAllowed && errno == ENOENT { return nil }
      throw StorageError("Operational leaf unavailable")
    }
    var info = stat()
    guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
      Darwin.close(file); throw StorageError("Operational leaf refused")
    }
    if flags & O_TRUNC != 0, ftruncate(file, 0) != 0 {
      Darwin.close(file); throw StorageError("Operational write refused")
    }
    return file
  }
  public func read(_ leaf: String) throws -> Data? {
    // Unreadable settings keep their defaults, including a directory at the expected leaf.
    try validate(leaf, allowUnreadableDirectory: true)
    let file = openat(descriptor, leaf, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    if file < 0 {
      if [ENOENT, EACCES, EPERM].contains(errno) { return nil }
      throw StorageError("Operational leaf unavailable")
    }
    let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
    defer { try? handle.close() }
    var info = stat()
    guard fstat(file, &info) == 0 else { throw StorageError("Operational leaf unavailable") }
    if info.st_mode & S_IFMT == S_IFDIR { return nil }
    guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
      throw StorageError("Operational leaf refused")
    }
    return try? handle.readToEnd()
  }
  public static func read(_ file: URL) throws -> Data? {
    try FileLocation.validate(file)
    var info = stat()
    if lstat(file.deletingLastPathComponent().path, &info) != 0, errno == ENOENT { return nil }
    return try OperationalDirectory(file.deletingLastPathComponent()).read(file.lastPathComponent)
  }
}
