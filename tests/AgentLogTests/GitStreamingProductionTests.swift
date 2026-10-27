@testable import Core
import CryptoKit
import Darwin
import Foundation
import SQLite3
@testable import Shell
@testable import Storage
import XCTest

func inventedSelfRSS() -> UInt64 {
  var info = mach_task_basic_info()
  var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
  let result = withUnsafeMutablePointer(to: &info) {
    $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
      task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
    }
  }
  return result == KERN_SUCCESS ? info.resident_size : 0
}

extension GitCollectionTests {
  private func productionStreaming(mebibytes: Int, manyUnits: Bool = false) throws {
    let message = root.appendingPathComponent("invented-large-message")
    FileManager.default.createFile(atPath: message.path, contents: nil)
    let output = try FileHandle(forWritingTo: message)
    let block = manyUnits ? Data(String(repeating: "permitted ordinary ", count: 4000).utf8.prefix(65536)) : Data(repeating: 120, count: 65536)
    for _ in 0..<(mebibytes * 16) { try autoreleasepool { try output.write(contentsOf: block) } }
    try output.write(contentsOf: Data([10])); try output.close()
    try git(["commit", "--quiet", "--allow-empty", "-F", message.path]); try observe()
    let later = root.appendingPathComponent("invented-later-repository")
    try FileManager.default.createDirectory(at: later, withIntermediateDirectories: false)
    try git(["init", "-b", "main"], in: later)
    try store.connection.run("CREATE TABLE invented_writer_probe(value INTEGER)")
    let writer = try SQLiteConnection(url: root.appendingPathComponent("invented.sqlite"), scope: .directory(root), busyMilliseconds: 0)
    let done = DispatchSemaphore(value: 0), ready = DispatchSemaphore(value: 0), observed = DispatchSemaphore(value: 0)
    let state = GitWriterProbeState()
    let baseline = inventedSelfRSS()
    var peak = baseline, observeDuration = 0.0, observeFailure: Error?
    var joined = false
    defer { if !joined { state.stop(); done.wait() } }
    DispatchQueue.global(qos: .utility).async {
      var busySince: Double?, signaled = false
      while !state.shouldStop() {
        peak = max(peak, inventedSelfRSS())
        let time = ProcessInfo.processInfo.systemUptime
        do {
          try writer.run("INSERT INTO invented_writer_probe VALUES(1)"); state.successful += 1
          if !signaled { ready.signal(); signaled = true }
          if let start = busySince { state.longest = max(state.longest, time - start); busySince = nil }
        } catch StorageError.busy {
          state.busy += 1; if busySince == nil { busySince = time }
        } catch { state.failure = error; break }
        Thread.sleep(forTimeInterval: 0.005)
      }
      if !signaled { ready.signal() }
      if let start = busySince { state.longest = max(state.longest, ProcessInfo.processInfo.systemUptime - start) }
      done.signal()
    }
    ready.wait()
    task.beforeMetadataRead = {
      self.task.beforeMetadataRead = nil
      DispatchQueue.global(qos: .utility).async {
        Thread.sleep(forTimeInterval: 0.05)
        let start = ProcessInfo.processInfo.systemUptime
        do { try self.task.observe(GitWorkingFolder(folder: later.path, session: "invented-later", source: "invented-later", device: 7,
          inode: 99, time: self.now - 1, tool: .claude), now: self.now) }
        catch { observeFailure = error }
        observeDuration = ProcessInfo.processInfo.systemUptime - start; observed.signal()
      }
    }
    let start = ProcessInfo.processInfo.systemUptime
    try scan()
    XCTAssertEqual(observed.wait(timeout: .now() + 10), .success)
    state.stop(); done.wait(); joined = true
    let duration = ProcessInfo.processInfo.systemUptime - start
    XCTAssertNil(state.failure); XCTAssertNil(observeFailure)
    XCTAssertEqual(try count("git_commits", "complete=1"), 1)
    XCTAssertEqual(try store.connection.integer("SELECT sum(length(payload)) FROM git_commit_text WHERE field=2"), (mebibytes << 20) + 1)
    var expected = SHA256(), stored = SHA256()
    let source = try FileHandle(forReadingFrom: message)
    defer { try? source.close() }
    while try autoreleasepool(invoking: { () throws -> Bool in
      guard let bytes = try source.read(upToCount: 65536), !bytes.isEmpty else { return false }
      expected.update(data: bytes); return true
    }) {}
    try store.connection.rows("SELECT payload FROM git_commit_text WHERE field=2 ORDER BY ordinal") { row in
      autoreleasepool {
        if let bytes = sqlite3_column_blob(row, 0) {
          stored.update(data: Data(bytes: bytes, count: Int(sqlite3_column_bytes(row, 0))))
        }
      }
    }
    XCTAssertEqual(Data(stored.finalize()), Data(expected.finalize()))
    XCTAssertLessThan(state.longest, 0.25)
    XCTAssertLessThan(observeDuration, 2)
    XCTAssertGreaterThan(baseline, 0)
    XCTAssertLessThan(peak - baseline, 32 << 20)
    print("invented production Git MiB=\(mebibytes) peak_self_rss_bytes=\(peak) scan_seconds=\(duration) cwd_seconds=\(observeDuration) successful_writes=\(state.successful) busy_attempts=\(state.busy) longest_busy_seconds=\(state.longest)")
  }
  func testProductionStreaming1MiB() throws { try productionStreaming(mebibytes: 1) }
  func testProductionStreaming8MiB() throws { try productionStreaming(mebibytes: 8) }
  func testProductionStreaming32MiB() throws { try productionStreaming(mebibytes: 32) }
  func testProductionStreaming128MiB() throws { try productionStreaming(mebibytes: 128) }
  func testProductionStreamingManyUnits8MiB() throws { try productionStreaming(mebibytes: 8, manyUnits: true) }
}
