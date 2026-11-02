import AppKit
import Combine
@testable import Core
import Foundation
import Outbound
@testable import Shell
@testable import Storage
import XCTest

private final class RefreshConnector: SubscriptionConnector {
  func connect() throws {}
  func cancel() {}
}

/// The window's reader on an invented database, with a second connection standing in for the recorder or the CLI.
/// Two connections see each other only through committed rows, as two processes do.
private final class RefreshFixture {
  static let dayStart = 20_000 * 86400 + 4 * 3600
  let root: URL, url: URL
  let other: ActivityStorage
  var now = RefreshFixture.dayStart + 3600 + 5
  var health = TimelineHealth()
  var opens = 0
  var failOpen = false
  /// Here the check answers before the read goes on, so these tests see health on the same read.
  /// The tests under "Slow health work" run it on its own thread, as the product does.
  var runHealth: (@escaping () -> Void) -> Void = { $0() }
  var chatGPT = ChatGPTStatusReader(account: ChatGPTSession(store: InMemoryChatGPTCredentialStore(), lock: ChatGPTCredentialLock(file: nil), openBrowser: { _ in false }))
  var calendar: Calendar = {
    var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0)!; return value
  }()
  lazy var reader: AppWindowDayReader = {
    let url = url, root = root
    return AppWindowDayReader(open: { [unowned self] in
      self.opens += 1
      if self.failOpen { throw StorageError("Invented open failure") }
      return try ActivityStorage(url: url, appDataDirectory: root, readOnly: true, databaseScope: .directory(root))
    }, edits: try! ActivityStorage(url: url, appDataDirectory: root, databaseScope: .directory(root)), health: { [unowned self] in self.health },
    chatGPT: chatGPT,
    clock: { [unowned self] in self.now }, calendar: { [unowned self] in self.calendar },
    runHealth: { [unowned self] in self.runHealth($0) })
  }()
  init() throws {
    root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ACTIVITYPROBE_TEST_ROOT"] ?? "/tmp/ap-window-tests")
      .appendingPathComponent("r-" + UUID().uuidString.prefix(8))
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    url = root.appendingPathComponent("invented.sqlite")
    other = try ActivityStorage(url: url, appDataDirectory: root, databaseScope: .directory(root))
    try other.saveFixtureSettings(StorageSettings(subscriptionConnected: true).withClaudeUse, at: 0)
  }
  deinit { try? FileManager.default.removeItem(at: root) }
  func sample(_ ts: Int, input: Bool = true) throws {
    try other.locked {
      try other.connection.run("""
        INSERT INTO samples(ts,bundle_id,app,window,document_key,keys,clicks,scrolls,moved,synthetic,keeping_awake,excluded)
        VALUES(?,'invented.editor','Invented editor','Invented title','invented/document',?,0,0,0,0,0,0)
        """, [.integer(ts), .integer(input ? 1 : 0)])
    }
  }
  func read(_ selected: Date? = nil) throws -> AppWindowSnapshot { try reader.read(selectedDate: selected) }
  func forget(_ range: TimeRange) throws {
    let preview = try other.previewDeletion(in: range)
    _ = try other.deleteRecords(in: range, confirmation: preview.confirmation)
  }
  func state(_ snapshot: AppWindowSnapshot, at minute: Int) -> SummaryMinuteKind? {
    snapshot.day.entries.first { $0.range.start <= minute && $0.range.end > minute }?.state
  }
  func name(_ snapshot: AppWindowSnapshot, at minute: Int) -> String? {
    snapshot.day.entries.first { $0.range.start <= minute && $0.range.end > minute }?.name
  }
}

final class AppWindowRefreshTests: XCTestCase {
  private let start = RefreshFixture.dayStart
  private func notices(_ snapshot: AppWindowSnapshot) -> [TimelineNoticeKind] { snapshot.day.notices.map(\.kind) }

  // MARK: The grid is reused only while nothing it shows can have changed.

  func testTheUnfinishedMinuteGrowingDoesNotRecomputeTheGrid() throws {
    let f = try RefreshFixture()
    try f.sample(start + 60)
    let first = try f.read()
    for offset in 1...40 {
      f.now += 1
      // The recorder's row for the second that just passed, in the unfinished minute.
      try f.sample(f.now - 1)
      XCTAssertEqual(try f.read().day, first.day, "second \(offset)")
    }
    XCTAssertEqual(f.reader.gridReads, 1)
    XCTAssertEqual(f.opens, 1, "the connection stays open between reads")
  }
  func testAFinishedMinuteShowsAtTheBoundary() throws {
    let f = try RefreshFixture()
    let minute = TimelineDay.floorMinute(f.now)
    _ = try f.read()
    try f.sample(minute + 2)
    XCTAssertNil(f.state(try f.read(), at: minute), "the unfinished minute waits")
    f.now = minute + 60
    XCTAssertEqual(f.state(try f.read(), at: minute), .unsummarized)
    XCTAssertEqual(f.reader.gridReads, 2)
  }
  func testALateRowInAFinishedMinuteShowsOnTheNextRead() throws {
    let f = try RefreshFixture()
    _ = try f.read()
    try f.sample(start + 120)
    XCTAssertEqual(f.state(try f.read(), at: start + 120), .unsummarized)
  }

  // MARK: Privacy: nothing removed stays on screen for longer than one read.

  func testForgetFromAnotherConnectionIsGoneOnTheNextRead() throws {
    let f = try RefreshFixture()
    try f.sample(start + 60)
    try f.sample(start + 600)
    try f.other.appendIntervals([NamedInterval(range: TimeRange(start + 540, start + 720), name: "Invented task", kind: .work)])
    let before = try f.read()
    XCTAssertEqual(f.name(before, at: start + 600), "Invented task")
    XCTAssertEqual(f.state(before, at: start + 60), .unsummarized)
    // Only part of the interval is in the range, and forget removes the whole interval.
    try f.forget(TimeRange(start + 540, start + 600))
    let after = try f.read()
    XCTAssertEqual(f.state(after, at: start + 60), .unsummarized)
    for minute in stride(from: start + 540, to: start + 720, by: 60) {
      XCTAssertNil(f.name(after, at: minute), "minute \(minute - start)")
      XCTAssertNotEqual(f.state(after, at: minute), .work, "minute \(minute - start)")
    }
    XCTAssertFalse(after.day.entries.contains { $0.name == "Invented task" })
    XCTAssertFalse(after.day.groups.contains { $0.name == "Invented task" })
  }
  /// A real other process, with no connection or lock shared with this one.
  func testAForgetCommittedByAnotherProcessIsGoneOnTheNextRead() throws {
    let f = try RefreshFixture()
    try f.sample(start + 60)
    try f.other.appendIntervals([NamedInterval(range: TimeRange(start + 60, start + 120), name: "Invented task", kind: .work)])
    XCTAssertEqual(f.name(try f.read(), at: start + 60), "Invented task")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = [f.url.path, """
      BEGIN;
      INSERT INTO forgotten_ranges(start_ts,end_ts) VALUES(\(start + 60),\(start + 120));
      DELETE FROM samples WHERE ts>=\(start + 60) AND ts<\(start + 120);
      DELETE FROM intervals WHERE end_ts>\(start + 60) AND start_ts<\(start + 120);
      COMMIT;
      """]
    try process.run(); process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
    let after = try f.read()
    XCTAssertNil(f.state(after, at: start + 60))
    XCTAssertFalse(after.day.entries.contains { $0.name == "Invented task" })
  }
  /// The kept grid is one entry: a day read before a forget must not come back when it is selected again.
  func testAForgottenDayDoesNotComeBackWhenSelectedAgain() throws {
    let f = try RefreshFixture()
    let yesterday = start - 86400
    let selected = Date(timeIntervalSince1970: Double(yesterday))
    try f.sample(yesterday + 60)
    XCTAssertEqual(f.state(try f.read(selected), at: yesterday + 60), .unsummarized)
    _ = try f.read()
    try f.forget(TimeRange(yesterday, yesterday + 120))
    _ = try f.read()
    XCTAssertNil(f.state(try f.read(selected), at: yesterday + 60))
  }
  /// Forget on the day being looked at, with the window on that past day and no minute passing.
  func testForgetOnASelectedPastDayIsGoneOnTheNextRead() throws {
    let f = try RefreshFixture()
    let yesterday = start - 86400
    let selected = Date(timeIntervalSince1970: Double(yesterday))
    try f.sample(yesterday + 60)
    XCTAssertEqual(f.state(try f.read(selected), at: yesterday + 60), .unsummarized)
    try f.forget(TimeRange(yesterday, yesterday + 120))
    XCTAssertNil(f.state(try f.read(selected), at: yesterday + 60))
  }
  /// Forget commits its marker and its row deletes in separate batches. Each commit shows on its own read:
  /// an input second inside the range keeps the minutes after the range lit until its row is gone.
  func testEachCommitOfABatchedForgetShowsOnItsOwnRead() throws {
    let f = try RefreshFixture()
    let last = start + 600 - 1
    try f.sample(last)
    XCTAssertEqual(f.state(try f.read(), at: start + 600), .unsummarized)
    try f.other.locked { try f.other.connection.run("INSERT INTO forgotten_ranges(start_ts,end_ts) VALUES(?,?)", [.integer(start + 540), .integer(start + 600)]) }
    let marked = try f.read()
    XCTAssertNil(f.state(marked, at: start + 540), "the marker alone hides the range")
    XCTAssertEqual(f.state(marked, at: start + 600), .unsummarized)
    try f.other.locked { try f.other.connection.run("DELETE FROM samples WHERE ts=?", [.integer(last)]) }
    XCTAssertNil(f.state(try f.read(), at: start + 600), "the row's own delete shows too")
  }
  func testForgetOfARangeWithoutRowsShowsAsRest() throws {
    let f = try RefreshFixture()
    try f.sample(start + 60)
    _ = try f.read()
    try f.other.locked { try f.other.connection.run("INSERT INTO forgotten_ranges(start_ts,end_ts) VALUES(?,?)", [.integer(start + 60), .integer(start + 120)]) }
    XCTAssertNil(f.state(try f.read(), at: start + 60))
  }
  /// Retention scrubs metadata and evidence, none of which the grid shows, and leaves what the grid counts.
  func testRetentionFromAnotherConnectionLeavesTheGridCorrect() throws {
    let f = try RefreshFixture()
    try f.sample(start + 60)
    try f.other.appendIntervals([NamedInterval(range: TimeRange(start + 120, start + 180), name: "Invented task", kind: .work)])
    let before = try f.read()
    _ = try f.other.cleanRetention(at: f.now + 400 * 86400)
    let after = try f.read()
    XCTAssertEqual(after.day, before.day)
    XCTAssertEqual(f.state(after, at: start + 60), .unsummarized)
    XCTAssertEqual(f.name(after, at: start + 120), "Invented task")
  }
  func testAReplacedDatabaseFileIsReadOnTheNextRead() throws {
    let f = try RefreshFixture()
    try f.sample(start + 60)
    XCTAssertEqual(f.state(try f.read(), at: start + 60), .unsummarized)
    let replacement = f.root.appendingPathComponent("replacement.sqlite")
    let store = try ActivityStorage(url: replacement, appDataDirectory: f.root, databaseScope: .directory(f.root))
    try store.saveFixtureSettings(StorageSettings(subscriptionConnected: true).withClaudeUse, at: 0)
    _ = store.connection.truncateWAL()
    // The old file's side files go with it, as a new file must not meet an old write-ahead log.
    for suffix in ["", "-wal", "-shm"] { _ = rename(f.url.path + suffix, f.url.path + ".old" + suffix) }
    XCTAssertEqual(rename(replacement.path, f.url.path), 0)
    // A read-only connection needs a writer to have opened the file first, as the recorder and the window's own settings connection do.
    let writer = try ActivityStorage(url: f.url, appDataDirectory: f.root, databaseScope: .directory(f.root))
    defer { withExtendedLifetime(writer) {} }
    XCTAssertNil(f.state(try f.read(), at: start + 60))
    XCTAssertEqual(f.opens, 2)
  }
  func testAFailedOpenDropsTheKeptGridAndTheNextReadReopens() throws {
    let f = try RefreshFixture()
    try f.sample(start + 60)
    _ = try f.read()
    XCTAssertEqual(rename(f.url.path, f.url.path + ".moved"), 0)
    f.failOpen = true
    XCTAssertThrowsError(try f.read())
    f.failOpen = false
    XCTAssertEqual(rename(f.url.path + ".moved", f.url.path), 0)
    XCTAssertEqual(f.state(try f.read(), at: start + 60), .unsummarized)
    XCTAssertEqual(f.reader.gridReads, 2)
  }
  /// No revision input sees a sample rewritten in place, and no code path does that today. A minute still ends it.
  func testAKeptGridLivesAtMostAMinuteOnAPastDayToo() throws {
    let f = try RefreshFixture()
    let yesterday = start - 86400
    let selected = Date(timeIntervalSince1970: Double(yesterday))
    try f.sample(yesterday + 60, input: false)
    XCTAssertNil(f.state(try f.read(selected), at: yesterday + 60))
    try f.other.locked { try f.other.connection.run("UPDATE samples SET keys=1 WHERE ts=?", [.integer(yesterday + 60)]) }
    XCTAssertNil(f.state(try f.read(selected), at: yesterday + 60))
    f.now += 60
    XCTAssertEqual(f.state(try f.read(selected), at: yesterday + 60), .unsummarized)
  }

  // MARK: Notices and health come from every read, whether or not the grid was kept.

  func testNoticesFollowSettingsHealthAndCallsOnEveryRead() throws {
    let f = try RefreshFixture()
    _ = try f.read()
    let grid = f.reader.gridReads
    // Health closure: permissions, FileVault, backup exclusion.
    f.health.missingPermissions = [.accessibility]
    XCTAssertTrue(notices(try f.read()).contains(.accessibility))
    f.health.missingPermissions = []
    XCTAssertFalse(notices(try f.read()).contains(.accessibility))
    f.health.security.fileVault = .off
    XCTAssertTrue(notices(try f.read()).contains(.fileVaultOff))
    f.health.security.backupExclusionFailure = .backupExclusionFailed
    XCTAssertTrue(notices(try f.read()).contains(.backupExclusion))
    // A settings row the recorder writes: paused until a time, which the clock also ends.
    let until = f.now + 5
    try f.other.saveSummaryUnavailableUntil(Double(until))
    let paused = try f.read()
    XCTAssertTrue(notices(paused).contains(.summaryPaused))
    XCTAssertEqual(paused.health.summary?.serviceUnavailableUntil, Double(until))
    f.now = until + 1
    XCTAssertFalse(notices(try f.read()).contains(.summaryPaused))
    // The Claude connection, in settings.
    _ = try f.other.patchSettings(.disconnectClaude)
    XCTAssertTrue(notices(try f.read()).contains(.subscription))
    XCTAssertEqual(f.reader.gridReads, grid, "none of these recompute the grid")
  }
  func testASummaryFailureAndItsRetryShowOnTheNextRead() throws {
    let f = try RefreshFixture()
    _ = try f.read()
    let range = TimeRange(start, start + 60)
    _ = try f.other.appendModelCall(ModelCall(ts: start + 60, range: range, model: "invented", succeeded: false))
    let failed = try f.read()
    XCTAssertTrue(notices(failed).contains(.summaryFailure))
    XCTAssertEqual(failed.health.summary?.failedRanges, [range])
    f.now += 1
    XCTAssertEqual(try f.read().health.summary?.failedRanges, [range], "a kept grid keeps its failures")
    _ = try f.other.appendModelCall(ModelCall(ts: start + 120, range: range, model: "invented", succeeded: true))
    XCTAssertFalse(notices(try f.read()).contains(.summaryFailure))
  }
  func testADeferredNoticeHidesAndClearsWhenItsProblemGoes() throws {
    let f = try RefreshFixture()
    f.health.missingPermissions = [.accessibility]
    XCTAssertTrue(notices(try f.read()).contains(.accessibility))
    var settings = try f.other.settings()
    TimelineNotices.deferNotice(.accessibility, in: &settings)
    try f.other.saveFixtureSettings(settings, at: 0)
    XCTAssertFalse(notices(try f.read()).contains(.accessibility))
    XCTAssertEqual(f.reader.gridReads, 1)
    f.health.missingPermissions = []
    _ = try f.read()
    XCTAssertEqual(try f.other.settings().general[TimelineNotices.deferredSettingKey], "[]", "resolved while the grid was kept")
  }

  // MARK: Summaries, day changes and settings show on the next read.

  func testANewSummaryIntervalShowsOnTheNextRead() throws {
    let f = try RefreshFixture()
    try f.sample(start + 60)
    XCTAssertEqual(f.state(try f.read(), at: start + 60), .unsummarized)
    try f.other.appendIntervals([NamedInterval(range: TimeRange(start + 60, start + 120), name: "Invented task", kind: .work)])
    let after = try f.read()
    XCTAssertEqual(f.state(after, at: start + 60), .work)
    XCTAssertEqual(f.name(after, at: start + 60), "Invented task")
  }
  func testACompletedCallShowsOnTheNextRead() throws {
    let f = try RefreshFixture()
    try f.sample(start + 60)
    XCTAssertEqual(f.state(try f.read(), at: start + 60), .unsummarized)
    _ = try f.other.appendModelCall(ModelCall(ts: start + 200, range: TimeRange(start, start + 180), model: "invented", succeeded: true))
    XCTAssertEqual(f.state(try f.read(), at: start + 60), .unnamed)
  }
  /// A call without sent-table facts rebuilds its rest tail from what follows its end, so a row in the
  /// unfinished minute can change a finished one. Only for such a call does that minute count.
  func testARowAfterALegacyCallEndChangesItsRestTailOnTheNextRead() throws {
    let f = try RefreshFixture()
    let end = TimelineDay.floorMinute(f.now)
    // Its input age reaches into the call but stops short of the call's end.
    try f.sample(end - 310)
    _ = try f.other.appendModelCall(ModelCall(ts: end, range: TimeRange(end - 180, end), model: "invented", succeeded: true))
    XCTAssertNil(f.state(try f.read(), at: end - 60), "rest while nothing follows the call")
    try f.sample(end + 1)
    XCTAssertEqual(f.state(try f.read(), at: end - 60), .unnamed)
  }
  func testDayRolloverDateSelectionDayStartAndTimeZoneShowOnTheNextRead() throws {
    let f = try RefreshFixture()
    XCTAssertEqual(try f.read().day.range.start, start)
    f.now = start + 86400
    XCTAssertEqual(try f.read().day.range.start, start + 86400)
    let earlier = Date(timeIntervalSince1970: Double(start - 86400))
    XCTAssertEqual(try f.read(earlier).day.range.start, start - 86400)
    XCTAssertEqual(try f.read().day.range.start, start + 86400)
    _ = try f.other.patchSettings(.edit(.dayStart(6), ownBundleID: AppPaths.bundleID, now: f.now))
    let moved = try f.read()
    // Four in the morning is before a six o'clock start, so it is still the previous date's day.
    XCTAssertEqual(moved.day.range.start, start + 2 * 3600)
    XCTAssertEqual(moved.dayStartHour, 6)
    f.calendar.timeZone = TimeZone(secondsFromGMT: 3600)!
    XCTAssertEqual(try f.read().day.range.start, moved.day.range.start - 3600)
  }
  @MainActor func testSettingsFromAnotherConnectionShowOnEveryRefresh() async throws {
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ACTIVITYPROBE_TEST_ROOT"] ?? "/tmp/ap-window-tests")
      .appendingPathComponent("s-" + UUID().uuidString.prefix(8))
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("invented.sqlite")
    let other = try ActivityStorage(url: url, appDataDirectory: root, databaseScope: .directory(root))
    let paths = AppPaths(userHome: root.appendingPathComponent("user"), appData: root, database: url,
      appBinary: root.appendingPathComponent("bin/ActivityProbe"), queryHelper: root.appendingPathComponent("bin/ActivityQueryServer"))
    var factories = AppFactories()
    factories.claudeConnector = { _, _ in RefreshConnector() }
    factories.chatGPT = { _ in ChatGPTSession(store: InMemoryChatGPTCredentialStore(), lock: ChatGPTCredentialLock(file: nil), openBrowser: { _ in false }) }
    factories.chatGPTTokens = { _ in ChatGPTSession(store: InMemoryChatGPTCredentialStore(), lock: ChatGPTCredentialLock(file: nil), openBrowser: { _ in false }) }
    let (model, _) = try AppComposition(paths: paths, factories: factories).windowModel(
      codex: .fixed(root.appendingPathComponent("absent-codex")), claude: .fixed(root.appendingPathComponent("absent-claude")), health: { TimelineHealth() })
    defer { model.close() }
    await model.refresh()
    let first = try XCTUnwrap(model.snapshot)
    let now = Int(Date().timeIntervalSince1970)
    func edit(_ edit: SettingsEdit) throws { _ = try other.patchSettings(.edit(edit, ownBundleID: AppPaths.bundleID, now: now)) }
    try edit(.addApp("invented.excluded"))
    await model.refresh()
    XCTAssertTrue(model.settings.settings.excludedApps.contains("invented.excluded"), "a new exclusion")
    try edit(.recording(false))
    await model.refresh()
    XCTAssertFalse(model.settings.settings.recordingEnabled, "recording off")
    try edit(.recording(true))
    try edit(.pause(now + 600))
    await model.refresh()
    XCTAssertEqual(model.settings.settings.pausedUntil, now + 600, "pause")
    try edit(.retention(screen: 7, prompt: 8))
    await model.refresh()
    XCTAssertEqual(model.settings.settings.screenRetentionDays, 7, "retention")
    var general = try other.settings()
    general.general["outputLanguage"] = "fr-FR"
    try other.saveFixtureSettings(general, at: 0)
    await model.refresh()
    XCTAssertEqual(model.settings.settings.general["outputLanguage"], "fr-FR", "language")
    try edit(.dayStart(first.dayStartHour == 4 ? 5 : 4))
    await model.refresh()
    XCTAssertNotEqual(model.snapshot?.dayStartHour, first.dayStartHour, "day start")
    // A forget from another connection, through the whole model.
    let start = try XCTUnwrap(model.snapshot).day.range.start
    try other.appendIntervals([NamedInterval(range: TimeRange(start, start + 60), name: "Invented task", kind: .work)])
    await model.refresh()
    XCTAssertTrue(model.snapshot?.day.entries.contains { $0.name == "Invented task" } == true || now - start < 60)
    let preview = try other.previewDeletion(in: TimeRange(start, start + 60))
    _ = try other.deleteRecords(in: TimeRange(start, start + 60), confirmation: preview.confirmation)
    await model.refresh()
    XCTAssertFalse(model.snapshot?.day.entries.contains { $0.name == "Invented task" } == true)
  }

  // MARK: The loop.

  private final class Reads {
    var count = 0
    var gate: CheckedContinuation<Void, Never>?
    var holding = false
    var value = 0
  }
  @MainActor private func loopModel(_ reads: Reads) throws -> (AppWindowModel, URL) {
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ACTIVITYPROBE_TEST_ROOT"] ?? "/tmp/ap-window-tests")
      .appendingPathComponent("l-" + UUID().uuidString.prefix(8))
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let store = try ActivityStorage(url: root.appendingPathComponent("invented.sqlite"), appDataDirectory: root, databaseScope: .directory(root))
    let settings = try SettingsController.forDatabase(store: store, connector: RefreshConnector(), ownBundleID: AppPaths.bundleID, claudeConnector: RefreshConnector())
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let start = RefreshFixture.dayStart
    let model = AppWindowModel(settings: settings, makeConversation: { throw ConversationError.unavailable }, readDay: { _ in
      reads.count += 1
      if reads.holding { await withCheckedContinuation { reads.gate = $0 } }
      let day = TimelineDay.make(range: TimeRange(start, start + 86400), minutes: [:], intervals: [], now: start + 3600, calendar: calendar)
      var health = TimelineHealth(); health.security.fileVault = reads.value == 0 ? .on : .off
      return AppWindowSnapshot(day: day, health: health, dayStartHour: 4, now: start + 3600)
    }, readMonth: { _ in [] })
    model.refreshInterval = .milliseconds(5)
    return (model, root)
  }
  @MainActor private func settle() async throws { try await Task.sleep(for: .milliseconds(60)) }
  @MainActor private func until(tries: Int = 1000, _ condition: () -> Bool) async throws {
    for _ in 0..<tries where !condition() { try await Task.sleep(for: .milliseconds(2)) }
  }
  /// One loop sleeps its whole interval between reads, so this many reads is the most it can make.
  private func mostReads(in elapsed: Duration, at interval: Duration) -> Int { Int(elapsed / interval) + 2 }
  @MainActor private func readsDuring(_ wait: Duration, _ reads: Reads) async throws -> (count: Int, elapsed: Duration) {
    let clock = ContinuousClock(), began = clock.now, before = reads.count
    try await Task.sleep(for: wait)
    return (reads.count - before, began.duration(to: clock.now))
  }
  @MainActor func testAHiddenWindowTicksSlowlyAndCatchesUpWhenShown() async throws {
    let reads = Reads()
    let (model, root) = try loopModel(reads)
    defer { model.close(); try? FileManager.default.removeItem(at: root) }
    model.hiddenRefreshInterval = .milliseconds(100)
    model.start()
    try await settle()
    XCTAssertGreaterThan(reads.count, 1, "visible: the loop runs")
    model.setWindowVisible(false)
    try await settle()
    let hidden = try await readsDuring(.milliseconds(350), reads)
    XCTAssertGreaterThanOrEqual(hidden.count, 1, "hidden: still reads")
    XCTAssertLessThanOrEqual(hidden.count, mostReads(in: hidden.elapsed, at: .milliseconds(100)), "hidden: slowly")
    // A late start from the view does not add a loop or speed it up.
    model.start()
    let afterStart = try await readsDuring(.milliseconds(250), reads)
    XCTAssertLessThanOrEqual(afterStart.count, mostReads(in: afterStart.elapsed, at: .milliseconds(100)))
    // A change while hidden shows on the first read after showing, with no hidden tick due.
    // The sleep under way keeps its old length, so wait for the tick that starts the long one.
    model.hiddenRefreshInterval = .seconds(60)
    let seen = reads.count
    try await until { reads.count > seen }
    XCTAssertGreaterThan(reads.count, seen)
    let quiet = reads.count
    reads.value = 1
    try await settle()
    XCTAssertEqual(reads.count, quiet, "no hidden tick due")
    model.setWindowVisible(true)
    try await until { model.snapshot?.health.security.fileVault == .off }
    XCTAssertEqual(model.snapshot?.health.security.fileVault, .off)
    XCTAssertGreaterThan(reads.count, quiet)
  }
  /// At the real pace, through the real composition: a forget from another connection, with no notification at all.
  @MainActor func testAHiddenWindowReadsAtTheRealPaceAndCatchesAForgetWithinFiveSeconds() async throws {
    final class Counter { let lock = NSLock(); var value = 0
      func add() { lock.lock(); value += 1; lock.unlock() }
      var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }
    let checks = Counter()
    let (model, other, root) = try composedModel(health: { checks.add(); return TimelineHealth() })
    defer { model.close(); try? FileManager.default.removeItem(at: root) }
    XCTAssertEqual(model.refreshInterval, .seconds(1))
    XCTAssertEqual(model.hiddenRefreshInterval, .seconds(5))
    let range = try await finishedMinuteOfToday(model)
    try other.appendIntervals([NamedInterval(range: range, name: "Invented task", kind: .work)])
    model.start()
    try await until { self.hasName(model) }
    XCTAssertTrue(hasName(model))
    model.setWindowVisible(false)
    // The visible loop's last one-second sleep ends, so everything from here is at the hidden pace.
    try await Task.sleep(for: .seconds(1.2))
    // Forget just after a tick's read, the worst moment: the whole sleep lies ahead.
    let ticked = checks.count
    try await until(tries: 3000) { checks.count > ticked }
    XCTAssertGreaterThan(checks.count, ticked, "a hidden window still ticks")
    try await Task.sleep(for: .milliseconds(200))
    let clock = ContinuousClock(), began = clock.now
    try forget(range, on: other)
    try await until(tries: 3000) { !self.hasName(model) }
    XCTAssertFalse(hasName(model), "the forget showed while hidden")
    let waited = began.duration(to: clock.now)
    XCTAssertLessThan(waited, .seconds(6), "about five seconds, with room for a loaded machine")
    XCTAssertGreaterThan(waited, .seconds(3), "not the visible pace")
    XCTAssertFalse(model.windowVisible)
  }
  @MainActor func testAWrongHiddenReportRecoversOnTheNextHiddenTick() async throws {
    let reads = Reads()
    let (model, root) = try loopModel(reads)
    defer { model.close(); try? FileManager.default.removeItem(at: root) }
    // Far from the visible pace, so a loaded machine cannot blur the two.
    model.hiddenRefreshInterval = .milliseconds(200)
    var onScreen = false
    let host = hostFor(model) { onScreen }
    model.start()
    try await settle()
    // The notification reports hidden, and the window's real occlusion says the same.
    host.windowDidChangeOcclusionState(occlusionNote)
    XCTAssertFalse(model.windowVisible)
    try await settle()
    let hiddenReads = reads.count
    try await until { reads.count > hiddenReads }
    XCTAssertGreaterThan(reads.count, hiddenReads, "a hidden tick ran")
    XCTAssertFalse(model.windowVisible, "a hidden tick that finds it hidden stays hidden")
    // The window comes back and its notification is missed: no call at all reaches the model.
    onScreen = true
    try await until { model.windowVisible }
    XCTAssertTrue(model.windowVisible, "the next hidden tick found it")
    // Back at the visible pace, which only a loop that is really awake can reach.
    let visible = try await readsDuring(.milliseconds(200), reads)
    XCTAssertGreaterThan(visible.count, mostReads(in: visible.elapsed, at: .milliseconds(200)))
    // A wrong report: the notification path says hidden once, and the real occlusion says visible.
    model.setWindowVisible(false)
    XCTAssertFalse(model.windowVisible)
    try await until { model.windowVisible }
    XCTAssertTrue(model.windowVisible, "the next tick corrected the report")
    withExtendedLifetime(host) {}
  }
  /// The worst case: occlusion itself keeps saying hidden for a window someone can see. Its reads still run.
  @MainActor func testAnOcclusionValueThatStaysWrongStillReadsEachHiddenTick() async throws {
    let reads = Reads()
    let (model, root) = try loopModel(reads)
    defer { model.close(); try? FileManager.default.removeItem(at: root) }
    model.hiddenRefreshInterval = .milliseconds(20)
    let host = hostFor(model) { false }
    host.windowDidChangeOcclusionState(occlusionNote)
    XCTAssertFalse(model.windowVisible)
    try await until { model.snapshot != nil }
    reads.value = 1
    try await until { model.snapshot?.health.security.fileVault == .off }
    XCTAssertEqual(model.snapshot?.health.security.fileVault, .off, "shown by a hidden tick")
    XCTAssertFalse(model.windowVisible)
    withExtendedLifetime(host) {}
  }
  @MainActor func testBecomingKeyShowsAtOnceWithNoHiddenTickDue() async throws {
    let reads = Reads()
    let (model, root) = try loopModel(reads)
    defer { model.close(); try? FileManager.default.removeItem(at: root) }
    model.hiddenRefreshInterval = .seconds(60)
    let host = hostFor(model) { false }
    model.start()
    try await settle()
    host.windowDidChangeOcclusionState(occlusionNote)
    try await settle()
    let before = reads.count
    host.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
    XCTAssertTrue(model.windowVisible)
    try await until { reads.count > before }
    XCTAssertGreaterThan(reads.count, before)
  }
  /// Closed means no read and no look at the window, however the close came and whatever arrives afterwards.
  @MainActor func testClosedMeansNoTickAtAll() async throws {
    let reads = Reads()
    let (model, root) = try loopModel(reads)
    defer { try? FileManager.default.removeItem(at: root) }
    model.hiddenRefreshInterval = .milliseconds(5)
    var looks = 0
    let host = hostFor(model) { looks += 1; return false }
    model.start()
    try await settle()
    host.windowDidChangeOcclusionState(occlusionNote)
    try await settle()
    XCTAssertGreaterThan(looks, 1, "hidden ticks look at the window")
    host.windowWillClose(Notification(name: NSWindow.willCloseNotification))
    XCTAssertTrue(model.closed); XCTAssertNil(host.model)
    await Task.yield()
    let (count, looked) = (reads.count, looks)
    model.setWindowVisible(true)
    model.setWindowVisible(false)
    model.windowOcclusionChanged()
    model.start()
    await model.refresh()
    try await settle()
    XCTAssertEqual(reads.count, count)
    XCTAssertEqual(looks, looked + 1, "only the explicit occlusion call above")
  }
  @MainActor func testClosingAHiddenWindowLeavesNothingRunning() async throws {
    let reads = Reads()
    let (model, root) = try loopModel(reads)
    defer { try? FileManager.default.removeItem(at: root) }
    model.hiddenRefreshInterval = .milliseconds(5)
    model.start()
    try await settle()
    model.setWindowVisible(false)
    model.close()
    await Task.yield()
    let count = reads.count
    model.setWindowVisible(true)
    model.start()
    try await settle()
    XCTAssertEqual(reads.count, count)
  }
  @MainActor func testQuickHideAndShowLeaveOneLoop() async throws {
    let reads = Reads()
    let (model, root) = try loopModel(reads)
    defer { model.close(); try? FileManager.default.removeItem(at: root) }
    model.refreshInterval = .milliseconds(30)
    model.hiddenRefreshInterval = .milliseconds(90)
    model.start()
    for _ in 0..<50 { model.setWindowVisible(false); model.setWindowVisible(true); await Task.yield() }
    try await settle()
    let shown = try await readsDuring(.milliseconds(300), reads)
    XCTAssertGreaterThan(shown.count, 0)
    XCTAssertLessThanOrEqual(shown.count, mostReads(in: shown.elapsed, at: .milliseconds(30)), "ends shown")
    for _ in 0..<50 { model.setWindowVisible(true); model.setWindowVisible(false); await Task.yield() }
    try await settle()
    let hidden = try await readsDuring(.milliseconds(450), reads)
    XCTAssertGreaterThan(hidden.count, 0)
    XCTAssertLessThanOrEqual(hidden.count, mostReads(in: hidden.elapsed, at: .milliseconds(90)), "ends hidden")
  }
  /// Every order the view's task and the host's reports can come in leaves a loop running.
  @MainActor func testTheLoopRunsAfterEveryOrderOfStartHideAndShow() async throws {
    enum Step: CaseIterable { case start, hide, show }
    for first in Step.allCases { for second in Step.allCases { for third in Step.allCases {
      let reads = Reads()
      let (model, root) = try loopModel(reads)
      defer { model.close(); try? FileManager.default.removeItem(at: root) }
      model.hiddenRefreshInterval = .milliseconds(5)
      for step in [first, second, third] {
        switch step {
        case .start: model.start()
        case .hide: model.setWindowVisible(false)
        case .show: model.setWindowVisible(true)
        }
        await Task.yield()
      }
      try await until { reads.count > 1 }
      XCTAssertGreaterThan(reads.count, 1, "\(first) \(second) \(third)")
    } } }
  }
  /// The hide cancels a running read, and its answer is dropped. A show during that read must still read.
  @MainActor func testShowingDuringADiscardedReadReadsAgain() async throws {
    let reads = Reads()
    let (model, root) = try loopModel(reads)
    defer { model.close(); try? FileManager.default.removeItem(at: root) }
    reads.holding = true
    // Long enough that only the read after the discarded one can publish within this test.
    model.refreshInterval = .seconds(60)
    model.start()
    try await until { reads.gate != nil }
    XCTAssertEqual(reads.count, 1)
    model.setWindowVisible(false)
    model.setWindowVisible(true)
    try await settle()
    reads.holding = false
    reads.gate?.resume(); reads.gate = nil
    try await until { model.snapshot != nil }
    XCTAssertNotNil(model.snapshot, "a read after the discarded one published")
    XCTAssertGreaterThanOrEqual(reads.count, 2)
  }
  @MainActor func testASecondInWhichNothingChangedPublishesNothing() async throws {
    let reads = Reads()
    let (model, root) = try loopModel(reads)
    defer { model.close(); try? FileManager.default.removeItem(at: root) }
    await model.refresh()
    let first = try XCTUnwrap(model.snapshot)
    var published = 0
    let observer = model.objectWillChange.sink { published += 1 }
    defer { observer.cancel() }
    await model.refresh(); await model.refresh()
    XCTAssertEqual(published, 0)
    reads.value = 1
    await model.refresh()
    XCTAssertEqual(published, 1)
    XCTAssertNotEqual(model.snapshot?.health, first.health)
  }

  private var occlusionNote: Notification { Notification(name: NSWindow.didChangeOcclusionStateNotification) }
  @MainActor private func hostFor(_ model: AppWindowModel, windowIsVisible: @escaping () -> Bool) -> AppWindowHost {
    let host = AppWindowHost(strings: AppWindowStrings(language: "en", resources: nil)) { throw AppCommandError.arguments }
    host.adopt(model, windowIsVisible: windowIsVisible)
    return host
  }

  // MARK: Slow health work does not hold the grid.

  /// A source that can stall, as fdesetup (up to 10 s) and the Keychain can. The stall has its own limit,
  /// so a test that fails does so on its assertion rather than by hanging.
  private final class Stall {
    private let lock = NSLock()
    private var stalling = false
    private var stalled = 0
    private let released = DispatchSemaphore(value: 0)
    var on: Bool {
      get { lock.lock(); defer { lock.unlock() }; return stalling }
      set { lock.lock(); stalling = newValue; lock.unlock() }
    }
    /// How many callers reached the stall.
    var reached: Int { lock.lock(); defer { lock.unlock() }; return stalled }
    private var entries = 0
    /// How many times the source was called at all, stalled or not.
    var entered: Int { lock.lock(); defer { lock.unlock() }; return entries }
    func enter() { lock.lock(); entries += 1; lock.unlock() }
    func pass() {
      guard on else { return }
      lock.lock(); stalled += 1; lock.unlock()
      _ = released.wait(timeout: .now() + 5)
    }
    func release() { on = false; released.signal() }
  }
  private final class StallingAccount: ChatGPTAccount {
    let stall: Stall
    init(stall: Stall) { self.stall = stall }
    func overview() -> ChatGPTAccountOverview { stall.pass(); return ChatGPTAccountOverview(status: .connected, registered: true) }
    func connect() throws {}
    func connectDifferentAccount() throws {}
    func revokeUnusedGrants() -> Bool { true }
    func cancel() {}
    func acknowledgePlanWelcome() {}
    func signOut() -> Bool { true }
  }
  private final class HealthValue {
    private let lock = NSLock()
    private var stored = TimelineHealth()
    var value: TimelineHealth {
      get { lock.lock(); defer { lock.unlock() }; return stored }
      set { lock.lock(); stored = newValue; lock.unlock() }
    }
  }
  /// The real composition, with a real clock and connections, as the product builds it.
  @MainActor private func composedModel(health: @escaping () -> TimelineHealth, statusReader: ChatGPTStatusReader? = nil) throws
    -> (model: AppWindowModel, other: ActivityStorage, root: URL) {
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ACTIVITYPROBE_TEST_ROOT"] ?? "/tmp/ap-window-tests")
      .appendingPathComponent("c-" + UUID().uuidString.prefix(8))
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let url = root.appendingPathComponent("invented.sqlite")
    let other = try ActivityStorage(url: url, appDataDirectory: root, databaseScope: .directory(root))
    try other.saveFixtureSettings(StorageSettings(subscriptionConnected: true).withClaudeUse, at: 0)
    let paths = AppPaths(userHome: root.appendingPathComponent("user"), appData: root, database: url,
      appBinary: root.appendingPathComponent("bin/ActivityProbe"), queryHelper: root.appendingPathComponent("bin/ActivityQueryServer"))
    var factories = AppFactories()
    factories.claudeConnector = { _, _ in RefreshConnector() }
    factories.chatGPT = { _ in ChatGPTSession(store: InMemoryChatGPTCredentialStore(), lock: ChatGPTCredentialLock(file: nil), openBrowser: { _ in false }) }
    factories.chatGPTTokens = { _ in ChatGPTSession(store: InMemoryChatGPTCredentialStore(), lock: ChatGPTCredentialLock(file: nil), openBrowser: { _ in false }) }
    let (model, _) = try AppComposition(paths: paths, factories: factories).windowModel(
      codex: .fixed(root.appendingPathComponent("absent-codex")), claude: .fixed(root.appendingPathComponent("absent-claude")),
      health: health, statusReader: statusReader)
    return (model, other, root)
  }
  /// An invented named minute that is finished and inside today, whatever the time of day.
  @MainActor private func finishedMinuteOfToday(_ model: AppWindowModel) async throws -> TimeRange {
    await model.refresh()
    let day = try XCTUnwrap(model.snapshot).day.range
    let minute = TimelineDay.floorMinute(Int(Date().timeIntervalSince1970)) - 120
    try XCTSkipIf(minute < day.start, "the day started in the last two minutes")
    return TimeRange(minute, minute + 60)
  }
  @MainActor private func hasName(_ model: AppWindowModel) -> Bool { model.snapshot?.day.entries.contains { $0.name == "Invented task" } == true }
  private func forget(_ range: TimeRange, on store: ActivityStorage) throws {
    let preview = try store.previewDeletion(in: range)
    _ = try store.deleteRecords(in: range, confirmation: preview.confirmation)
  }
  @MainActor func testASlowHealthSourceDoesNotDelayTheGridAfterShowing() async throws {
    let stall = Stall(), source = HealthValue()
    let (model, other, root) = try composedModel(health: { stall.enter(); stall.pass(); return source.value })
    defer { stall.release(); model.close(); try? FileManager.default.removeItem(at: root) }
    // Long enough that only the read on showing, and the one when health returns, can act in this test.
    model.refreshInterval = .seconds(60)
    let range = try await finishedMinuteOfToday(model)
    try other.appendIntervals([NamedInterval(range: range, name: "Invented task", kind: .work)])
    await model.refresh()
    XCTAssertTrue(hasName(model))
    // The Keychain's first answer asks for a read of its own, which must not land among the counted checks.
    try await until { model.snapshot?.health.chatGPT != nil }
    XCTAssertNotNil(model.snapshot?.health.chatGPT)
    model.setWindowVisible(false)
    try await settle()
    try forget(range, on: other)
    stall.on = true
    let checksBefore = stall.entered
    let shown = Date()
    model.setWindowVisible(true)
    try await until { !self.hasName(model) }
    XCTAssertFalse(hasName(model), "removed data waited behind health")
    XCTAssertLessThan(Date().timeIntervalSince(shown), 1, "the first read after showing")
    // Reads go on during the stall, and they do not start a second check beside it.
    try await until { stall.reached > 0 }
    await model.refresh(); await model.refresh()
    XCTAssertFalse(model.readFailed)
    XCTAssertEqual(stall.reached, 1, "one check at a time")
    // Health then updates when it returns, with no tick due for a minute.
    var missing = TimelineHealth(); missing.missingPermissions = [.accessibility]
    source.value = missing
    stall.release()
    try await until { model.snapshot?.health.missingPermissions == [.accessibility] }
    XCTAssertEqual(model.snapshot?.health.missingPermissions, [.accessibility])
    XCTAssertTrue(model.snapshot?.day.notices.contains { $0.kind == .accessibility } == true)
    XCTAssertEqual(model.settings.health.missingPermissions, [.accessibility])
    // The stalled check, and the one the read for its answer asks for. Reads during the stall queued none.
    try await until { stall.entered - checksBefore >= 2 }
    // That second check has run, so this only gives any extra ones the chance to show.
    try await settle()
    XCTAssertEqual(stall.entered - checksBefore, 2, "no checks piled up behind the stall")
  }
  /// The same for the Keychain read, which comes due after 30 s.
  @MainActor func testASlowChatGPTStatusDoesNotDelayTheGridAfterShowing() async throws {
    let stall = Stall()
    final class Clock { var now: TimeInterval = 100; let lock = NSLock()
      func read() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return now }
      func set(_ value: TimeInterval) { lock.lock(); now = value; lock.unlock() }
    }
    let clock = Clock()
    let reader = ChatGPTStatusReader(account: StallingAccount(stall: stall), clock: clock.read)
    let (model, other, root) = try composedModel(health: { TimelineHealth() }, statusReader: reader)
    defer { stall.release(); model.close(); try? FileManager.default.removeItem(at: root) }
    model.refreshInterval = .seconds(60)
    let range = try await finishedMinuteOfToday(model)
    try other.appendIntervals([NamedInterval(range: range, name: "Invented task", kind: .work)])
    await model.refresh()
    XCTAssertTrue(hasName(model))
    model.setWindowVisible(false)
    try await settle()
    try forget(range, on: other)
    stall.on = true
    clock.set(1000)
    let shown = Date()
    model.setWindowVisible(true)
    try await until { !self.hasName(model) }
    XCTAssertFalse(hasName(model), "removed data waited behind the Keychain")
    XCTAssertLessThan(Date().timeIntervalSince(shown), 1, "the first read after showing")
  }
  /// Before any check has answered, nothing is known about health. The window must not claim a problem from
  /// that, and must not treat it as a deferred problem having gone.
  @MainActor func testTheFirstReadDuringAStalledCheckClaimsNothingAboutHealth() async throws {
    let stall = Stall()
    stall.on = true
    let (model, other, root) = try composedModel(health: { stall.pass(); return TimelineHealth() })
    defer { stall.release(); model.close(); try? FileManager.default.removeItem(at: root) }
    model.refreshInterval = .seconds(60)
    var settings = try other.settings()
    TimelineNotices.deferNotice(.accessibility, in: &settings)
    try other.saveFixtureSettings(settings, at: 0)
    let began = Date()
    await model.refresh()
    XCTAssertLessThan(Date().timeIntervalSince(began), 1)
    let first = try XCTUnwrap(model.snapshot)
    XCTAssertFalse(first.day.notices.contains { $0.kind == .fileVaultUnknown })
    XCTAssertNotEqual(try other.settings().general[TimelineNotices.deferredSettingKey], "[]", "not resolved by an unread check")
    // The check answers: FileVault really is unknown here, and the deferred problem really has gone.
    stall.release()
    try await until { model.snapshot?.day.notices.contains { $0.kind == .fileVaultUnknown } == true }
    XCTAssertTrue(model.snapshot?.day.notices.contains { $0.kind == .fileVaultUnknown } == true)
    XCTAssertEqual(try other.settings().general[TimelineNotices.deferredSettingKey], "[]")
  }
  // MARK: A stalled Keychain holds up only its own value.

  @MainActor private func kinds(_ model: AppWindowModel) -> [TimelineNoticeKind] { model.snapshot?.day.notices.map(\.kind) ?? [] }
  private func badHealth() -> TimelineHealth {
    var value = TimelineHealth(); value.missingPermissions = [.accessibility]; value.security.fileVault = .off
    return value
  }
  private func goodHealth() -> TimelineHealth {
    var value = TimelineHealth(); value.security.fileVault = .on
    return value
  }
  @MainActor func testAStalledKeychainDoesNotHoldPermissionAndFileVaultNotices() async throws {
    let stall = Stall(), source = HealthValue()
    stall.on = true
    source.value = badHealth()
    let reader = ChatGPTStatusReader(account: StallingAccount(stall: stall))
    let (model, _, root) = try composedModel(health: { source.value }, statusReader: reader)
    defer { stall.release(); model.close(); try? FileManager.default.removeItem(at: root) }
    model.refreshInterval = .seconds(60)
    let began = Date()
    await model.refresh()
    try await until(tries: 500) { self.kinds(model).contains(.accessibility) && stall.reached > 0 }
    XCTAssertEqual(stall.reached, 1, "the Keychain read is under way and stalled")
    XCTAssertTrue(kinds(model).contains(.accessibility))
    XCTAssertTrue(kinds(model).contains(.fileVaultOff))
    XCTAssertFalse(kinds(model).contains(.fileVaultUnknown))
    XCTAssertEqual(model.settings.health.missingPermissions, [.accessibility])
    XCTAssertEqual(model.settings.model.permissionLabel(.accessibility), .missing)
    XCTAssertNil(model.snapshot?.health.chatGPT, "no value for the Keychain yet")
    // The stall itself gives up after five seconds, so this says the answer did not wait for it.
    XCTAssertLessThan(Date().timeIntervalSince(began), 4)
    // Its own value arrives when it ends, with no tick due for a minute, and takes nothing away.
    stall.release()
    try await until { model.snapshot?.health.chatGPT == .connected }
    XCTAssertEqual(model.snapshot?.health.chatGPT, .connected)
    XCTAssertTrue(kinds(model).contains(.accessibility))
  }
  /// The same after the first answer: what changes during the stall still shows, and the ChatGPT value stays.
  @MainActor func testAPermissionLostDuringAStalledKeychainShows() async throws {
    let stall = Stall(), source = HealthValue()
    source.value = goodHealth()
    final class Clock { let lock = NSLock(); var value: TimeInterval = 100
      var now: TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
      func set(_ new: TimeInterval) { lock.lock(); value = new; lock.unlock() }
    }
    let clock = Clock()
    let reader = ChatGPTStatusReader(account: StallingAccount(stall: stall), clock: { clock.now })
    let (model, _, root) = try composedModel(health: { source.value }, statusReader: reader)
    defer { stall.release(); model.close(); try? FileManager.default.removeItem(at: root) }
    model.refreshInterval = .seconds(60)
    await model.refresh()
    try await until { model.snapshot?.health.chatGPT == .connected }
    XCTAssertEqual(model.snapshot?.health.chatGPT, .connected)
    stall.on = true
    clock.set(1000)
    await model.refresh()
    try await until(tries: 500) { stall.reached > 0 }
    XCTAssertEqual(stall.reached, 1)
    source.value = badHealth()
    // Each of these may find a check running; the one after it ends reads the new value.
    for _ in 0..<50 where !kinds(model).contains(.accessibility) {
      await model.refresh()
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(kinds(model).contains(.accessibility))
    XCTAssertTrue(kinds(model).contains(.fileVaultOff))
    XCTAssertEqual(model.snapshot?.health.chatGPT, .connected, "the previous value is kept")
    XCTAssertEqual(stall.reached, 1, "the Keychain is not asked twice")
  }
  /// Deferred notices are decided from permissions and security, none of which waits for the Keychain.
  @MainActor func testDeferredNoticesResolveDuringAStalledKeychain() async throws {
    let stall = Stall(), source = HealthValue()
    stall.on = true
    var health = goodHealth(); health.missingPermissions = [.inputMonitoring]
    source.value = health
    let reader = ChatGPTStatusReader(account: StallingAccount(stall: stall))
    let (model, other, root) = try composedModel(health: { source.value }, statusReader: reader)
    defer { stall.release(); model.close(); try? FileManager.default.removeItem(at: root) }
    model.refreshInterval = .seconds(60)
    var settings = try other.settings()
    TimelineNotices.deferNotice(.accessibility, in: &settings)
    TimelineNotices.deferNotice(.inputMonitoring, in: &settings)
    try other.saveFixtureSettings(settings, at: 0)
    func deferred() throws -> String? { try other.settings().general[TimelineNotices.deferredSettingKey] }
    await model.refresh()
    try await until(tries: 500) { (try? deferred()) == "[\"inputMonitoring\"]" }
    XCTAssertEqual(try deferred(), "[\"inputMonitoring\"]", "the problem that went is resolved, the one still there stays")
    XCTAssertEqual(stall.reached, 1)
    XCTAssertFalse(kinds(model).contains(.inputMonitoring), "still deferred")
  }
  /// A window closed and opened again during the stall gets its own answers, and no second read starts.
  @MainActor func testANewWindowDuringAStalledKeychainGetsItsAnswers() async throws {
    let stall = Stall(), source = HealthValue()
    stall.on = true
    source.value = badHealth()
    let reader = ChatGPTStatusReader(account: StallingAccount(stall: stall))
    var roots: [URL] = []
    defer { stall.release(); roots.forEach { try? FileManager.default.removeItem(at: $0) } }
    var last: AppWindowModel?
    for window in 1...3 {
      let (model, _, root) = try composedModel(health: { source.value }, statusReader: reader)
      roots.append(root)
      model.refreshInterval = .seconds(60)
      await model.refresh()
      try await until(tries: 300) { self.kinds(model).contains(.accessibility) }
      XCTAssertTrue(kinds(model).contains(.accessibility), "window \(window)")
      if window < 3 { model.close() } else { last = model }
    }
    XCTAssertEqual(stall.reached, 1, "one read, whatever the windows did")
    // The one read's answer goes to the window open now.
    let model = try XCTUnwrap(last)
    defer { model.close() }
    stall.release()
    try await until { model.snapshot?.health.chatGPT == .connected }
    XCTAssertEqual(model.snapshot?.health.chatGPT, .connected)
  }
  /// Every check's own thread comes back during the stall, so only the one in the Keychain stays tied up.
  func testAStalledKeychainTiesUpOneThreadHoweverManyWindowsOpen() throws {
    let stall = Stall()
    stall.on = true
    defer { stall.release() }
    let lock = NSLock()
    var keychainRuns = 0
    let reader = ChatGPTStatusReader(account: StallingAccount(stall: stall), run: { work in
      lock.lock(); keychainRuns += 1; lock.unlock()
      DispatchQueue.global(qos: .utility).async(execute: work)
    })
    var windows: [RefreshFixture] = []
    let returned = DispatchSemaphore(value: 0)
    for window in 1...4 {
      let f = try RefreshFixture()
      windows.append(f)
      f.chatGPT = reader
      // As the product: each window's reader has its own health queue.
      let queue = DispatchQueue(label: "invented-health-\(window)")
      f.runHealth = { work in queue.async { work(); returned.signal() } }
      _ = try f.read()
      XCTAssertEqual(returned.wait(timeout: .now() + 2), .success, "window \(window)'s check came back")
    }
    let deadline = Date().addingTimeInterval(2)
    while stall.reached == 0, Date() < deadline { Thread.sleep(forTimeInterval: 0.002) }
    XCTAssertEqual(stall.reached, 1)
    lock.lock(); defer { lock.unlock() }
    XCTAssertEqual(keychainRuns, 1)
    withExtendedLifetime(windows) {}
  }
  func testAskingTheStatusDuringAStallReturnsAtOnceAndAnswersOnce() throws {
    let stall = Stall()
    stall.on = true
    defer { stall.release() }
    let reader = ChatGPTStatusReader(account: StallingAccount(stall: stall))
    let lock = NSLock()
    var answers: [String] = []
    let began = Date()
    for name in ["first", "second", "third"] {
      reader.check { _ in lock.lock(); answers.append(name); lock.unlock() }
    }
    XCTAssertLessThan(Date().timeIntervalSince(began), 1)
    let deadline = Date().addingTimeInterval(2)
    while stall.reached == 0, Date() < deadline { Thread.sleep(forTimeInterval: 0.002) }
    stall.release()
    let answered = Date().addingTimeInterval(2)
    while Date() < answered, lock.withLock({ answers.isEmpty }) { Thread.sleep(forTimeInterval: 0.002) }
    lock.withLock { XCTAssertEqual(answers, ["third"], "the latest to ask, and nobody queued up behind the stall") }
  }

  // MARK: Health that never answers.

  /// The check itself never comes back: the limit is what ends the silence, and it claims nothing else.
  func testAHealthCheckWithNoAnswerSaysUnknownAfterTheLimit() throws {
    let f = try RefreshFixture()
    var waiting: [() -> Void] = []
    f.runHealth = { waiting.append($0) }
    var settings = try f.other.settings()
    TimelineNotices.deferNotice(.accessibility, in: &settings)
    try f.other.saveFixtureSettings(settings, at: 0)
    let first = try f.read()
    XCTAssertFalse(notices(first).contains(.fileVaultUnknown), "not yet")
    XCTAssertFalse(first.health.permissionsRead)
    f.now += AppWindowDayReader.healthAnswerLimit - 1
    XCTAssertFalse(notices(try f.read()).contains(.fileVaultUnknown), "not yet")
    f.now += 1
    let overdue = try f.read()
    XCTAssertTrue(notices(overdue).contains(.fileVaultUnknown), "says it could not be checked")
    XCTAssertFalse(overdue.health.permissionsRead)
    XCTAssertEqual(overdue.health.security.fileVault, .unknown)
    XCTAssertEqual(waiting.count, 1, "one check at a time")
    XCTAssertNotEqual(try f.other.settings().general[TimelineNotices.deferredSettingKey], "[]", "nothing is known to have gone")
    // A late answer replaces all of it.
    f.health.security.fileVault = .on
    f.health.missingPermissions = [.screenRecording]
    waiting.removeFirst()()
    let answered = try f.read()
    XCTAssertFalse(notices(answered).contains(.fileVaultUnknown))
    XCTAssertTrue(notices(answered).contains(.screenRecording))
    XCTAssertTrue(answered.health.permissionsRead)
    XCTAssertEqual(try f.other.settings().general[TimelineNotices.deferredSettingKey], "[]")
  }
  /// A person who deferred the notice has it stay deferred after the limit.
  func testADeferredUnknownNoticeStaysHiddenAfterTheLimit() throws {
    let f = try RefreshFixture()
    f.runHealth = { _ in }
    var settings = try f.other.settings()
    TimelineNotices.deferNotice(.fileVaultUnknown, in: &settings)
    try f.other.saveFixtureSettings(settings, at: 0)
    _ = try f.read()
    f.now += AppWindowDayReader.healthAnswerLimit
    XCTAssertFalse(notices(try f.read()).contains(.fileVaultUnknown))
  }
  /// A clock set back during the silence does not extend it.
  func testAClockSetBackDoesNotExtendTheSilence() throws {
    let f = try RefreshFixture()
    f.runHealth = { _ in }
    _ = try f.read()
    f.now -= 3600
    XCTAssertTrue(notices(try f.read()).contains(.fileVaultUnknown))
  }
  @MainActor func testSettingsSaysNothingIsAllowedBeforeAnAnswer() async throws {
    let stall = Stall(), source = HealthValue()
    stall.on = true
    source.value = goodHealth()
    let (model, _, root) = try composedModel(health: { stall.pass(); return source.value })
    defer { stall.release(); model.close(); try? FileManager.default.removeItem(at: root) }
    model.refreshInterval = .seconds(60)
    func labels() -> [SettingsLabel] { TimelinePermission.allCases.map { model.settings.model.permissionLabel($0) } }
    XCTAssertEqual(labels(), [.unknown, .unknown, .unknown], "before the first read")
    await model.refresh()
    XCTAssertNotNil(model.snapshot)
    XCTAssertEqual(labels(), [.unknown, .unknown, .unknown], "during the first check")
    stall.release()
    try await until { labels() == [.granted, .granted, .granted] }
    XCTAssertEqual(labels(), [.granted, .granted, .granted], "after an answer that finds them all")
    source.value = badHealth()
    await model.refresh()
    try await until { self.kinds(model).contains(.accessibility) }
    XCTAssertEqual(labels(), [.missing, .granted, .granted])
  }
  /// The page itself draws that state, not only the label behind it.
  @MainActor func testThePageDrawsUnreadPermissionsDifferently() throws {
    let settings = StorageSettings(subscriptionConnected: true)
    func page(_ health: TimelineHealth) -> Data? {
      SettingsOffscreenRender.png(model: SettingsViewModel(settings: settings, health: health, ownBundleID: "org.example.self", now: 1_800_000_000),
        strings: SettingsStrings(language: "en", resources: nil), width: 720, dark: false, scale: 1)
    }
    let unread = try XCTUnwrap(page(.unread)), read = try XCTUnwrap(page(TimelineHealth()))
    XCTAssertEqual(read, page(TimelineHealth()), "the same state draws the same, so the difference below means something")
    XCTAssertNotEqual(unread, read)
  }
  func testHealthAndTheKeychainRunOffTheMainThread() async throws {
    final class Threads { let lock = NSLock(); var main: [Bool] = []
      func note() { lock.lock(); main.append(Thread.isMainThread); lock.unlock() }
      var seen: [Bool] { lock.lock(); defer { lock.unlock() }; return main }
    }
    let threads = Threads()
    final class Account: ChatGPTAccount {
      let note: () -> Void
      init(note: @escaping () -> Void) { self.note = note }
      func overview() -> ChatGPTAccountOverview { note(); return ChatGPTAccountOverview(status: .connected, registered: true) }
      func connect() throws {}
      func connectDifferentAccount() throws {}
      func revokeUnusedGrants() -> Bool { true }
      func cancel() {}
      func acknowledgePlanWelcome() {}
      func signOut() -> Bool { true }
    }
    let (model, _, root) = try await MainActor.run {
      try composedModel(health: { threads.note(); return TimelineHealth() }, statusReader: ChatGPTStatusReader(account: Account(note: threads.note)))
    }
    defer { try? FileManager.default.removeItem(at: root) }
    await model.refresh()
    for _ in 0..<1000 where threads.seen.count < 2 { try await Task.sleep(for: .milliseconds(2)) }
    await MainActor.run { model.close() }
    XCTAssertGreaterThanOrEqual(threads.seen.count, 2, "both ran")
    XCTAssertFalse(threads.seen.contains(true))
  }

  // MARK: The lean read.

  private struct FullSampleReader: TimelineStorageReader {
    let store: ActivityStorage
    func settings() throws -> StorageSettings { try store.settings() }
    func samples(in range: TimeRange) throws -> [TimeSample] { try store.samples(in: range) }
    func intervals(in range: TimeRange) throws -> [NamedInterval] { try store.intervals(in: range) }
    func modelCalls(in range: TimeRange) throws -> [ModelCall] { try store.modelCalls(in: range) }
    func modelCalls(overlapping range: TimeRange) throws -> [ModelCall] { try store.modelCalls(overlapping: range) }
    func forgottenRanges(in range: TimeRange) throws -> [TimeRange] { try store.forgottenRanges(in: range) }
  }
  func testTheGridFromTheLeanReadMatchesTheFullRead() throws {
    let f = try RefreshFixture()
    // An app whose name was masked when it was recorded, as the full read's privacy identity sees it.
    let historical = "invented." + Redaction.emailMark
    var settings = try f.other.settings()
    settings.excludedApps = [historical]
    try f.other.saveFixtureSettings(settings, at: 0)
    for second in stride(from: start, to: start + 7200, by: 7) {
      let app = second >= start + 5400 && second < start + 5700 ? historical : "invented.editor"
      try f.other.locked {
        try f.other.connection.run("""
          INSERT INTO samples(ts,bundle_id,app,window,document_key,keys,clicks,scrolls,moved,synthetic,keeping_awake,excluded)
          VALUES(?,?,?,'Invented title','invented/document',?,?,?,?,0,?,?)
          """, [.integer(second), .text(app), .text(app), .integer(second % 3 == 0 ? 1 : 0), .integer(second % 5 == 0 ? 1 : 0), .integer(second % 11 == 0 ? 1 : 0),
            .integer(second % 13 == 0 ? 1 : 0), .integer(second % 17 == 0 ? 1 : 0), .integer(second % 19 == 0 ? 1 : 0)])
      }
    }
    // A call with no facts, then one with them.
    _ = try f.other.appendModelCall(ModelCall(ts: start + 4000, range: TimeRange(start + 600, start + 3600), model: "invented", succeeded: true))
    let sent = TimeRange(start + 3600, start + 4800)
    let facts = SummaryCallFacts(through: sent.end, sentRanges: [sent], endsAtRest: false, activeMinutes: Array(stride(from: sent.start, to: sent.end, by: 60)))
    _ = try f.other.appendModelCall(ModelCall(ts: sent.end + 30, range: sent, model: "invented", succeeded: true, tableFacts: facts))
    try f.other.appendIntervals([
      NamedInterval(range: TimeRange(start + 600, start + 1200), name: "Invented task", kind: .work),
      NamedInterval(range: TimeRange(start + 1800, start + 2400), state: .private),
      NamedInterval(range: TimeRange(start + 3600, start + 4200), name: "Invented task with facts", kind: .work),
    ])
    try f.other.locked { try f.other.connection.run("INSERT INTO forgotten_ranges(start_ts,end_ts) VALUES(?,?)", [.integer(start + 6000), .integer(start + 6300)]) }
    let range = TimeRange(start, start + 7200)
    let full = FullSampleReader(store: f.other)
    let lean = try SummaryTimeline.minutes(in: range, storage: f.other)
    XCTAssertEqual(lean, try SummaryTimeline.minutes(in: range, storage: full))
    // The comparison means something only if each of these reached the grid.
    XCTAssertEqual(lean[start + 600], .work)
    XCTAssertEqual(lean[start + 1800], .private)
    XCTAssertEqual(lean[start + 3600], .work)
    XCTAssertEqual(lean[start + 6000], .rest, "forgotten")
    XCTAssertNotNil(lean[start + 5400], "the historical name's minutes count as any other")
    let now = start + 7200
    XCTAssertEqual(try TimelineDay.read(containing: now - 1, now: now, calendar: f.calendar, storage: f.other),
      try TimelineDay.read(containing: now - 1, now: now, calendar: f.calendar, storage: full))
  }
}
