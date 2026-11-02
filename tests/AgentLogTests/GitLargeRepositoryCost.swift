import Darwin
import Foundation
import XCTest

/// CPU per history run on an invented large repository, measured only with
/// ACTIVITYPROBE_GIT_RUN_COST=1. It uses nothing but `scan` and Git, so the same file builds
/// and measures on a commit without the unchanged-read skip.
///
/// The fixture comes from `git fast-import`: one branch of ACTIVITYPROBE_GIT_RUN_COMMITS
/// commits (60,000) and ACTIVITYPROBE_GIT_RUN_REFS refs (11,000) spread over them, all packed
/// but the last 1,000. All but the last 20 commits are older than retention, so the first
/// read finishes in minutes rather than reading 60,000 commits one Git child at a time. With
/// ACTIVITYPROBE_GIT_RUN_ROOT the fixture is built once there and copied for each run.
/// ACTIVITYPROBE_GIT_RUN_LOOSE changes how many refs stay loose, the unchanged walk's worst case.
extension GitCollectionTests {
  private static func usage(_ who: Int32) -> Double {
    var usage = rusage()
    getrusage(who, &usage)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
  }
  private func shell(_ script: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", script] + arguments
    process.environment = ["PATH": "/usr/bin:/bin", "HOME": root.path, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]
    process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
    try process.run(); process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0, script)
  }
  private func buildLargeRepository(at folder: URL, commits: Int, refs: Int, loose: Int) throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try git(["init", "-b", "main"], in: folder)
    let stream = root.appendingPathComponent("invented-large-stream")
    FileManager.default.createFile(atPath: stream.path, contents: nil)
    let output = try FileHandle(forWritingTo: stream)
    let old = now - 400 * 86400
    for index in 0..<commits {
      let time = index >= commits - 20 ? now - 20 * 3600 + index - commits : old + index
      let message = "Invented change \(index)", content = "Invented content \(index)\n"
      try output.write(contentsOf: Data(("commit refs/heads/main\nmark :\(index + 1)\ncommitter Invented <invented@example.test> \(time) +0000\n"
        + "data \(message.utf8.count)\n\(message)\nM 100644 inline invented-\(index % 100).txt\ndata \(content.utf8.count)\n\(content)\n").utf8))
    }
    let packed = max(0, refs - loose)
    func name(_ index: Int) -> String { String(format: "refs/remotes/origin/invented-topic-%02d/invented-branch-%05d", index % 40, index) }
    for index in 0..<packed {
      try output.write(contentsOf: Data("reset \(name(index))\nfrom :\((index + 1) * commits / max(refs, 1))\n\n".utf8))
    }
    try output.close()
    try shell("/usr/bin/git -C \"$0\" fast-import --quiet < \"$1\"", [folder.path, stream.path])
    try FileManager.default.removeItem(at: stream)
    try git(["pack-refs", "--all"], in: folder)
    let head = try git(["rev-parse", "main"], in: folder)
    let updates = root.appendingPathComponent("invented-large-updates")
    try Data((packed..<refs).map { "create \(name($0)) \(head)\n" }.joined().utf8).write(to: updates)
    try shell("/usr/bin/git -C \"$0\" update-ref --stdin < \"$1\"", [folder.path, updates.path])
    try FileManager.default.removeItem(at: updates)
  }

  func testLargeRepositoryRunCost() throws {
    let environment = ProcessInfo.processInfo.environment
    try XCTSkipUnless(environment["ACTIVITYPROBE_GIT_RUN_COST"] == "1")
    let commits = environment["ACTIVITYPROBE_GIT_RUN_COMMITS"].flatMap(Int.init) ?? 60_000
    let refs = environment["ACTIVITYPROBE_GIT_RUN_REFS"].flatMap(Int.init) ?? 11_000
    let home = environment["ACTIVITYPROBE_GIT_RUN_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? root!
    let loose = environment["ACTIVITYPROBE_GIT_RUN_LOOSE"].flatMap(Int.init) ?? 1000
    let pristine = home.appendingPathComponent("invented-large-\(commits)-\(refs)-\(loose)")
    if !FileManager.default.fileExists(atPath: pristine.path) {
      let began = ProcessInfo.processInfo.systemUptime
      try buildLargeRepository(at: pristine, commits: commits, refs: refs, loose: loose)
      print("RUN-COST fixture built wall=\(ProcessInfo.processInfo.systemUptime - began)")
    }
    let large = root.appendingPathComponent("invented-large")
    try shell("/bin/cp -Rp \"$0\" \"$1\"", [pristine.path, large.path])
    try observe(large)
    func measure(_ label: String, at time: Int) throws {
      let selfBefore = Self.usage(RUSAGE_SELF), childBefore = Self.usage(RUSAGE_CHILDREN), began = ProcessInfo.processInfo.systemUptime
      try scan(time)
      let own = Self.usage(RUSAGE_SELF) - selfBefore, children = Self.usage(RUSAGE_CHILDREN) - childBefore
      print(String(format: "RUN-COST %@ selfCPU=%.3f childCPU=%.3f wall=%.3f commits=%d refs=%d", label, own, children,
        ProcessInfo.processInfo.systemUptime - began, try count("git_commits", "complete=1"), try count("git_refs")))
    }
    func newCommit(_ index: Int, at time: Int) throws {
      let tree = try git(["rev-parse", "main^{tree}"], in: large), parent = try git(["rev-parse", "main"], in: large)
      let hash = try git(["commit-tree", tree, "-p", parent, "-m", "Invented new \(index)"], in: large, author: time)
      try git(["update-ref", "refs/heads/main", hash], in: large)
    }
    var time = now + 300
    try measure("first-read", at: time)
    for index in 1...4 { time += 300; try measure("no-change-\(index)", at: time) }
    if environment["ACTIVITYPROBE_GIT_RUN_NO_CHANGE_ONLY"] == "1" { return }
    for index in 1...2 {
      try newCommit(index, at: time)
      time += 300; try measure("one-new-commit-\(index)", at: time)
      time += 300; try measure("after-new-commit-\(index)", at: time)
    }
  }
}
