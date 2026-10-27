import Core
import Darwin
import Foundation
@testable import Inbound
@testable import Shell
@testable import Storage
import XCTest

extension GitCollectionTests {
  private func wordRichCommit(reader: GitRepositoryReader) throws {
    task = GitCollectionTask(storage: store, reader: reader, secureInput: { false }, scratchDirectory: root)
    let file = root.appendingPathComponent("invented-word-rich-message")
    FileManager.default.createFile(atPath: file.path, contents: nil)
    let output = try FileHandle(forWritingTo: file)
    let bytes = Data(String(repeating: "permitted ordinary ", count: 4000).utf8.prefix(65536))
    for _ in 0..<32 { try autoreleasepool { try output.write(contentsOf: bytes) } }
    try output.write(contentsOf: Data([10])); try output.close()
    try git(["commit", "--quiet", "--allow-empty", "-F", file.path]); try observe()
  }
  func testSlowBoundedPreparationDoesNotSpendGitIdleTimeout() throws {
    let reader = GitRepositoryReader(timeout: 1)
    try wordRichCommit(reader: reader)
    var delayed = false
    reader.beforePreparedChunk = { count in
      guard count >= 4096, !delayed else { return }
      delayed = true
      Thread.sleep(forTimeInterval: 1.2)
    }
    defer { reader.beforePreparedChunk = nil }
    try scan()
    XCTAssertTrue(delayed)
    XCTAssertEqual(try count("git_commits", "complete=1"), 1)
    XCTAssertEqual(try store.connection.integer("SELECT sum(length(payload)) FROM git_commit_text WHERE field=2"), (2 << 20) + 1)
    XCTAssertTrue(reader.activeProcessIDs.isEmpty)
  }
  private func interruptWordPreparation(_ action: String) throws {
    let reader = GitRepositoryReader()
    try wordRichCommit(reader: reader)
    var child: Int32?
    reader.beforePreparedChunk = { count in
      guard count >= 4096, child == nil else { return }
      child = reader.activeProcessIDs.first
      if action == "forget" {
        let range = TimeRange(self.now - 61, self.now - 59)
        let preview = try self.store.previewDeletion(in: range)
        try self.store.deleteRecords(in: range, confirmation: preview.confirmation)
      } else if action == "retention" {
        try self.store.saveSettings(StorageSettings(promptRetentionDays: 1), at: self.now + 1)
      } else { self.task.stop() }
    }
    defer { reader.beforePreparedChunk = nil }
    try scan()
    let pid = try XCTUnwrap(child)
    XCTAssertTrue(reader.activeProcessIDs.isEmpty)
    var status: Int32 = 0
    XCTAssertEqual(waitpid(pid, &status, WNOHANG), -1); XCTAssertEqual(errno, ECHILD)
    XCTAssertEqual(try count("git_commits"), 0); XCTAssertEqual(try count("git_refs"), 0)
    if action == "retention" {
      XCTAssertEqual(try count("git_tombstones"), 0)
      try scan(now + 300)
      XCTAssertEqual(try count("git_commits", "complete=1"), 1)
    }
  }
  func testForgetDuringBoundedPreparationKillsAndReapsChild() throws { try interruptWordPreparation("forget") }
  func testRetentionChangeDuringBoundedPreparationIsInterruptibleAndRetryable() throws { try interruptWordPreparation("retention") }
  func testStopDuringBoundedPreparationKillsAndReapsChild() throws { try interruptWordPreparation("stop") }

  private func inventedFIFO() throws -> (URL, Int32) {
    let fifo = root.appendingPathComponent("invented-git-input")
    guard mkfifo(fifo.path, 0o600) == 0 else { throw GitReadError.failed }
    let descriptor = open(fifo.path, O_RDWR | O_NONBLOCK)
    guard descriptor >= 0 else { throw GitReadError.failed }
    return (fifo, descriptor)
  }
  private func activeChild(_ reader: GitRepositoryReader) throws -> Int32 {
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    while ProcessInfo.processInfo.systemUptime < deadline {
      if let pid = reader.activeProcessIDs.first { return pid }
      Thread.sleep(forTimeInterval: 0.005)
    }
    return try XCTUnwrap(reader.activeProcessIDs.first)
  }
  private func checkGitCancellation(stop: Bool) throws {
    let reader = GitRepositoryReader()
    task = GitCollectionTask(storage: store, reader: reader, secureInput: { false }, scratchDirectory: root)
    try commit(); try observe()
    let (fifo, descriptor) = try inventedFIFO(); defer { close(descriptor) }
    let began = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
    task.beforeMetadataRead = {
      began.signal()
      try reader.run(at: self.repo.path, ["cat-file", "--batch-check"], input: fifo) { _ in }
    }
    var failure: Error?, joined = false
    defer { if !joined { reader.cancel(); _ = done.wait(timeout: .now() + 5) } }
    DispatchQueue.global(qos: .utility).async {
      do { try self.task.scan(at: self.now) } catch { failure = error }
      done.signal()
    }
    XCTAssertEqual(began.wait(timeout: .now() + 5), .success)
    let pid = try activeChild(reader)
    if stop { task.stop() }
    else { try store.saveSettings(StorageSettings(recordingEnabled: false), at: now + 1) }
    XCTAssertEqual(done.wait(timeout: .now() + 3), .success); joined = true
    let drained = DispatchSemaphore(value: 0)
    task.finish { drained.signal() }
    XCTAssertEqual(drained.wait(timeout: .now() + 3), .success)
    XCTAssertNil(failure); XCTAssertTrue(reader.activeProcessIDs.isEmpty)
    var status: Int32 = 0
    XCTAssertEqual(waitpid(pid, &status, WNOHANG), -1); XCTAssertEqual(errno, ECHILD)
    XCTAssertEqual(try count("git_commits"), 0); XCTAssertEqual(try count("git_refs"), 0)
  }
  func testRecordingOffKillsAndReapsOwnedGitChild() throws { try checkGitCancellation(stop: false) }
  func testGitTaskStopKillsAndReapsOwnedChildAndDrainsHistory() throws { try checkGitCancellation(stop: true) }
  func testGitTimeoutReapsBlockedOwnedChild() throws {
    let (fifo, descriptor) = try inventedFIFO(); defer { close(descriptor) }
    let reader = GitRepositoryReader(timeout: 0.2), done = DispatchSemaphore(value: 0)
    var failure: Error?
    DispatchQueue.global(qos: .utility).async {
      do { try reader.run(at: self.repo.path, ["cat-file", "--batch-check"], input: fifo) { _ in } }
      catch { failure = error }
      done.signal()
    }
    let pid = try activeChild(reader)
    XCTAssertEqual(done.wait(timeout: .now() + 3), .success)
    guard case GitReadError.timedOut? = failure else { return XCTFail("Expected Git timeout") }
    XCTAssertTrue(reader.activeProcessIDs.isEmpty)
    var status: Int32 = 0
    XCTAssertEqual(waitpid(pid, &status, WNOHANG), -1); XCTAssertEqual(errno, ECHILD)
  }
}
