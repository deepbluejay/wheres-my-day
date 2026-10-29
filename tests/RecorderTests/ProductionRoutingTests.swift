import Core
import Foundation
import Storage
import XCTest
@testable import Shell

final class ProductionRoutingTests: XCTestCase {
  // Ideal: production needs no isolation flags, and DB overrides move only the database.
  func testProductionAndExplicitIsolatedRouting() throws {
    let root = URL(fileURLWithPath: "/tmp/ap-routing-tests").appendingPathComponent(UUID().uuidString)
    let home = root.appendingPathComponent("person"), binary = root.appendingPathComponent("bin/ActivityProbe")
    let expected = home.appendingPathComponent("Library/Application Support/ActivityProbe", isDirectory: true)
    let production = try ActivityProbeEntry.recorderConfiguration(arguments: ["collect"], environment: [:], userHome: home, appBinary: binary)
    XCTAssertEqual(production.paths.appData, expected)
    XCTAssertEqual(production.paths.database, expected.appendingPathComponent("activity.sqlite"))
    XCTAssertFalse(production.isolated)
    let overridden = try ActivityProbeEntry.command(arguments: ["status"], environment: ["ACTIVITYPROBE_DB": root.appendingPathComponent("override.sqlite").path], userHome: home, appBinary: binary)
    XCTAssertEqual(overridden.paths.appData, expected)
    XCTAssertEqual(overridden.paths.codexHome, expected.appendingPathComponent("codex", isDirectory: true))
    XCTAssertEqual(overridden.paths.queryHelper, binary.deletingLastPathComponent().appendingPathComponent("ActivityQueryServer"))
    XCTAssertEqual(overridden.arguments, ["status"])
    XCTAssertNoThrow(try overridden.paths.databaseScope.validatePath(overridden.paths.database))
    for target in [[], ["timeline"], ["settings"], ["agent-window"]] {
      let parsed = try ActivityProbeEntry.command(arguments: target, environment: [:], userHome: home, appBinary: binary)
      XCTAssertNotNil(AppWindowTarget(arguments: parsed.arguments)); XCTAssertEqual(parsed.paths.appData, expected)
    }
    let isolated = try ActivityProbeEntry.recorderConfiguration(arguments: ["collect", "--isolated-root", root.path, "--app-data", root.appendingPathComponent("data").path], environment: ["ACTIVITYPROBE_DB": root.appendingPathComponent("invented.sqlite").path], userHome: home, appBinary: binary)
    XCTAssertTrue(isolated.isolated)
    // Unexpected recorder arguments are refused before any Mac source is constructed.
    XCTAssertThrowsError(try ActivityProbeEntry.recorderConfiguration(arguments: ["collect", "--isolated-root", root.path, "--app-data",
      root.appendingPathComponent("data").path, "--unknown", "/unavailable"], environment: ["ACTIVITYPROBE_DB": root.appendingPathComponent("invented.sqlite").path],
      userHome: home, appBinary: binary))
    XCTAssertThrowsError(try ActivityProbeEntry.command(arguments: ["status", "--app-data", expected.path], environment: [:], userHome: home, appBinary: binary))
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
  }
  // Ideal: fresh app data can start, but a deliberately disabled recorder touches no Mac adapters.
  func testFreshStartupAndDisabledEntry() throws {
    let root = URL(fileURLWithPath: "/tmp/ap-routing-tests").appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("person"), binary = root.appendingPathComponent("ActivityProbe")
    let configuration = try ActivityProbeEntry.recorderConfiguration(arguments: ["collect"], environment: [:], userHome: home, appBinary: binary)
    try FileManager.default.createDirectory(at: configuration.paths.appData, withIntermediateDirectories: true)
    XCTAssertTrue(try configuration.composition().recordingEnabledAtStartup())
    let store = try ActivityStorage(url: configuration.paths.database, appDataDirectory: configuration.paths.appData,
      databaseScope: configuration.paths.databaseScope)
    _ = try store.patchSettings(.edit(.recording(false), ownBundleID: AppPaths.bundleID, now: 100))
    XCTAssertFalse(try configuration.composition().recordingEnabledAtStartup())
    XCTAssertEqual(ActivityProbeEntry.run(arguments: ["collect"], environment: [:], userHome: home, appBinary: binary,
      adapters: .refusing("the disabled collect")), 0)
    XCTAssertEqual(ActivityProbeEntry.run(arguments: ["status"], environment: [:], userHome: home, appBinary: binary), 0)
  }
  // Ideal: a plain swift test invocation protects the real home, even with an explicit override.
  func testDefaultTestGuardIsAutomaticAndCoversDescendants() {
    XCTAssertEqual(ActivityProbeEntry.run(arguments: ["selftest"], environment: [:],
      userHome: FileManager.default.homeDirectoryForCurrentUser, appBinary: URL(fileURLWithPath: "/invented/ActivityProbe")), 2)
    XCTAssertTrue(TestPathGuard.active)
    let real = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ActivityProbe")
    XCTAssertFalse(TestPathGuard.permits(real))
    XCTAssertFalse(TestPathGuard.permits(real.appendingPathComponent("codex/invented")))
    XCTAssertFalse(TestPathGuard.permits(real.appendingPathComponent("activity.sqlite")))
    XCTAssertTrue(TestPathGuard.permits(URL(fileURLWithPath: "/tmp/ap-routing-tests/invented")))
    XCTAssertTrue(TestPathGuard.permits(real, testing: false))
  }
}
