import Core
import Foundation
import Storage

/// Synthetic CLI assurance survives removal of the old executable and needs no OS adapters.
enum StorageCommandTests {
  static func run(parent: URL, leakOnly: Bool, scope: DatabaseOpenScope) throws -> AppCommandResult {
    let folder = parent.appendingPathComponent("command-test-" + UUID().uuidString)
    try scope.validatePath(folder.appendingPathComponent("test.sqlite"))
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = try ActivityStorage(url: folder.appendingPathComponent("test.sqlite"), appDataDirectory: folder, databaseScope: scope)
    var failures = 0
    func check(_ condition: Bool) { if !condition { failures += 1 } }
    let secret = "password=invented-secret", range = TimeRange(60, 120)
    _ = try store.appendSamples([TimeSample(ts: 61, bundleID: "invented.app", app: "Invented", window: secret, keys: 1),
      TimeSample(ts: 62, bundleID: "invented.excluded", window: "invented hidden", documentKey: "invented hidden", excluded: true)])
    _ = try store.appendScreenCapture(text: secret, at: 63, source: "invented.app", knownKeys: [])
    _ = try store.appendEvidence([EvidenceText(ts: 64, kind: .prompt, source: "invented.app", sourceID: "invented-id", text: secret)])
    _ = try store.appendIntervals([NamedInterval(range: range, name: secret, kind: .work)])
    check(try store.samples(in: range).allSatisfy { !$0.window.contains("invented-secret") && (!$0.excluded || ($0.window.isEmpty && $0.documentKey.isEmpty)) })
    check(try store.evidence(in: range).allSatisfy { !$0.text.contains("invented-secret") })
    check(try store.intervals(in: range).allSatisfy { !$0.name.contains("invented-secret") })
    let preview = try store.previewDeletion(in: range)
    _ = try store.appendSamples([TimeSample(ts: 65)])
    do { _ = try store.deleteRecords(in: range, confirmation: preview.confirmation); check(false) } catch {}
    check(try store.samples(in: range).count == 3)
    var settings = try store.settings(); settings.recordingEnabled = false; settings.pausedUntil = 500
    try store.saveSettings(settings, at: 100)
    let savedSettings = try store.settings(), history = try store.logRecordingHistory()
    try store.saveLogPosition(LogPosition(path: "invented-log", device: 1, inode: 2, offset: 123, state: "", seenAt: 100))
    _ = try store.appendModelCall(ModelCall(ts: 100, range: range, model: "invented", inputTokens: 123, cachedTokens: 23, outputTokens: 4, succeeded: true))
    check(try store.appendSamples([TimeSample(ts: 66)]).refused == 1)
    let fresh = try store.previewDeletion(in: range)
    _ = try store.deleteRecords(in: range, confirmation: fresh.confirmation)
    check(try store.samples(in: range).isEmpty && store.evidence(in: range).isEmpty && store.intervals(in: range).isEmpty)
    check(try store.appendSamples([TimeSample(ts: 61)]).refused == 1)
    check(try store.appendEvidence([EvidenceText(ts: 180, kind: .prompt, source: "invented.app", sourceID: "invented-id", text: "invented")]).refused == 1)
    _ = try store.cleanRetention(at: 10000000)
    check(try store.settings() == savedSettings && store.logRecordingHistory() == history)
    check(try store.logPosition(path: "invented-log")?.offset == 123)
    check(try store.modelCalls(in: range).first?.inputTokens == 123)
    if !leakOnly {
      for args in [["0", "0"], ["120", "60"], ["60", "1001"], ["0", "86401"]] {
        do { _ = try ForgetCommandRequest.parse(args, now: 1000, zone: TimeZone(secondsFromGMT: 0)!); check(false) } catch {}
      }
    }
    return AppCommandResult(failures == 0 ? 0 : 1, failures == 0 ? "all passed" : "failed=\(failures)")
  }
}
