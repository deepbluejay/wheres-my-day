import Core
import Darwin
import Foundation
import Shell
import Storage
import XCTest

final class OperatorCommandTests: XCTestCase {
  var root: URL!, paths: AppPaths!
  override func setUpWithError() throws {
    root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ACTIVITYPROBE_TEST_ROOT"] ?? "/tmp").appendingPathComponent("commands-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    paths = AppPaths(userHome:root.appendingPathComponent("person"),appData:root,database:root.appendingPathComponent("new.sqlite"),appBinary:root.appendingPathComponent("ActivityProbe"),queryHelper:root.appendingPathComponent("helper"))
    _ = try storage()
  }
  override func tearDownWithError() throws { try FileManager.default.removeItem(at:root) }
  func storage() throws -> ActivityStorage { try ActivityStorage(url:paths.database,appDataDirectory:paths.appData, databaseScope: paths.databaseScope) }
  func run(_ args: [String], input: String = "", calendar: Calendar = Calendar(identifier:.gregorian)) -> AppCommandResult {
    RetainedCommands.run(args, paths:paths,input:Data(input.utf8),now:400000,calendar:calendar)
  }
  func code(_ output: String) throws -> String { try XCTUnwrap(output.components(separatedBy:"\n").first { $0.hasPrefix("Confirmation code: ") }).replacingOccurrences(of:"Confirmation code: ",with:"") }

  // Ideal: a preview cannot delete; confirmations bind the exact database, range and current rows.
  // Invalid, future, empty, ambiguous and oversized requests must leave records and tombstones alone.
  func testForgetPreviewStaleThenFreshConfirmationAndResurrectionGuard() throws {
    let store = try storage()
    _ = try store.appendSamples([TimeSample(ts:61,keys:1)])
    _ = try store.appendIntervals([NamedInterval(range:TimeRange(0,180),name:"Invented",kind:.work)])
    let before = try store.samples(in:TimeRange(0,300)), preview = run(["privacy","forget","60","120"])
    XCTAssertEqual(preview.status,0); XCTAssertTrue(preview.output.contains("including portions outside"))
    XCTAssertEqual(try store.samples(in:TimeRange(0,300)),before); XCTAssertEqual(try store.deletionsSoFar(),0)
    let old = try code(preview.output)
    _ = try store.appendSamples([TimeSample(ts:62)])
    XCTAssertEqual(run(["privacy","forget","60","120","--confirm",old]).status,1)
    XCTAssertEqual(try store.samples(in:TimeRange(0,300)).count,2); XCTAssertEqual(try store.deletionsSoFar(),0)
    let fresh = try code(run(["privacy","forget","60","120"]).output)
    XCTAssertEqual(run(["privacy","forget","60","120","--confirm",fresh]).status,0)
    XCTAssertTrue(try store.intervals(in:TimeRange(0,300)).isEmpty)
    XCTAssertEqual(try store.appendSamples([TimeSample(ts:61)]).refused,1)
    XCTAssertEqual(run(["privacy","forget","60","120"]).status,1)
  }
  func testForgetGuardsAndWidePreviewRequiresAllowanceAgain() throws {
    let store = try storage(); _ = try store.appendSamples([TimeSample(ts:61)])
    for rest in [["0","0"],["120","60"],["0","400001"],["0","86401"],["0","120","--confirm"],["0","120","--other"],["0","120","--allow-over-24h","--allow-over-24h"]] {
      XCTAssertNotEqual(run(["privacy","forget"] + rest).status,0)
      XCTAssertEqual(try store.deletionsSoFar(),0)
    }
    let preview = run(["privacy","forget","0","86401","--allow-over-24h"])
    XCTAssertEqual(preview.status,0)
    XCTAssertEqual(run(["privacy","forget","0","86401","--confirm",try code(preview.output)]).status,1)
    XCTAssertEqual(try store.samples(in:TimeRange(0,100)).count,1)
  }
  func testForgetRefusesAmbiguousOrInvalidLocalTimes() throws {
    let zone = try XCTUnwrap(TimeZone(identifier:"America/New_York"))
    for text in ["2026-03-08 02:30:00","2026-11-01 01:30:00","2026-02-30 12:00:00"] {
      XCTAssertThrowsError(try ForgetCommandRequest.timestamp(text,zone:zone))
    }
  }
  func testMaskAndVerdictsKeepMachineShapesWithoutReadingTitles() throws {
    let result = RetainedCommands.mask(Data(#"["password=invented-secret","invented ordinary text"]"#.utf8))
    XCTAssertEqual(result.status,0)
    XCTAssertEqual(try JSONDecoder().decode([String].self,from:Data(result.output.utf8)),["[secret]","invented ordinary text"])
    _ = try storage().patchSettings(.edit(.addApp("invented.hidden"),ownBundleID:AppPaths.bundleID,now:1))
    let verdicts = RetainedCommands.run(["privacy","verdicts"],paths:paths,input:Data("Invented Alias\tinvented title\ninvented.open\t\nmissing\t\ndev.local.ActivityProbe\t\n".utf8),applications:[CommandApplicationIdentity(bundleID:"invented.hidden",names:["Invented Alias"]),CommandApplicationIdentity(bundleID:"invented.open",names:["Invented Open"])])
    XCTAssertEqual(verdicts.output,"hidden app\nopen\nopen unmatched\nhidden app")
  }
  func testStopWaitsForLifetimeLockBeyondOldCutoffWithoutPID() throws {
    var owner: RecorderStartupGuard? = try RecorderStartupGuard(paths: paths)
    var waits = 0
    let control = RecorderControl(wait: {
      waits += 1
      XCTAssertFalse(try! self.storage().settings().recordingEnabled)
      if waits == 61 { owner = nil }
    }, uptime: { Double(waits) / 20 }, timeout: 10)
    XCTAssertEqual(try control.stop(paths: paths).status, 0)
    XCTAssertEqual(waits, 61); XCTAssertNil(owner)
    XCTAssertTrue(try control.status(paths: paths).output.contains("running=0 recording=0"))
  }
  func testProbeOnOffStatusNeedsNoManifestAndRejectsOldEnableFlags() throws {
    XCTAssertEqual(run(["ax-probe", "on"]).status, 0)
    let first = try XCTUnwrap(storage().settings().axProbeRun)
    XCTAssertTrue(run(["ax-probe", "status"]).output.contains("ax_probe_enabled=1"))
    XCTAssertEqual(run(["ax-probe", "on"]).status, 1)
    XCTAssertEqual(run(["ax-probe", "off"]).status, 0)
    XCTAssertTrue(run(["ax-probe", "status"]).output.contains("ax_probe_enabled=0"))
    XCTAssertEqual(run(["ax-probe", "on"]).status, 0)
    XCTAssertNotEqual(try storage().settings().axProbeRun?.id, first.id)
    XCTAssertEqual(run(["ax-probe", "enable", "--browser", "exclude", "--manifest", "invented"]).status, 1)
  }
  func testStatusShowsProbeCancellationReasonAndTime() throws {
    let store = try storage()
    _ = try store.enableAXProbe(at: 10000)
    try store.disableAXProbe(at: 10007)
    let result = run(["status"])
    XCTAssertEqual(result.status, 0)
    XCTAssertTrue(result.output.contains("ax_probe_cancelled=1 ax_probe_reason=off ax_probe_cancelled_at=10007"))
  }
  func testStopWithoutRecorderIgnoresStaleAndLinkedPID() throws {
    let pidFile = root.appendingPathComponent("collector.pid"), target = root.appendingPathComponent("protected-pid")
    try Data("123".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(at: pidFile, withDestinationURL: target)
    let control = RecorderControl(wait: { XCTFail("No recorder must return immediately") })
    XCTAssertEqual(try control.stop(paths: paths).status, 0)
    XCTAssertEqual(try Data(contentsOf: target), Data("123".utf8))
    XCTAssertThrowsError(try RecorderStartupGuard(paths: paths, identity: { _ in XCTFail("Linked PID must not be inspected"); return .gone }))
    try FileManager.default.removeItem(at: pidFile)
    try Data("2147483647".utf8).write(to: pidFile)
    XCTAssertEqual(try control.stop(paths: paths).status, 0)
    XCTAssertEqual(try String(contentsOf: pidFile), "2147483647")
  }
  func testIgnoringRecorderTimesOutWithoutTouchingPIDOrReleasingItsLock() throws {
    let owner = try RecorderStartupGuard(paths: paths)
    let pidFile = root.appendingPathComponent("collector.pid")
    try Data("123".utf8).write(to: pidFile)
    var waits = 0
    let control = RecorderControl(wait: { waits += 1 }, uptime: { Double(waits) }, timeout: 3)
    let result = try control.stop(paths: paths)
    XCTAssertEqual(result.status, 1); XCTAssertEqual(result.output, "stop_timed_out"); XCTAssertEqual(waits, 3)
    XCTAssertFalse(try storage().settings().recordingEnabled)
    XCTAssertEqual(try String(contentsOf: pidFile), "123")
    XCTAssertThrowsError(try RecorderStartupGuard(paths: paths))
    withExtendedLifetime(owner) {}
  }
  func testNewSelftestAndLeaktestUseOnlySyntheticStorage() throws {
    XCTAssertEqual(run(["selftest"]).output,"all passed")
    XCTAssertEqual(run(["leaktest"]).output,"all passed")
  }
  func testIsolationRequiredForRetainedCommandsAndNoPathEscape() throws {
    XCTAssertThrowsError(try ActivityProbeEntry.isolatedCommand(arguments:["status"],environment:[:],userHome:paths.userHome,appBinary:paths.appBinary))
    let parsed = try ActivityProbeEntry.isolatedCommand(arguments:["privacy","forget","0","120","--isolated-root",root.path,"--app-data",root.appendingPathComponent("data").path],environment:["ACTIVITYPROBE_DB":root.appendingPathComponent("other.sqlite").path],userHome:paths.userHome,appBinary:paths.appBinary)
    XCTAssertEqual(parsed.arguments,["privacy","forget","0","120"])
    XCTAssertEqual(parsed.paths.database.deletingLastPathComponent().resolvingSymlinksInPath().path,root.resolvingSymlinksInPath().path)
    XCTAssertEqual(parsed.paths.database.lastPathComponent,"other.sqlite")
  }
  func oldSource() throws -> URL {
    let source = root.appendingPathComponent("old.sqlite"), child = Process()
    child.executableURL = URL(fileURLWithPath:"/usr/bin/sqlite3")
    child.arguments = [source.path, """
      CREATE TABLE samples(ts INTEGER,bundle_id TEXT,app TEXT,title TEXT,doc_key TEXT,keys INTEGER,clicks INTEGER,scrolls INTEGER,moved INTEGER,synth INTEGER);
      CREATE TABLE evidence(ts INTEGER,bundle_id TEXT,doc_key TEXT,kind TEXT,text TEXT);
      CREATE TABLE activities(id INTEGER,start_ts INTEGER,end_ts INTEGER,title TEXT,summary TEXT,category TEXT,kind TEXT,project TEXT);
      INSERT INTO samples VALUES(61,'invented','Invented','invented title','invented doc',1,0,0,0,0);
      INSERT INTO activities VALUES(1,60,180,'Invented','Invented','coding','normal','invented-project');
      PRAGMA user_version=10;
      """]
    child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
    try child.run(); child.waitUntilExit(); XCTAssertEqual(child.terminationStatus,0)
    return source
  }
  func conversion(_ source: URL, intent: String = "on") -> AppCommandResult {
    ConversionCommand.run(["--source",source.path,"--destination",paths.database.path,"--app-data",root.path,"--old-settings",root.path,"--recording-intent",intent],userHome:root.appendingPathComponent("person"),appBinary:paths.appBinary)
  }
  func testConversionOperatorRunsTwiceAndWritesOnlyNumericManifest() throws {
    let source = try oldSource(), result = conversion(source)
    XCTAssertEqual(result.status,0,result.output)
    XCTAssertTrue(result.output.contains("manifest PASS"))
    XCTAssertFalse(result.output.contains("invented title")); XCTAssertFalse(result.output.contains("invented-project")); XCTAssertFalse(result.output.contains(source.path))
    XCTAssertEqual(conversion(source).status,0)
    XCTAssertEqual(try storage().samples(in:TimeRange(0,1000)).count,1)
    XCTAssertEqual(conversion(source,intent:"off").status,1)
    XCTAssertTrue(try storage().settings().recordingEnabled)
  }
  func testConversionRefusesWALNonemptyAndUnownedPaths() throws {
    let source = try oldSource()
    try Data().write(to:URL(fileURLWithPath:source.path + "-wal"))
    XCTAssertEqual(conversion(source).status,1)
    XCTAssertTrue(try storage().samples(in:TimeRange(0,1000)).isEmpty)
    try FileManager.default.removeItem(atPath:source.path + "-wal")
    _ = try storage().appendSamples([TimeSample(ts:1)])
    XCTAssertEqual(conversion(source).status,1)
    XCTAssertEqual(try storage().samples(in:TimeRange(0,1000)).count,1)
    let unsafe = ConversionCommand.run(["--source",source.path,"--destination",paths.database.path,"--app-data","/var/empty/invented","--old-settings",root.path,"--recording-intent","on"],userHome:paths.userHome,appBinary:paths.appBinary)
    XCTAssertEqual(unsafe.status,1)
  }

  func testConversionRefusesLinkedSettingsLeavesBeforeAnyImport() throws {
    let source = try oldSource(), protected = root.appendingPathComponent("protected")
    try FileManager.default.createDirectory(at: protected, withIntermediateDirectories: true)
    for leaf in ["privacy.json", "settings.json", "pause-until", "pause-kept", "collector.pid", "recorder-start.lock"] {
      let target = protected.appendingPathComponent(leaf), alias = root.appendingPathComponent(leaf)
      let bytes = Data((leaf.hasSuffix("json") ? #"{"pausedUntil":2000000000}"# : "2000000000").utf8)
      try bytes.write(to: target)
      if FileManager.default.fileExists(atPath: alias.path) { try FileManager.default.removeItem(at: alias) }
      try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
      XCTAssertEqual(conversion(source).status, 1, leaf)
      XCTAssertTrue(try storage().samples(in: TimeRange(0,1000)).isEmpty, leaf)
      XCTAssertEqual(try Data(contentsOf: target), bytes)
      try FileManager.default.removeItem(at: alias)
    }
  }
  func testConversionRefusesSourceAndDestinationAliases() throws {
    let source = try oldSource(), alias = root.appendingPathComponent("source-alias.sqlite")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
    XCTAssertEqual(conversion(alias).status, 1)
    let destination = root.appendingPathComponent("destination-alias.sqlite")
    try FileManager.default.linkItem(at: paths.database, to: destination)
    XCTAssertEqual(conversion(source).status, 1)
    try FileManager.default.removeItem(at: destination)
    XCTAssertTrue(try storage().samples(in: TimeRange(0,1000)).isEmpty)
  }

  func testConversionRefusesSourceSidecarsAndLinkedDestinationLeaves() throws {
    let source = try oldSource()
    for suffix in ["-shm", "-journal"] {
      let sidecar = URL(fileURLWithPath: source.path + suffix)
      try Data().write(to: sidecar)
      XCTAssertEqual(conversion(source).status, 1)
      try FileManager.default.removeItem(at: sidecar)
    }
    let target = root.appendingPathComponent("protected.sqlite")
    try FileManager.default.copyItem(at: paths.database, to: target)
    let before = try Data(contentsOf: target)
    try FileManager.default.removeItem(at: paths.database)
    try FileManager.default.createSymbolicLink(at: paths.database, withDestinationURL: target)
    XCTAssertEqual(conversion(source).status, 1)
    XCTAssertEqual(try Data(contentsOf: target), before)
    try FileManager.default.removeItem(at: paths.database)
    _ = try storage()
    for suffix in ["-wal", "-shm", ".recorder-lock"] {
      let leaf = URL(fileURLWithPath: paths.database.path + suffix)
      if FileManager.default.fileExists(atPath: leaf.path) { try FileManager.default.removeItem(at: leaf) }
      try FileManager.default.createSymbolicLink(at: leaf, withDestinationURL: target)
      XCTAssertEqual(conversion(source).status, 1)
      XCTAssertEqual(try Data(contentsOf: target), before)
      try FileManager.default.removeItem(at: leaf)
    }
  }
  func testPIDPublicationRefusesLeafReplacedAfterStartupWithoutWritingTarget() throws {
    let owner = try RecorderStartupGuard(paths: paths), target = root.appendingPathComponent("protected-pid")
    let bytes = Data("123".utf8); try bytes.write(to: target)
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("collector.pid"), withDestinationURL: target)
    XCTAssertThrowsError(try owner.publish())
    XCTAssertEqual(try Data(contentsOf: target), bytes)
  }

  func testUnreadableSettingsDirectoriesKeepDefaultsWithoutReadingChildren() throws {
    let source = try oldSource()
    for leaf in ["privacy.json", "settings.json", "pause-until", "pause-kept"] {
      let directory = root.appendingPathComponent(leaf)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try Data("Invented protected child".utf8).write(to: directory.appendingPathComponent("keep"))
    }
    XCTAssertEqual(conversion(source).status, 0)
    var expected = StorageSettings(); expected.recordingEnabled = true
    XCTAssertEqual(try storage().settings(), expected)
    for leaf in ["privacy.json", "settings.json", "pause-until", "pause-kept"] {
      XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(leaf).appendingPathComponent("keep")), "Invented protected child")
    }
  }

}
