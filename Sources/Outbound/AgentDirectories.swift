import Core
import Darwin
import Foundation

/// Validate the whole path set before mutation; only app-owned directories receive chmod.
public enum AgentDirectories {
  static let environmentFolders = ["XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME"]
  static func environment(appData: URL) -> [String: String] {
    let home = appData.appendingPathComponent("agent-home")
    var values = ["HOME": home.path, "CFFIXED_USER_HOME": home.path, "ZDOTDIR": home.path,
      "TMPDIR": home.appendingPathComponent("tmp").path]
    for key in environmentFolders { values[key] = home.appendingPathComponent(key.lowercased()).path }
    return values
  }
  public static func prepare(appData: URL, ownedDirectories: [URL], owner: uid_t = getuid()) throws {
    let app = try components(appData)
    let directories = [appData] + ownedDirectories
    let paths = try directories.map(components)
    guard app.count > 1 else { throw ConversationError.unavailable }
    for directory in directories {
      guard try FileLocation.contains(directory, in: appData, granting: true) else { throw ConversationError.unavailable }
    }
    for path in paths { try walk(path, appDepth: app.count, owner: owner, create: false) }
    for path in paths { try walk(path, appDepth: app.count, owner: owner, create: true) }
  }
  private static func components(_ url: URL) throws -> [String] {
    var parts = Array(url.pathComponents.dropFirst())
    // These OS-owned aliases are trusted roots on macOS, not user-controlled path components.
    if let first = parts.first, ["tmp", "var"].contains(first) {
      var info = stat()
      if lstat("/" + first, &info) == 0, info.st_mode & S_IFMT == S_IFLNK, info.st_uid == 0,
        let canonical = realpath("/" + first, nil) {
        defer { free(canonical) }
        if String(cString: canonical) == "/private/" + first { parts.insert("private", at: 0) }
      }
    }
    guard !parts.isEmpty, !parts.contains(".."), !parts.contains(".") else { throw ConversationError.unavailable }
    return parts
  }
  private static func walk(_ parts: [String], appDepth: Int, owner: uid_t, create: Bool) throws {
    var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw ConversationError.unavailable }
    defer { Darwin.close(descriptor) }
    for (index, part) in parts.enumerated() {
      var next = openat(descriptor, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      if next < 0, errno == ENOENT {
        if !create { return }
        guard mkdirat(descriptor, part, 0o700) == 0 || errno == EEXIST else { throw ConversationError.unavailable }
        next = openat(descriptor, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      }
      guard next >= 0 else { throw ConversationError.unavailable }
      Darwin.close(descriptor); descriptor = next
      var info = stat()
      guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
        info.st_uid == owner || (index < appDepth - 1 && info.st_uid == 0) else { throw ConversationError.unavailable }
      if create, index == parts.count - 1 {
        guard fchmod(descriptor, 0o700) == 0 else { throw ConversationError.unavailable }
      }
    }
  }
}
