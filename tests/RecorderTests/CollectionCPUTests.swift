import Core
import Darwin
import Foundation
import Shell
import XCTest
@testable import Storage

/// Calls the recorder's probe gate as often as an invented AX traversal would, then
/// delivers invented OCR and AX nodes. No Accessibility API is used.
final class InventedTraversalScreen: AXProbeScreenSource {
  var gateCalls = 2511
  /// Called with each gate call's index, so writes can land between gate calls as they do live.
  var between: (Int) -> Void = { _ in }
  var pending: [() -> Void] = []
  var round = 0
  func invalidateProbe() {}
  func captureText(window: WindowIdentity, permitted: @escaping (CaptureCheck) -> Bool,
    completion: @escaping (SourceReading<String>) -> Void) { completion(.value("Invented OCR line")) }
  func captureText(window: WindowIdentity, probe: AXProbeRequest, permitted: @escaping (CaptureCheck) -> Bool,
    probePermitted: @escaping () -> Bool, probeBegin: @escaping () -> AXProbeStatus?,
    probeEnd: @escaping (AXProbeResult) -> Void, probeWatchdogOCR: @escaping (AXProbePair, Bool) -> Void, probeRefused: @escaping () -> Void, probeCompletion: @escaping (AXProbePair) -> Void,
    completion: @escaping (SourceReading<String>) -> Void) {
    round += 1
    let round = self.round, gateCalls = self.gateCalls, between = self.between
    pending.append {
      _ = permitted(.beforeImage)
      guard probeBegin() == nil else { completion(.absent(.policyRefused)); return }
      for index in 0..<gateCalls { between(index); guard probePermitted() else { break } }
      var ax = AXProbeResult(status: .completed)
      // A third of the invented nodes change between captures; the rest deduplicate.
      ax.nodes = (0..<240).map { index in
        let text = index % 3 == 0 ? "Invented changing line \(index) round \(round)" : "Invented stable line \(index)"
        return AXProbeNode(nodeID: index, role: "AXStaticText", attributes: [AXProbeText(attribute: "AXValue", text: text)])
      }
      ax.start = 100; ax.end = 100.2; ax.identity = "geometry_validated"; ax.workerWall = 0.2
      probeEnd(ax)
      let ocr = "Invented OCR text for round \(round)"
      completion(.value(ocr))
      probeCompletion(AXProbePair(request: probe, ax: ax, ocrStatus: "completed", ocr: ocr,
        imageRequest: 100, imageReturn: 100.1, ocrCompletion: 101))
    }
  }
}

final class CollectionCPUTests: XCTestCase {
  private static func cpu() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
  }

  /// Owner-rate invented workload, measured only with ACTIVITYPROBE_COLLECTION_CPU=1.
  /// One tick per second with person input (one observation and one sample per second,
  /// sample batches every 5 s), a screen capture with an AX probe every 15 s, and
  /// ACTIVITYPROBE_COLLECTION_CPU_GATES probe gate calls per capture (default 2511).
  /// As live, writes land between gate calls: every ACTIVITYPROBE_COLLECTION_CPU_OTHER_EVERY
  /// calls (default 250) a commit by another connection, as the collection and probe content
  /// writers make, and every ACTIVITYPROBE_COLLECTION_CPU_OWN_EVERY calls (default 500) a
  /// counter write through the recorder's own connection. 0 turns either off.
  func testOwnerRateCollectionAndProbeCost() throws {
    let environment = ProcessInfo.processInfo.environment
    try XCTSkipUnless(environment["ACTIVITYPROBE_COLLECTION_CPU"] == "1")
    let minutes = environment["ACTIVITYPROBE_COLLECTION_CPU_MINUTES"].flatMap(Int.init) ?? 10
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    // The production recorder role: its connection never waits on a busy database.
    let store = try ActivityStorage(url: folder.appendingPathComponent("invented.sqlite"), appDataDirectory: folder, role: .recorder, databaseScope: .directory(folder))
    try store.saveSettings(StorageSettings(), at: 0)
    _ = try store.enableAXProbe(at: 10000)
    let clock = FakeClock(), sources = FakeSources(), screen = InventedTraversalScreen()
    sources.clock = clock
    screen.gateCalls = environment["ACTIVITYPROBE_COLLECTION_CPU_GATES"].flatMap(Int.init) ?? 2511
    let otherEvery = environment["ACTIVITYPROBE_COLLECTION_CPU_OTHER_EVERY"].flatMap(Int.init) ?? 250
    let ownEvery = environment["ACTIVITYPROBE_COLLECTION_CPU_OWN_EVERY"].flatMap(Int.init) ?? 500
    let other = try ActivityStorage(url: folder.appendingPathComponent("invented.sqlite"), appDataDirectory: folder, databaseScope: .directory(folder))
    let runID = try store.settings().axProbeRun!.id
    screen.between = { index in
      if otherEvery > 0, index % otherEvery == otherEvery - 1 { try? other.countAXProbeEvent(runID: runID, event: .eligible) }
      if ownEvery > 0, index % ownEvery == ownEvery - 1 { try? store.countAXProbeEvent(runID: runID, event: .eligible) }
    }
    let loop = RecorderLoop(clock: clock, input: sources, front: sources, secure: sources, awake: sources,
      screen: screen, storage: store, maintenanceStorage: store, ownBundleID: "invented.own")
    func drain() {
      let drained = expectation(description: "probe writer drained")
      loop.finishMaintenance { drained.fulfill() }
      wait(for: [drained], timeout: 120)
    }
    func second() {
      clock.now += 1
      sources.front.title = "Invented title \(clock.now / 15)"
      loop.tick()
      let work = screen.pending; screen.pending.removeAll()
      for item in work { item() }
      // Pace like one-second ticks: let the collection writer finish this second's
      // record and the probe writer its capture, so busy contention drops no work.
      Thread.sleep(forTimeInterval: 0.05)
      if !work.isEmpty { drain() }
    }
    // Warm-up minute: schema, caches and first blobs are not part of the steady rate.
    for _ in 0..<60 { second() }
    loop.flush(); drain()
    PolicyReadStats.counting = true
    defer { PolicyReadStats.counting = false }
    _ = PolicyReadStats.take()
    let start = Self.cpu(), began = ProcessInfo.processInfo.systemUptime
    for _ in 0..<(minutes * 60) { second() }
    // Busy retries leave ready records in the spool; finish them inside the measurement.
    func spooled() -> Int { (try? FileManager.default.contentsOfDirectory(atPath: store.collectionDirectory.path).filter { $0.hasSuffix(".json") }.count) ?? 0 }
    for _ in 0..<200 where spooled() > 0 { loop.flush(); Thread.sleep(forTimeInterval: 0.01) }
    loop.flush(); drain()
    let cpu = Self.cpu() - start, wall = ProcessInfo.processInfo.systemUptime - began
    let reads = PolicyReadStats.take().sorted { $0.key < $1.key }.map { "\($0.key):\($0.value.hits)/\($0.value.hits + $0.value.misses)" }
    loop.stop(); drain()
    let attempts = try store.connection.integer("SELECT count(*) FROM ax_probe_attempts WHERE json_extract(payload,'$.ax.status')='completed'")
    let observations = try store.connection.integer("SELECT count(*) FROM sample_observations")
    let evidence = try store.connection.integer("SELECT count(*) FROM evidence")
    var statuses: [String] = []
    try store.connection.rows("SELECT s||':'||count(*) FROM (SELECT json_extract(payload,'$.ax.status') AS s FROM ax_probe_attempts) GROUP BY s") { statuses.append(SQLiteConnection.text($0, 0)) }
    let spool = spooled()
    print("COLLECTION-CPU statuses=\(statuses) spool=\(spool) health=\(loop.health)")
    let line = "COLLECTION-CPU minutes=\(minutes) gates=\(screen.gateCalls) cpuSeconds=\(cpu) cpuPerMinute=\(cpu / Double(minutes)) wall=\(wall) completedProbes=\(attempts) observations=\(observations) evidence=\(evidence) policyHits=\(reads)"
    print(line)
    if let log = environment["ACTIVITYPROBE_COLLECTION_CPU_LOG"] {
      try? (line + "\n").appendingFile(log)
    }
    XCTAssertGreaterThan(attempts, 0)
    XCTAssertGreaterThan(observations, minutes * 50)
  }
}

private extension String {
  func appendingFile(_ path: String) throws {
    if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
    let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
    defer { try? handle.close() }
    handle.seekToEndOfFile(); handle.write(Data(utf8))
  }
}
