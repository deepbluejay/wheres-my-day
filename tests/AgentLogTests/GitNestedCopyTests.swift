import Core
import Darwin
import Foundation
@testable import Inbound
@testable import Shell
@testable import Storage
import XCTest

extension GitCollectionTests {
  /// An outer repository that ignores .build/, holding an invented dependency clone at
  /// .build/checkouts/invented-pkg with `commits` commits made by fast-import.
  func nestedCopyFixture(commits: Int = 3, rule: String = ".build/\n") throws -> URL {
    try Data(rule.utf8).write(to: repo.appendingPathComponent(".gitignore"))
    try git(["add", ".gitignore"])
    try git(["commit", "-m", "Invented ignore"])
    let nested = repo.appendingPathComponent(".build/checkouts/invented-pkg")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try inventedRepository(nested, commits: commits)
    return nested
  }
  func inventedRepository(_ folder: URL, commits: Int) throws {
    try git(["init", "-b", "main"], in: folder)
    var stream = ""
    for index in 0..<commits {
      let text = "Invented dependency change \(index)"
      stream += "commit refs/heads/main\ncommitter Invented <invented@example.test> \(now - 3600 + index) +0000\n"
      stream += "data \(text.utf8.count)\n\(text)\nM 100644 inline invented.txt\ndata \(text.utf8.count)\n\(text)\n\n"
    }
    let file = root.appendingPathComponent("invented-stream-" + UUID().uuidString)
    try Data(stream.utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", folder.path, "fast-import", "--quiet"]
    process.environment = ["PATH": "/usr/bin:/bin", "HOME": root.path, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]
    process.standardInput = try FileHandle(forReadingFrom: file)
    process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
    try process.run(); process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
    try git(["reset", "--hard", "main"], in: folder)
  }
  /// An invented agent-log event whose record works in `folder`, and its checkpoint.
  func inventedOccurrence(_ folder: URL, tag: String = "invented-log", time: Int? = nil) throws -> (AgentLogEvent, LogPosition) {
    var state = AgentLogState(); state.tool = AgentLogTool.claude.rawValue
    state.session = AgentLogIdentity.decoded(tag).session.subject
    state.project = folder.path; state.cwdObservedAt = time ?? now - 10
    let position = LogPosition(path: root.appendingPathComponent(tag).path, device: 7, inode: 88,
      offset: 10, state: try state.encoded(), seenAt: now)
    let bytes = try JSONSerialization.data(withJSONObject: ["type": "assistant", "cwd": folder.path, "timestamp": time ?? now - 10])
    let event = try XCTUnwrap(AgentLogEventParser.parse(bytes, byteCount: bytes.count, offset: 0, observedAt: now,
      tool: .claude, file: tag, state: &state, logsRelativePath: nil, fingerprint: { _ in tag }))
    return (event, position)
  }

  /// The fixture of the reported bug, measured only with ACTIVITYPROBE_GIT_COPY_CPU=1: one
  /// agent-log event in a file's folder inside the ignored clone, then one whole scan.
  func testNestedCopyFixtureCost() throws {
    let environment = ProcessInfo.processInfo.environment
    try XCTSkipUnless(environment["ACTIVITYPROBE_GIT_COPY_CPU"] == "1")
    let nested = try nestedCopyFixture(commits: environment["ACTIVITYPROBE_GIT_COPY_COMMITS"].flatMap(Int.init) ?? 2000)
    let inside = nested.appendingPathComponent("invented-sources")
    try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
    let (event, position) = try inventedOccurrence(inside)
    let usage = StageUsage()
    task.usage = usage
    func cpu(_ who: Int32) -> Double {
      var value = rusage(); getrusage(who, &value)
      return Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec) + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1_000_000
    }
    let started = Date(), own = cpu(RUSAGE_SELF), children = cpu(RUSAGE_CHILDREN)
    try work { try self.task.observe([event], position: position) }
    try scan()
    let history = usage.roll(at: now).stages["git_history"]
    let line = String(format: "git-copy-fixture repositories=%d commits=%d commit_reads=%d own_cpu_s=%.2f git_children_cpu_s=%.2f wall_s=%.2f history_thread_cpu_ms=%d",
      try count("git_repositories"), try count("git_commits", "complete=1"), task.commitReads, cpu(RUSAGE_SELF) - own, cpu(RUSAGE_CHILDREN) - children,
      Date().timeIntervalSince(started), Int((history?.totalCPUNanoseconds ?? 0) / 1_000_000))
    print(line)
    if let path = environment["ACTIVITYPROBE_GIT_COPY_OUT"] {
      try Data((line + "\n").utf8).write(to: URL(fileURLWithPath: path))
    }
  }

  private func inventedFolder(in base: URL, _ name: String = "invented-sources") throws -> URL {
    let inside = base.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
    return inside
  }
  private func assertNoHistory(_ message: String = "", file: StaticString = #filePath, line: UInt = #line) throws {
    try scan()
    XCTAssertEqual(try count("git_repositories"), 0, message, file: file, line: line)
    XCTAssertEqual(try count("git_commits"), 0, message, file: file, line: line)
    XCTAssertEqual(task.commitReads, 0, message, file: file, line: line)
  }
  private func assertRefused(file: StaticString = #filePath, line: UInt = #line) throws {
    try assertNoHistory(file: file, line: line)
    XCTAssertGreaterThanOrEqual(try count("git_working_folders", "status='\(GitCollectionTask.copyStatus)' AND repo_id IS NULL"), 1, file: file, line: line)
  }
  private func assertCollected(_ commits: Int, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) throws {
    try scan()
    XCTAssertEqual(try count("git_repositories"), 1, message, file: file, line: line)
    XCTAssertEqual(try count("git_commits", "complete=1"), commits, message, file: file, line: line)
    XCTAssertEqual(try count("git_working_folders", "status='\(GitCollectionTask.copyStatus)'"), 0, message, file: file, line: line)
  }
  /// A Claude log with one record in `folder`, stored by the agent-log path without any Git task.
  private func storedOccurrence(_ folder: URL) throws -> LogPosition {
    let logs = root.appendingPathComponent(AgentLogTool.claude.defaultHomeName).appendingPathComponent(AgentLogTool.claude.logsFolder)
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    let log = logs.appendingPathComponent("invented-stored.jsonl")
    let record: [String: Any] = ["type": "assistant", "timestamp": now - 10, "sessionId": "invented-stored", "cwd": folder.path,
      "message": ["role": "assistant", "content": "Invented activity"]]
    try (JSONSerialization.data(withJSONObject: record) + Data([10])).write(to: log)
    let reader = ClaudeAgentLogReader(userHome: root.path, processes: InventedProcesses(), appDataDirectory: root)
    let source = try XCTUnwrap(reader.files().first { $0.path == log.path })
    let batch = try reader.read(source, position: nil, at: now)
    try store.appendLogEvents(batch.events, evidence: batch.evidence, position: batch.position)
    return batch.position
  }

  // Every way a repository can enter. All of them end in observeAllowed, the only caller of
  // rememberGitFolder with a location; the front window registers no working folder.
  func testCopyRefusedWhenObservedDirectly() throws {
    try observe(try inventedFolder(in: try nestedCopyFixture()))
    try assertRefused()
  }
  func testCopyRefusedFromALiveAgentLogBatch() throws {
    let (event, position) = try inventedOccurrence(try inventedFolder(in: try nestedCopyFixture()))
    try work { try self.task.observe([event], position: position) }
    try assertRefused()
  }
  func testCopyRefusedFromAHandOff() throws {
    let (event, position) = try inventedOccurrence(try inventedFolder(in: try nestedCopyFixture()))
    task.handOff([event], position: position) { _ in XCTFail("deferred") }
    task.waitForBackfill()
    XCTAssertGreaterThan(task.backfillOffers, 0)
    try assertRefused()
  }
  func testCopyRefusedFromSourceRecovery() throws {
    let position = try storedOccurrence(try inventedFolder(in: try nestedCopyFixture()))
    task.requestRecovery(position)
    task.waitForBackfill()
    XCTAssertGreaterThan(task.backfillOffers, 0)
    try assertRefused()
  }
  func testCopyRefusedFromTheStoredEventBackfill() throws {
    _ = try storedOccurrence(try inventedFolder(in: try nestedCopyFixture()))
    task.backfill(at: now + 300)
    task.waitForBackfill()
    XCTAssertGreaterThan(task.backfillRows, 0)
    XCTAssertGreaterThan(task.backfillOffers, 0)
    try assertRefused()
  }
  func testCopyRefusedFromTheCheckpointBackfill() throws {
    _ = try storedOccurrence(try inventedFolder(in: try nestedCopyFixture()))
    try store.connection.run("DELETE FROM agent_log_events")
    task.backfill(at: now + 300)
    task.waitForBackfill()
    XCTAssertEqual(task.backfillRows, 0)
    XCTAssertGreaterThan(task.checkpointRows, 0)
    XCTAssertGreaterThan(task.backfillOffers, 0)
    try assertRefused()
  }
  func testCopyRefusedWhenDiscoveryRevisitsAnUnlinkedFolder() throws {
    let nested = try nestedCopyFixture()
    let later = nested.appendingPathComponent("invented-later")
    try observe(later)
    XCTAssertEqual(try count("git_working_folders", "status='missing'"), 1)
    try FileManager.default.createDirectory(at: later, withIntermediateDirectories: true)
    try scan(now + 300)
    try assertRefused()
  }
  func testCopyRefusedAgainAfterForgetTombstones() throws {
    let inside = try inventedFolder(in: try nestedCopyFixture())
    try observe(inside, time: now - 100)
    let preview = try store.previewDeletion(in: TimeRange(now - 101, now - 99))
    try work { try self.store.deleteRecords(in: preview.range, confirmation: preview.confirmation) }
    XCTAssertEqual(try count("git_working_folders"), 0)
    XCTAssertGreaterThan(try count("git_discovery_tombstones"), 0)
    // A later occurrence is a new discovery, which the tombstone does not cover.
    try observe(inside, time: now - 10)
    try assertNoHistory()
    // In the next process it costs a resolve again, and is refused the same.
    task = GitCollectionTask(storage: store, secureInput: { false }, scratchDirectory: root)
    try observe(inside, time: now - 5)
    try assertRefused()
  }

  // What decides is the enclosing repository's rule, wherever it lives, not a folder's name.
  func testIgnoreRuleDecidesNotTheFolderName() throws {
    // The same place, not ignored.
    let unignored = repo.appendingPathComponent(".build/checkouts/invented-pkg")
    try FileManager.default.createDirectory(at: unignored, withIntermediateDirectories: true)
    try inventedRepository(unignored, commits: 2)
    try observe(unignored)
    try assertCollected(2)
  }
  func testOtherNamesAndRuleKindsAreRefused() throws {
    // A name with a space and a leading colon, ignored through .git/info/exclude.
    try Data("invented vendor*/\n".utf8).write(to: repo.appendingPathComponent(".git/info/exclude"))
    let odd = repo.appendingPathComponent("invented vendor one/:invented pkg")
    try FileManager.default.createDirectory(at: odd, withIntermediateDirectories: true)
    try inventedRepository(odd, commits: 2)
    try observe(odd)
    try assertRefused()
  }
  func testNegatedRuleKeepsTheRepository() throws {
    try Data("invented-parent/*\n!invented-parent/invented-kept\n".utf8).write(to: repo.appendingPathComponent(".gitignore"))
    let kept = repo.appendingPathComponent("invented-parent/invented-kept")
    try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
    try inventedRepository(kept, commits: 1)
    try observe(kept)
    try assertCollected(1)
  }
  /// A clone's submodule is tracked by the clone, and still lies inside what the outer ignores.
  func testRepositoryInsideACopyIsACopy() throws {
    let nested = try nestedCopyFixture()
    let inner = nested.appendingPathComponent("invented-inner")
    try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
    try inventedRepository(inner, commits: 2)
    try observe(inner)
    try assertRefused()
  }

  // The owner's repositories are still collected.
  func testPlainRepositoryInANonRepositoryFolderStartsNoCheck() throws {
    try commit()
    var checks = 0
    task.reader.beforeIgnoreCheck = { checks += 1 }
    // Git passes over an empty .git folder, so nothing encloses the repository here either.
    try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
    try observe()
    try assertCollected(1)
    XCTAssertEqual(checks, 0)
  }
  func testWorktreeOutsideTheRepositoryIsCollected() throws {
    try commit()
    let tree = root.appendingPathComponent("invented-tree")
    try git(["worktree", "add", "-b", "invented-work", tree.path])
    try observe(tree)
    try assertCollected(1)
  }
  /// Worktrees often sit in an ignored folder of their own repository. That is no other repository.
  func testWorktreeInsideItsOwnIgnoredFolderIsCollected() throws {
    try Data(".invented-trees/\n".utf8).write(to: repo.appendingPathComponent(".gitignore"))
    try commit()
    let tree = repo.appendingPathComponent(".invented-trees/one")
    try git(["worktree", "add", "-b", "invented-work", tree.path])
    try observe(tree)
    try assertCollected(1)
    XCTAssertEqual(try count("git_working_folders", "repo_id IS NOT NULL"), 1)
  }
  /// A copy inside a linked worktree is judged by the worktree's own rules.
  func testCopyInsideALinkedWorktreeIsRefused() throws {
    try Data(".build/\n".utf8).write(to: repo.appendingPathComponent(".gitignore"))
    try git(["add", ".gitignore"])
    try commit()
    let tree = root.appendingPathComponent("invented-tree")
    try git(["worktree", "add", "-b", "invented-work", tree.path])
    let nested = tree.appendingPathComponent(".build/checkouts/invented-pkg")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try inventedRepository(nested, commits: 2)
    try observe(nested)
    try assertRefused()
  }
  /// The bare-plus-worktrees layout: a repository is above the worktree, a working tree is not.
  func testWorktreeInsideABareRepositoryIsCollected() throws {
    try commit()
    let bare = root.appendingPathComponent("invented-bare.git")
    try git(["clone", "--bare", repo.path, bare.path])
    let tree = bare.appendingPathComponent("invented-tree")
    try git(["worktree", "add", tree.path, "main"], in: bare)
    try observe(tree)
    try assertCollected(1)
  }
  /// Tracked by the enclosing repository, and so not ignored, even under a matching rule.
  func testTrackedSubmodulesAreCollected() throws {
    let source = root.appendingPathComponent("invented-source")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try inventedRepository(source, commits: 2)
    try commit()
    try Data("invented-matching/\n".utf8).write(to: repo.appendingPathComponent(".gitignore"))
    try git(["add", ".gitignore"])
    for path in ["invented-vendor/sub", "invented-matching/sub"] {
      try git(["-c", "protocol.file.allow=always", "submodule", "add", "-f", source.path, path])
    }
    try git(["commit", "-m", "Invented submodules"])
    for path in ["invented-vendor/sub", "invented-matching/sub"] {
      try observe(repo.appendingPathComponent(path))
    }
    try scan()
    XCTAssertEqual(try count("git_repositories"), 2)
    XCTAssertEqual(try count("git_working_folders", "repo_id IS NOT NULL"), 2)
    XCTAssertEqual(try count("git_working_folders", "status='\(GitCollectionTask.copyStatus)'"), 0)
    XCTAssertEqual(try count("git_commits", "complete=1"), 4)
  }
  /// An untracked repository that is not ignored stays what it was.
  func testUntrackedRepositoryThatIsNotIgnoredIsCollected() throws {
    try commit()
    let nested = repo.appendingPathComponent("invented-nested")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try inventedRepository(nested, commits: 2)
    try observe(nested)
    try assertCollected(2)
  }

  // A repository admitted earlier.
  func testAdmittedCopyStopsAtTheNextProcess() throws {
    let nested = repo.appendingPathComponent(".build/checkouts/invented-pkg")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try inventedRepository(nested, commits: 3)
    try observe(nested)
    XCTAssertEqual(try count("git_repositories"), 1)
    try Data(".build/\n".utf8).write(to: repo.appendingPathComponent(".gitignore"))
    task = GitCollectionTask(storage: store, secureInput: { false }, scratchDirectory: root)
    try scan()
    XCTAssertEqual(task.commitReads, 0)
    XCTAssertEqual(try count("git_commits"), 0)
    XCTAssertEqual(try count("git_refs"), 0)
    // Every further unit is refused at the gate, not only by the loop.
    let id = try XCTUnwrap(try store.nextGitRepository(after: 0)).id
    XCTAssertNil(try store.gitPreparationGeneration(repo: id, now: now))
    let attempts = try store.locked { self.store.gitPublishCalls }
    try work { try self.task.observe(GitWorkingFolder(folder: nested.path, session: "invented-session", source: "invented-source",
      device: 7, inode: 8, time: self.now - 5, tool: .claude), now: self.now) }
    XCTAssertGreaterThan(try store.locked { self.store.gitPublishCalls }, attempts)
    XCTAssertEqual(try count("git_working_folders", "last_seen=\(now - 5)"), 0)
  }
  func testRunningReadOfACopyStopsAtTheNextCancellationPoint() throws {
    let nested = repo.appendingPathComponent(".build/checkouts/invented-pkg")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try inventedRepository(nested, commits: 40)
    try observe(nested)
    var started = 0
    let later = now + GitCopyCheck.lifetime
    let other = try inventedFolder(in: nested)
    task.afterCommitStarted = { [unowned self] _ in
      started += 1
      guard started == 3 else { return }
      // Discovery sees the new rule on another thread, while this read is inside a commit.
      try Data(".build/\n".utf8).write(to: self.repo.appendingPathComponent(".gitignore"))
      try self.work { try self.task.observe(GitWorkingFolder(folder: other.path, session: "invented-session", source: "invented-source",
        device: 7, inode: 8, time: self.now - 5, tool: .claude), now: later) }
    }
    try scan()
    XCTAssertEqual(started, 3)
    XCTAssertEqual(task.commitReads, 3)
    XCTAssertEqual(try count("git_commits", "complete=1"), 2)
    XCTAssertEqual(try count("git_commits", "complete!=1"), 0)
    // Nothing certifies the interrupted read, and a later pass reads no more of it.
    XCTAssertEqual(try count("git_refs"), 0)
    try scan()
    XCTAssertEqual(task.commitReads, 3)
  }

  /// A stored working tree that was masked names nothing on disk, so nothing judges the
  /// repository until a raw folder of it is observed. That observation decides at once.
  func testRefusedFolderStopsARepositoryWhoseStoredPathIsMasked() throws {
    let nested = try nestedCopyFixture(rule: "invented-nothing/\n")
    try observe(nested)
    try store.connection.run("UPDATE git_working_folders SET top_level='[invented-masked]'")
    try Data(".build/\n".utf8).write(to: repo.appendingPathComponent(".gitignore"))
    task = GitCollectionTask(storage: store, secureInput: { false }, scratchDirectory: root)
    try scan()
    XCTAssertEqual(task.commitReads, 3)
    try commit("Invented later change", file: "later.txt", in: nested)
    try observe(try inventedFolder(in: nested))
    XCTAssertEqual(try count("git_working_folders", "status='\(GitCollectionTask.copyStatus)'"), 1)
    try scan()
    XCTAssertEqual(task.commitReads, 3)
    XCTAssertEqual(try count("git_commits", "complete=1"), 3)
  }

  // Failure refuses for now and retries later.
  func testFailedIgnoreCheckRefusesThenRetries() throws {
    let nested = repo.appendingPathComponent("invented-nested")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try inventedRepository(nested, commits: 2)
    try commit()
    let index = repo.appendingPathComponent(".git/index"), good = try Data(contentsOf: index)
    try Data("invented broken index".utf8).write(to: index)
    var checks = 0
    task.reader.beforeIgnoreCheck = { checks += 1 }
    try observe(nested)
    try assertNoHistory()
    XCTAssertEqual(try count("git_working_folders", "status='failed' AND repo_id IS NULL"), 1)
    XCTAssertEqual(checks, 1)
    // The usual backoff: no second check before five minutes.
    try scan(now + 60)
    XCTAssertEqual(checks, 1)
    XCTAssertEqual(try count("git_repositories"), 0)
    try scan(now + 301)
    XCTAssertEqual(checks, 2)
    XCTAssertEqual(try count("git_repositories"), 0)
    try good.write(to: index)
    try scan(now + 301 + 600)
    XCTAssertEqual(checks, 3)
    XCTAssertEqual(try count("git_repositories"), 1)
    XCTAssertEqual(try count("git_commits", "complete=1"), 2)
  }
  func testFailedIgnoreCheckStopsAnAdmittedRepositoryUntilItsRetry() throws {
    let nested = repo.appendingPathComponent("invented-nested")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try inventedRepository(nested, commits: 2)
    try commit()
    try observe(nested)
    let index = repo.appendingPathComponent(".git/index"), good = try Data(contentsOf: index)
    try Data("invented broken index".utf8).write(to: index)
    task = GitCollectionTask(storage: store, secureInput: { false }, scratchDirectory: root)
    try scan()
    XCTAssertEqual(task.commitReads, 0)
    try good.write(to: index)
    try scan(now + 60)
    XCTAssertEqual(task.commitReads, 0)
    try scan(now + 301)
    XCTAssertEqual(task.commitReads, 2)
    XCTAssertEqual(try count("git_commits", "complete=1"), 2)
  }

  // Bounded cost.
  func testRefusalCostsOneCheckNotOnePerTick() throws {
    let nested = try nestedCopyFixture()
    let inside = try inventedFolder(in: nested)
    var checks = 0, prepared = 0
    task.reader.beforeIgnoreCheck = { checks += 1 }
    task.beforeLocationPrepared = { _ in prepared += 1 }
    for tick in 0..<5 {
      try observe(inside, time: now - 10 + tick, scan: now + tick * 300)
      try scan(now + tick * 300 + 1)
    }
    XCTAssertEqual(checks, 1)
    XCTAssertEqual(prepared, 1)
    XCTAssertGreaterThan(task.discoverySkips, 0)
    // Another folder of the same copy resolves once and reuses the answer.
    try observe(try inventedFolder(in: nested, "invented-other"), scan: now + 1500)
    XCTAssertEqual(checks, 1)
    XCTAssertEqual(prepared, 2)
    try assertNoHistory()
    // The answer has a lifetime, so a changed rule counts without a restart.
    try Data("invented-nothing/\n".utf8).write(to: repo.appendingPathComponent(".gitignore"))
    try observe(inside, time: now - 5, scan: now + GitCopyCheck.lifetime + 1)
    XCTAssertEqual(checks, 2)
    XCTAssertEqual(try count("git_repositories"), 1)
  }

  // A run longer than a tick shows in `status` while it runs.
  func testHistoryProgressShowsDuringALongRun() throws {
    let usage = StageUsage()
    let nested = root.appendingPathComponent("invented-plain")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try inventedRepository(nested, commits: 6)
    task = GitCollectionTask(storage: store, sliceDuration: 0, secureInput: { false }, scratchDirectory: root)
    task.usage = usage
    try observe(nested)
    var seen = 0, status = ""
    task.afterCommitStarted = { [unowned self] _ in
      seen += 1
      guard seen == 4 else { return }
      // The tick publishes while the Git queue is still inside this one run.
      try self.store.saveStageUsage(usage.roll(at: self.now))
      status = self.store.stageUsageStatus()
    }
    try scan()
    XCTAssertTrue(status.contains("stage_git_history_running_commits=3"), status)
    XCTAssertTrue(status.contains("stage_git_history_running_cpu_ms="), status)
    XCTAssertTrue(status.contains("stage_git_history_last_runs=0"), status)
    XCTAssertTrue(status.contains("stage_git_history_total_runs=0"), status)
    let stage = try XCTUnwrap(usage.roll(at: now + 1).stages["git_history"])
    XCTAssertNil(stage.running)
    XCTAssertEqual(stage.last["commits"], 6); XCTAssertEqual(stage.total["commits"], 6); XCTAssertEqual(stage.totalRuns, 1)
  }
  func testBackfillProgressShowsDuringAPass() throws {
    let usage = StageUsage()
    task.usage = usage
    _ = try storedOccurrence(repo)
    try commit()
    var running: StageUsage.Running?, pages = 0
    task.beforeBackfillPage = {
      pages += 1
      if pages == 2 { running = usage.roll(at: self.now).stages["git_backfill"]?.running }
    }
    task.backfill(at: now + 300)
    task.waitForBackfill()
    XCTAssertEqual(running?.items["rows"], 1)
    XCTAssertGreaterThan(running?.items["offers"] ?? 0, 0)
    XCTAssertNil(usage.roll(at: now + 1).stages["git_backfill"]?.running)
  }
  func testDiscoveryProgressShowsDuringAPass() throws {
    let usage = StageUsage()
    task.usage = usage
    let later = [root.appendingPathComponent("invented-a"), root.appendingPathComponent("invented-b")]
    for (index, folder) in later.enumerated() { try observe(folder, source: "invented-source-\(index)") }
    for folder in later {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try git(["init", "-b", "main"], in: folder)
    }
    var running: [StageUsage.Running?] = []
    task.beforeLocationPrepared = { _ in running.append(usage.roll(at: self.now).stages["git_discovery"]?.running) }
    try work { try self.task.scan(at: self.now + 300) }
    XCTAssertEqual(running.count, 2)
    XCTAssertEqual(running.last??.items["visited"], 1)
    XCTAssertNil(usage.roll(at: now + 1).stages["git_discovery"]?.running)
  }
}
