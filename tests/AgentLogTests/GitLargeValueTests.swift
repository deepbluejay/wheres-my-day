@testable import Core
import Foundation
import Inbound
import SQLite3
@testable import Storage
import XCTest

extension GitCollectionTests {
  private func inventedObject(_ type: String, _ bytes: Data) throws -> String {
    let input = root.appendingPathComponent("invented-object-input")
    try bytes.write(to: input)
    let file = try FileHandle(forReadingFrom: input); defer { try? file.close() }
    let p = Process(), out = Pipe(), errors = Pipe()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    p.arguments = ["-C", repo.path, "hash-object", "--literally", "-w", "-t", type, "--stdin"]
    p.environment = ["PATH": "/usr/bin:/bin", "HOME": root.path, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]
    p.standardInput = file; p.standardOutput = out; p.standardError = errors
    try p.run(); let result = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    guard p.terminationStatus == 0 else {
      XCTFail("invented object type=\(type) status=\(p.terminationStatus), \(String(decoding: errors.fileHandleForReading.readDataToEndOfFile().prefix(200), as: UTF8.self))")
      throw GitReadError.failed
    }
    return String(decoding: result, as: UTF8.self).trimmingCharacters(in: .newlines)
  }
  func testProductionOversizedAuthorPackedRefAndTreePathUseChunks() throws {
    let large = String(repeating: "x", count: 100000)
    let blob = try inventedObject("blob", Data("invented\n".utf8))
    var tree = Data(("100644 " + large + "\0").utf8)
    let hashBytes = Array(blob.utf8)
    for index in stride(from: 0, to: hashBytes.count, by: 2) {
      tree.append(try XCTUnwrap(UInt8(String(decoding: hashBytes[index..<index + 2], as: UTF8.self), radix: 16)))
    }
    let treeHash = try inventedObject("tree", tree)
    let stamp = String(now - 60)
    let raw = "tree \(treeHash)\nauthor \(large) <invented@example.test> \(stamp) +0000\ncommitter Invented <invented@example.test> \(stamp) +0000\n\nInvented change\n"
    let commit = try inventedObject("commit", Data(raw.utf8))
    try git(["update-ref", "refs/heads/main", commit])
    let name = "refs/heads/" + large
    try Data(("# pack-refs with: peeled fully-peeled sorted\n" + commit + " " + name + "\n").utf8).write(to: repo.appendingPathComponent(".git/packed-refs"))
    try observe(); try scan()
    XCTAssertEqual(try count("git_commits", "complete=1"), 1)
    XCTAssertEqual(try store.connection.integer("SELECT sum(length(payload)) FROM git_commit_text WHERE field=0"), large.utf8.count)
    XCTAssertEqual(try store.connection.integer("SELECT sum(length(payload)) FROM git_value_text WHERE kind=1 AND field=1"), large.utf8.count)
    for kind in [2, 3] {
      XCTAssertEqual(try store.connection.integer("SELECT sum(length(payload)) FROM git_value_text WHERE kind=?", [.integer(kind)]), name.utf8.count)
    }
    XCTAssertLessThanOrEqual(try store.connection.integer("SELECT max(length(payload)) FROM git_value_text"), 65536)
    let range = TimeRange(now - 61, now - 59), preview = try store.previewDeletion(in: TimeRange(now - 61, now - 59))
    XCTAssertGreaterThan(preview.counts["git_value_text"] ?? 0, 0)
    try store.deleteRecords(in: range, confirmation: preview.confirmation)
    XCTAssertEqual(try count("git_value_text", "kind IN (1,2)"), 0)
    XCTAssertEqual(try count("git_commits"), 0)
  }
  func testOversizedPreparedInitialBranchPublishesCompleteChunksAndForgetsThem() throws {
    try commit()
    let name = String(repeating: "x", count: 100000)
    let location = try work { try GitRepositoryReader().directoryLocation(self.repo.path) }
    let branch = try GitMaskedText.prepare(name, in: root)
    let folder = GitWorkingFolder(folder: repo.path, session: "invented-session", source: "invented-source", device: 7, inode: 8, time: now - 10, tool: .claude)
    try store.rememberGitFolder(folder, location: location, status: "ready", now: now, preparedBranch: branch)
    XCTAssertEqual(try count("git_working_folders", "complete=1"), 1)
    XCTAssertEqual(try store.connection.integer("SELECT sum(length(payload)) FROM git_value_text WHERE kind=4"), name.utf8.count)
    let range = TimeRange(now - 11, now - 9), preview = try store.previewDeletion(in: TimeRange(now - 11, now - 9))
    XCTAssertEqual(preview.counts["git_value_text"], 2)
    try store.deleteRecords(in: range, confirmation: preview.confirmation)
    XCTAssertEqual(try count("git_value_text"), 0)
    XCTAssertEqual(try count("git_working_folders"), 0)
  }
  func testOversizedPreparedInitialBranchPauseResumeCannotLeavePartialDiscovery() throws {
    try commit()
    let location = try work { try GitRepositoryReader().directoryLocation(self.repo.path) }
    let branch = try GitMaskedText.prepare(String(repeating: "x", count: 100000), in: root)
    let folder = GitWorkingFolder(folder: repo.path, session: "invented-session", source: "invented-source", device: 7, inode: 8, time: now - 10, tool: .claude)
    store.afterGitFolderStarted = { _ in
      try self.store.saveSettings(StorageSettings(recordingEnabled: false), at: self.now + 1)
      try self.store.saveSettings(StorageSettings(), at: self.now + 2)
    }
    XCTAssertThrowsError(try store.rememberGitFolder(folder, location: location, status: "ready", now: now, preparedBranch: branch))
    XCTAssertEqual(try count("git_working_folders"), 0)
    XCTAssertEqual(try count("git_repositories"), 0)
    XCTAssertEqual(try count("git_value_text"), 0)
  }
}
