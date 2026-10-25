import Core
import Darwin
import Foundation
import Storage
import XCTest
@testable import Shell

final class PathBoundaryTests: XCTestCase {
  private var root: URL!
  override func setUpWithError() throws {
    root = URL(fileURLWithPath: "/tmp/ap-path-boundary-tests").appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }
  override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

  // Ideal: an alias with two missing descendants cannot create anything in a protected home.
  func testProtectedAliasWithMissingDescendantsIsRefusedBeforeCreation() throws {
    let home = root.appendingPathComponent("person")
    let protected = home.appendingPathComponent("Library/Application Support/ActivityProbe")
    try FileManager.default.createDirectory(at: protected, withIntermediateDirectories: true)
    let alias = root.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: protected)
    let data = alias.appendingPathComponent("missing/child")
    let database = data.appendingPathComponent("invented.sqlite")
    let safeData = root.appendingPathComponent("safe-data")
    let safeDatabase = root.appendingPathComponent("safe.sqlite")
    XCTAssertTrue(TestPathGuard.active)
    for candidate in [data, database] {
      XCTAssertFalse(TestPathGuard.permits(candidate, userHome: home))
      XCTAssertThrowsError(try DatabaseOpenScope.directory(root, excluding: [protected]).validatePath(candidate))
    }
    for (appData, file) in [(data, database), (data, safeDatabase), (safeData, database)] {
      XCTAssertThrowsError(try ActivityProbeEntry.isolatedConfiguration(
        arguments: ["collect", "--isolated-root", root.path, "--app-data", appData.path],
        environment: ["ACTIVITYPROBE_DB": file.path], excludedUserHome: home, appBinary: root.appendingPathComponent("ActivityProbe")))
      let paths = AppPaths(userHome: home, appData: appData, database: file,
        appBinary: root.appendingPathComponent("ActivityProbe"), queryHelper: root.appendingPathComponent("helper"),
        databaseScope: .directory(root, excluding: [protected]))
      XCTAssertThrowsError(try RecorderStartupGuard(paths: paths))
      XCTAssertThrowsError(try RecorderControl().stop(paths: paths))
      if appData == data {
        for command in ["selftest", "leaktest"] {
          XCTAssertEqual(RetainedCommands.run([command], paths: paths).status, 1)
        }
      }
      XCTAssertFalse(FileManager.default.fileExists(atPath: protected.appendingPathComponent("missing").path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: safeData.path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: safeDatabase.path))
    }
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: protected.path), [])
  }

  // Ideal: every spelling is refused before startup, stop or conversion creates a child.
  func testIdentityWitnessesLeaveProtectedDirectoryUntouched() throws {
    let home = root.appendingPathComponent("Person-Café")
    let protected = home.appendingPathComponent("Library/Application Support/ActivityProbe")
    let inside = protected.appendingPathComponent("inside")
    try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
    let alias = root.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: inside)
    let caseVariant = URL(fileURLWithPath: protected.path.uppercased())
    let unicodeVariant = URL(fileURLWithPath: protected.path.decomposedStringWithCanonicalMapping)
    XCTAssertTrue(try FileLocation.same(protected, caseVariant))
    XCTAssertTrue(try FileLocation.same(protected, unicodeVariant))
    let unsafe = [URL(fileURLWithPath: alias.path + "/../missing/child"),
      alias.appendingPathComponent("missing/child"), caseVariant.appendingPathComponent("missing/child"),
      unicodeVariant.appendingPathComponent("missing/child")]
    let safeData = root.appendingPathComponent("safe-data"), safeDatabase = root.appendingPathComponent("safe.sqlite")
    for data in unsafe {
      let database = data.appendingPathComponent("invented.sqlite")
      for candidate in [data, database] {
        XCTAssertFalse(TestPathGuard.permits(candidate, userHome: home))
        XCTAssertThrowsError(try DatabaseOpenScope.directory(root, excluding: [protected]).validatePath(candidate))
      }
      for (appData, file) in [(data, database), (data, safeDatabase), (safeData, database)] {
        XCTAssertThrowsError(try ActivityProbeEntry.isolatedConfiguration(
          arguments: ["collect", "--isolated-root", root.path, "--app-data", appData.path],
          environment: ["ACTIVITYPROBE_DB": file.path], excludedUserHome: home, appBinary: root.appendingPathComponent("binary")))
        guard (try? FileLocation.validate(appData)) != nil, (try? FileLocation.validate(file)) != nil else { continue }
        let paths = AppPaths(userHome: home, appData: appData, database: file,
          appBinary: root.appendingPathComponent("binary"), queryHelper: root.appendingPathComponent("helper"),
          databaseScope: .directory(root, excluding: [protected]))
        XCTAssertThrowsError(try RecorderStartupGuard(paths: paths))
        XCTAssertThrowsError(try RecorderControl().stop(paths: paths))
      }
      let result = ConversionCommand.run(["--source", root.appendingPathComponent("source.sqlite").path,
        "--destination", database.path, "--app-data", safeData.path, "--old-settings", root.path,
        "--recording-intent", "on"], userHome: home, appBinary: root.appendingPathComponent("binary"))
      XCTAssertEqual(result.status, 1)
      XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: protected.path), ["inside"])
      XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: inside.path), [])
      XCTAssertFalse(FileManager.default.fileExists(atPath: safeData.path))
    }
  }

  func testInvalidComponentsAreRejectedAtEveryInput() throws {
    let binary = root.appendingPathComponent("binary"), home = root.appendingPathComponent("person")
    for suffix in ["/../missing", "/./missing", "//missing", "/missing//child"] {
      let raw = root.path + suffix, candidate = URL(fileURLWithPath: raw)
      XCTAssertThrowsError(try FileLocation.validate(raw))
      XCTAssertThrowsError(try CanonicalPath.resolve(candidate))
      XCTAssertThrowsError(try OperationalDirectory.validatePath(candidate))
      XCTAssertThrowsError(try DatabaseOpenScope.liveSwitch.validatePath(candidate))
      XCTAssertThrowsError(try ActivityProbeEntry.command(arguments: ["status"],
        environment: ["ACTIVITYPROBE_DB": raw], userHome: home, appBinary: binary))
      for flag in ["--source", "--destination", "--app-data", "--old-settings"] {
        var args = ["--source", root.appendingPathComponent("source.sqlite").path,
          "--destination", root.appendingPathComponent("new.sqlite").path,
          "--app-data", root.appendingPathComponent("data").path, "--old-settings", root.path,
          "--recording-intent", "on"]
        args[args.firstIndex(of: flag)! + 1] = raw
        XCTAssertEqual(ConversionCommand.run(args, userHome: home, appBinary: binary).status, 1)
      }
    }
    for raw in ["", "./missing", "../missing", root.path + "/"] { XCTAssertThrowsError(try FileLocation.validate(raw)) }
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
  }

  func testMissingProtectedNamesAndIdentityAliases() throws {
    let home = root.appendingPathComponent("Person-Café")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let reserved = home.appendingPathComponent("Library/Application Support/ActivityProbe")
    for suffix in ["LIBRARY/APPLICATION SUPPORT/ACTIVITYPROBE/missing/child",
      "Library/Application Support/ActivityProbe/missing/child"] {
      let candidate = URL(fileURLWithPath: home.path.decomposedStringWithCanonicalMapping).appendingPathComponent(suffix)
      XCTAssertFalse(TestPathGuard.permits(candidate, userHome: home))
      XCTAssertThrowsError(try DatabaseOpenScope.directory(root, excluding: [reserved]).validatePath(candidate))
    }
    let file = home.appendingPathComponent("file"), alias = root.appendingPathComponent("hard-link")
    try Data().write(to: file)
    try FileManager.default.linkItem(at: file, to: alias)
    XCTAssertTrue(try FileLocation.same(file, alias))
    XCTAssertThrowsError(try DatabaseOpenScope.directory(root, excluding: [file]).validatePath(alias))
    // macOS disallows directory hard links. If supported, exercise the same directory guard.
    let directoryAlias = root.appendingPathComponent("directory-link")
    if link(home.path, directoryAlias.path) == 0 {
      XCTAssertTrue(try FileLocation.same(home, directoryAlias))
      XCTAssertFalse(TestPathGuard.permits(directoryAlias.appendingPathComponent("Library/Application Support/ActivityProbe/new"), userHome: home))
    }
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home.path), ["file"])
  }

  // Ideal: approved and excluded locations use the same resolved identity as candidates.
  func testApprovedAndExcludedAliasesWithMissingSuffixes() throws {
    let directory = root.appendingPathComponent("directory")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let alias = root.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
    let direct = directory.appendingPathComponent("missing/child/invented.sqlite")
    let linked = alias.appendingPathComponent("missing/child/invented.sqlite")
    XCTAssertTrue(try CanonicalPath.resolve(direct).path.hasPrefix(CanonicalPath.resolve(directory).path + "/"))
    XCTAssertEqual(try CanonicalPath.resolve(linked).path, try CanonicalPath.resolve(direct).path)
    XCTAssertNoThrow(try DatabaseOpenScope.directory(alias).validatePath(direct))
    for candidate in [direct, linked] {
      XCTAssertThrowsError(try DatabaseOpenScope.directory(root, excluding: [alias.appendingPathComponent("missing")]).validatePath(candidate))
    }
    XCTAssertThrowsError(try OperationalDirectory.validatePath(alias.appendingPathComponent("missing/child")))
    XCTAssertNoThrow(try OperationalDirectory.validatePath(directory.appendingPathComponent("missing/child")))
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("missing").path))
  }

  // Ideal: an unresolvable candidate or exclusion cannot turn an uncertain path into a grant.
  func testDanglingLoopAndNonDirectoryAncestorsFailClosed() throws {
    let dangling = root.appendingPathComponent("dangling")
    try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: root.appendingPathComponent("absent"))
    let loop = root.appendingPathComponent("loop")
    try FileManager.default.createSymbolicLink(at: loop, withDestinationURL: loop)
    let regular = root.appendingPathComponent("regular")
    try Data().write(to: regular)
    let home = root.appendingPathComponent("person")
    for ancestor in [dangling, loop, regular] {
      let candidate = ancestor.appendingPathComponent("missing/child")
      XCTAssertThrowsError(try CanonicalPath.resolve(candidate))
      XCTAssertFalse(TestPathGuard.permits(candidate, userHome: home))
      XCTAssertFalse(TestPathGuard.permits(root.appendingPathComponent("safe"), userHome: ancestor))
      XCTAssertThrowsError(try DatabaseOpenScope.directory(root, excluding: [candidate]).validatePath(root.appendingPathComponent("safe.sqlite")))
      XCTAssertThrowsError(try OperationalDirectory.validatePath(candidate))
    }
  }

  func testUnavailableAncestorFailsClosed() throws {
    guard geteuid() != 0 else { throw XCTSkip("Requires ordinary user permissions") }
    let blocked = root.appendingPathComponent("blocked")
    try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: blocked.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path) }
    let candidate = blocked.appendingPathComponent("missing/child")
    XCTAssertThrowsError(try CanonicalPath.resolve(candidate))
    XCTAssertFalse(TestPathGuard.permits(candidate, userHome: root.appendingPathComponent("person")))
    XCTAssertThrowsError(try DatabaseOpenScope.directory(root).validatePath(candidate))
    XCTAssertThrowsError(try OperationalDirectory.validatePath(candidate))
  }

  // Ideal: a missing protected folder and an aliased home are protected before either exists.
  func testMissingProtectedFolderAndAliasedHome() throws {
    let home = root.appendingPathComponent("person")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let alias = root.appendingPathComponent("home-alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: home)
    for userHome in [home, alias] {
      for candidateHome in [home, alias] {
        let protected = candidateHome.appendingPathComponent("Library/Application Support/ActivityProbe")
        XCTAssertFalse(TestPathGuard.permits(protected.appendingPathComponent("missing/child"), userHome: userHome))
        XCTAssertFalse(TestPathGuard.permits(protected.appendingPathComponent("missing/child/invented.sqlite"), userHome: userHome))
      }
    }
    XCTAssertTrue(TestPathGuard.permits(root.appendingPathComponent("safe/missing/child"), userHome: alias))
    XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("Library").path))
  }
}
