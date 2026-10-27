@testable import Core
import Foundation
@testable import Shell
@testable import Storage
import XCTest

extension GitCollectionTests {
  func testSecureInputAndUnknownReadingDeferDiscoveryAndResume() throws {
    try commit()
    for reading: Bool? in [true, nil] {
      store.setGitSecureInput { reading }
      try observe()
      XCTAssertEqual(try count("git_working_folders"), 0)
    }
    store.setGitSecureInput { false }
    try observe()
    XCTAssertEqual(try count("git_working_folders"), 1)
  }

  func testSecureInputIsRecheckedAfterPreparedDiscovery() throws {
    try commit()
    task.afterLocationPrepared = { _ in self.store.setGitSecureInput { true } }
    try observe()
    XCTAssertEqual(try count("git_working_folders"), 0)
    XCTAssertEqual(try count("git_repositories"), 0)
  }

  func testSecureInputIsRecheckedAfterPreparedCommit() throws {
    try commit(); try observe()
    task.afterMetadataRead = { self.store.setGitSecureInput { true } }
    try scan()
    XCTAssertEqual(try count("git_commits"), 0)
    XCTAssertEqual(try count("git_tombstones"), 0)
    XCTAssertEqual(try count("git_repositories", "last_read IS NOT NULL"), 0)
    store.setGitSecureInput { false }; task.afterMetadataRead = nil
    try scan()
    XCTAssertEqual(try count("git_commits", "complete=1"), 1)
  }

  func testUnknownToolAndUnavailableRecordingHistoryNeverAuthorizeDiscovery() throws {
    try commit()
    let folder = GitWorkingFolder(folder: repo.path, session: "invented-session", source: "invented-source",
      device: 7, inode: 8, time: now - 10)
    XCTAssertFalse(try store.validateGitObservation(folder, now: now))
    try store.connection.run("DELETE FROM log_recording_history")
    XCTAssertFalse(try store.gitRecordingAllowed(at: now))
    try observe()
    XCTAssertEqual(try count("git_working_folders"), 0)
  }
}

extension GitCollectionTests {
  func testGitMutationSitesCannotBypassPublicationGate() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let process = Process(), output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = [root.appendingPathComponent("tools/test_git_publication.py").path]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output; process.standardError = output
    try process.run()
    let result = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0, String(decoding: result, as: UTF8.self))
  }
}

extension GitCollectionTests {
  func testUnavailableNativeTimeHistoryDefersWithoutPermanentRefusal() throws {
    try commit()
    try store.connection.run("DELETE FROM log_recording_history")
    try store.saveSettings(StorageSettings(), at: now - 30)
    try observe(); try scan()
    XCTAssertEqual(try count("git_commits"), 0)
    XCTAssertEqual(try count("git_tombstones"), 0)
    XCTAssertEqual(try count("git_repositories", "last_read IS NOT NULL"), 0)
  }

  func testSecureInputBetweenChildrenCannotCertifyPartialCommitOrFrontier() throws {
    try commit(); try observe()
    task.afterFileAppended = { self.store.setGitSecureInput { true } }
    try scan()
    XCTAssertEqual(try count("git_commits", "complete=1"), 0)
    XCTAssertEqual(try count("git_repositories", "last_read IS NOT NULL"), 0)
    XCTAssertEqual(try count("git_tombstones"), 0)
    task.afterFileAppended = nil; store.setGitSecureInput { false }
    try scan()
    XCTAssertEqual(try count("git_commits", "complete=1"), 1)
    XCTAssertEqual(try count("git_files"), 1)
  }

  func testSecureInputBeforeFrontierCertificationPreservesOldFrontier() throws {
    try commit(); try observe(); try scan()
    let previous = try store.connection.integer("SELECT last_read FROM git_repositories")
    try commit("Invented second change")
    store.beforeGitFrontierPublication = {
      self.store.beforeGitFrontierPublication = nil
      self.store.setGitSecureInput { true }
    }
    try scan(now + 300)
    XCTAssertEqual(try store.connection.integer("SELECT last_read FROM git_repositories"), previous)
    XCTAssertEqual(try count("git_repositories", "pending_frontier!=''"), 0)
    store.setGitSecureInput { false }; try scan(now + 600)
    XCTAssertEqual(try count("git_commits", "complete=1"), 2)
    XCTAssertEqual(try store.connection.integer("SELECT last_read FROM git_repositories"), now + 600)
  }
}


extension GitCollectionTests {
  func testFailedChildStreamCannotBeCertifiedAfterCallerCatchesError() throws {
    let hash = try commit(); try observe()
    let repository = try XCTUnwrap(store.nextGitRepository(after: 0))
    let generation = try XCTUnwrap(store.gitPreparationGeneration(repo: repository.id, now: now))
    let id = try XCTUnwrap(store.beginGitCommit(repo: repository.id, prepared: preparedGit(hash: hash, bytes: 1024), generation: generation, now: now))
    let file = root.appendingPathComponent("invented-incomplete-child")
    try Data(repeating: 120, count: 65536).write(to: file)
    let incomplete = GitMaskedText(maskedFile: file, byteCount: 65537)
    XCTAssertThrowsError(try store.appendGitFile(GitPreparedChangedFile(oldPath: nil, path: incomplete, added: 1, deleted: 0), commit: id, now: now))
    XCTAssertEqual(try store.finishGitCommit(id, now: now), .retry)
    XCTAssertEqual(try count("git_commits"), 0)
    XCTAssertEqual(try count("git_value_text"), 0)
    XCTAssertEqual(try count("git_tombstones"), 0)
  }
}


extension GitCollectionTests {
  func testMissingSourceRevisionAndSourceAttributionNeverAuthorizeRegistration() throws {
    try commit()
    var folder = GitWorkingFolder(folder: repo.path, session: "invented-session", source: "", device: 7, inode: 8, time: now - 10, tool: .claude)
    XCTAssertFalse(try store.gitShouldResolve(folder, now: now))
    XCTAssertFalse(try store.validateGitObservation(folder, now: now))
    try store.rememberGitFolder(folder, location: nil, status: "missing", now: now)
    XCTAssertEqual(try count("git_working_folders"), 0)
    folder.source = "invented-source"
    try store.connection.run("DROP TABLE git_source_revision")
    XCTAssertFalse(try store.gitShouldResolve(folder, now: now))
    XCTAssertFalse(try store.validateGitObservation(folder, now: now))
    try store.rememberGitFolder(folder, location: nil, status: "missing", now: now)
    XCTAssertEqual(try count("git_working_folders"), 0)
  }
}


extension GitCollectionTests {
  func testUnknownCheckpointAttributionDefersUntilQualifiedStartupBackfill() throws {
    try commit()
    var state = AgentLogState(); state.project = repo.path; state.cwdObservedAt = now - 10; state.session = AgentLogIdentity.decoded("invented-unattributed").session.subject
    let position = LogPosition(path: "invented-unattributed", device: 7, inode: 8, offset: 0, state: try state.encoded(), seenAt: now - 10)
    try store.saveLogPosition(position); try scan()
    XCTAssertEqual(try count("git_working_folders"), 0)
    XCTAssertEqual(try count("git_commits"), 0)
    XCTAssertEqual(try count("git_discovery_tombstones"), 0)
    state.tool = "claude"
    var qualified = position; qualified.state = try state.encoded()
    try store.saveLogPosition(qualified)
    task = GitCollectionTask(storage: store, secureInput: { false }, scratchDirectory: root)
    try scan()
    XCTAssertEqual(try count("git_working_folders"), 1)
    XCTAssertEqual(try count("git_commits", "complete=1"), 1)
  }
}


extension GitCollectionTests {
  func testRefStagingWithoutPreparationReceiptIsRejected() throws {
    try commit(); try observe()
    let repository = try XCTUnwrap(store.nextGitRepository(after: 0))
    XCTAssertThrowsError(try store.stageGitRef(repo: repository.id, name: "refs/heads/invented-unprepared", tip: String(repeating: "a", count: 40)))
    XCTAssertEqual(try count("git_refs"), 0)
    XCTAssertEqual(try count("git_repositories", "last_read IS NOT NULL"), 0)
  }
}


extension GitCollectionTests {
  func testRetainedActiveFolderDiagnosticsUseLastSeenWithoutRefreshingOriginalTime() throws {
    try commit(); try observe()
    let initial = now - 10
    var settings = try store.settings(); settings.promptRetentionDays = 1
    try store.saveSettings(settings, at: now)
    let current = now + 2 * 86400
    try observe(time: current - 10, scan: current)
    try store.cleanRetention(at: current)
    let id = try store.connection.integer("SELECT id FROM git_working_folders")
    func status() throws -> String {
      var value = ""
      try store.connection.namedRows("SELECT ts,last_seen,status FROM git_working_folders WHERE id=?", [.integer(id)]) {
        XCTAssertEqual(try $0.int("ts"), initial)
        XCTAssertEqual(try $0.int("last_seen"), current - 10)
        value = try $0.text("status")
      }
      return value
    }
    try store.gitFolderPresence(id: id, exists: false, now: current)
    XCTAssertEqual(try status(), "missing")
    store.setGitSecureInput { true }
    try store.gitFolderPresence(id: id, exists: true, now: current)
    XCTAssertEqual(try status(), "missing")
    store.setGitSecureInput { false }
    try store.gitFolderPresence(id: id, exists: true, now: current)
    XCTAssertEqual(try status(), "ready")
  }
}


extension GitCollectionTests {
  func testCancelledCommitProducerCannotBeReplacedByFreshCancellationScope() throws {
    try commit(); try observe(); try scan()
    let repository = try XCTUnwrap(store.nextGitRepository(after: 0))
    let owner = GitTaskCancellation(), replacement = GitTaskCancellation()
    let hash = String(repeating: "b", count: 40)
    let record = GitCommitRecord(hash: hash, authorTime: now - 60, commitTime: now - 60, author: "Invented", email: "", message: "Invented")
    let id = try store.withGitCancellation(owner) { try XCTUnwrap(store.beginGitCommit(repo: repository.id, commit: record, now: now)) }
    owner.cancel()
    try store.withGitCancellation(replacement) {
      try store.appendGitFile(GitChangedFile(path: "invented-cancelled", added: 1, deleted: 0), commit: id, now: now)
      XCTAssertEqual(try count("git_files", "commit_id=\(id)"), 0)
      XCTAssertEqual(try store.finishGitCommit(id, now: now), .retry)
    }
    XCTAssertEqual(try count("git_commits", "id=\(id)"), 0)
    XCTAssertEqual(try count("git_tombstones"), 0)
  }

  func testCancelledReadProducerCannotCertifyOrCountFailureInFreshScope() throws {
    let hash = try commit(); try observe(); try scan()
    let repository = try XCTUnwrap(store.nextGitRepository(after: 0))
    let previous = try store.connection.integer("SELECT last_read FROM git_repositories")
    let refs = try count("git_refs")
    for outcome: GitReadFinish in [.accounted, .nativeFailure] {
      let owner = GitTaskCancellation(), replacement = GitTaskCancellation()
      let file = root.appendingPathComponent("invented-owner-tips")
      FileManager.default.createFile(atPath: file.path, contents: nil)
      let output = try FileHandle(forWritingTo: file)
      defer { try? output.close() }
      try store.withGitCancellation(owner) {
        try store.prepareGitRefs(repo: repository.id, to: output, now: now + 300)
        try store.stageGitRef(repo: repository.id, name: "refs/heads/invented-cancelled", tip: hash)
      }
      owner.cancel()
      try store.withGitCancellation(replacement) {
        try store.finishGitRead(repo: repository.id, now: now + 300, outcome: outcome)
      }
      XCTAssertEqual(try store.connection.integer("SELECT last_read FROM git_repositories"), previous)
      XCTAssertEqual(try store.connection.integer("SELECT failures FROM git_repositories"), 0)
      XCTAssertEqual(try count("git_refs"), refs)
    }
  }
}
