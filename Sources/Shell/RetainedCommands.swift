import AppKit
import Core
import Foundation
import Storage

public struct CommandApplicationIdentity {
  public var bundleID: String
  public var names: [String]
  public init(bundleID: String, names: [String]) { self.bundleID = bundleID; self.names = names }
}
public enum RetainedCommands {
  public static func mask(_ data: Data) -> AppCommandResult {
    guard let strings = try? JSONDecoder().decode([String].self, from: data),
      let result = try? JSONEncoder().encode(strings.map { Redaction.apply($0).text }) else { return AppCommandResult(1, "") }
    return AppCommandResult(0, String(decoding: result, as: UTF8.self))
  }
  public static func run(_ arguments: [String], paths: AppPaths, input: Data = Data(),
    now: Int = Int(Date().timeIntervalSince1970), calendar: Calendar = .current,
    applications: [CommandApplicationIdentity] = [], control: RecorderControl = RecorderControl()) -> AppCommandResult {
    do {
      switch arguments.first {
      case "stop" where arguments.count == 1: return try control.stop(paths: paths)
      case "status" where arguments.count == 1: return try control.status(paths: paths)
      case "ax-probe" where arguments.count >= 2:
        return try axProbe(Array(arguments.dropFirst()), paths: paths, now: now)
      case "privacy" where arguments.count >= 2:
        switch arguments[1] {
        case "mask" where arguments.count == 2: return mask(input)
        case "forget": return try forget(Array(arguments.dropFirst(2)), paths: paths, now: now, zone: calendar.timeZone)
        case "verdicts" where arguments.count == 2:
          let settings = try ActivityStorage(url: paths.database, appDataDirectory: paths.appData, readOnly: true, databaseScope: paths.databaseScope).settings()
          let historical = HistoricalApplicationPrivacy(applications: settings.excludedApps + [AppPaths.bundleID])
          func hidden(_ identity: String) -> Bool {
            identity.lowercased() == AppPaths.bundleID.lowercased() || settings.excludesApplication(identity)
          }
          var bundles: [String: Set<String>] = [:], known = Set<String>()
          for app in applications {
            let id = app.bundleID.lowercased(); known.insert(id)
            for name in app.names + [id] { bundles[name.lowercased(), default: []].insert(id) }
          }
          let text = String(decoding: input, as: UTF8.self)
          var lines = text.components(separatedBy: "\n"); if lines.last == "" { lines.removeLast() }
          return AppCommandResult(0, lines.map { line in
            let name = line.components(separatedBy: "\t")[0].lowercased()
            let matches = bundles[name] ?? []
            let refused = matches.contains(where: hidden) || hidden(name)
              || (HistoricalApplicationPrivacy.masked(name) && historical.contains(name))
            return refused ? "hidden app"
              : !matches.isEmpty || known.contains(name) ? "open" : "open unmatched"
          }.joined(separator: "\n"))
        default: throw AppCommandError.arguments
        }
      case "selftest" where arguments.count == 1, "leaktest" where arguments.count == 1:
        return try StorageCommandTests.run(parent: paths.appData, leakOnly: arguments[0] == "leaktest", scope: paths.databaseScope)
      default: throw AppCommandError.arguments
      }
    } catch AppCommandError.time { return AppCommandResult(1, "Refused: invalid or ambiguous local time, use Unix seconds. Nothing deleted.") }
    catch AppCommandError.future { return AppCommandResult(1, "Refused: future range. Nothing deleted.") }
    catch AppCommandError.wide { return AppCommandResult(1, "Refused: ranges over 24 hours require --allow-over-24h. Nothing deleted.") }
    catch AppCommandError.empty { return AppCommandResult(1, "Refused: empty range or no rows to delete. Nothing deleted.") }
    catch AppCommandError.stale { return AppCommandResult(1, "Refused: wrong or stale confirmation. Nothing deleted.") }
    catch { return AppCommandResult(1, "command_refused") }
  }
  private static func forget(_ arguments: [String], paths: AppPaths, now: Int, zone: TimeZone) throws -> AppCommandResult {
    if arguments.first == "--probe-run" { return try forgetAXProbe(Array(arguments.dropFirst()), paths: paths) }
    let request = try ForgetCommandRequest.parse(arguments, now: now, zone: zone)
    let store = try ActivityStorage(url: paths.database, appDataDirectory: paths.appData, readOnly: request.confirmation == nil, databaseScope: paths.databaseScope)
    let preview = try store.previewDeletion(in: request.range, allowOver24Hours: request.allowOver24Hours)
    guard preview.counts.values.reduce(0, +) > 0 else { throw AppCommandError.empty }
    if let code = request.confirmation {
      guard code == preview.confirmation else { throw AppCommandError.stale }
      let result = try store.deleteRecords(in: request.range, confirmation: code, allowOver24Hours: request.allowOver24Hours)
      return AppCommandResult(0, "Forgot [\(request.range.start),\(request.range.end)): \(result.preview.counts.values.reduce(0,+)) rows deleted.\nwal_truncated=\(result.walTruncated ? 1 : 0)\n" + retained + "\nDeletion is immediate and irreversible. No undo.")
    }
    var lines = ["Preview only. Nothing deleted.", "Range: [\(ForgetCommandRequest.local(request.range.start, zone: zone)), \(ForgetCommandRequest.local(request.range.end, zone: zone)))", "Unix seconds: [\(request.range.start),\(request.range.end))"]
    for table in ["samples", "evidence", "intervals", "ax_probe_attempts", "ax_probe_review", "agent_log_events", "git_repositories", "git_working_folders", "git_refs", "git_commits", "git_commit_refs", "git_files", "git_commit_text", "git_value_text"] { lines.append("\(table): \(preview.counts[table, default: 0]) rows") }
    if let extent = preview.intervalExtent { lines.append("Whole interval extent (Unix seconds): [\(extent.start),\(extent.end))") }
    lines += ["Overlapping intervals are removed whole, including portions outside this range.", retained,
      "Deletion is immediate and irreversible. No undo. A code validates the snapshot, not human approval.",
      "Confirmation code: \(preview.confirmation)",
      "Confirm: privacy forget \(request.range.start) \(request.range.end)" + (request.allowOver24Hours ? " --allow-over-24h" : "") + " --confirm \(preview.confirmation)"]
    return AppCommandResult(0, lines.joined(separator: "\n"))
  }
  private static let retained = "Not removed: settings, log recording history, reading positions, numeric model call costs and outer ranges, existing database copies and source logs. Deleted ranges and source identities block resurrection."
  /// Bundle metadata only. Never reads a window, starts an app or asks for permission.
  public static func applicationIdentities(paths: AppPaths) throws -> [CommandApplicationIdentity] {
    var urls = Set<URL>()
    let settings = try ActivityStorage(url: paths.database, appDataDirectory: paths.appData, readOnly: true, databaseScope: paths.databaseScope).settings()
    for directory in ["/Applications", "/System/Applications", paths.userHome.appendingPathComponent("Applications").path] {
      if let enumerator = FileManager.default.enumerator(at: URL(fileURLWithPath: directory), includingPropertiesForKeys: nil) {
        for case let url as URL in enumerator where url.pathExtension == "app" { urls.insert(url); enumerator.skipDescendants() }
      }
    }
    for id in settings.excludedApps + [AppPaths.bundleID] {
      if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { urls.insert(url) }
    }
    for app in NSWorkspace.shared.runningApplications { if let url = app.bundleURL { urls.insert(url) } }
    return urls.compactMap { url in
      guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return nil }
      var names = [url.deletingPathExtension().lastPathComponent]
      for info in [bundle.infoDictionary, bundle.localizedInfoDictionary] {
        for field in ["CFBundleName", "CFBundleDisplayName", "CFBundleExecutable"] { if let name = info?[field] as? String { names.append(name) } }
      }
      for language in bundle.localizations {
        if let file = bundle.path(forResource: "InfoPlist", ofType: "strings", inDirectory: nil, forLocalization: language),
          let bytes = try? Data(contentsOf: URL(fileURLWithPath: file)),
          let info = (try? PropertyListSerialization.propertyList(from: bytes, format: nil)) as? [String: Any] {
          for field in ["CFBundleName", "CFBundleDisplayName", "CFBundleExecutable"] {
            if let name = info[field] as? String { names.append(name) }
          }
        }
      }
      return CommandApplicationIdentity(bundleID: id, names: names)
    }
  }
}
