@testable import Core
import Foundation
@testable import Shell
@testable import Storage
import XCTest

// Exercise the native reader/traversal as well as the prepared-artifact adapter.
// All Git subprocesses operate on this test's invented repository.
extension GitCollectionTests {
  func testGeneratedNativeReaderSchedulesMatchPublicationModel() throws {
    let message = String(repeating: "Invented ordinary sentence.\n", count: 2600)
    let first = try commit(message)
    let second = try commit("Invented second change", file: "invented-second")
    var checks = 0
    for seed: UInt64 in [1, 7, 19, 41, 97, 313, 2027, 0xdecafbad] {
      var random = GitScheduleRandom(state: seed)
      for event: GitScheduleEvent in [.secureOn, .secureUnknown, .roundTrip, .forget, .stop] {
        task.stop()
        let finished = DispatchSemaphore(value: 0); task.finish { finished.signal() }
        XCTAssertEqual(finished.wait(timeout: .now() + 3), .success)
        task = nil; store = nil
        let database = root.appendingPathComponent("invented-native-\(seed)-\(event.rawValue).sqlite")
        store = try ActivityStorage(url: database, appDataDirectory: root, databaseScope: .directory(root))
        try store.saveSettings(StorageSettings(), at: 0)
        var reference = GitPublicationModel()
        reference.author = now - 60; reference.committed = now - 60
        task = GitCollectionTask(storage: store, secureInput: { reference.secure }, scratchDirectory: root)
        try observe(); reference.linked.insert(0)
        var fired = false, countAtTransition = 0
        var transitionError: Error?
        func transition() throws {
          do { try applyTransition() }
          catch { transitionError = error; throw error }
        }
        func applyTransition() throws {
          checks += 1
          if fired {
            // Previously admitted complete commits can survive deferral. New
            // completion and frontier certification cannot cross the transition.
            XCTAssertLessThanOrEqual(try count("git_commits", "complete=1"), countAtTransition)
            return
          }
          fired = true; countAtTransition = try count("git_commits", "complete=1")
          switch event {
          case .secureOn: reference.secure = true
          case .secureUnknown: reference.secure = nil
          case .roundTrip:
            reference.settings(enabled: false, pause: nil, at: now)
            try store.saveSettings(StorageSettings(recordingEnabled: false), at: now)
            reference.settings(enabled: true, pause: nil, at: now)
            try store.saveSettings(StorageSettings(), at: now)
          case .forget:
            let range = TimeRange(reference.author, reference.author + 1)
            let preview = try store.previewDeletion(in: range)
            try store.deleteRecords(in: range, confirmation: preview.confirmation)
            reference.forgotten.append(reference.author..<(reference.author + 1))
            reference.erased.formUnion([first, second]); reference.forgetRevision += 1
          case .stop:
            reference.cancelled = true; reference.producerCancelled = true
            task.stop()
          default: XCTFail("unsupported native schedule event")
          }
        }
        switch random.next(4) {
        case 0: task.afterMetadataRead = { try transition() }
        case 1: task.afterCommitStarted = { _ in try transition() }
        case 2: task.afterFileAppended = { try transition() }
        default: store.beforeGitFrontierPublication = { try transition() }
        }
        try scan()
        if let transitionError { throw transitionError }
        XCTAssertTrue(fired)
        XCTAssertLessThanOrEqual(try count("git_commits", "complete=1"), countAtTransition)
        XCTAssertEqual(try count("git_repositories", "last_read IS NOT NULL"), 0)
        task.stop()
        let drained = DispatchSemaphore(value: 0); task.finish { drained.signal() }
        XCTAssertEqual(drained.wait(timeout: .now() + 3), .success)
        task = nil; store = nil
        reference.secure = false; reference.cancelled = false; reference.producerCancelled = false
        store = try ActivityStorage(url: database, appDataDirectory: root, databaseScope: .directory(root))
        task = GitCollectionTask(storage: store, secureInput: { reference.secure }, scratchDirectory: root)
        try scan(now + 300)
        XCTAssertEqual(try count("git_commits", "complete!=1"), 0)
        if reference.erased.isEmpty {
          XCTAssertEqual(try count("git_commits", "complete=1"), 2)
          XCTAssertEqual(try count("git_files"), 2)
        } else {
          XCTAssertEqual(try count("git_commits"), 0)
          XCTAssertEqual(try count("git_tombstones"), 2)
        }
        XCTAssertEqual(try store.connection.integer("SELECT COALESCE(max(last_read),0) FROM git_repositories"), now + 300)
      }
    }
    print("generated native Git reader: schedules=40 transition_checks=\(checks) message_bytes=\(message.utf8.count)")
  }
}
