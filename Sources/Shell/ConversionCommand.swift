import Core
import Darwin
import Foundation
import Storage

public enum ConversionCommand {
  public static let help = """
    Usage: convert --source <frozen-db> --destination <new-db> --app-data <directory> --old-settings <directory> --recording-intent <on|off> [--live-switch]
    Precondition: no other process may change the source, destination, app-data or old-settings directories during conversion or isolated commands.
    """
  public static func run(_ arguments: [String], userHome: URL, appBinary: URL) -> AppCommandResult {
    if arguments == ["--help"] { return AppCommandResult(0, help) }
    do {
      var values: [String: String] = [:], live = false, index = 0
      let required = ["--source", "--destination", "--app-data", "--old-settings", "--recording-intent"]
      while index < arguments.count {
        let flag = arguments[index]
        if flag == "--live-switch" { guard !live else { throw AppCommandError.arguments }; live = true; index += 1; continue }
        guard required.contains(flag), values[flag] == nil, index + 1 < arguments.count,
          !arguments[index + 1].hasPrefix("--") else { throw AppCommandError.arguments }
        values[flag] = arguments[index + 1]; index += 2
      }
      guard required.allSatisfy({ values[$0] != nil }), ["on", "off"].contains(values["--recording-intent"]!) else { throw AppCommandError.arguments }
      for flag in required where flag != "--recording-intent" { try FileLocation.validate(values[flag]!) }
      try FileLocation.validate(userHome)
      let sourceInput = URL(fileURLWithPath: values["--source"]!)
      let source = sourceInput
      let destinationInput = URL(fileURLWithPath: values["--destination"]!)
      // Resolve only the parent so a linked database leaf cannot become an approved path.
      let destination = try CanonicalPath.resolve(destinationInput.deletingLastPathComponent()).appendingPathComponent(destinationInput.lastPathComponent)
      let appData = try CanonicalPath.resolve(URL(fileURLWithPath: values["--app-data"]!))
      let settings = try CanonicalPath.resolve(URL(fileURLWithPath: values["--old-settings"]!))
      let defaults = try CanonicalPath.resolve(userHome.appendingPathComponent("Library/Application Support/ActivityProbe"))
      let processHome = try CanonicalPath.resolve(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ActivityProbe"))
      guard try !FileLocation.same(source, destination) else { throw AppCommandError.unsafePath }
      if !live {
        // Before the live gate, all four explicit paths must be confined to a temporary rehearsal.
        let temporary = try CanonicalPath.resolve(URL(fileURLWithPath: "/tmp"))
        for path in [appData, settings] {
          guard try FileLocation.contains(path, in: temporary, includingRoot: false, granting: true),
            try !FileLocation.contains(path, in: defaults), try !FileLocation.contains(path, in: processHome) else { throw AppCommandError.unsafePath }
        }
      }
      let scope: DatabaseOpenScope = live ? .liveSwitch : .directory(URL(fileURLWithPath: "/tmp"), excluding: [defaults, processHome])
      try scope.validatePath(destination)
      let settingsDirectory = try OperationalDirectory(settings)
      for leaf in ["privacy.json", "settings.json", "pause-until", "pause-kept"] { try settingsDirectory.validate(leaf, allowUnreadableDirectory: true) }
      try ActivityStorage.validateOldConversionSource(source, scope: scope)
      try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      let paths = AppPaths(userHome: userHome, appData: appData, database: destination, appBinary: appBinary, queryHelper: appBinary, databaseScope: scope)
      // Keep starts excluded until the destination is checkpointed and the manifest is complete.
      let owner = try RecorderStartupGuard(paths: paths)
      return try withExtendedLifetime((owner, settingsDirectory)) {
        let store = try ActivityStorage(url: destination, appDataDirectory: appData, databaseScope: scope)
        let converted = try store.convertOldDatabase(at: source, verifyFrozenContent: true)
        guard converted.finished else { throw AppCommandError.arguments }
        let intent = values["--recording-intent"] == "on"
        _ = try store.importOldSettings(privacyFile: settings.appendingPathComponent("privacy.json"),
          generalFile: settings.appendingPathComponent("settings.json"),
          pauseUntilFile: settings.appendingPathComponent("pause-until"), pauseKeptFile: settings.appendingPathComponent("pause-kept"), recordingIntent: intent, approvedDirectory: settingsDirectory)
        var manifest = try store.conversionManifest(source: source)
        let settingsLines = try store.conversionSettingsManifest(privacyFile: settings.appendingPathComponent("privacy.json"),
          generalFile: settings.appendingPathComponent("settings.json"), pauseUntilFile: settings.appendingPathComponent("pause-until"),
          pauseKeptFile: settings.appendingPathComponent("pause-kept"), recordingIntent: intent, approvedDirectory: settingsDirectory)
        // Repeating the same operator command must carry no further rows or change settings.
        let repeated = try store.convertOldDatabase(at: source, verifyFrozenContent: true)
        let idempotent = repeated.tables.values.reduce(0) { $0 + $1.carried + $1.refused + $1.notCarried }
        manifest = ConversionManifest(lines: manifest.lines + settingsLines + [
          ConversionManifestLine(metric: "rerun.processed", expected: 0, actual: idempotent)])
        try store.finishConversion()
        return AppCommandResult(manifest.passed ? 0 : 1, manifest.text)
      }
    } catch { return AppCommandResult(1, "conversion_refused") }
  }
}
