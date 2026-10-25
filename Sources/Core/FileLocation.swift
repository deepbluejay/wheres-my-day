import Foundation

/// Existing locations are compared by filesystem identity, including aliased ancestors.
public enum FileLocation {
  public enum Failure: Error { case unavailable }
  private struct Identity: Equatable {
    let device: dev_t
    let inode: ino_t
    init(_ info: stat) { device = info.st_dev; inode = info.st_ino }
  }
  private struct Location {
    let ancestors: [Identity]
    let missing: [String]
    let resolved: URL
  }

  /// Validate raw inputs before Foundation can discard relative or empty components.
  public static func validate(_ path: String) throws {
    guard path.hasPrefix("/"), !path.contains("\0") else { throw Failure.unavailable }
    if path == "/" { return }
    guard path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
      !$0.isEmpty && $0 != "." && $0 != ".."
    }) else { throw Failure.unavailable }
  }
  public static func validate(_ url: URL) throws {
    guard url.isFileURL else { throw Failure.unavailable }
    try validate(url.path)
  }

  private static func location(_ url: URL) throws -> Location {
    try validate(url)
    var ancestor = url
    var missing: [String] = []
    var info = stat()
    while lstat(ancestor.path, &info) != 0 {
      guard errno == ENOENT, ancestor.path != "/" else { throw Failure.unavailable }
      missing.insert(ancestor.lastPathComponent, at: 0)
      ancestor.deleteLastPathComponent()
    }
    guard let physical = realpath(ancestor.path, nil) else { throw Failure.unavailable }
    defer { free(physical) }
    var current = URL(fileURLWithPath: String(cString: physical))
    var resolved = current
    for component in missing { resolved.appendPathComponent(component) }
    var identities: [Identity] = []
    repeat {
      guard stat(current.path, &info) == 0,
        identities.count > 0 || missing.isEmpty || info.st_mode & S_IFMT == S_IFDIR else {
        throw Failure.unavailable
      }
      identities.append(Identity(info))
      if current.path == "/" { break }
      current.deleteLastPathComponent()
    } while true
    return Location(ancestors: identities, missing: missing, resolved: resolved)
  }

  /// A spelling for filesystem operations, never a key for protected-location comparison.
  public static func resolve(_ url: URL) throws -> URL { try location(url).resolved }

  /// Stable across file creation. The parent must already exist; callers validate grants
  /// before creating it. A database inode cannot be used because an absent file has none.
  public static func key(_ url: URL) throws -> String {
    let file = try resolve(url)
    let parent = try location(file.deletingLastPathComponent())
    guard parent.missing.isEmpty else { throw Failure.unavailable }
    let values = try parent.resolved.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
    guard let caseSensitive = values.volumeSupportsCaseSensitiveNames else { throw Failure.unavailable }
    let identity = parent.ancestors[0]
    let name = normalizedName(file.lastPathComponent, caseSensitive: caseSensitive)
    return "\(identity.device):\(identity.inode):\(Data(name.utf8).base64EncodedString())"
  }

  static func normalizedName(_ name: String, caseSensitive: Bool) -> String {
    // macOS native volumes compare canonical Unicode equivalents even in case-sensitive mode.
    let folded = caseSensitive ? name : name.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    return folded.precomposedStringWithCanonicalMapping
  }

  /// Missing names have no inode yet. Grants require exact bytes; exclusions conservatively
  /// fold case and Unicode so alternate spellings cannot create a protected destination.
  public static func contains(_ candidate: URL, in root: URL, includingRoot: Bool = true,
    granting: Bool = false) throws -> Bool {
    let path = try location(candidate), parent = try location(root)
    if parent.missing.isEmpty {
      guard let index = path.ancestors.firstIndex(of: parent.ancestors[0]) else { return false }
      return includingRoot || index > 0 || !path.missing.isEmpty
    }
    guard path.ancestors[0] == parent.ancestors[0], path.missing.count >= parent.missing.count else { return false }
    for (name, expected) in zip(path.missing, parent.missing) {
      if granting {
        guard name.utf8.elementsEqual(expected.utf8) else { return false }
      } else {
        guard name.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
          .precomposedStringWithCanonicalMapping == expected.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
          .precomposedStringWithCanonicalMapping else { return false }
      }
    }
    return includingRoot || path.missing.count > parent.missing.count
  }

  public static func same(_ first: URL, _ second: URL) throws -> Bool {
    let a = try location(first), b = try location(second)
    if a.missing.isEmpty && b.missing.isEmpty { return a.ancestors[0] == b.ancestors[0] }
    if let a = try? key(first), let b = try? key(second) { return a == b }
    return try contains(first, in: second, granting: true) && contains(second, in: first, granting: true)
  }
}
