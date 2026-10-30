import Core
import Foundation

/// Tells a tool's copy from the owner's repository: a copy's working tree lies inside
/// another repository's working tree, at a path that repository ignores. Only Git's own
/// ignore rules decide; there is no list of folder names.
///
/// A worktree of the same repository is not another repository, whichever of its folders
/// it sits in. A tracked submodule is not ignored. A repository below a non-repository
/// folder has nothing enclosing it and starts no Git child at all.
///
/// A failed Git read throws and is never remembered, so the caller refuses for now and
/// asks again later. Answers last `lifetime` seconds, so one check per repository, not one
/// per tick, and a rule the owner changes counts by the next day at the latest.
/// Not thread-safe: the Git task calls it under its discovery lock.
public final class GitCopyCheck {
  public static let lifetime = 86_400
  private static let limit = 4096
  private struct Enclosing { let top: String, common: String }
  private struct IgnoreKey: Hashable { let common: String, path: String }
  private let reader: GitRepositoryReader
  private var enclosures: [String: (found: Enclosing?, at: Int)] = [:]
  private var answers: [IgnoreKey: (ignored: Bool, at: Int)] = [:]
  public init(reader: GitRepositoryReader) { self.reader = reader }

  private static func fresh(_ at: Int, _ now: Int) -> Bool { abs(now - at) < lifetime }

  /// Each enclosing repository is asked in turn, so a submodule inside a dependency's
  /// clone is a copy too, even though the clone itself tracks it.
  public func isCopy(topLevel: String, commonDirectory: String, now: Int) throws -> Bool {
    var top = topLevel, common = commonDirectory
    while let enclosing = try enclosure(above: top, now: now) {
      if enclosing.common != common, try ignored(top, by: enclosing, now: now) { return true }
      top = enclosing.top; common = enclosing.common
    }
    return false
  }
  private func ignored(_ path: String, by enclosing: Enclosing, now: Int) throws -> Bool {
    let key = IgnoreKey(common: enclosing.common, path: path)
    if let known = answers[key], Self.fresh(known.at, now) { return known.ignored }
    let answer = try reader.ignores(path, inWorkTree: enclosing.top)
    if answers.count >= Self.limit { answers.removeAll() }
    answers[key] = (answer, now)
    return answer
  }
  private func enclosure(above top: String, now: Int) throws -> Enclosing? {
    let start = URL(fileURLWithPath: top).deletingLastPathComponent().path
    guard start != top else { return nil }
    if let known = enclosures[start], Self.fresh(known.at, now) { return known.found }
    let found = try find(from: start, inside: top)
    if enclosures.count >= Self.limit { enclosures.removeAll() }
    enclosures[start] = (found, now)
    return found
  }
  /// Git is asked at the folder that holds a repository, so a mount point between it and
  /// `top` stops nothing. A bare repository or a repository whose working tree is elsewhere
  /// holds no working tree around `top`, and the walk goes on above it.
  private func find(from start: String, inside top: String) throws -> Enclosing? {
    var path = start
    while let holder = Self.nearestRepository(from: path) {
      if try reader.insideWorkTree(holder) {
        let location = try reader.directoryLocation(holder)
        if top.hasPrefix(location.topLevel.hasSuffix("/") ? location.topLevel : location.topLevel + "/") {
          return Enclosing(top: location.topLevel, common: location.commonDirectory)
        }
      }
      let parent = URL(fileURLWithPath: holder).deletingLastPathComponent().path
      guard parent != holder else { return nil }
      path = parent
    }
    return nil
  }
  /// The nearest folder Git would take for a repository. Git passes over a .git directory
  /// without a HEAD, such as an empty one, so this walk does too.
  private static func nearestRepository(from start: String) -> String? {
    let files = FileManager.default
    var url = URL(fileURLWithPath: start, isDirectory: true)
    while true {
      let mark = url.appendingPathComponent(".git")
      var directory: ObjCBool = false
      if files.fileExists(atPath: mark.path, isDirectory: &directory),
        !directory.boolValue || files.fileExists(atPath: mark.appendingPathComponent("HEAD").path) { return url.path }
      if ["HEAD", "objects", "refs"].allSatisfy({ files.fileExists(atPath: url.appendingPathComponent($0).path) }) { return url.path }
      if url.path == "/" { return nil }
      url.deleteLastPathComponent()
    }
  }
}
