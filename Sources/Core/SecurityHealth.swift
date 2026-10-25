import Foundation

public enum AppDataPaths {
  public static func directory(in userHome: URL) -> URL {
    let path = userHome.appendingPathComponent("Library/Application Support/ActivityProbe", isDirectory: true)
    precondition(TestPathGuard.permits(path), "Tests must inject an invented app-data folder")
    return path
  }
  public static func summaryCodexHome(in appData: URL) -> URL {
    appData.appendingPathComponent("codex", isDirectory: true)
  }
}
public enum FileVaultStatus: String { case on, off, unknown }
public protocol FileVaultStatusSource {
  func fileVaultStatus() -> FileVaultStatus
}
public enum StorageSecurityFailure: String {
  case backupExclusionFailed = "backup_exclusion_failed"
  case backupExclusionSkippedOverride = "backup_exclusion_skipped_override"
}
public struct StorageSecurityHealth {
  public var backupExclusionFailure: StorageSecurityFailure?
  public init(backupExclusionFailure: StorageSecurityFailure? = nil) {
    self.backupExclusionFailure = backupExclusionFailure
  }
}
public struct DeviceSecurityHealth {
  public var fileVault: FileVaultStatus = .unknown
  public var backupExclusionFailure: StorageSecurityFailure?
  public init() {}
}

/// Enabled by the test runner itself, without relying on an opt-in environment variable.
public enum TestPathGuard {
  public static var active: Bool {
    CommandLine.arguments.contains { $0.contains(".xctest") }
      || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
      || NSClassFromString("XCTest.XCTestCase") != nil
  }
  public static func permits(_ url: URL, testing: Bool = active,
    userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
    guard testing else { return true }
    let reserved = userHome.appendingPathComponent("Library/Application Support/ActivityProbe")
    return (try? !FileLocation.contains(url, in: reserved)) ?? false
  }
}
