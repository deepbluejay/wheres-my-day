import Core
import Darwin
import Foundation
import Inbound
import Shell
import Storage
import XCTest

/// The product's adapters, `RecorderAdapters.mac`, as the recorder entry uses them: no test hook, nothing
/// attached before the recording check, and both stop signals taken over by the main queue.
final class RecorderAdaptersTests: XCTestCase {
  // Ideal: the product starts no test hook after the recorder starts.
  func testProductAdaptersHaveNoRunningHook() {
    XCTAssertNil(RecorderAdapters.mac.running)
  }

  // Ideal: a start that finds recording off asks for no clock, collector, process source, FileVault reader,
  // session observer, snapshot, signal handler or hook; every one is created only past that check.
  func testRecorderStartWithRecordingOffAttachesNothing() throws {
    let folder = URL(fileURLWithPath: "/tmp").appendingPathComponent("recorder-adapters-\(UUID().uuidString)")
    let data = folder.appendingPathComponent("app-data")
    try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let isolated = ["--isolated-root", folder.path, "--app-data", data.path]
    let environment = ["ACTIVITYPROBE_DB": folder.appendingPathComponent("invented.sqlite").path]
    func run(_ arguments: [String], adapters: RecorderAdapters = .mac) -> Int32 {
      ActivityProbeEntry.run(arguments: arguments + isolated, environment: environment,
        userHome: folder.appendingPathComponent("home"), appBinary: folder.appendingPathComponent("bin/ActivityProbe"), adapters: adapters)
    }
    XCTAssertEqual(run(["stop"]), 0)
    var calls: [String] = []
    func count<T>(_ name: String, _ value: T) -> T { calls.append(name); return value }
    let adapters = RecorderAdapters(clock: { count("clock", WallRecorderClock()) },
      processes: { count("processes", NoAgentLogProcesses()) },
      fileVault: { count("fileVault", UnusedFileVault()) },
      sources: { count("sources", RecorderAdapters.Sources(input: UnusedSources(), front: UnusedSources(), secure: UnusedSources(),
        awake: UnusedSources(), screen: UnusedSources(), startInput: {}, stopInput: {})) },
      observeSession: { _ in count("observeSession", nil) }, initialSnapshot: { count("initialSnapshot", RecorderSessionSnapshot()) },
      signals: { _ in count("signals", []) }, running: { _, stop in calls.append("running"); stop() })
    XCTAssertEqual(run(["collect"], adapters: adapters), 0)
    XCTAssertEqual(calls, [])
    let store = try ActivityStorage(url: URL(fileURLWithPath: environment["ACTIVITYPROBE_DB"]!), appDataDirectory: data,
      readOnly: true, databaseScope: .directory(folder))
    XCTAssertFalse(try store.settings().recordingEnabled, "the start found recording off")
  }

  // Ideal: the refusing adapters fail a collect that gets past the recording check, and stop it, instead of
  // letting it run on. This is what a regressed stop would leave; only invented collectors are attached.
  func testRefusingAdaptersFailACollectThatFindsRecordingOn() throws {
    let folder = URL(fileURLWithPath: "/tmp").appendingPathComponent("recorder-adapters-\(UUID().uuidString)")
    let data = folder.appendingPathComponent("app-data")
    try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let environment = ["ACTIVITYPROBE_DB": folder.appendingPathComponent("invented.sqlite").path]
    var status: Int32 = -1
    let options = XCTExpectedFailure.Options(); options.isStrict = true
    XCTExpectFailure("a collect with recording on asks for the adapters", options: options) {
      status = ActivityProbeEntry.run(arguments: ["collect", "--isolated-root", folder.path, "--app-data", data.path],
        environment: environment, userHome: folder.appendingPathComponent("home"),
        appBinary: folder.appendingPathComponent("bin/ActivityProbe"), adapters: .refusing("the recording-on collect"))
    }
    XCTAssertEqual(status, 0, "the refusing hook stopped the recorder")
  }

  // Ideal: SIGTERM and SIGINT are both ignored by default handling and both reach the stop on the main queue.
  func testProductSignalsIgnoreBothSignalsAndDeliverThemToTheStop() throws {
    let numbers = [SIGTERM, SIGINT]
    var saved = numbers.map { _ in sigaction() }
    for (index, number) in numbers.enumerated() {
      XCTAssertEqual(sigaction(number, nil, &saved[index]), 0)
      // Start from the default disposition, so the adapter alone must ignore it.
      var initial = sigaction(); initial.__sigaction_u.__sa_handler = SIG_DFL
      XCTAssertEqual(sigaction(number, &initial, nil), 0)
    }
    var stops = 0, offMain = 0
    // The stop drains the recorder, which belongs to the main queue: a handler on any other queue is refused here.
    let installed = RecorderAdapters.mac.signals { if !Thread.isMainThread { offMain += 1 }; stops += 1 }
    defer {
      for case let source as DispatchSourceSignal in installed { source.cancel() }
      for (index, number) in numbers.enumerated() { sigaction(number, &saved[index], nil) }
    }
    let sources = installed.compactMap { $0 as? DispatchSourceSignal }
    XCTAssertEqual(installed.count, 2)
    XCTAssertEqual(sources.count, 2)
    XCTAssertEqual(Set(sources.map { Int32($0.handle) }), Set(numbers))
    for (index, number) in numbers.enumerated() {
      var current = sigaction()
      XCTAssertEqual(sigaction(number, nil, &current), 0)
      let ignored = unsafeBitCast(current.__sigaction_u.__sa_handler, to: Int.self) == unsafeBitCast(SIG_IGN, to: Int.self)
      XCTAssertTrue(ignored, "signal \(number) is ignored")
      // Sent only once ignored: a default disposition would end this test process.
      guard ignored else { continue }
      kill(getpid(), number)
      let deadline = Date().addingTimeInterval(5)
      while stops < index + 1, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
      XCTAssertEqual(stops, index + 1, "signal \(number) reached the stop")
    }
    XCTAssertEqual(offMain, 0, "every stop ran on the main queue")
  }
}

extension RecorderAdapters {
  /// For a collect that must find recording off: every adapter asked for fails the test, and a recorder that
  /// started anyway is stopped by its own hook at once, so the test neither hangs nor attaches a Mac collector.
  static func refusing(_ context: String, file: StaticString = #filePath, line: UInt = #line) -> RecorderAdapters {
    func refuse<T>(_ name: String, _ value: T) -> T { XCTFail("\(context) asked for \(name)", file: file, line: line); return value }
    return RecorderAdapters(clock: { refuse("the clock", WallRecorderClock()) },
      processes: { refuse("the agent process source", NoAgentLogProcesses()) },
      fileVault: { refuse("the FileVault reader", UnusedFileVault()) },
      sources: { refuse("the collectors", Sources(input: UnusedSources(), front: UnusedSources(), secure: UnusedSources(),
        awake: UnusedSources(), screen: UnusedSources(), startInput: {}, stopInput: {})) },
      observeSession: { _ in refuse("the session observer", nil) }, initialSnapshot: { refuse("the session snapshot", RecorderSessionSnapshot()) },
      signals: { _ in refuse("the signal handlers", []) }, running: { _, stop in refuse("a running recorder", ()); stop() })
  }
}

/// Collectors that must never be asked: the start with recording off returns before using any of them.
private final class UnusedSources: InputCountSource, FrontWindowSource, SecureInputSource, DisplayAwakeSource, ScreenTextSource {
  func takeInput() -> SourceReading<InputCounts> { XCTFail("input read"); return .value(InputCounts()) }
  func frontApplication() -> FrontObservation { XCTFail("front window read"); return FrontObservation(bundleID: "", app: "", title: "") }
  func details(for application: FrontObservation) -> FrontObservation { XCTFail("window details read"); return application }
  func secureInput() -> SourceReading<Bool> { XCTFail("secure input read"); return .value(false) }
  func keepingDisplayAwake(processID: Int32) -> SourceReading<Bool> { XCTFail("display read"); return .value(false) }
  func captureText(window: WindowIdentity, permitted: @escaping (CaptureCheck) -> Bool,
    completion: @escaping (SourceReading<String>) -> Void) { XCTFail("screen read"); completion(.value("")) }
}

private final class UnusedFileVault: FileVaultStatusSource {
  func fileVaultStatus() -> FileVaultStatus { XCTFail("FileVault read"); return .on }
}
