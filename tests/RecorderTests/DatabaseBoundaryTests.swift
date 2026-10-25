import Core
import Darwin
import Foundation
import Outbound
import XCTest
@testable import Shell
@testable import Storage

final class DatabaseBoundaryTests: XCTestCase {
  var root: URL!
  override func setUpWithError() throws {
    root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ACTIVITYPROBE_TEST_ROOT"] ?? "/tmp").appendingPathComponent("boundary-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }
  override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
  func paths(_ database: URL, data: URL? = nil) -> AppPaths {
    AppPaths(userHome: root.appendingPathComponent("person"), appData: data ?? root,
      database: database, appBinary: root.appendingPathComponent("ActivityProbe"), queryHelper: root.appendingPathComponent("helper"),
      databaseScope: .directory(root.deletingLastPathComponent(), excluding: [root.appendingPathComponent("excluded")]))
  }
  func oldSource() throws -> URL {
    let file = root.appendingPathComponent("old.sqlite")
    let db = try SQLiteConnection(url: file, scope: .directory(root))
    try db.run("CREATE TABLE samples(ts INTEGER,bundle_id TEXT,app TEXT,title TEXT,doc_key TEXT,keys INTEGER,clicks INTEGER,scrolls INTEGER,moved INTEGER,synth INTEGER)")
    try db.run("CREATE TABLE evidence(ts INTEGER,bundle_id TEXT,doc_key TEXT,kind TEXT,text TEXT)")
    try db.run("CREATE TABLE activities(id INTEGER,start_ts INTEGER,end_ts INTEGER,title TEXT,summary TEXT,category TEXT,kind TEXT)")
    try db.run("CREATE TABLE llm_runs(created_at INTEGER,model TEXT,input_tokens INTEGER,cached_tokens INTEGER,output_tokens INTEGER,ok INTEGER)")
    try db.run("INSERT INTO samples VALUES(61,'invented','Invented','','',0,0,0,0,0)")
    try db.run("INSERT INTO llm_runs VALUES(61,'invented',0,0,0,1)")
    return file
  }
  func convert(_ source: URL, to destination: URL) -> AppCommandResult {
    ConversionCommand.run(["--source",source.path,"--destination",destination.path,"--app-data",root.path,
      "--old-settings",root.path,"--recording-intent","on"], userHome:root.appendingPathComponent("person"),appBinary:root.appendingPathComponent("ActivityProbe"))
  }
  // Ideal: an explicit directory grant survives every handler, including destructive confirmation.
  func testForgetOutsideApprovedScopeChangesNothing() throws {
    let protected = root.appendingPathComponent("protected.sqlite")
    do {
      let store = try ActivityStorage(url: protected, appDataDirectory: root, databaseScope: .directory(root))
      _ = try store.appendSamples([TimeSample(ts:61), TimeSample(ts:121)])
    }
    let preview = RetainedCommands.run(["privacy","forget","60","120"], paths:paths(protected), now:1000)
    let line = try XCTUnwrap(preview.output.components(separatedBy:"\n").first { $0.hasPrefix("Confirmation code: ") })
    let code = String(line.dropFirst("Confirmation code: ".count))
    do { let db = try SQLiteConnection(url:protected, scope: .directory(root)); try db.run("PRAGMA journal_mode=DELETE") }
    let before = try Data(contentsOf:protected)
    let grant = root.appendingPathComponent("approved")
    try FileManager.default.createDirectory(at:grant,withIntermediateDirectories:true)
    let context = AppPaths(userHome:root.appendingPathComponent("person"),appData:grant,database:protected,
      appBinary:root.appendingPathComponent("ActivityProbe"),queryHelper:root.appendingPathComponent("helper"),
      databaseScope:.directory(grant,excluding:[grant.appendingPathComponent("excluded")]))
    for args in [["privacy","forget","60","120"],["privacy","forget","60","120","--confirm",code]] {
      XCTAssertNotEqual(RetainedCommands.run(args,paths:context,now:1000).status,0)
      XCTAssertEqual(try Data(contentsOf:protected),before)
    }
    let db = try SQLiteConnection(url:protected,readOnly:true, scope: .directory(root))
    XCTAssertEqual(try db.integer("SELECT count(*) FROM samples"),2)
    XCTAssertEqual(try db.integer("SELECT count(*) FROM forgotten_ranges"),0)
  }
  // Ideal: every persisted key and value must match, even when the row count is unchanged.
  func testSameCountSettingsReplacementFailsOperatorManifest() throws {
    let source = try oldSource(), target = root.appendingPathComponent("new.sqlite")
    XCTAssertEqual(convert(source,to:target).status,0)
    for key in ["general.chat.skipApprovals", "invented.unknown"] {
      do {
        let db = try SQLiteConnection(url:target, scope: .directory(root))
        XCTAssertEqual(try db.integer("SELECT count(*) FROM settings"),19)
        try db.run("UPDATE settings SET key=?,value='1' WHERE key='initialized'",[.key(key)])
        XCTAssertEqual(try db.integer("SELECT count(*) FROM settings"),19)
      }
      let result = convert(source,to:target)
      XCTAssertEqual(result.status,1,result.output)
      XCTAssertTrue(result.output.contains("manifest FAIL"),result.output)
      do { let db = try SQLiteConnection(url:target, scope: .directory(root)); try db.run("UPDATE settings SET key='initialized',value='1' WHERE key=?",[.key(key)]) }
    }
  }
  func testMissingAdoptionMarkerIsNotRepairedBeforeAudit() throws {
    let source = try oldSource(), target = root.appendingPathComponent("new.sqlite")
    XCTAssertEqual(convert(source,to:target).status,0)
    do { let db = try SQLiteConnection(url:target,scope:.directory(root)); try db.run("DELETE FROM settings WHERE key='old-files-imported'") }
    let result = convert(source,to:target)
    XCTAssertEqual(result.status,1,result.output)
    XCTAssertTrue(result.output.contains("settings.mismatch.\"old-files-imported\" expected=0 actual=1 FAIL"),result.output)
    let db = try SQLiteConnection(url:target,readOnly:true,scope:.directory(root))
    XCTAssertEqual(try db.integer("SELECT count(*) FROM settings WHERE key='old-files-imported'"),0)
  }
  // Ideal: a decoded old file has an empty list for missing/null apps; unreadable files use defaults.
  func testDecodedPrivacyWithoutAppsImportsEmptyList() throws {
    let source = try oldSource(), privacy = root.appendingPathComponent("privacy.json")
    for (index,json) in [#"{"pausedUntil":2000000000}"#, #"{"apps":null,"pausedUntil":2000000000}"#].enumerated() {
      let bytes = Data(json.utf8); try bytes.write(to:privacy)
      let target = root.appendingPathComponent("new-\(index).sqlite")
      XCTAssertEqual(convert(source,to:target).status,0)
      do {
        let store = try ActivityStorage(url:target,appDataDirectory:root, databaseScope: .directory(root))
        XCTAssertEqual(try store.settings().excludedApps,[])
        XCTAssertEqual(try store.settings().pausedUntil,2000000000)
        var empty = try store.settings(); empty.excludedApps = []
        try store.saveSettings(empty,at:Int.min)
      }
      XCTAssertEqual(convert(source,to:target).status,0)
      XCTAssertEqual(try Data(contentsOf:privacy),bytes)
    }
  }
  func testConversionHelpStatesDirectoryStabilityPrecondition() {
    let result = ConversionCommand.run(["--help"],userHome:root,appBinary:root.appendingPathComponent("unavailable"))
    XCTAssertEqual(result.status,0)
    XCTAssertTrue(result.output.contains("no other process may change"))
    XCTAssertTrue(result.output.contains("during conversion or isolated commands"))
  }
  // Ideal: conversion refuses a protected destination before creating its missing parents.
  func testConversionProtectedDestinationCreatesNoParents() throws {
    let source = try oldSource(), home = root.appendingPathComponent("Person-Café")
    let protected = home.appendingPathComponent("Library/Application Support/ActivityProbe")
    try FileManager.default.createDirectory(at: protected, withIntermediateDirectories: true)
    let alias = root.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: protected)
    let dotAlias = root.appendingPathComponent("dot-alias")
    let inside = protected.appendingPathComponent("inside")
    try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: dotAlias, withDestinationURL: inside)
    for parent in [protected, alias, URL(fileURLWithPath: protected.path.uppercased()),
      URL(fileURLWithPath: protected.path.decomposedStringWithCanonicalMapping),
      URL(fileURLWithPath: dotAlias.path + "/..")] {
      let destination = parent.appendingPathComponent("missing/child/invented.sqlite")
      let result = ConversionCommand.run(["--source", source.path, "--destination", destination.path,
        "--app-data", root.path, "--old-settings", root.path, "--recording-intent", "on"],
        userHome: home, appBinary: root.appendingPathComponent("ActivityProbe"))
      XCTAssertEqual(result.status, 1)
      XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: protected.path), ["inside"])
      XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: inside.path), [])
    }
  }
  // A name beneath the isolated root must never grant access to another inode alias.
  func testStopStatusAndForgetRefuseHardLinkedDatabase() throws {
    let protected = root.appendingPathComponent("protected.sqlite")
    do {
      let store = try ActivityStorage(url: protected, appDataDirectory: root, databaseScope: .directory(root))
      _ = try store.appendSamples([TimeSample(ts:61), TimeSample(ts:121)])
    }
    do { let db = try SQLiteConnection(url: protected, scope: .directory(root)); try db.run("PRAGMA journal_mode=DELETE") }
    let isolated = root.appendingPathComponent("isolated"), data = isolated.appendingPathComponent("data")
    try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
    let alias = isolated.appendingPathComponent("alias.sqlite")
    try FileManager.default.linkItem(at: protected, to: alias)
    let before = try Data(contentsOf: protected)
    for arguments in [["stop"], ["status"], ["privacy","forget","60","120"], ["privacy","forget","60","120","--confirm","invented"]] {
      let result = ActivityProbeEntry.run(arguments: arguments + ["--isolated-root",isolated.path,"--app-data",data.path],
        environment:["ACTIVITYPROBE_DB":alias.path], userHome:root.appendingPathComponent("person"),appBinary:root.appendingPathComponent("ActivityProbe"))
      XCTAssertNotEqual(result,0,arguments.joined(separator:" "))
      XCTAssertEqual(try Data(contentsOf:protected),before)
    }
    try FileManager.default.removeItem(at: alias)
    let db = try SQLiteConnection(url: protected, readOnly: true, scope: .directory(root))
    XCTAssertEqual(try db.integer("SELECT count(*) FROM samples"),2)
    XCTAssertEqual(try db.integer("SELECT count(*) FROM forgotten_ranges"),0)
  }
  // Fractional values used to decode as zero, preserving the digest and every row count.
  func testFractionalSampleAndTokenValuesFailManifest() throws {
    let source = try oldSource(), target = root.appendingPathComponent("new.sqlite")
    XCTAssertEqual(convert(source,to:target).status,0)
    for (table,column) in [("samples","keys"),("model_calls","input_tokens")] {
      do { let db = try SQLiteConnection(url:target, scope: .directory(root)); try db.run("UPDATE \(table) SET \(column)=0.5") }
      let result = convert(source,to:target)
      XCTAssertEqual(result.status,1,result.output)
      XCTAssertTrue(result.output.contains("FAIL"),result.output)
      do { let db = try SQLiteConnection(url:target, scope: .directory(root)); try db.run("UPDATE \(table) SET \(column)=0") }
    }
  }
  // Operators select a closed generation by moving its single staging file.
  func testColdFinalNameWorksBeforeAnyWritableBootstrap() throws {
    let source = try oldSource(), staging = root.appendingPathComponent("staging.sqlite"), final = root.appendingPathComponent("selected.sqlite")
    XCTAssertEqual(convert(source,to:staging).status,0)
    for suffix in ["-wal","-shm","-journal"] { XCTAssertFalse(FileManager.default.fileExists(atPath:staging.path + suffix)) }
    try FileManager.default.moveItem(at:staging,to:final)
    XCTAssertNoThrow(try ActivityStorage.validateRecorderDatabase(at:final, scope: .directory(root)))
    XCTAssertEqual(RetainedCommands.run(["status"],paths:paths(final)).status,0)
    // The same isolated collect composition starts with fake dependencies, never Mac sources.
    let configuration = try ActivityProbeEntry.isolatedConfiguration(arguments:["collect","--isolated-root",root.path,
      "--app-data",root.appendingPathComponent("data").path],environment:["ACTIVITYPROBE_DB":final.path],
      excludedUserHome:root.appendingPathComponent("person"),appBinary:root.appendingPathComponent("ActivityProbe"))
    let owner = try RecorderStartupGuard(paths:configuration.paths)
    var factories = AppFactories()
    factories.summary = { _, _ in BoundarySummary() }
    let connections = try configuration.composition(factories: factories).recorder(processes: NoAgentLogProcesses(),
      fileVault: BoundaryVault(), from: 0, dayStart: { $0 }, locale: { "en" }, recorderLock: owner.recorderLock)
    let clock = FakeClock(), sources = FakeSources(); sources.clock = clock
    let loop = connections.makeLoop(clock: clock, input: sources, front: sources, secure: sources,
      awake: sources, screen: sources, ownBundleID: AppPaths.bundleID)
    var started = 0
    let lifecycle = RecorderLifecycle(loop: loop, clock: clock, startInput: { started += 1 }, stopInput: {}, requestSummary: { _ in })
    lifecycle.start(); loop.tick(); loop.flush()
    XCTAssertEqual(started, 1)
    XCTAssertEqual(try connections.client.samples(in: TimeRange(10000,10001)).count, 1)
    var mode = ""
    try connections.client.connection.namedRows("PRAGMA journal_mode") { mode = try $0.text("journal_mode") }
    XCTAssertEqual(mode, "wal")
    let stopped = expectation(description: "fake collect drained")
    lifecycle.stop { _ in stopped.fulfill() }; wait(for: [stopped], timeout: 5)
    withExtendedLifetime(owner) {}
  }
  func testFirstStartBetweenLockOpenAndSettingsPatchMustDrainBeforeStopReturns() throws {
    let file = root.appendingPathComponent("new.sqlite"), context = paths(file)
    _ = try ActivityStorage(url: file, appDataDirectory: root, databaseScope: .directory(root))
    let lock = root.appendingPathComponent("recorder-start.lock")
    XCTAssertFalse(FileManager.default.fileExists(atPath:lock.path))
    XCTAssertEqual(try RecorderControl().status(paths:context).status,0)
    XCTAssertFalse(FileManager.default.fileExists(atPath:lock.path))
    var owner: RecorderStartupGuard?, waits = 0
    var control = RecorderControl(wait: {
      waits += 1
      XCTAssertFalse(try! ActivityStorage(url:file,appDataDirectory:self.root, databaseScope: .directory(self.root)).settings().recordingEnabled)
      if waits == 3 { owner = nil }
    }, uptime:{ Double(waits) }, timeout:10)
    control.beforeSettingsPatch = { owner = try RecorderStartupGuard(paths:context) }
    XCTAssertEqual(try control.stop(paths:context).status,0)
    XCTAssertEqual(waits,3); XCTAssertNil(owner)
  }

  func testEveryCommandDatabaseOpenTraversesApprovedBoundary() throws {
    let folder = root.appendingPathComponent("databases")
    try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
    let target = folder.appendingPathComponent("new.sqlite"), source = try oldSource()
    _ = try ActivityStorage(url:target,appDataDirectory:root, databaseScope: .directory(root))
    let context = paths(target)
    var scope = context.databaseScope
    enum Intercepted: Error { case open }
    var opens = 0
    DatabaseOpenBoundary.beforeOpen = { file, received in
      opens += 1
      guard case .directory(let receivedRoot, let excluded) = received, case .directory(let approvedRoot, let approvedExcluded) = scope else { return XCTFail("Directory scope required") }
      XCTAssertEqual(OperationalDirectory.systemURL(receivedRoot),OperationalDirectory.systemURL(approvedRoot))
      XCTAssertEqual(excluded,approvedExcluded); XCTAssertFalse(excluded.isEmpty)
      XCTAssertTrue(file.path.hasPrefix(OperationalDirectory.systemURL(self.root).path + "/"))
      throw Intercepted.open
    }
    defer { DatabaseOpenBoundary.beforeOpen = nil }
    for args in [["stop"],["status"],
      ["privacy","forget","60","120"],["privacy","forget","60","120","--confirm","invented"],
      ["privacy","verdicts"],["selftest"],["leaktest"]] {
      opens = 0
      XCTAssertNotEqual(RetainedCommands.run(args,paths:context,now:1000).status,0)
      XCTAssertEqual(opens,1,args.joined(separator:" "))
    }
    opens = 0
    XCTAssertEqual(RetainedCommands.mask(Data("[]".utf8)).status,0); XCTAssertEqual(opens,0)
    opens = 0
    scope = try ActivityProbeEntry.isolatedConfiguration(arguments:["collect","--isolated-root",root.path,
      "--app-data",root.appendingPathComponent("data").path],
      environment:["ACTIVITYPROBE_DB":target.path],excludedUserHome:context.userHome,appBinary:context.appBinary).paths.databaseScope
    XCTAssertNotEqual(ActivityProbeEntry.run(arguments:["collect","--isolated-root",root.path,"--app-data",root.appendingPathComponent("data").path],environment:["ACTIVITYPROBE_DB":target.path],userHome:context.userHome,appBinary:context.appBinary),0)
    XCTAssertEqual(opens,1)
    opens = 0
    // Conversion's source uses the same boundary with its separately approved temporary root.
    DatabaseOpenBoundary.beforeOpen = { _, received in
      opens += 1
      guard case .directory(let root, let excluded) = received else { return XCTFail("Conversion scope required") }
      XCTAssertEqual(OperationalDirectory.systemURL(root),URL(fileURLWithPath:"/private/tmp")); XCTAssertEqual(excluded.count,2)
      throw Intercepted.open
    }
    XCTAssertNotEqual(convert(source,to:root.appendingPathComponent("conversion.sqlite")).status,0)
    XCTAssertEqual(opens,1)
  }

  // Walk successful routes too, including every later source and destination open in conversion.
  func testCompleteCommandRoutesCountEveryApprovedOpen() throws {
    let folder = root.appendingPathComponent("databases")
    try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
    let source = try oldSource(), target = folder.appendingPathComponent("new.sqlite"), context = paths(target)
    do {
      let store = try ActivityStorage(url:target,appDataDirectory:root, databaseScope: .directory(root))
      _ = try store.appendSamples([TimeSample(ts:61)])
    }
    var opened: [URL] = []
    DatabaseOpenBoundary.beforeOpen = { file, scope in
      opened.append(file)
      XCTAssertTrue(file.path.hasPrefix(OperationalDirectory.systemURL(self.root).path + "/"))
      guard case .directory(let approved, let excluded) = scope else { return XCTFail("Isolated route required") }
      XCTAssertTrue(file.path.hasPrefix(OperationalDirectory.systemURL(approved).path + "/"))
      XCTAssertFalse(excluded.isEmpty)
      if approved == self.root.deletingLastPathComponent() { XCTAssertEqual(scope,context.databaseScope) }
    }
    defer { DatabaseOpenBoundary.beforeOpen = nil }
    for args in [["stop"],["status"],
      ["privacy","verdicts"],["selftest"],["leaktest"]] {
      opened = []
      let result = RetainedCommands.run(args,paths:context,now:1000)
      XCTAssertEqual(result.status,0,result.output); XCTAssertEqual(opened.count,1,args.joined(separator:" "))
    }
    opened = []
    let preview = RetainedCommands.run(["privacy","forget","60","120"],paths:context,now:1000)
    XCTAssertEqual(preview.status,0); XCTAssertEqual(opened.count,1)
    let line = try XCTUnwrap(preview.output.components(separatedBy:"\n").first{$0.hasPrefix("Confirmation code: ")})
    let code = String(line.dropFirst("Confirmation code: ".count))
    opened = []
    XCTAssertEqual(RetainedCommands.run(["privacy","forget","60","120","--confirm",code],paths:context,now:1000).status,0)
    XCTAssertEqual(opened.count,1)
    opened = []
    do {
      let owner = try RecorderStartupGuard(paths:context)
      var factories = AppFactories(); factories.summary = {_,_ in BoundarySummary()}
      let configuration = IsolatedRecorderConfiguration(paths:context)
      let connections = try configuration.composition(factories:factories).recorder(processes:NoAgentLogProcesses(),
        fileVault:BoundaryVault(),from:0,dayStart:{$0},locale:{"en"},recorderLock:owner.recorderLock)
      XCTAssertEqual(opened.count,3) // Preflight, recorder and maintenance client.
      withExtendedLifetime((owner,connections)){}
    }
    let destination = root.appendingPathComponent("conversion.sqlite")
    for count in [5,6] { // A repeat also performs read-only destination preflight.
      opened = []
      let result = convert(source,to:destination)
      XCTAssertEqual(result.status,0,result.output); XCTAssertEqual(opened.count,count)
      XCTAssertEqual(opened.filter{$0.lastPathComponent==source.lastPathComponent}.count,4)
    }
  }

  func testUnsafeLeavesAreRefusedBeforeSQLiteForEveryStorageOpen() throws {
    let protected = root.appendingPathComponent("protected"), file = root.appendingPathComponent("new.sqlite")
    try Data("invented".utf8).write(to:protected)
    var opens = 0
    DatabaseOpenBoundary.beforeOpen = { _, _ in opens += 1 }
    defer { DatabaseOpenBoundary.beforeOpen = nil }
    for suffix in ["","-wal","-shm","-journal",".recorder-lock"] {
      let alias = URL(fileURLWithPath:file.path + suffix)
      for hardLink in [true,false] {
        if hardLink { try FileManager.default.linkItem(at:protected,to:alias) }
        else { try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:protected) }
        for readOnly in [false,true] {
          XCTAssertThrowsError(try ActivityStorage(url:file,appDataDirectory:root,readOnly:readOnly, databaseScope: .directory(root)))
          XCTAssertEqual(opens,0)
        }
        try FileManager.default.removeItem(at:alias)
      }
    }
    XCTAssertEqual(try String(contentsOf:protected),"invented")
    XCTAssertThrowsError(try ActivityStorage(url:file,appDataDirectory:root,databaseScope:.directory(root.appendingPathComponent("other"))))
    XCTAssertEqual(opens,0)
  }

  func testGenericIntegerAuditIncludesNewTablesAndQuotedColumns() throws {
    let db = try SQLiteConnection(url:root.appendingPathComponent("typed.sqlite"), scope: .directory(root))
    try db.run("CREATE TABLE \"invented table\" (\"invented column\" INTEGER, other INT)")
    try db.run("INSERT INTO \"invented table\" VALUES(NULL,1)")
    XCTAssertEqual(try db.invalidIntegerValues(),0)
    try db.run("INSERT INTO \"invented table\" VALUES(0.5,0.5)")
    XCTAssertEqual(try db.invalidIntegerValues(),2)
  }

}

private struct BoundarySummary: SummaryCaller {
  func call(_ prompt: String) throws -> SummaryAnswer { throw SummaryError.notConnected }
}
private struct BoundaryVault: FileVaultStatusSource {
  func fileVaultStatus() -> FileVaultStatus { .unknown }
}
