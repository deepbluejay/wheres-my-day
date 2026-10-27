import Core
import Foundation
import Shell
@testable import Storage
import XCTest

/// Billing fixtures use only invented activity and an isolated SQLite database.
final class SummaryAccountingTests: XCTestCase {
  final class Caller: SummaryCaller {
    var answers: [Result<SummaryAnswer, Error>] = []
    var requests = 0
    func call(_ prompt: String) throws -> SummaryAnswer {
      requests += 1
      return try answers.removeFirst().get()
    }
  }
  var root: URL!
  var url: URL { root.appendingPathComponent("invented.sqlite") }
  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("accounting-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }
  override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
  func database() throws -> ActivityStorage {
    try ActivityStorage(url: url, appDataDirectory: root, databaseScope: .directory(root))
  }
  func service(_ store: SummaryStorage, _ caller: Caller) -> SummaryService {
    SummaryService(storage: store, caller: caller, format: SummaryFormat(timeZone: TimeZone(secondsFromGMT: 0)!))
  }
  func run(_ service: SummaryService, through: Int, requested: Bool = false) throws {
    try service.summarize(from: 0, through: through, dayStart: 0, locale: "en", requested: requested)
  }
  let all = TimeRange(0, 10000)
  func seed(_ store: ActivityStorage, through: Int) throws {
    try store.saveFixtureSettings(StorageSettings(subscriptionConnected: true).withClaudeUse, at: 0)
    try store.appendSamples((0..<through).map { TimeSample(ts: $0, app: "Invented", keys: 1) })
  }

  func testRequestedBillingSurvivesWaitingLargerReplanAndRestart() throws {
    let caller = Caller()
    do {
      let store = try database(); try seed(store, through: 600)
      caller.answers = [.success(SummaryAnswer(text: "invalid", inputTokens: 120, cachedTokens: 20, outputTokens: 30)), .failure(SummaryError.paused)]
      let first = service(store, caller)
      try run(first, through: 600, requested: true)
      XCTAssertEqual(try store.modelCalls(in: all).map(\.inputTokens), [120])
      XCTAssertTrue(try store.modelCalls(in: all).allSatisfy(\.pending))
      XCTAssertTrue(SummaryHealth.unresolvedFailedRanges(in: try store.modelCalls(in: all)).isEmpty)
      // A regular pass cannot yet send the short ongoing piece; billing must survive that change too.
      try run(first, through: 900)
      XCTAssertEqual(caller.requests, 2)
      XCTAssertEqual(try store.modelCalls(in: all).map(\.inputTokens), [120])
    }
    let store = try database()
    try store.appendSamples((600..<3600).map { TimeSample(ts: $0, app: "Invented", keys: 1) })
    let resumed = service(store, caller)
    XCTAssertEqual(try resumed.plan(from: 0, through: 3600).pieces.map(\.range), [TimeRange(0, 3600)])
    caller.answers = [.success(SummaryAnswer(text: "00:00\t01:00\twork\tInvented\tInvented", inputTokens: 10, cachedTokens: 2, outputTokens: 3))]
    try run(resumed, through: 3600)
    let calls = try store.modelCalls(in: all)
    XCTAssertEqual(calls.map(\.inputTokens), [120, 10]); XCTAssertEqual(calls.map(\.pending), [true, false])
    XCTAssertEqual(calls.reduce(0) { $0 + $1.cachedTokens }, 22)
    XCTAssertEqual(calls.reduce(0) { $0 + $1.outputTokens }, 33)
    XCTAssertEqual(try store.connection.integer("SELECT SUM(input_tokens) FROM model_calls"), 130)
    XCTAssertTrue(SummaryHealth.unresolvedFailedRanges(in: calls).isEmpty)
    XCTAssertTrue(try resumed.plan(from: 0, through: 3600).pieces.isEmpty)
  }

  func testStorageThrowAfterBillingKeepsUsageAcrossRestart() throws {
    let caller = Caller()
    do {
      let store = try database(); try seed(store, through: 600)
      try store.connection.run("CREATE TRIGGER invented_throw BEFORE INSERT ON intervals BEGIN SELECT RAISE(ABORT,'invented'); END")
      caller.answers = [.success(SummaryAnswer(text: "00:00\t00:10\twork\tInvented\tInvented", inputTokens: 120))]
      XCTAssertThrowsError(try run(service(store, caller), through: 600, requested: true))
      XCTAssertEqual(try store.modelCalls(in: all).map(\.inputTokens), [120])
      XCTAssertTrue(try store.modelCalls(in: all).allSatisfy(\.pending))
      try store.connection.run("DROP TRIGGER invented_throw")
    }
    let store = try database()
    caller.answers = [.success(SummaryAnswer(text: "00:00\t00:10\twork\tInvented\tInvented", inputTokens: 10))]
    try run(service(store, caller), through: 600, requested: true)
    XCTAssertEqual(try store.modelCalls(in: all).map(\.inputTokens), [120, 10])
  }

  func testAmbiguousAccountingAppendIsRetriedOnceBeforeAnyNewCall() throws {
    let memory = SummaryMemory(), caller = Caller()
    memory.rows = (0..<600).map { TimeSample(ts: $0, keys: 1) }
    memory.throwAfterCallWrite = true
    caller.answers = [.success(SummaryAnswer(text: "invalid", inputTokens: 120))]
    let summaries = service(memory, caller)
    XCTAssertThrowsError(try run(summaries, through: 600, requested: true))
    XCTAssertEqual(caller.requests, 1)
    memory.options.claudeUse = false
    try run(summaries, through: 600, requested: true)
    XCTAssertEqual(memory.calls.map(\.inputTokens), [120]); XCTAssertEqual(caller.requests, 1)
  }

  func testFailedAccountingAppendIsRetriedBeforeAnotherRequest() throws {
    let memory = SummaryMemory(), caller = Caller()
    memory.rows = (0..<600).map { TimeSample(ts: $0, keys: 1) }
    memory.throwBeforeCallWrite = true
    caller.answers = [.success(SummaryAnswer(text: "invalid", inputTokens: 120))]
    let summaries = service(memory, caller)
    XCTAssertThrowsError(try run(summaries, through: 600, requested: true))
    XCTAssertTrue(memory.calls.isEmpty); XCTAssertEqual(caller.requests, 1)
    memory.options.claudeUse = false
    try run(summaries, through: 600, requested: true)
    XCTAssertEqual(memory.calls.map(\.inputTokens), [120]); XCTAssertEqual(caller.requests, 1)
  }

  func testPrivacyForgetDeletesPendingAttemptsAndRefusesLateReplays() throws {
    let store = try database(); try seed(store, through: 600)
    let caller = Caller()
    caller.answers = [.failure(SummaryPausedAfterBilling(usage: SummaryAnswer(text: "", inputTokens: 120)))]
    let summaries = service(store, caller)
    try run(summaries, through: 600, requested: true)
    let pending = try XCTUnwrap(try store.modelCalls(in: all).first)
    let preview = try store.previewDeletion(in: TimeRange(60, 120))
    XCTAssertEqual(preview.counts["model_calls"], 1)
    try store.deleteRecords(in: preview.range, confirmation: preview.confirmation)
    XCTAssertTrue(try store.modelCalls(in: all).isEmpty)
    XCTAssertEqual(try store.appendModelCall(pending).refused, 1)
    var terminal = pending; terminal.pending = false
    XCTAssertEqual(try store.appendModelCall(terminal).refused, 1)
    XCTAssertTrue(try store.modelCalls(in: all).isEmpty)
  }

  func testUnsupportedSchemaFourLeavesBillingRowsUnchanged() throws {
    let old = ModelCall(ts: 600, range: TimeRange(0, 600), model: "invented", inputTokens: 12, succeeded: true)
    do {
      let store = try database(); try store.appendModelCall(old)
      try store.connection.run("DROP INDEX model_call_attempt")
      try store.connection.run("ALTER TABLE model_calls DROP COLUMN pending")
      try store.connection.run("ALTER TABLE model_calls DROP COLUMN attempt_id")
      try store.connection.run("PRAGMA user_version=4")
    }
    XCTAssertThrowsError(try database())
    let connection = try SQLiteConnection(url: root.appendingPathComponent("invented.sqlite"), readOnly: true, scope: .directory(root))
    XCTAssertEqual(try connection.integer("PRAGMA user_version"), 4)
    XCTAssertEqual(try connection.integer("SELECT count(*) FROM model_calls WHERE ts=600 AND input_tokens=12 AND succeeded=1"), 1)
    XCTAssertEqual(try connection.integer("SELECT count(*) FROM pragma_table_info('model_calls') WHERE name IN ('pending','attempt_id')"), 0)
  }
}

extension SummaryAccountingTests {
  func testRecorderPublishesAndClearsUnavailableReason() throws {
    final class Unavailable: SummaryCaller {
      var serviceUnavailableUntil: TimeInterval? = 1300
      func beginPass() throws { throw SummaryError.paused }
      func call(_ prompt: String) throws -> SummaryAnswer { XCTFail("No call during pause"); throw SummaryError.paused }
    }
    let memory = SummaryMemory()
    memory.rows = (0..<600).map { TimeSample(ts: $0, keys: 1) }
    let caller = Unavailable()
    var published: TimeInterval?
    let task = SummaryTask(storage: memory, caller: caller, from: 0, dayStart: { _ in 0 }, locale: { "en" }, publish: { published = $0 })
    task.request(through: 600)
    try task.maintenanceTask.run(1000)
    XCTAssertEqual(task.health.serviceUnavailableUntil, 1300)
    XCTAssertEqual(published, 1300); XCTAssertTrue(task.health.planUsePaused)
    caller.serviceUnavailableUntil = nil
    task.request(through: 600); try task.maintenanceTask.run(1400)
    XCTAssertNil(published)
  }
}

extension SummaryAccountingTests {
  func testDatabaseAppendFailureIsRecoveredAfterRecorderRestart() throws {
    let caller = Caller()
    do {
      let store = try database(); try seed(store, through: 600)
      try store.connection.run("CREATE TRIGGER invented_throw BEFORE INSERT ON model_calls WHEN NEW.input_tokens=120 BEGIN SELECT RAISE(ABORT,'invented'); END")
      caller.answers = [.success(SummaryAnswer(text: "invalid", inputTokens: 120, cachedTokens: 20, outputTokens: 30))]
      XCTAssertThrowsError(try run(service(store, caller), through: 600, requested: true))
      XCTAssertTrue(try store.modelCalls(in: all).isEmpty)
      XCTAssertEqual(try ModelCallJournal(database: url).read()?.0.inputTokens, 120)
      try store.connection.run("DROP TRIGGER invented_throw")
    }
    let store = try database()
    try store.saveFixtureSettings(StorageSettings(subscriptionConnected: false))
    let resumed = service(store, caller)
    try run(resumed, through: 600, requested: true)
    XCTAssertEqual(try store.modelCalls(in: all).map(\.inputTokens), [120])
    XCTAssertEqual(caller.requests, 1)
    try store.saveFixtureSettings(StorageSettings(subscriptionConnected: true).withClaudeUse)
    caller.answers = [.success(SummaryAnswer(text: "", inputTokens: 10, cachedTokens: 2, outputTokens: 3))]
    try run(resumed, through: 600, requested: true)
    XCTAssertEqual(try store.modelCalls(in: all).map(\.inputTokens), [120, 10])
    XCTAssertEqual(try store.connection.integer("SELECT SUM(input_tokens) FROM model_calls"), 130)
    XCTAssertNil(try ModelCallJournal(database: url).read())
  }

  func testPrivacyForgetAlsoDeletesAnUncommittedJournalAttempt() throws {
    let store = try database(); try seed(store, through: 600)
    let caller = Caller(), summaries = service(store, caller)
    try store.connection.run("CREATE TRIGGER invented_throw BEFORE INSERT ON model_calls BEGIN SELECT RAISE(ABORT,'invented'); END")
    caller.answers = [.success(SummaryAnswer(text: "invalid", inputTokens: 120))]
    XCTAssertThrowsError(try run(summaries, through: 600, requested: true))
    let journal = try ModelCallJournal(database: url), before = try journal.read()?.1
    let preview = try store.previewDeletion(in: TimeRange(60, 120))
    XCTAssertEqual(preview.counts["model_calls"], 1)
    XCTAssertEqual(try journal.read()?.1, before); XCTAssertTrue(try store.modelCalls(in: all).isEmpty)
    try store.deleteRecords(in: preview.range, confirmation: preview.confirmation)
    XCTAssertNil(try journal.read())
    try store.connection.run("DROP TRIGGER invented_throw")
    try store.saveFixtureSettings(StorageSettings(subscriptionConnected: false))
    try run(summaries, through: 600, requested: true)
    XCTAssertTrue(try store.modelCalls(in: all).isEmpty); XCTAssertEqual(caller.requests, 1)
    XCTAssertNil(try journal.read())
  }

  func testAccountingJournalRefusesAnAlias() throws {
    let store = try database(), target = root.appendingPathComponent("invented-target")
    try Data("invented-kept".utf8).write(to: target)
    let journal = try ModelCallJournal(database: url)
    try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent(journal.leaf).path, withDestinationPath: target.path)
    XCTAssertThrowsError(try store.appendModelCall(ModelCall(ts: 600, range: TimeRange(0, 600), model: "invented",
      inputTokens: 120, succeeded: false, pending: true, attemptID: "invented-attempt")))
    XCTAssertEqual(try String(contentsOf: target), "invented-kept")
  }
}

extension SummaryAccountingTests {
  func testForgottenLateAttemptNeverPreparesAJournalWhileDatabaseWritesAreBlocked() throws {
    let store = try database(), blocker = try database()
    let call = ModelCall(ts: 600, range: TimeRange(0, 600), model: "invented", inputTokens: 120,
      succeeded: false, pending: true, attemptID: "invented-late")
    let preview = try store.previewDeletion(in: TimeRange(60, 120))
    try store.deleteRecords(in: preview.range, confirmation: preview.confirmation)
    try store.connection.run("PRAGMA busy_timeout=0")
    try blocker.connection.run("BEGIN IMMEDIATE")
    defer { try? blocker.connection.run("ROLLBACK") }
    XCTAssertEqual(try store.appendModelCall(call).refused, 1)
    XCTAssertNil(try ModelCallJournal(database: url).read())
    XCTAssertTrue(try store.modelCalls(in: all).isEmpty)
  }

  func testRecoveryErasesAnAlreadyForgottenJournalWithoutWaitingForADatabaseWriter() throws {
    let store = try database(), blocker = try database()
    let call = ModelCall(ts: 600, range: TimeRange(0, 600), model: "invented", inputTokens: 120,
      succeeded: false, pending: true, attemptID: "invented-interrupted-cleanup")
    let preview = try store.previewDeletion(in: TimeRange(60, 120))
    try store.deleteRecords(in: preview.range, confirmation: preview.confirmation)
    let journal = try ModelCallJournal(database: url)
    // Invent the file a crash between the deletion commit and journal cleanup could leave.
    try journal.withLock { try journal.save(call) }
    try store.connection.run("PRAGMA busy_timeout=0")
    try blocker.connection.run("BEGIN IMMEDIATE")
    defer { try? blocker.connection.run("ROLLBACK") }
    try store.recoverModelCalls()
    XCTAssertNil(try journal.read())
    XCTAssertTrue(try store.modelCalls(in: all).isEmpty)
  }
}
