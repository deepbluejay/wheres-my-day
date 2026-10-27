import Foundation

/// Shared accounting estimates and cleanup for temporary summary artifacts from older builds.
public enum SummaryMaintenance {
  public static let callTimeoutSeconds: TimeInterval = 600
  // Chosen tolerance for tokenizer differences; an excess is diagnostic, never an answer edit.
  public static let inputMarginTokens = 1_024
  public static func estimatedTokens(_ prompt: String) -> Int { (prompt.utf8.count + 3) / 4 }
  public static func sweepStaleWorkFolders(in parent: URL, timeout: TimeInterval, prefix: String = "summary-work-",
    keeping: Set<String> = [], files: FileManager = .default, now: Date = Date()) throws {
    // Preserve the four-deadline lifetime of prompt work folders left by older builds.
    let lifetime = 4 * max(callTimeoutSeconds, timeout)
    for folder in try files.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
      where folder.lastPathComponent.hasPrefix(prefix) && !keeping.contains(folder.lastPathComponent) {
      guard let attributes = try? files.attributesOfItem(atPath: folder.path),
        let modified = attributes[.modificationDate] as? Date,
        now.timeIntervalSince(modified) > lifetime else { continue }
      // Another process may finish and remove its folder after either read.
      try? files.removeItem(at: folder)
    }
  }
  public static func sweepStalePromptFiles(in directory: URL, timeout: TimeInterval,
    files: FileManager = .default, now: Date = Date()) throws {
    // A prompt exists only during execution, which has one deadline.
    let lifetime = max(callTimeoutSeconds, timeout)
    for file in try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      where file.lastPathComponent.hasPrefix("prompt-") {
      guard let attributes = try? files.attributesOfItem(atPath: file.path),
        let modified = attributes[.modificationDate] as? Date,
        now.timeIntervalSince(modified) > lifetime else { continue }
      try? files.removeItem(at: file)
    }
  }
}
