import Core
import CryptoKit
import Darwin
import Foundation
import Inbound
import SQLite3
@testable import Storage
import XCTest

extension GitCollectionTests {
  // Each size starts a fresh collector process, so earlier allocations cannot hide growth.
  private func allFieldsInIndependentProcess(mebibytes: Int, ownRegistry: Bool = false, test: String = #function) throws {
    if ProcessInfo.processInfo.environment["ACTIVITYPROBE_GIT_RSS_CHILD"] == String(mebibytes) {
      if ownRegistry { try store.ownLogSources().registerSession("invented-unrelated-own", tool: .claude) }
      try collectAllLargeFields(mebibytes: mebibytes)
      return
    }
    let log = root.appendingPathComponent("invented-child-result")
    XCTAssertTrue(FileManager.default.createFile(atPath: log.path, contents: nil))
    let output = try FileHandle(forWritingTo: log)
    defer { try? output.close() }
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    child.arguments = ["xctest", "-XCTest", "AgentLogTests.GitCollectionTests/" + test.replacingOccurrences(of: "()", with: ""),
      Bundle(for: GitCollectionTests.self).bundleURL.path]
    child.environment = ["PATH": "/usr/bin:/bin", "HOME": root.path, "TMPDIR": root.path,
      "ACTIVITYPROBE_TEST_ROOT": root.path, "ACTIVITYPROBE_GIT_RSS_CHILD": String(mebibytes), "NSUnbufferedIO": "YES"]
    child.standardInput = FileHandle.nullDevice
    child.standardOutput = output; child.standardError = output
    let done = DispatchSemaphore(value: 0)
    child.terminationHandler = { _ in done.signal() }
    try child.run()
    if done.wait(timeout: .now() + 600) != .success {
      child.terminate()
      if done.wait(timeout: .now() + 10) != .success { kill(child.processIdentifier, SIGKILL); done.wait() }
      XCTFail("Independent invented collector timed out")
    }
    child.waitUntilExit()
    let result = try String(contentsOf: log, encoding: .utf8)
    print(result)
    XCTAssertEqual(child.terminationStatus, 0, result)
    XCTAssertTrue(result.contains("all_field_digests=6"), "Child must run the selected regression")
  }

  func largeInventedObject(_ type: String, write: (FileHandle) throws -> Void) throws -> String {
    let input = root.appendingPathComponent("invented-object-input")
    XCTAssertTrue(FileManager.default.createFile(atPath: input.path, contents: nil))
    let output = try FileHandle(forWritingTo: input)
    do { try write(output); try output.close() } catch { try? output.close(); throw error }
    let source = try FileHandle(forReadingFrom: input)
    defer { try? source.close() }
    let child = Process(), result = Pipe()
    child.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    child.arguments = ["-C", repo.path, "hash-object", "--literally", "-w", "-t", type, "--stdin"]
    child.environment = ["PATH": "/usr/bin:/bin", "HOME": root.path, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]
    child.standardInput = source; child.standardOutput = result; child.standardError = FileHandle.nullDevice
    try child.run()
    let bytes = result.fileHandleForReading.readDataToEndOfFile()
    child.waitUntilExit()
    guard child.terminationStatus == 0 else { throw GitReadError.failed }
    return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .newlines)
  }

  private func collectAllLargeFields(mebibytes: Int) throws {
    // Every block has an ordinal marker, so digest checks also detect chunk reordering.
    func writeField(_ file: FileHandle, byte: UInt8, prefix: String = "", suffix: String = "") throws -> Data {
      var digest = SHA256()
      let start = Data(prefix.utf8), end = Data(suffix.utf8)
      try file.write(contentsOf: start); digest.update(data: start)
      for ordinal in 0..<(mebibytes * 16) {
        try autoreleasepool {
          var block = Data(repeating: byte, count: 65536)
          var value = ordinal
          for index in 0..<8 { block[index] = 97 + UInt8(value % 26); value /= 26 }
          try file.write(contentsOf: block); digest.update(data: block)
        }
      }
      try file.write(contentsOf: end); digest.update(data: end)
      return Data(digest.finalize())
    }
    let blob = try largeInventedObject("blob") { try $0.write(contentsOf: Data("invented\n".utf8)) }
    var expected: [Data] = []
    var pathDigest = Data()
    let tree = try largeInventedObject("tree") { file in
      try file.write(contentsOf: Data("100644 ".utf8))
      pathDigest = try writeField(file, byte: 119)
      try file.write(contentsOf: Data([0]))
      let bytes = Array(blob.utf8)
      for index in stride(from: 0, to: bytes.count, by: 2) {
        let byte = try XCTUnwrap(UInt8(String(decoding: bytes[index..<index + 2], as: UTF8.self), radix: 16))
        try file.write(contentsOf: Data([byte]))
      }
    }
    let commit = try largeInventedObject("commit") { file in
      try file.write(contentsOf: Data("tree \(tree)\nauthor ".utf8))
      expected.append(try writeField(file, byte: 120))
      try file.write(contentsOf: Data(" <".utf8))
      expected.append(try writeField(file, byte: 121))
      try file.write(contentsOf: Data("> \(now - 60) +0000\ncommitter Invented <invented@example.test> \(now - 60) +0000\n\n".utf8))
      expected.append(try writeField(file, byte: 122, suffix: "\n"))
    }
    try git(["update-ref", "refs/heads/main", commit])
    let packed = repo.appendingPathComponent(".git/packed-refs")
    XCTAssertTrue(FileManager.default.createFile(atPath: packed.path, contents: nil))
    let refs = try FileHandle(forWritingTo: packed)
    var refDigest: Data
    do {
      try refs.write(contentsOf: Data("# pack-refs with: peeled fully-peeled sorted\n\(commit) ".utf8))
      refDigest = try writeField(refs, byte: 118, prefix: "refs/heads/")
      try refs.write(contentsOf: Data([10])); try refs.close()
    } catch { try? refs.close(); throw error }
    expected += [pathDigest, refDigest, refDigest]
    try observe()
    try store.connection.run("CREATE TABLE invented_all_fields_writer(value INTEGER)")
    let writer = try SQLiteConnection(url: root.appendingPathComponent("invented.sqlite"), scope: .directory(root), busyMilliseconds: 0)
    let state = GitWriterProbeState(), ready = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
    let baseline = inventedSelfRSS()
    var peak = baseline
    var longestProbe = 0.0, longestProbeGap = 0.0
    // Utility timer coalescing can miss short writer admission intervals.
    DispatchQueue.global(qos: .userInitiated).async {
      var busySince: Double?, first = true, previousEnd = ProcessInfo.processInfo.systemUptime
      while !state.shouldStop() {
        peak = max(peak, inventedSelfRSS())
        let time = ProcessInfo.processInfo.systemUptime
        longestProbeGap = max(longestProbeGap, time - previousEnd)
        do {
          try writer.run("INSERT INTO invented_all_fields_writer VALUES(1)"); state.successful += 1
          if let start = busySince { state.longest = max(state.longest, time - start); busySince = nil }
        } catch StorageError.busy {
          state.busy += 1; if busySince == nil { busySince = time }
        } catch { state.failure = error; break }
        previousEnd = ProcessInfo.processInfo.systemUptime
        longestProbe = max(longestProbe, previousEnd - time)
        if first { ready.signal(); first = false }
        Thread.sleep(forTimeInterval: 0.005)
      }
      if first { ready.signal() }
      if let start = busySince { state.longest = max(state.longest, ProcessInfo.processInfo.systemUptime - start) }
      done.signal()
    }
    ready.wait()
    let start = ProcessInfo.processInfo.systemUptime
    do { try scan() } catch { state.stop(); done.wait(); throw error }
    state.stop(); done.wait()
    let elapsed = ProcessInfo.processInfo.systemUptime - start
    XCTAssertNil(state.failure)
    XCTAssertGreaterThan(state.successful, 0)
    XCTAssertLessThan(state.longest, 0.25)
    XCTAssertEqual(try count("git_commits", "complete=1"), 1)
    XCTAssertEqual(try count("git_files"), 1)
    XCTAssertEqual(try count("git_refs", "frontier=(SELECT frontier FROM git_repositories)"), 3)
    let queries = (0...2).map { "SELECT ordinal,payload FROM git_commit_text WHERE field=\($0) ORDER BY ordinal" } + [
      "SELECT ordinal,payload FROM git_value_text WHERE kind=1 AND field=1 ORDER BY ordinal",
      "SELECT ordinal,payload FROM git_value_text WHERE kind=2 ORDER BY ordinal",
      "SELECT ordinal,payload FROM git_value_text WHERE kind=3 ORDER BY ordinal",
    ]
    for (index, query) in queries.enumerated() {
      var digest = SHA256(), size = 0, ordinal = 0
      try store.connection.rows(query) { row in
        try autoreleasepool {
          XCTAssertEqual(SQLiteConnection.int(row, 0), ordinal); ordinal += 1
          let bytes = try XCTUnwrap(sqlite3_column_blob(row, 1))
          let count = Int(sqlite3_column_bytes(row, 1))
          XCTAssertLessThanOrEqual(count, 65536)
          digest.update(data: Data(bytes: bytes, count: count)); size += count
        }
      }
      XCTAssertEqual(size, (mebibytes << 20) + (index == 2 ? 1 : index >= 4 ? 11 : 0))
      XCTAssertEqual(Data(digest.finalize()), expected[index], "Complete ordered field \(index)")
    }
    XCTAssertGreaterThan(baseline, 0)
    XCTAssertLessThan(peak - baseline, 32 << 20)
    print("invented all-fields MiB=\(mebibytes) baseline_self_rss_bytes=\(baseline) peak_self_rss_bytes=\(peak) growth_bytes=\(peak - baseline) scan_seconds=\(elapsed) all_field_digests=6 successful_writes=\(state.successful) busy_attempts=\(state.busy) longest_busy_seconds=\(state.longest) longest_probe_seconds=\(longestProbe) longest_probe_gap_seconds=\(longestProbeGap)")
  }

  func testProductionAllFields1MiB() throws { try allFieldsInIndependentProcess(mebibytes: 1) }
  func testProductionAllFields8MiB() throws { try allFieldsInIndependentProcess(mebibytes: 8) }
  func testProductionAllFields32MiB() throws { try allFieldsInIndependentProcess(mebibytes: 32) }
  func testProductionAllFields128MiB() throws { try allFieldsInIndependentProcess(mebibytes: 128) }
  func testProductionAllFields128MiBWithUnrelatedOwnReceipt() throws {
    try allFieldsInIndependentProcess(mebibytes: 128, ownRegistry: true)
  }
}
