import CryptoKit
import Darwin
import Foundation

/// A one-way digest of the stat data of every file Git reads for a repository's refs. No Git
/// child and no file content, so it costs a few milliseconds where a read costs seconds.
/// The same digest means the same files, so `for-each-ref`, `worktree list` and
/// `rev-list --all` would answer the same. Git replaces a ref through a lock file and a
/// rename, so any write gives a new inode and nanosecond times, even a ref moved back.
///
/// Nil means it cannot vouch and the caller reads as usual: not APFS (coarser or cached
/// times), a symlink in the walk (lstat cannot see through it), another volume inside the
/// walk, no HEAD or refs, or a ref format other than files and reftable, whose refs could
/// live somewhere this walk does not look. The object store is left out on purpose: when
/// the refs equal the frontier, every tip is both wanted and excluded, so `rev-list`
/// answers nothing.
public enum GitRefState {
  private enum CannotVouch: Error { case found }
  private static let checkInterval = 1024

  /// Files that hold no history and change all the time (index, logs, FETCH_HEAD, gc.pid) are
  /// not read, so a `git status` or an empty fetch does not count as a change.
  public static func digest(commonDirectory common: String, check: @escaping () throws -> Void = {}) throws -> String? {
    var volume = statfs(), top = stat()
    guard statfs(common, &volume) == 0, stat(common, &top) == 0,
      withUnsafeBytes(of: volume.f_fstypename, { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }) == "apfs" else { return nil }
    var walk = Walk(root: common, device: top.st_dev, check: check)
    do {
      guard try walk.add("HEAD"), try walk.tree("refs") else { return nil }
      for name in ["packed-refs", "config", "config.worktree", "shallow"] { _ = try walk.add(name) }
      guard knownRefFormat(common + "/config") else { return nil }
      // A reftable repository keeps its refs here instead.
      _ = try walk.tree("reftable")
      if try walk.add("worktrees") {
        // Only what `worktree list` reads. Not the folder itself: its time moves with every
        // index lock in a worktree that is merely in use.
        for id in try walk.names("worktrees") {
          for name in ["HEAD", "gitdir", "commondir", "locked", "config.worktree"] { _ = try walk.add("worktrees/\(id)/\(name)") }
          _ = try walk.tree("worktrees/\(id)/refs")
          // Under reftable a linked worktree's HEAD and its own refs are here, not in its HEAD file.
          _ = try walk.tree("worktrees/\(id)/reftable")
        }
      }
    } catch CannotVouch.found { return nil }
    return walk.finish()
  }

  /// Whether `extensions.refStorage` names a format this walk knows: none (files), files or
  /// reftable. Git reads extensions from this file alone, with no includes. A config too big
  /// or unreadable cannot vouch either. Its stat is in the digest, so a change is seen anyway.
  static func knownRefFormat(_ path: String) -> Bool {
    let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { return errno == ENOENT }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    guard let data = try? handle.read(upToCount: 1 << 20), data.count < 1 << 20 else { return false }
    var section = ""
    for raw in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
      var line = raw.trimmingCharacters(in: .whitespaces).lowercased()
      if line.hasPrefix("[") {
        section = String(line.dropFirst().prefix { $0 != "]" && $0 != " " && $0 != "\"" })
        guard let close = line.firstIndex(of: "]") else { continue }
        line = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
      }
      guard section == "extensions" else { continue }
      let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
      guard parts.first == "refstorage" else { continue }
      let value = parts.count == 2 ? String(parts[1].prefix { $0 != "#" && $0 != ";" }).trimmingCharacters(in: CharacterSet(charactersIn: " \t\"")) : ""
      if value != "files" && value != "reftable" { return false }
    }
    return true
  }

  private struct Walk {
    let root: String
    let device: Int32
    let check: () throws -> Void
    var hash = SHA256()
    var seen = 0
    init(root: String, device: Int32, check: @escaping () throws -> Void) {
      self.root = root; self.device = device; self.check = check
    }
    private func path(_ relative: String) -> String { root + "/" + relative }
    private mutating func mix(_ relative: String, _ values: [Int64]) {
      hash.update(data: Data(relative.utf8))
      values.withUnsafeBytes { hash.update(bufferPointer: $0) }
    }
    /// Whether the entry exists. Its absence goes into the digest too. A file vanishing
    /// during the walk reads as absent, and its folder's time then differs at the next walk.
    mutating func add(_ relative: String) throws -> Bool { try entry(relative) != nil }
    private mutating func entry(_ relative: String) throws -> mode_t? {
      seen += 1
      if seen % checkInterval == 0 { try check() }
      var info = stat()
      guard lstat(path(relative), &info) == 0 else {
        guard errno == ENOENT || errno == ENOTDIR else { throw CannotVouch.found }
        mix(relative, [-1])
        return nil
      }
      let kind = info.st_mode & S_IFMT
      guard kind == S_IFREG || kind == S_IFDIR, info.st_dev == device else { throw CannotVouch.found }
      mix(relative, [Int64(kind), Int64(bitPattern: UInt64(info.st_ino)), info.st_size,
        Int64(info.st_mtimespec.tv_sec), Int64(info.st_mtimespec.tv_nsec), Int64(info.st_ctimespec.tv_sec), Int64(info.st_ctimespec.tv_nsec)])
      return kind
    }
    /// The entry and, for a folder, everything below it.
    mutating func tree(_ relative: String) throws -> Bool {
      guard let kind = try entry(relative) else { return false }
      if kind == S_IFDIR { for name in try names(relative) { _ = try tree(relative + "/" + name) } }
      return true
    }
    /// Sorted, since nothing promises a listing's order stays the same.
    func names(_ relative: String) throws -> [String] {
      guard let folder = opendir(path(relative)) else { throw CannotVouch.found }
      defer { closedir(folder) }
      var names: [String] = []
      while let item = readdir(folder) {
        let name = withUnsafeBytes(of: item.pointee.d_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        if name != "." && name != ".." { names.append(name) }
      }
      return names.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }
    func finish() -> String { hash.finalize().map { String(format: "%02x", $0) }.joined() }
  }
}
