import Foundation

/// Only explicitly discarded collector directories are eligible for recovery.
/// Enumeration is lazy and deletion checks stop between individual filesystem items.
public enum GitScratchCleanup {
  private static let marker = ".activityprobe-git-discarded"
  public static func discard(_ directory: URL, cancellation: GitTaskCancellation? = nil) {
    guard FileManager.default.fileExists(atPath: directory.path) else { return }
    let receipt = directory.appendingPathComponent(marker)
    guard FileManager.default.createFile(atPath: receipt.path, contents: Data(), attributes: [.posixPermissions: 0o600]) else { return }
    try? remove(directory, cancellation: cancellation)
  }
  public static func recover(in parent: URL = FileManager.default.temporaryDirectory, cancellation: GitTaskCancellation? = nil) throws {
    guard let entries = FileManager.default.enumerator(at: parent, includingPropertiesForKeys: nil,
      options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]) else { return }
    for case let directory as URL in entries {
      try cancellation?.checkCleanup()
      guard directory.lastPathComponent.hasPrefix("activityprobe-git-"),
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(marker).path) else { continue }
      do {
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
        try remove(directory, cancellation: cancellation)
      }
      catch { if FileManager.default.fileExists(atPath: directory.path) { throw error } }
    }
  }
  private static func remove(_ directory: URL, cancellation: GitTaskCancellation?) throws {
    try cancellation?.checkCleanup()
    if let entries = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsSubdirectoryDescendants]) {
      for case let item as URL in entries {
        try cancellation?.checkCleanup()
        if item.lastPathComponent == marker { continue }
        do {
          let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
          if values.isDirectory == true && values.isSymbolicLink != true { try remove(item, cancellation: cancellation) }
          else { try FileManager.default.removeItem(at: item) }
        } catch {
          // Startup recovery and the retiring owner may dispose the same receipt.
          if FileManager.default.fileExists(atPath: item.path) { throw error }
        }
      }
    }
    try cancellation?.checkCleanup()
    // The root now contains only its small disposal receipt, if any.
    do { try FileManager.default.removeItem(at: directory) }
    catch { if FileManager.default.fileExists(atPath: directory.path) { throw error } }
  }
}
