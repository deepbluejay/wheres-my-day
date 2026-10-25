import Core
import Foundation
import Storage

extension RetainedCommands {
  static func axProbe(_ args: [String], paths: AppPaths, now: Int) throws -> AppCommandResult {
    let storage = try ActivityStorage(url: paths.database, appDataDirectory: paths.appData, readOnly: args == ["status"], databaseScope: paths.databaseScope)
    if args == ["off"] {
      try storage.disableAXProbe(at: now)
      return AppCommandResult(0, "ax_probe_disabled")
    }
    if args == ["status"] { return AppCommandResult(0, try storage.axProbeStatus()) }
    guard args == ["on"] else { throw ActivityQueryError.invalidArguments }
    let run = try storage.enableAXProbe(at: now)
    return AppCommandResult(0, "ax_probe_enabled run=\(run.id) start=\(run.start)")
  }
  static func forgetAXProbe(_ args: [String], paths: AppPaths) throws -> AppCommandResult {
    guard args.count == 1 || (args.count == 3 && args[1] == "--confirm") else { throw ActivityQueryError.invalidArguments }
    let storage = try ActivityStorage(url: paths.database, appDataDirectory: paths.appData,
      readOnly: args.count == 1, databaseScope: paths.databaseScope)
    let preview = try storage.previewAXProbeDeletion(run: args[0])
    if args.count == 3 {
      let result = try storage.deleteAXProbe(run: args[0], confirmation: args[2])
      return AppCommandResult(0, "Probe forgotten. wal_truncated=\(result.walTruncated ? 1 : 0)\nOrdinary history retained. Existing unmanaged copies are not erased.")
    }
    let counts = preview.counts.keys.sorted().map { "\($0): \(preview.counts[$0]!)" }.joined(separator: "\n")
    return AppCommandResult(0, "Preview only. Nothing deleted.\n" + counts
      + "\nRun metadata is cleared except its content-free cancellation barrier.\nOrdinary history retained. Existing unmanaged copies are not erased.\nDeletion is immediate and irreversible. A code proves freshness, not human approval.\nConfirm: privacy forget --probe-run \(args[0]) --confirm \(preview.confirmation)")
  }
}
