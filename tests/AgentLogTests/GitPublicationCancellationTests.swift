@testable import Core
import Darwin
import Foundation
@testable import Inbound
@testable import Shell
@testable import Storage
import XCTest

extension GitCollectionTests {
  private func resetStopFixture(_ phase: String) throws -> GitRepositoryReader {
    task = nil; store = nil
    repo = root.appendingPathComponent("invented-" + phase)
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: false)
    try git(["init", "-b", "main"])
    store = try ActivityStorage(url: root.appendingPathComponent(phase + ".sqlite"), appDataDirectory: root, databaseScope: .directory(root))
    try store.saveSettings(StorageSettings(), at: 0)
    let reader = GitRepositoryReader()
    task = GitCollectionTask(storage: store, reader: reader, secureInput: { false }, scratchDirectory: root)
    return reader
  }
  private func writeStopField(_ output: FileHandle, mebibytes: Int, byte: UInt8) throws {
    let block = Data(repeating: byte, count: 65536)
    for _ in 0..<(mebibytes * 16) { try autoreleasepool { try output.write(contentsOf: block) } }
  }
  private func stopFixtureCommit(mebibytes: Int, metadata: Bool, path: Bool, messageOnly: Bool = false) throws -> String {
    let blob = try largeInventedObject("blob") { try $0.write(contentsOf: Data("invented\n".utf8)) }
    let tree = try largeInventedObject("tree") { output in
      try output.write(contentsOf: Data("100644 ".utf8))
      if path { try writeStopField(output, mebibytes: mebibytes, byte: 119) }
      else { try output.write(contentsOf: Data("invented".utf8)) }
      try output.write(contentsOf: Data([0]))
      let hex = Array(blob.utf8)
      for index in stride(from: 0, to: hex.count, by: 2) {
        try output.write(contentsOf: Data([try XCTUnwrap(UInt8(String(decoding: hex[index..<index + 2], as: UTF8.self), radix: 16))]))
      }
    }
    let hash = try largeInventedObject("commit") { output in
      try output.write(contentsOf: Data("tree \(tree)\nauthor ".utf8))
      if metadata && !messageOnly { try writeStopField(output, mebibytes: mebibytes, byte: 120) }
      else { try output.write(contentsOf: Data("Invented".utf8)) }
      try output.write(contentsOf: Data(" <".utf8))
      if metadata && !messageOnly { try writeStopField(output, mebibytes: mebibytes, byte: 121) }
      else { try output.write(contentsOf: Data("invented@example.test".utf8)) }
      try output.write(contentsOf: Data("> \(now - 60) +0000\ncommitter Invented <invented@example.test> \(now - 60) +0000\n\n".utf8))
      if metadata { try writeStopField(output, mebibytes: mebibytes, byte: 122) }
      else { try output.write(contentsOf: Data("Invented change".utf8)) }
      try output.write(contentsOf: Data([10]))
    }
    try git(["update-ref", "refs/heads/main", hash])
    return hash
  }
  private func installStopRef(_ hash: String, mebibytes: Int, branch: Bool) throws {
    let file = repo.appendingPathComponent(".git/packed-refs")
    XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil))
    let out = try FileHandle(forWritingTo: file); defer { try? out.close() }
    try out.write(contentsOf: Data("# pack-refs with: peeled fully-peeled sorted\n\(hash) refs/heads/".utf8))
    try writeStopField(out, mebibytes: mebibytes, byte: 118)
    try out.write(contentsOf: Data([10])); try out.close()
    if branch {
      let head = repo.appendingPathComponent(".git/HEAD")
      let output = try FileHandle(forWritingTo: head); defer { try? output.close() }
      try output.truncate(atOffset: 0)
      try output.write(contentsOf: Data("ref: refs/heads/".utf8))
      try writeStopField(output, mebibytes: mebibytes, byte: 118)
      try output.write(contentsOf: Data([10])); try output.close()
    }
  }
  private func frontierReceipt() throws -> String {
    try store.locked {
      var result = ""
      try store.connection.namedRows("SELECT frontier,last_read FROM git_repositories WHERE frontier!='' OR last_read!=0 ORDER BY id") {
        result += try $0.text("frontier") + ":" + String($0.int("last_read"))
      }
      return result
    }
  }
  private func stopPublicationMatrix(mebibytes: Int) throws {
    for phase in ["preparation", "replay", "author", "email", "message", "commit-completion", "file", "commit-ref", "branch", "staging", "frontier-export", "frontier", "completion", "commit-cleanup", "frontier-cleanup", "staging-cleanup", "branch-cleanup"] {
      let reader = try resetStopFixture(phase)
      let largeMetadata = ["preparation", "replay", "author", "email", "message", "commit-completion", "commit-cleanup"].contains(phase)
      let hash = try stopFixtureCommit(mebibytes: mebibytes, metadata: largeMetadata, path: phase == "file")
      let largeRef = ["commit-ref", "staging", "frontier-export", "frontier", "completion", "frontier-cleanup", "staging-cleanup", "branch", "branch-cleanup"].contains(phase)
      let branch = phase == "branch" || phase == "branch-cleanup"
      if phase == "frontier-export" {
        for index in 0..<8 {
          let tip = try commit("Invented export \(index)")
          try git(["update-ref", "refs/heads/invented-export-\(index)", tip])
        }
      }
      if !branch { try observe() }
      if ["frontier-export", "frontier", "completion", "frontier-cleanup", "staging-cleanup"].contains(phase) { try scan() }
      if largeRef { try installStopRef(hash, mebibytes: mebibytes, branch: false) }
      if branch {
        // Git rejects oversized symbolic HEAD files before emitting a branch.
        // Exercise the actual observation publisher with an invented prepared
        // branch receipt after the real location read has completed instead.
        let file = root.appendingPathComponent("invented-branch-" + phase)
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil))
        let output = try FileHandle(forWritingTo: file)
        try writeStopField(output, mebibytes: mebibytes, byte: 118); try output.close()
        task.afterLocationPrepared = { $0.branch = GitMaskedText(maskedFile: file, byteCount: mebibytes << 20) }
      }
      if phase == "frontier-cleanup" { try scan() }
      var units = 0, preparationArmed = false, stoppedAt: Double?, receiptAtStop = ""
      var branchUnits = 0, chunksAtStop = 0, finishedAt = 0.0
      let finished = DispatchSemaphore(value: 0)
      func stop() throws {
        guard stoppedAt == nil else { return }
        if ["author", "email", "message", "commit-completion", "file", "commit-ref", "branch", "frontier", "completion"].contains(phase) {
          // At a completed text token, Git has no further payload to produce.
          // Wait only for its exit, proving cancellation also works without a
          // live child to kill (metadata/frontier have already reaped theirs).
          let end = ProcessInfo.processInfo.systemUptime + 0.2
          while !reader.runningProcessIDs.isEmpty, ProcessInfo.processInfo.systemUptime < end { Thread.sleep(forTimeInterval: 0.001) }
          XCTAssertTrue(reader.runningProcessIDs.isEmpty, phase)
        }
        receiptAtStop = try frontierReceipt()
        chunksAtStop = try count("git_commit_text") + count("git_value_text")
        stoppedAt = ProcessInfo.processInfo.systemUptime
        let maintenance = task.maintenanceTask
        maintenance.cancel()
        maintenance.finish { finishedAt = ProcessInfo.processInfo.systemUptime; finished.signal() }
      }
      task.beforeMetadataRead = { preparationArmed = true }
      reader.afterPreparedUnit = { current in
        if preparationArmed, current == phase { units += 1; if units == 4 { try stop() } }
      }
      task.afterCommitStarted = { _ in if phase == "commit-cleanup" { throw GitReadError.failed } }
      store.beforeGitFrontierPublication = { if phase == "completion" { units += 1; try stop() } }
      store.beforeGitCommitCompletion = { if phase == "commit-completion" { units += 1; try stop() } }
      store.afterGitUnit = { current in
        if phase == "branch-cleanup", current == "branch" {
          branchUnits += 1
          if branchUnits == mebibytes * 16 { throw GitReadError.failed }
        }
        if current == phase { units += 1; if units == 4 { try stop() } }
      }
      if branch { try observe() } else { try scan(now + 300) }
      let returnedAt = ProcessInfo.processInfo.systemUptime
      XCTAssertEqual(finished.wait(timeout: .now() + 1), .success, phase)
      let start = try XCTUnwrap(stoppedAt, phase)
      let latency = max(returnedAt, finishedAt) - start
      XCTAssertLessThan(latency, 0.5, phase)
      XCTAssertEqual(try frontierReceipt(), receiptAtStop, phase)
      XCTAssertEqual(try count("git_repositories", "pending_frontier!=''"), 0, phase)
      XCTAssertEqual(try count("git_tombstones"), 0, phase)
      XCTAssertTrue(reader.activeProcessIDs.isEmpty, phase)
      XCTAssertLessThanOrEqual(try count("git_commit_text") + count("git_value_text"), chunksAtStop, phase)
      if ["author", "email", "message", "commit-completion", "file", "commit-ref", "preparation", "replay", "commit-cleanup"].contains(phase) {
        XCTAssertEqual(try count("git_commits", "complete=1"), 0, phase)
      }
      if branch { XCTAssertEqual(try count("git_working_folders", "complete=1"), 0, phase) }
      print("invented stop MiB=\(mebibytes) phase=\(phase) units=\(units) chunks_at_stop=\(chunksAtStop) return_and_finish_seconds=\(latency)")
      reader.afterPreparedUnit = nil; store.afterGitUnit = nil; store.beforeGitFrontierPublication = nil; store.beforeGitCommitCompletion = nil
      task.afterCommitStarted = nil; task.beforeMetadataRead = nil
      // A fresh scan must erase abandonment even while Recording is off.
      try store.saveSettings(StorageSettings(recordingEnabled: false), at: now + 301)
      task = GitCollectionTask(storage: store, secureInput: { false }, scratchDirectory: root)
      try scan(now + 302)
      XCTAssertEqual(try count("git_commits", "complete=-1"), 0, phase)
      XCTAssertEqual(try count("git_working_folders", "complete=-1"), 0, phase)
      XCTAssertEqual(try count("git_refs", "frontier!=(SELECT frontier FROM git_repositories WHERE id=repo_id)"), 0, phase)
      if phase == "author", mebibytes == 32 {
        try store.saveSettings(StorageSettings(), at: now + 303)
        try scan(now + 304)
        XCTAssertEqual(try count("git_commits", "complete=1"), 1)
      }
      if phase == "staging" || phase == "staging-cleanup" {
        XCTAssertEqual(try store.locked { try store.gitStageConnection?.integer("SELECT count(*) FROM git_next_ref_text") ?? 0 }, 0, phase)
        XCTAssertEqual(try store.locked { try store.gitStageConnection?.integer("SELECT count(*) FROM git_next_refs") ?? 0 }, 0, phase)
      }
    }
  }
  func testProductionStopEveryBoundedLoop32MiB() throws { try stopPublicationMatrix(mebibytes: 32) }
  func testProductionStopEveryBoundedLoop128MiB() throws { try stopPublicationMatrix(mebibytes: 128) }
}

extension GitCollectionTests {
  private func cancelledCleanupDebt() throws -> (Int, String) {
    let hash = try commit(); try observe()
    let repo = try XCTUnwrap(store.nextGitRepository(after: 0))
    let generation = try XCTUnwrap(store.gitPreparationGeneration(repo: repo.id, now: now))
    let prepared = try preparedGit(hash: hash)
    let id = try XCTUnwrap(store.beginGitCommit(repo: repo.id, prepared: prepared, generation: generation, now: now))
    let cancellation = GitTaskCancellation(); cancellation.cancel()
    Thread.sleep(forTimeInterval: 0.11)
    XCTAssertThrowsError(try store.withGitCancellation(cancellation) { try store.abandonGitCommit(id) })
    XCTAssertEqual(try count("git_commits", "complete=-1"), 1)
    XCTAssertEqual(try count("git_commit_text"), 16)
    XCTAssertFalse(try store.gitCommitKnown(repo: repo.id, hash: hash))
    XCTAssertEqual(try count("git_tombstones"), 0)
    return (id, hash)
  }
  func testCancelledCleanupIsRecoveredOnCollectorStartupWhileRecordingOff() throws {
    _ = try cancelledCleanupDebt()
    try store.saveSettings(StorageSettings(recordingEnabled: false), at: now + 1)
    task = nil; store = nil
    store = try ActivityStorage(url: root.appendingPathComponent("invented.sqlite"), appDataDirectory: root, databaseScope: .directory(root))
    task = GitCollectionTask(storage: store, secureInput: { false }, scratchDirectory: root)
    let done = DispatchSemaphore(value: 0)
    task.finish { done.signal() }
    XCTAssertEqual(done.wait(timeout: .now() + 3), .success)
    XCTAssertFalse(try store.settings().recordingEnabled)
    XCTAssertEqual(try count("git_commits"), 0)
    XCTAssertEqual(try count("git_commit_text"), 0)
    XCTAssertEqual(try count("git_tombstones"), 0)
  }
  func testCancelledCleanupRemainsInForgetPreviewAndIsPhysicallyErased() throws {
    _ = try cancelledCleanupDebt()
    let range = TimeRange(now - 61, now - 59)
    let preview = try store.previewDeletion(in: range)
    XCTAssertEqual(preview.counts["git_commit_text"], 16)
    XCTAssertTrue(try store.gitStatus().contains("git_commit_text=16"))
    try store.deleteRecords(in: range, confirmation: preview.confirmation)
    XCTAssertEqual(try count("git_commits"), 0)
    XCTAssertEqual(try count("git_commit_text"), 0)
  }
  func testCancelledCleanupIsCoveredByRetention() throws {
    _ = try cancelledCleanupDebt()
    try store.saveSettings(StorageSettings(promptRetentionDays: 1), at: now + 2 * 86400)
    try store.cleanRetention(at: now + 2 * 86400)
    XCTAssertEqual(try count("git_commits"), 0)
    XCTAssertEqual(try count("git_commit_text"), 0)
    XCTAssertEqual(try count("git_tombstones"), 0)
  }
  func testCancelledScratchDisposalRecoversOnlyExplicitlyDiscardedDirectories() throws {
    let cancelled = root.appendingPathComponent("activityprobe-git-invented-discarded")
    let active = root.appendingPathComponent("activityprobe-git-invented-active")
    for folder in [cancelled, active] {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
      for index in 0..<32 { try Data("invented".utf8).write(to: folder.appendingPathComponent(String(index))) }
    }
    let cancellation = GitTaskCancellation(); cancellation.cancel()
    Thread.sleep(forTimeInterval: 0.11)
    GitScratchCleanup.discard(cancelled, cancellation: cancellation)
    XCTAssertTrue(FileManager.default.fileExists(atPath: cancelled.path))
    try GitScratchCleanup.recover(in: root)
    XCTAssertFalse(FileManager.default.fileExists(atPath: cancelled.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: active.path))
  }
}

extension GitCollectionTests {
  func testSmallPreparationRecipeContainsNoTextAndReplayStaysExact() throws {
    let directory = root.appendingPathComponent("invented-small-recipe")
    let bytes = Data("Invented readable metadata\n".utf8)
    let plan = try GitTextPreparation(directory: directory, digest: GitSHA256Digest())
    try plan.consume(bytes); try plan.seal()
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("text").path))
    let replay = try GitTextPreparation(replaying: directory, digest: GitSHA256Digest())
    try replay.replay(bytes)
    XCTAssertEqual(try replay.finishReplay().smallText(), String(decoding: bytes, as: UTF8.self))
  }
  func testStoppedReplayUnlinksTextBeforeDeferringNumericRecipeDisposal() throws {
    let directory = root.appendingPathComponent("activityprobe-git-invented-recipe")
    let block = Data(repeating: 120, count: 65536)
    let cancellation = GitTaskCancellation()
    let plan = try GitTextPreparation(directory: directory, digest: GitSHA256Digest(), cancellation: cancellation)
    for _ in 0..<16 { try plan.consume(block) }
    try plan.seal()
    var replay: GitTextPreparation? = try GitTextPreparation(replaying: directory, digest: GitSHA256Digest(), cancellation: cancellation)
    for _ in 0..<4 { try replay?.replay(block) }
    XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("text").path))
    cancellation.cancel(); Thread.sleep(forTimeInterval: 0.11)
    replay = nil
    XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("text").path))
    try GitScratchCleanup.recover(in: root)
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
  }
}

extension GitCollectionTests {
  private func contestedWriterStop(mebibytes: Int) throws {
    for phase in ["branch-completion", "commit-completion", "frontier-completion", "between-chunks"] {
      let reader = try resetStopFixture(phase)
      let branch = phase == "branch-completion"
      let hash = try stopFixtureCommit(mebibytes: mebibytes, metadata: !branch && phase != "frontier-completion", path: false, messageOnly: true)
      if !branch { try observe() }
      if phase == "frontier-completion" { try installStopRef(hash, mebibytes: mebibytes, branch: false) }
      if branch {
        let file = root.appendingPathComponent("invented-contested-branch")
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil))
        let out = try FileHandle(forWritingTo: file)
        try writeStopField(out, mebibytes: mebibytes, byte: 118); try out.close()
        task.afterLocationPrepared = { $0.branch = GitMaskedText(maskedFile: file, byteCount: mebibytes << 20) }
      }
      let holder = try SQLiteConnection(url: root.appendingPathComponent(phase + ".sqlite"), scope: .directory(root), busyMilliseconds: 0)
      let admitted = DispatchSemaphore(value: 0), returned = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
      let release = DispatchSemaphore(value: 0), released = DispatchSemaphore(value: 0)
      var armed = true, units = 0, scanError: Error?, returnedAt = 0.0, finishedAt = 0.0
      var receipt = ""
      func snapshot() throws -> String {
        var result = ""
        try holder.namedRows("SELECT frontier,last_read FROM git_repositories ORDER BY id") {
          result += try $0.text("frontier") + ":" + String($0.int("last_read"))
        }
        return result
      }
      func hold() throws {
        guard armed else { return }; armed = false
        try holder.run("BEGIN IMMEDIATE")
        receipt = try snapshot()
        DispatchQueue.global(qos: .utility).async {
          // The deadline makes a broken implementation fail without hanging the suite.
          _ = release.wait(timeout: .now() + 2)
          try? holder.run("ROLLBACK"); released.signal()
        }
        admitted.signal()
      }
      store.beforeGitFolderCompletion = { if branch { try hold() } }
      store.beforeGitCommitCompletion = { if phase == "commit-completion" { try hold() } }
      store.beforeGitFrontierPublication = { if phase == "frontier-completion" { try hold() } }
      store.afterGitUnit = { current in
        if phase == "between-chunks", current == "message" { units += 1; if units == 4 { try hold() } }
      }
      let activeTask = task!
      DispatchQueue.global(qos: .utility).async {
        do {
          if branch {
            try activeTask.observe(GitWorkingFolder(folder: self.repo.path, session: "invented-contested", source: "invented-contested", device: 7, inode: 9, time: self.now - 10, tool: .claude), now: self.now)
          } else { try activeTask.scan(at: self.now + 300) }
        } catch { scanError = error }
        returnedAt = ProcessInfo.processInfo.systemUptime; returned.signal()
      }
      XCTAssertEqual(admitted.wait(timeout: .now() + 180), .success, phase)
      Thread.sleep(forTimeInterval: 0.02)
      let start = ProcessInfo.processInfo.systemUptime
      activeTask.stop()
      let stopLatency = ProcessInfo.processInfo.systemUptime - start
      activeTask.finish { finishedAt = ProcessInfo.processInfo.systemUptime; finished.signal() }
      XCTAssertEqual(returned.wait(timeout: .now() + 1), .success, phase)
      XCTAssertEqual(finished.wait(timeout: .now() + 1), .success, phase)
      let finishLatency = max(returnedAt, finishedAt) - start
      XCTAssertLessThan(stopLatency, 0.5, phase)
      XCTAssertLessThan(finishLatency, 0.5, phase)
      XCTAssertEqual(try snapshot(), receipt, phase)
      XCTAssertEqual(try holder.integer("SELECT count(*) FROM git_commits WHERE complete=1"), phase == "frontier-completion" ? 1 : 0, phase)
      if branch { XCTAssertEqual(try holder.integer("SELECT count(*) FROM git_working_folders WHERE complete=1"), 0) }
      XCTAssertTrue(reader.activeProcessIDs.isEmpty, phase)
      print("invented contested stop MiB=\(mebibytes) phase=\(phase) stop_seconds=\(stopLatency) return_and_finish_seconds=\(finishLatency) scan_cancelled=\(scanError != nil)")
      release.signal(); XCTAssertEqual(released.wait(timeout: .now() + 3), .success)
      store.beforeGitFolderCompletion = nil; store.beforeGitCommitCompletion = nil
      store.beforeGitFrontierPublication = nil; store.afterGitUnit = nil
      // Contention can prevent even an invalidation UPDATE. Durable incomplete rows
      // and inactive frontiers remain invisible and must recover after reopening.
      task = nil; store = nil
      store = try ActivityStorage(url: root.appendingPathComponent(phase + ".sqlite"), appDataDirectory: root, databaseScope: .directory(root))
      try store.saveSettings(StorageSettings(recordingEnabled: false), at: now + 301)
      task = GitCollectionTask(storage: store, secureInput: { false }, scratchDirectory: root)
      try scan(now + 302)
      XCTAssertEqual(try count("git_commits", "complete!=1"), 0, phase)
      XCTAssertEqual(try count("git_working_folders", "complete!=1"), 0, phase)
      XCTAssertEqual(try count("git_repositories", "pending_frontier!=''"), 0, phase)
      XCTAssertEqual(try count("git_tombstones"), 0, phase)
    }
  }
  func testExternalStopAndFinishWhileWriterHeld32MiB() throws { try contestedWriterStop(mebibytes: 32) }
  func testExternalStopAndFinishWhileWriterHeld128MiB() throws { try contestedWriterStop(mebibytes: 128) }
}
