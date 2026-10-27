import Core
import Foundation
import SQLite3
@testable import Inbound
@testable import Shell
@testable import Storage
import XCTest

final class GitCollectionTests: XCTestCase {
  var root: URL!
  var repo: URL!
  var store: ActivityStorage!
  var task: GitCollectionTask!
  let now = 1_780_000_000
  override func setUpWithError() throws {
    let scratch = ProcessInfo.processInfo.environment["ACTIVITYPROBE_TEST_ROOT"]
      .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
    root = scratch.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    repo = root.appendingPathComponent("invented-repo")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    _ = try git(["init", "-b", "main"])
    store = try ActivityStorage(url: root.appendingPathComponent("invented.sqlite"), appDataDirectory: root,
      databaseScope: .directory(root))
    try store.saveSettings(StorageSettings(), at: 0)
    task = GitCollectionTask(storage: store, secureInput: { false }, scratchDirectory: root)
  }
  override func tearDownWithError() throws {
    task = nil; store = nil
    try FileManager.default.removeItem(at: root)
  }
  @discardableResult func git(_ args: [String], in folder: URL? = nil, author: Int? = nil, commit: Int? = nil,
    name: String = "Invented Author", email: String = "invented@example.test") throws -> String {
    let p = Process(), out = Pipe()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    p.arguments = ["-C", (folder ?? repo).path] + args
    p.environment = ["PATH": "/usr/bin:/bin", "HOME": root.path, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
      "GIT_AUTHOR_NAME": name, "GIT_AUTHOR_EMAIL": email, "GIT_COMMITTER_NAME": name, "GIT_COMMITTER_EMAIL": email,
      "GIT_AUTHOR_DATE": "@\(author ?? now - 60) +0000", "GIT_COMMITTER_DATE": "@\(commit ?? author ?? now - 60) +0000"]
    p.standardOutput = out; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
    try p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { throw GitReadError.failed }
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
  }
  @discardableResult func commit(_ text: String = "Invented change", file: String = "invented.txt",
    author: Int? = nil, time: Int? = nil, in folder: URL? = nil) throws -> String {
    let base = folder ?? repo!
    let fileURL = base.appendingPathComponent(file)
    try Data(text.utf8).write(to: fileURL)
    try git(["add", "--", file], in: base)
    try git(["commit", "-m", text], in: base, author: author, commit: time)
    return try git(["rev-parse", "HEAD"], in: base)
  }
  func work<T>(_ body: @escaping () throws -> T) throws -> T {
    let done = DispatchSemaphore(value: 0)
    var result: Result<T, Error>!
    DispatchQueue.global(qos: .utility).async { result = Result(catching: body); done.signal() }
    done.wait()
    return try result.get()
  }
  func observe(_ folder: URL? = nil, source: String = "invented-source", time: Int? = nil, scan: Int? = nil) throws {
    let observation = GitWorkingFolder(folder: (folder ?? repo).path, session: "invented-session", source: source,
      device: 7, inode: source == "invented-source" ? 8 : 9, time: time ?? now - 10, tool: .claude)
    try work { try self.task.observe(observation, now: scan ?? self.now) }
  }
  func scan(_ time: Int? = nil) throws { try work { try self.task.scan(at: time ?? self.now) } }
  func count(_ table: String, _ predicate: String = "1") throws -> Int {
    try store.locked { try self.store.connection.integer("SELECT count(*) FROM \(table) WHERE \(predicate)") }
  }
  func testDurableWorktreeLinkSurvivesFolderDeletionAndReopen() throws {
    try commit()
    let tree = root.appendingPathComponent("invented-worktree")
    try git(["worktree", "add", "-b", "invented-work", tree.path])
    try observe(tree)
    var common = "", top = "", branch = "", head = ""
    try store.connection.namedRows("SELECT common_dir,top_level,branch,head FROM git_repositories r JOIN git_working_folders f ON f.repo_id=r.id") {
      common = try $0.text("common_dir"); top = try $0.text("top_level"); branch = try $0.text("branch"); head = try $0.text("head")
    }
    XCTAssertEqual(common, try CanonicalPath.resolve(repo.appendingPathComponent(".git")).path)
    XCTAssertEqual(top, try CanonicalPath.resolve(tree).path)
    XCTAssertEqual(branch, "invented-work")
    XCTAssertTrue(GitRepositoryReader.validHash(head))
    try FileManager.default.removeItem(at: tree)
    task = nil; store = nil
    store = try ActivityStorage(url: root.appendingPathComponent("invented.sqlite"), appDataDirectory: root, databaseScope: .directory(root))
    task = GitCollectionTask(storage: store, secureInput: { false }, scratchDirectory: root)
    try scan()
    XCTAssertEqual(try count("git_working_folders", "status='missing' AND repo_id IS NOT NULL"), 1)
    XCTAssertEqual(try count("git_commits", "complete=1"), 1)
  }
  func testBranchesRenamesMergesBinaryAndIncrementalDeduplication() throws {
    let initial = try commit("Invented base")
    try git(["checkout", "-b", "side"])
    let side = try commit("Invented side", file: "side.txt")
    try git(["checkout", "main"])
    try git(["mv", "invented.txt", "renamed\tfile\n.txt"])
    try git(["commit", "-m", "Invented rename"])
    try Data([0, 1, 2]).write(to: repo.appendingPathComponent("binary.dat"))
    try git(["add", "binary.dat"])
    try git(["commit", "-m", "Invented binary"])
    try git(["merge", "--no-ff", "-m", "Invented merge", "side"])
    try git(["tag", "-a", "invented-tag", "-m", "Invented tag", initial])
    try observe(); try scan()
    XCTAssertEqual(try count("git_commits", "complete=1"), 5)
    XCTAssertEqual(try count("git_files", "old_path='invented.txt' AND path LIKE 'renamed%' AND added=0 AND deleted=0"), 1)
    XCTAssertEqual(try count("git_files", "path='binary.dat' AND added IS NULL AND deleted IS NULL"), 1)
    XCTAssertEqual(try count("git_commit_refs", "name='refs/heads/side'"), 2)
    XCTAssertEqual(try count("git_commit_refs", "name='refs/tags/invented-tag'"), 1)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM git_files WHERE commit_id=(SELECT id FROM git_commits WHERE message LIKE 'Invented merge%')"), 1)
    try scan(now + 300)
    XCTAssertEqual(try count("git_commits"), 5)
    try git(["reset", "--hard", initial])
    let fresh = try commit("Invented rewritten branch", file: "fresh.txt", author: now + 250)
    try scan(now + 600)
    XCTAssertEqual(try count("git_commits"), 6)
    XCTAssertEqual(try count("git_commits", "hash='\(side)' OR hash='\(fresh)'"), 2)
  }
  func testHistoricalOffAndPauseCheckBothTimesAndCurrentOffSkipsGit() throws {
    try store.saveSettings(StorageSettings(recordingEnabled: false), at: now - 500)
    try store.saveSettings(StorageSettings(), at: now - 400)
    try store.saveSettings(StorageSettings(pausedUntil: now - 200), at: now - 300)
    try store.saveSettings(StorageSettings(), at: now - 100)
    try commit("Invented author off", author: now - 450, time: now - 90)
    try commit("Invented commit off", file: "second", author: now - 90, time: now - 450)
    try commit("Invented author paused", file: "third", author: now - 250, time: now - 90)
    try commit("Invented commit paused", file: "fourth", author: now - 90, time: now - 250)
    try commit("Invented allowed", file: "fifth", author: now - 90)
    try observe(); try scan()
    XCTAssertEqual(try count("git_commits"), 1)
    XCTAssertEqual(try count("git_tombstones"), 4)
    let reads = try store.connection.integer("SELECT last_read FROM git_repositories")
    try store.saveSettings(StorageSettings(recordingEnabled: false), at: now + 1)
    try scan(now + 300)
    XCTAssertEqual(try store.connection.integer("SELECT last_read FROM git_repositories"), reads)
    try store.saveSettings(StorageSettings(pausedUntil: now + 1000), at: now + 301)
    try scan(now + 600)
    XCTAssertEqual(try store.connection.integer("SELECT last_read FROM git_repositories"), reads)
  }
  func testRetentionUsesBothTimesAndTraversesSkewedAncestors() throws {
    try store.saveSettings(StorageSettings(promptRetentionDays: 1), at: 0)
    try commit("Invented old root", author: now - 200000)
    try commit("Invented old author", file: "second", author: now - 200000, time: now - 100)
    try commit("Invented recent ancestor", file: "third", author: now - 90)
    try commit("Invented skewed child", file: "fourth", author: now - 200000)
    try observe(); try scan()
    XCTAssertEqual(try count("git_commits"), 1)
    XCTAssertEqual(try count("git_commits", "message LIKE 'Invented recent ancestor%'"), 1)
    try store.cleanRetention(at: now + 90000)
    for table in ["git_repositories", "git_working_folders", "git_refs", "git_commits", "git_commit_refs", "git_files"] {
      XCTAssertEqual(try count(table), 0, table)
    }
  }
  func testForgetAuthorTimeTombstonesAndFreshPreviewIncludesFilesAndRefs() throws {
    let forgotten = try commit("Invented forgotten", author: now - 1000, time: now - 60)
    try observe(); try scan()
    let range = TimeRange(now - 1001, now - 999)
    let preview = try store.previewDeletion(in: range)
    XCTAssertEqual(preview.counts["git_commits"], 1)
    XCTAssertEqual(preview.counts["git_files"], 1)
    try store.connection.run("UPDATE git_files SET added=99")
    XCTAssertThrowsError(try store.deleteRecords(in: range, confirmation: preview.confirmation))
    let second = try store.previewDeletion(in: range)
    try store.connection.run("UPDATE git_commit_refs SET name=name||'/invented-changed'")
    XCTAssertThrowsError(try store.deleteRecords(in: range, confirmation: second.confirmation))
    let fresh = try store.previewDeletion(in: range)
    try store.deleteRecords(in: range, confirmation: fresh.confirmation)
    XCTAssertEqual(try count("git_commits"), 0)
    XCTAssertEqual(try count("git_files"), 0)
    XCTAssertEqual(try count("git_tombstones", "hash='\(forgotten)'"), 1)
    try store.connection.run("DELETE FROM git_refs")
    try scan(now + 300)
    XCTAssertEqual(try count("git_commits"), 0)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM pragma_table_info('git_tombstones')"), 1)
  }
  func testForgetRepositoryLinkDeletesAllDependentsWithFreshness() throws {
    try commit()
    try observe(time: now - 10); try scan()
    let range = TimeRange(now - 11, now - 9)
    let preview = try store.previewDeletion(in: range)
    XCTAssertEqual(preview.counts["git_repositories"], 1)
    XCTAssertEqual(preview.counts["git_commits"], 1)
    try store.connection.run("UPDATE git_refs SET name='refs/heads/invented-changed'")
    XCTAssertThrowsError(try store.deleteRecords(in: range, confirmation: preview.confirmation))
    let fresh = try store.previewDeletion(in: range)
    try store.deleteRecords(in: range, confirmation: fresh.confirmation)
    for table in ["git_repositories", "git_working_folders", "git_refs", "git_commits", "git_commit_refs", "git_files"] {
      XCTAssertEqual(try count(table), 0, table)
    }
    try observe(time: now - 10, scan: now + 300)
    XCTAssertEqual(try count("git_repositories"), 0)
  }
  func testOwnOnlyDoesNotRegisterSharedHumanRepoSurvivesLateOwnRevocation() throws {
    try commit()
    let observation = GitWorkingFolder(folder: repo.path, session: "invented-session", source: "invented-own", device: 7, inode: 9, time: now - 10, tool: .claude)
    var state = AgentLogState(); state.tool = "claude"; state.ownWorkingFolder = true
    let ownPosition = LogPosition(path: "invented-own", device: 7, inode: 9, offset: 10, state: try state.encoded(), seenAt: now)
    try store.appendLogEvents([], evidence: [], position: ownPosition)
    try work { try self.task.observe(observation, now: self.now) }
    XCTAssertEqual(try count("git_repositories"), 0)
    XCTAssertEqual(try count("agent_log_revoked_sessions", "session_id='invented-session'"), 0)
    try observe(); try observe(source: "invented-late-own"); try scan()
    state.ownWorkingFolder = true
    try store.appendLogEvents([], evidence: [], position: LogPosition(path: "invented-late-own", device: 7, inode: 9, offset: 10, state: try state.encoded(), seenAt: now))
    XCTAssertEqual(try count("git_working_folders"), 1)
    XCTAssertEqual(try count("git_commits"), 1)
    try store.appendLogEvents([], evidence: [], position: LogPosition(path: "invented-source", device: 7, inode: 8, offset: 10, state: try state.encoded(), seenAt: now))
    XCTAssertEqual(try count("git_repositories"), 0)
    XCTAssertEqual(try count("git_commits"), 0)
  }
  func testBackfillFromExistingEventsAndCheckpointWithoutNewLogRecords() throws {
    try commit()
    var state = AgentLogState(); state.project = repo.path; state.cwdObservedAt = now - 10; state.session = AgentLogIdentity.decoded("invented-checkpoint").session.subject; state.tool = "claude"
    let position = LogPosition(path: "invented-checkpoint", device: 7, inode: 8, offset: 0, state: try state.encoded(), seenAt: now - 10)
    try store.saveLogPosition(position)
    try scan()
    XCTAssertEqual(try count("git_working_folders"), 1)
    XCTAssertEqual(try count("git_commits"), 1)
    try store.connection.run("DELETE FROM git_working_folders")
    try store.connection.run("DELETE FROM log_positions")
    let bytes = Data("{\"type\":\"assistant\",\"sessionId\":\"invented-backfill\",\"timestamp\":\(now - 20),\"cwd\":\"\(repo.path)\"}".utf8)
    var eventState = AgentLogState()
    let event = AgentLogEventParser.parse(bytes, byteCount: bytes.count, offset: 0, observedAt: now, tool: .claude,
      file: "invented-log", state: &eventState, logsRelativePath: nil, fingerprint: { _ in "invented" })!
    try store.appendLogEvents([event], evidence: [], position: LogPosition(path: "invented-log", device: 7, inode: 8, offset: bytes.count, state: try eventState.encoded(), seenAt: now))
    task = GitCollectionTask(storage: store, secureInput: { false }, scratchDirectory: root)
    try scan()
    XCTAssertEqual(try count("git_working_folders", "session='invented-backfill'"), 1)
  }
  func testBrokenAndMissingFoldersCountFailuresAndRetry() throws {
    let broken = root.appendingPathComponent("invented-broken")
    try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
    try observe(broken)
    try observe(root.appendingPathComponent("invented-missing"))
    XCTAssertEqual(try count("git_working_folders", "status='failed'"), 1)
    XCTAssertEqual(try count("git_working_folders", "status='missing'"), 1)
    try git(["init", "-b", "main"], in: broken)
    try commit(in: broken)
    try scan(now + 300)
    XCTAssertEqual(try count("git_repositories"), 1)
    XCTAssertEqual(try count("git_commits"), 1)
    try FileManager.default.removeItem(at: broken.appendingPathComponent(".git"))
    try scan(now + 600)
    XCTAssertEqual(try store.connection.integer("SELECT failures FROM git_repositories"), 1)
    XCTAssertTrue(try store.gitStatus().contains("git_failures=2"))
  }
  func testEveryMetadataStringIsMaskedIncludingRawSecretFolderFirstSight() throws {
    let secret = "sk-" + String(repeating: "Invented", count: 5)
    let renamed = root.appendingPathComponent(secret)
    try FileManager.default.moveItem(at: repo, to: renamed); repo = renamed
    let secretFile = "file-" + secret
    try Data("Invented".utf8).write(to: repo.appendingPathComponent(secretFile))
    try git(["add", "--", secretFile])
    try git(["commit", "-m", "Invented " + secret], name: secret)
    try git(["branch", secret])
    try observe(); try scan()
    XCTAssertEqual(try count("git_repositories"), 1)
    XCTAssertEqual(try count("git_commits"), 1)
    XCTAssertEqual(try count("git_files"), 1)
    // The raw path is used for discovery in this read, while only its masked spelling is durable.
    for table in ["git_repositories", "git_working_folders", "git_refs", "git_commits", "git_commit_refs", "git_files"] {
      try store.connection.rows("SELECT * FROM \(table)") { row in
        for column in 0..<sqlite3_column_count(row) {
          XCTAssertFalse(SQLiteConnection.text(row, column).contains(secret), table)
        }
      }
    }
    for suffix in ["", "-wal"] {
      let bytes = try Data(contentsOf: root.appendingPathComponent("invented.sqlite" + suffix))
      XCTAssertNil(bytes.range(of: Data(secret.utf8)))
      XCTAssertNil(bytes.range(of: Data("invented@example.test".utf8)))
    }
  }
  func testMainThreadRefusedAndTimeoutKillsOnlyOwnedGitProcess() throws {
    XCTAssertThrowsError(try GitRepositoryReader().locate(repo.path))
    try commit()
    try work {
      XCTAssertThrowsError(try GitRepositoryReader(timeout: 0).locate(self.repo.path))
    }
  }
  func testQueryProjectionNeverReceivesGit() throws {
    try store.connection.run("INSERT INTO evidence(ts,kind,source,document_key,project,text) VALUES(?,'prompt','invented','','','Invented retained')", [.integer(now - 5)])
    try commit("Invented local-only git message"); try observe(); try scan()
    let evidence = try store.evidence(in: TimeRange(now - 1000, now + 1000))
    XCTAssertEqual(evidence.count, 1)
    XCTAssertEqual(evidence.first?.text, "Invented retained")
  }
  func testLogReaderResolvesRawFirstCwdForBothTools() throws {
    try commit()
    for tool in AgentLogTool.allCases {
      let logs = root.appendingPathComponent(tool.defaultHomeName).appendingPathComponent(tool.logsFolder)
      try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
      let record: [String: Any] = tool == .claude
        ? ["type": "assistant", "sessionId": "invented-claude", "timestamp": now - 10, "cwd": repo.path]
        : ["type": "session_meta", "timestamp": now - 10, "payload": ["id": "invented-codex", "cwd": repo.path]]
      var bytes = try JSONSerialization.data(withJSONObject: record); bytes.append(10)
      try bytes.write(to: logs.appendingPathComponent("invented.jsonl"))
      let reader: AgentLogReader = tool == .claude
        ? ClaudeAgentLogReader(userHome: root.path, processes: InventedProcesses(), appDataDirectory: root)
        : CodexAgentLogReader(userHome: root.path, processes: InventedProcesses(), appDataDirectory: root)
      let logTask = AgentLogTask(reader: reader, storage: store, git: task)
      try work { try logTask.scan(at: self.now) }
    }
    XCTAssertEqual(try count("git_repositories"), 1)
    XCTAssertEqual(try count("git_working_folders"), 2)
    try scan()
    XCTAssertEqual(try count("git_commits"), 1)
    let logs = RecorderConnections.makeLogTasks(database: store, appDataDirectory: root, userHome: root.path,
      processes: InventedProcesses(), summaryCodexHome: nil)
    XCTAssertNotNil(logs.first?.git)
    XCTAssertTrue(logs[0].git === logs[1].git)
    let connections = RecorderConnections(recorder: store, client: store, logTasks: logs, fileVault: GitInventedVault())
    XCTAssertTrue(connections.maintenanceTasks.contains { $0.name == "git-history" })
  }
  func testCollectionIgnoresRepositoryHelpersAndLeavesEveryRepositoryByteUnchanged() throws {
    try commit()
    let helper = root.appendingPathComponent("invented-helper")
    let marker = root.appendingPathComponent("invented-helper-ran")
    try Data(("#!/bin/sh\necho invented > '" + marker.path + "'\n").utf8).write(to: helper)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
    try git(["config", "core.fsmonitor", helper.path])
    try git(["config", "diff.external", helper.path])
    try git(["config", "core.hooksPath", helper.path])
    func snapshot() throws -> [String: Data] {
      var result: [String: Data] = [:]
      let files = FileManager.default.enumerator(at: repo, includingPropertiesForKeys: [.isRegularFileKey])!
      for case let url as URL in files where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
        result[String(url.path.dropFirst(repo.path.count))] = try Data(contentsOf: url)
      }
      return result
    }
    let before = try snapshot()
    try observe(); try scan()
    XCTAssertEqual(try count("git_commits"), 1)
    XCTAssertEqual(try snapshot(), before)
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
  }
  func testPauseDuringCommitStreamRemovesPartialContentAndAllowsRetry() throws {
    try observe()
    let id = try store.connection.integer("SELECT id FROM git_repositories")
    let commit = GitCommitRecord(hash: String(repeating: "a", count: 40), authorTime: now - 20,
      commitTime: now - 10, author: "Invented", email: "invented@example.test", message: "Invented")
    let row = try XCTUnwrap(store.beginGitCommit(repo: id, commit: commit, now: now))
    try store.appendGitFile(GitChangedFile(path: "invented", added: 1, deleted: 0), commit: row, now: now)
    try store.saveSettings(StorageSettings(recordingEnabled: false), at: now)
    try store.appendGitFile(GitChangedFile(path: "invented-after-off", added: 1, deleted: 0), commit: row, now: now)
    XCTAssertEqual(try count("git_files"), 1)
    XCTAssertEqual(try store.finishGitCommit(row, now: now), .retry)
    XCTAssertEqual(try count("git_commits"), 0)
    XCTAssertEqual(try count("git_files"), 0)
    XCTAssertEqual(try count("git_tombstones"), 0)
  }
  func testActiveSessionLinkSurvivesRetentionWhileItsOldCommitsExpire() throws {
    try store.saveSettings(StorageSettings(promptRetentionDays: 1), at: 0)
    try commit(); try observe(); try scan()
    try observe(time: now + 90000, scan: now + 90000)
    try store.cleanRetention(at: now + 90000)
    XCTAssertEqual(try count("git_repositories"), 1)
    XCTAssertEqual(try count("git_working_folders"), 1)
    XCTAssertEqual(try count("git_commits"), 0)
  }
  func testHeavyDayStorageGrowthForTwoHundredCommitsAndFourThousandFiles() throws {
    try observe()
    let repoID = try store.connection.integer("SELECT id FROM git_repositories")
    let before = try store.connection.integer("PRAGMA page_count") * store.connection.integer("PRAGMA page_size")
    for number in 1...200 {
      let suffix = String(number, radix: 16)
      let commit = GitCommitRecord(hash: String(repeating: "0", count: 40 - suffix.count) + suffix,
        authorTime: now - 20, commitTime: now - 10, author: "Invented Author", email: "invented@example.test",
        message: "Invented change " + String(repeating: "ordinary description ", count: 12))
      let id = try XCTUnwrap(store.beginGitCommit(repo: repoID, commit: commit, now: now))
      for file in 1...20 {
        try store.appendGitFile(GitChangedFile(path: "invented/module/ordinary/path/for/component/number-\(file).swift", added: 15, deleted: 4), commit: id, now: now)
      }
      try store.appendGitCommitRef("refs/heads/invented-main", commit: id, now: now)
      try store.appendGitCommitRef("refs/heads/invented-feature", commit: id, now: now)
      try store.finishGitCommit(id, now: now)
    }
    let after = try store.connection.integer("PRAGMA page_count") * store.connection.integer("PRAGMA page_size")
    XCTAssertEqual(try count("git_commits"), 200)
    XCTAssertEqual(try count("git_files"), 4000)
    print("GIT_GROWTH commits=200 files=4000 refs=400 sqlite_growth_bytes=\(after - before)")
  }

  func testAllRefsIncludesDetachedHeadsInBothMainAndLinkedWorktrees() throws {
    try commit()
    try git(["checkout", "--detach"])
    let main = try commit("Invented detached main", file: "main-detached")
    let tree = root.appendingPathComponent("invented-detached-worktree")
    try git(["worktree", "add", "--detach", tree.path])
    let linked = try commit("Invented detached worktree", file: "worktree-detached", in: tree)
    try observe(); try scan()
    XCTAssertEqual(try count("git_commits"), 3)
    XCTAssertEqual(try count("git_commits", "hash='\(main)' OR hash='\(linked)'"), 2)
    XCTAssertGreaterThan(try count("git_commit_refs", "name LIKE 'worktree:%:HEAD'"), 0)
  }

  func testForgetDuringReadCannotResurrectOrAttachToReusedRepositoryOrCommitIDs() throws {
    try observe()
    let oldRepo = try store.connection.integer("SELECT id FROM git_repositories")
    let first = GitCommitRecord(hash: String(repeating: "a", count: 40), authorTime: now - 20, commitTime: now - 20,
      author: "Invented", email: "invented@example.test", message: "Invented first")
    let oldCommit = try XCTUnwrap(store.beginGitCommit(repo: oldRepo, commit: first, now: now))
    try store.appendGitFile(GitChangedFile(path: "invented", added: 1, deleted: 0), commit: oldCommit, now: now)
    let range = TimeRange(now - 11, now - 9)
    let preview = try store.previewDeletion(in: range)
    try store.deleteRecords(in: range, confirmation: preview.confirmation)
    try observe(time: now + 10, scan: now + 20)
    let newRepo = try store.connection.integer("SELECT id FROM git_repositories")
    XCTAssertNotEqual(oldRepo, newRepo)
    let second = GitCommitRecord(hash: String(repeating: "b", count: 40), authorTime: now + 5, commitTime: now + 5,
      author: "Invented", email: "invented@example.test", message: "Invented second")
    let newCommit = try XCTUnwrap(store.beginGitCommit(repo: newRepo, commit: second, now: now + 20))
    XCTAssertNotEqual(oldCommit, newCommit)
    try store.appendGitFile(GitChangedFile(path: "invented-late", added: 1, deleted: 0), commit: oldCommit, now: now + 20)
    XCTAssertEqual(try count("git_files"), 0)
    XCTAssertNil(try store.beginGitCommit(repo: oldRepo, commit: second, now: now + 20))
    try store.finishGitRead(repo: oldRepo, now: now + 20, succeeded: true)
    XCTAssertEqual(try count("git_refs"), 0)
    XCTAssertEqual(try count("git_commits"), 1)
  }

  func testPrunedPreviousRefTipDoesNotBlockLaterReads() throws {
    let old = try commit()
    try observe(); try scan()
    try git(["checkout", "--orphan", "invented-replacement"])
    try git(["rm", "-rf", "."])
    try commit("Invented replacement", file: "replacement")
    try git(["branch", "-D", "main"])
    let object = repo.appendingPathComponent(".git/objects").appendingPathComponent(String(old.prefix(2)))
      .appendingPathComponent(String(old.dropFirst(2)))
    try FileManager.default.removeItem(at: object)
    try scan(now + 300)
    XCTAssertEqual(try count("git_commits", "complete=1"), 2)
    XCTAssertEqual(try store.connection.integer("SELECT failures FROM git_repositories"), 0)
  }

  func testMaskedFolderAndRefNameCollisionsKeepDistinctRepositoryAndRefIdentities() throws {
    let firstSecret = "sk-" + String(repeating: "Invented", count: 5) + "A"
    let secondSecret = "sk-" + String(repeating: "Invented", count: 5) + "B"
    let firstFolder = root.appendingPathComponent(firstSecret)
    let secondFolder = root.appendingPathComponent(secondSecret)
    try FileManager.default.moveItem(at: repo, to: firstFolder)
    repo = firstFolder
    try commit()
    try git(["branch", firstSecret]); try git(["branch", secondSecret])
    try observe()
    try FileManager.default.createDirectory(at: secondFolder, withIntermediateDirectories: true)
    repo = secondFolder
    try git(["init", "-b", "main"])
    try commit("Invented second repository")
    try observe(); try scan()
    XCTAssertEqual(try count("git_repositories"), 2)
    XCTAssertEqual(try count("git_working_folders"), 2)
    XCTAssertEqual(try count("git_commits"), 2)
    XCTAssertEqual(try count("git_commit_refs", "name='refs/heads/[secret]'"), 2)
  }

  func testSignedMetadataNeverRunsLocalGPGSSHOrOtherHelpers() throws {
    try commit()
    let helper = root.appendingPathComponent("invented-helper")
    let marker = root.appendingPathComponent("invented-helper-marker")
    try Data("#!/bin/sh\necho invented > '\(marker.path)'\nexit 0\n".utf8).write(to: helper)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
    let tree = try git(["rev-parse", "HEAD^{tree}"])
    for (index, signature) in ["PGP", "SSH"].enumerated() {
      let body = "tree \(tree)\nauthor Invented <invented@example.test> \(now - 60) +0000\ncommitter Invented <invented@example.test> \(now - 60) +0000\ngpgsig -----BEGIN \(signature) SIGNATURE-----\n invented\n -----END \(signature) SIGNATURE-----\n\nInvented signed metadata\n"
      let object = root.appendingPathComponent("invented-commit")
      try Data(body.utf8).write(to: object)
      let hash = try git(["hash-object", "-t", "commit", "-w", object.path])
      try git(["update-ref", "refs/heads/main", hash])
      for key in ["gpg.program", "gpg.openpgp.program", "gpg.ssh.program", "gpg.x509.program", "core.sshCommand", "core.gitProxy", "credential.helper", "core.fsmonitor", "core.hooksPath", "core.pager", "pager.show", "diff.external", "diff.invented.command", "diff.invented.textconv", "filter.invented.clean", "filter.invented.smudge", "filter.invented.process", "core.alternateRefsCommand", "alias.show"] {
        try git(["config", key, helper.path])
      }
      let signers = root.appendingPathComponent("invented-signers")
      try Data("invented@example.test ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIInvented\n".utf8).write(to: signers)
      try git(["config", "gpg.ssh.allowedSignersFile", signers.path])
      try git(["config", "log.showSignature", "true"])
      try git(["config", "gpg.format", index == 0 ? "openpgp" : "ssh"])
      try git(["config", "protocol.ext.allow", "always"])
      try git(["config", "remote.origin.url", "ext::" + helper.path])
      try git(["config", "http.proxy", "http://127.0.0.1:1"])
      let included = root.appendingPathComponent("invented-included-config")
      try Data("[gpg]\n program = \(helper.path)\n[log]\n showSignature = true\n".utf8).write(to: included)
      try git(["config", "include.path", included.path])
      try Data("* diff=invented filter=invented\n".utf8).write(to: repo.appendingPathComponent(".git/info/attributes"))
      try observe(); try scan(now + index * 300)
      XCTAssertEqual(try count("git_commits", "hash='\(hash)' AND complete=1"), 1)
      XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }
  }

  func testOwnSessionReceiptBlocksBackfillWithUnavailableSourceForBothTools() throws {
    try commit()
    for tool in AgentLogTool.allCases {
      let session = "invented-receipt-" + tool.rawValue
      var state = AgentLogState(); state.tool = tool.rawValue; state.session = AgentLogIdentity.decoded(session).session.subject
      let object: [String: Any] = tool == .claude
        ? ["type": "assistant", "sessionId": session, "timestamp": now - 10, "cwd": repo.path]
        : ["type": "session_meta", "timestamp": now - 10, "payload": ["id": session, "cwd": repo.path]]
      let bytes = try JSONSerialization.data(withJSONObject: object)
      let event = try XCTUnwrap(AgentLogEventParser.parse(bytes, byteCount: bytes.count, offset: 0, observedAt: now,
        tool: tool, file: "invented", state: &state, logsRelativePath: nil, fingerprint: { _ in "invented" }))
      try store.appendLogEvents([event], evidence: [], position: LogPosition(path: root.appendingPathComponent(session).path,
        device: 7, inode: tool == .claude ? 80 : 81, offset: bytes.count, state: try state.encoded(), seenAt: now))
      try store.ownLogSources().registerSession(session, tool: tool)
    }
    task = GitCollectionTask(storage: store, secureInput: { false }, scratchDirectory: root)
    try scan()
    XCTAssertEqual(try count("git_repositories"), 0)
    XCTAssertEqual(try count("git_commits"), 0)
  }

  func testLateOwnSessionRevokesGitOnlyLinksAndPreservesIndependentToolSession() throws {
    try commit()
    for tool in AgentLogTool.allCases {
      let folder = GitWorkingFolder(folder: repo.path, session: "invented-crash-session", source: "invented-copy-" + tool.rawValue,
        device: 7, inode: tool == .claude ? 80 : 81, time: now - 10, tool: tool)
      try work { try self.task.observe(folder, now: self.now) }
    }
    XCTAssertEqual(try count("agent_log_events"), 0)
    XCTAssertEqual(try count("log_positions"), 0)
    var state = AgentLogState(); state.tool = AgentLogTool.claude.rawValue
    state.session = AgentLogIdentity.decoded("invented-crash-session").session.subject; state.ownedSession = state.session; state.ownWorkingFolder = true
    try store.appendLogEvents([], evidence: [], position: LogPosition(path: "invented-other-copy", device: 7, inode: 90,
      offset: 1, state: try state.encoded(), seenAt: now))
    XCTAssertEqual(try count("git_working_folders"), 1)
    XCTAssertEqual(try count("git_working_folders", "tool='codex'"), 1)
    try scan()
    XCTAssertEqual(try count("git_commits"), 1)
    state.tool = AgentLogTool.codex.rawValue
    try store.appendLogEvents([], evidence: [], position: LogPosition(path: "invented-third-copy", device: 7, inode: 91,
      offset: 1, state: try state.encoded(), seenAt: now))
    XCTAssertEqual(try count("git_repositories"), 0)
    XCTAssertEqual(try count("git_commits"), 0)
  }

  func testLateReceiptRevokesExistingGitOnlyLinkWithoutLogCheckpoint() throws {
    try commit()
    let folder = GitWorkingFolder(folder: repo.path, session: "invented-late-receipt", source: "invented-copy",
      device: 7, inode: 80, time: now - 10, tool: .claude)
    try work { try self.task.observe(folder, now: self.now) }
    try store.ownLogSources().registerSession(folder.session, tool: .claude)
    task = GitCollectionTask(storage: store, secureInput: { false }, scratchDirectory: root)
    try scan()
    XCTAssertEqual(try count("git_working_folders"), 0)
    XCTAssertEqual(try count("git_repositories"), 0)
  }

  func testForgetCheckpointDiscoverySurvivesRestartAndConcurrentOldObservation() throws {
    try commit()
    var state = AgentLogState(); state.tool = "claude"; state.session = AgentLogIdentity.decoded("invented-checkpoint").session.subject
    state.project = repo.path; state.cwdObservedAt = now - 10
    let position = LogPosition(path: "invented-checkpoint", device: 7, inode: 80, offset: 1, state: try state.encoded(), seenAt: now)
    try store.saveLogPosition(position)
    try scan()
    let old = GitWorkingFolder(folder: repo.path, session: state.session!.storedKey, source: position.path, device: 7, inode: 80, time: now - 10, tool: .claude)
    XCTAssertTrue(try store.gitShouldResolve(GitWorkingFolder(folder: repo.path, session: "invented-late", source: "invented-late", device: 7, inode: 81, time: now - 10, tool: .claude), now: now))
    let range = TimeRange(now - 11, now - 9)
    let preview = try store.previewDeletion(in: range)
    XCTAssertEqual(preview.counts["git_checkpoint_discoveries"], 1)
    try store.deleteRecords(in: range, confirmation: preview.confirmation)
    try store.rememberGitFolder(old, location: GitRepositoryLocation(commonDirectory: repo.appendingPathComponent(".git").path,
      topLevel: repo.path, branch: "main", head: ""), status: "ready", now: now + 300)
    task = nil; store = nil
    store = try ActivityStorage(url: root.appendingPathComponent("invented.sqlite"), appDataDirectory: root, databaseScope: .directory(root))
    task = GitCollectionTask(storage: store, secureInput: { false }, scratchDirectory: root)
    var polled = position; polled.seenAt = now + 300
    try store.saveLogPosition(polled)
    try scan(now + 300)
    for table in ["git_repositories", "git_working_folders", "git_refs", "git_commits", "git_commit_refs", "git_files"] { XCTAssertEqual(try count(table), 0, table) }
    XCTAssertGreaterThan(try count("git_discovery_tombstones"), 0)
    var fresh = old; fresh.time = now + 301
    try work { try self.task.observe(fresh, now: self.now + 302) }
    XCTAssertEqual(try count("git_repositories"), 1)
  }

  func testCheckpointFreshnessIncludesOriginalNativeDiscoveryTime() throws {
    try commit()
    var state = AgentLogState(); state.tool = "claude"; state.session = AgentLogIdentity.decoded("invented-checkpoint").session.subject; state.project = repo.path; state.cwdObservedAt = now - 10
    var position = LogPosition(path: "invented-checkpoint", device: 7, inode: 80, offset: 1, state: try state.encoded(), seenAt: now - 10)
    try store.saveLogPosition(position)
    position.seenAt = now
    try store.saveLogPosition(position)
    let saved = try XCTUnwrap(store.logPosition(path: position.path))
    XCTAssertEqual(try AgentLogState.decode(saved.state).cwdObservedAt, now - 10)
    try scan()
    let range = TimeRange(now - 11, now - 9)
    let preview = try store.previewDeletion(in: range)
    state.cwdObservedAt = now - 8; position.state = try state.encoded()
    try store.saveLogPosition(position)
    XCTAssertThrowsError(try store.deleteRecords(in: range, confirmation: preview.confirmation))
  }

  func testMaskedCommonDirectoryReopenGapHasSeparateCountAndRawRediscoveryRepairsIt() throws {
    let secret = "sk-" + String(repeating: "Invented", count: 5)
    let renamed = root.appendingPathComponent(secret)
    try FileManager.default.moveItem(at: repo, to: renamed); repo = renamed
    try commit(); try observe(); try scan()
    XCTAssertTrue(try store.gitStatus().contains("git_masked_reopen_blocked=0"))
    task = GitCollectionTask(storage: store, secureInput: { false }, scratchDirectory: root)
    try scan(now + 300)
    XCTAssertTrue(try store.gitStatus().contains("git_masked_reopen_blocked=1"))
    try observe(scan: now + 600); try scan(now + 600)
    XCTAssertTrue(try store.gitStatus().contains("git_masked_reopen_blocked=0"))
  }

  func testLargeInitialHistoryDoesNotDelayCwdAndRepositoriesProgressFairly() throws {
    // One fast-import process creates a sizeable invented first history without test setup dominating.
    let stream = root.appendingPathComponent("invented-fast-import")
    var data = Data()
    for number in 1...300 {
      data.append(Data("commit refs/heads/main\ncommitter Invented <invented@example.test> \(now - 60) +0000\ndata 9\nInvented\n\n".utf8))
      if number == 1 { data.append(Data("deleteall\n".utf8)) }
      data.append(10)
    }
    try data.write(to: stream)
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    p.arguments = ["-C", repo.path, "fast-import", "--quiet"]
    p.environment = ["PATH": "/usr/bin:/bin", "HOME": root.path, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]
    let input = try FileHandle(forReadingFrom: stream); p.standardInput = input
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    try p.run(); p.waitUntilExit(); try input.close(); XCTAssertEqual(p.terminationStatus, 0)
    try observe()
    task = GitCollectionTask(storage: store, sliceDuration: 0, secureInput: { false }, scratchDirectory: root)
    let started = ProcessInfo.processInfo.systemUptime
    try work { try self.task.maintenanceTask.run(self.now) }
    defer { try? scan() }
    let dispatchSeconds = ProcessInfo.processInfo.systemUptime - started
    var later: [URL] = []
    for number in 1...8 {
      let folder = root.appendingPathComponent("invented-later-\(number)")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try git(["init", "-b", "main"], in: folder)
      try commit("Invented later", in: folder)
      later.append(folder)
    }
    let discoveryStarted = ProcessInfo.processInfo.systemUptime
    for folder in later { try observe(folder) }
    let discoverySeconds = ProcessInfo.processInfo.systemUptime - discoveryStarted
    XCTAssertEqual(try count("git_repositories"), 9)
    let mainID = try store.withQuerySnapshot { try self.store.connection.integer("SELECT repo_id FROM git_working_folders ORDER BY id LIMIT 1") }
    let mainBefore = try store.withQuerySnapshot { try self.count("git_commits", "repo_id=\(mainID) AND complete=1") }
    XCTAssertLessThan(mainBefore, 300)
    let deadline = ProcessInfo.processInfo.systemUptime + 30
    var fair = false
    while ProcessInfo.processInfo.systemUptime < deadline {
      fair = try store.withQuerySnapshot {
        try self.count("git_repositories", "id!=\(mainID) AND last_read IS NOT NULL") == 8
          && self.count("git_commits", "repo_id=\(mainID) AND complete=1") < 300
      }
      if fair { break }
      Thread.sleep(forTimeInterval: 0.05)
    }
    XCTAssertTrue(fair)
    try scan() // Drains the owned history queue before fixture teardown.
    XCTAssertEqual(try count("git_commits", "complete=1"), 308)
    print("GIT_FAIRNESS initial_commits=300 later_repositories=8 dispatch_seconds=\(dispatchSeconds) cwd_seconds=\(discoverySeconds) main_commits_at_discovery=\(mainBefore) total_seconds=\(ProcessInfo.processInfo.systemUptime - started)")
  }

  func testNativeCwdTimeAndToolProvenanceSurviveReopen() throws {
    try commit()
    var state = AgentLogState(); state.tool = "claude"
    let bytes = try JSONSerialization.data(withJSONObject: ["type": "assistant", "sessionId": "invented-migration", "timestamp": now - 10, "cwd": repo.path])
    let event = try XCTUnwrap(AgentLogEventParser.parse(bytes, byteCount: bytes.count, offset: 0, observedAt: now,
      tool: .claude, file: "invented", state: &state, logsRelativePath: nil, fingerprint: { _ in "invented" }))
    let position = LogPosition(path: "invented-migration", device: 7, inode: 80, offset: 1, state: try state.encoded(), seenAt: now)
    try store.appendLogEvents([event], evidence: [], position: position)
    try scan()
    task = nil; store = nil
    store = try ActivityStorage(url: root.appendingPathComponent("invented.sqlite"), appDataDirectory: root, databaseScope: .directory(root))
    task = GitCollectionTask(storage: store, secureInput: { false }, scratchDirectory: root)
    XCTAssertEqual(try count("git_working_folders", "tool='claude'"), 1)
    XCTAssertEqual(try AgentLogState.decode(XCTUnwrap(store.logPosition(path: position.path)).state).cwdObservedAt, now - 10)
    let range = TimeRange(now - 11, now - 9)
    try store.deleteRecords(in: range, confirmation: store.previewDeletion(in: range).confirmation)
    task = GitCollectionTask(storage: store, secureInput: { false }, scratchDirectory: root)
    try scan(now + 300)
    XCTAssertEqual(try count("git_repositories"), 0)
    XCTAssertEqual(try count("git_refs"), 0)
    XCTAssertEqual(try count("git_commits"), 0)
  }

  func testForgottenDiscoveryCannotReturnFromUnprovenCheckpoint() throws {
    try commit()
    var state = AgentLogState(); state.tool = "claude"; state.session = AgentLogIdentity.decoded("invented-old-forget").session.subject
    state.project = repo.path; state.cwdObservedAt = now - 10
    let position = LogPosition(path: "invented-old-forget", device: 7, inode: 80, offset: 1, state: try state.encoded(), seenAt: now)
    try store.saveLogPosition(position); try scan()
    let range = TimeRange(now - 11, now - 9)
    try store.deleteRecords(in: range, confirmation: store.previewDeletion(in: range).confirmation)
    try store.connection.run("UPDATE log_positions SET state=json_remove(state,'$.cwdObservedAt')")
    task = nil; store = nil
    store = try ActivityStorage(url: root.appendingPathComponent("invented.sqlite"), appDataDirectory: root, databaseScope: .directory(root))
    task = GitCollectionTask(storage: store, secureInput: { false }, scratchDirectory: root)
    try scan(now + 300)
    XCTAssertEqual(try count("git_repositories"), 0)
    XCTAssertEqual(try count("git_refs"), 0)
    XCTAssertGreaterThan(try count("git_discovery_tombstones"), 0)
  }

  func testDiscoveryTombstoneBlocksOldTimeOutsideForgetAndConcurrentResolution() throws {
    try commit()
    var state = AgentLogState(); state.tool = "claude"; state.session = AgentLogIdentity.decoded("invented-original").session.subject
    state.project = repo.path; state.cwdObservedAt = now - 100
    let position = LogPosition(path: "invented-original", device: 7, inode: 80, offset: 1, state: try state.encoded(), seenAt: now)
    try store.saveLogPosition(position); try scan()
    let original = GitWorkingFolder(folder: repo.path, session: state.session!.storedKey, source: position.path,
      device: 7, inode: 80, time: now - 100, tool: .claude)
    var recent = original; recent.time = now - 10
    try work { try self.task.observe(recent, now: self.now) }
    let range = TimeRange(now - 11, now - 9)
    let location = try work { try GitRepositoryReader().locate(self.repo.path) }
    let preview = try store.previewDeletion(in: range)
    XCTAssertEqual(preview.counts["git_checkpoint_discoveries"], 1)
    try store.deleteRecords(in: range, confirmation: preview.confirmation)
    // This timestamp is permitted by forgotten_ranges, so only the discovery refusal blocks it.
    XCTAssertFalse(try store.gitShouldResolve(original, now: now + 300))
    try store.rememberGitFolder(original, location: location, status: "ready", now: now + 300)
    task = GitCollectionTask(storage: store, secureInput: { false }, scratchDirectory: root); try scan(now + 300)
    XCTAssertEqual(try count("git_repositories"), 0)
    XCTAssertEqual(try count("git_working_folders"), 0)
    XCTAssertEqual(try count("git_refs"), 0)
  }

  func testVersion13ReadOnlyPreviewAndStatusDoNotRequireNewColumnsOrTables() throws {
    try commit(); try observe(); try scan()
    try store.connection.run("DROP INDEX git_folder_session")
    try store.connection.run("ALTER TABLE git_working_folders DROP COLUMN tool")
    try store.connection.run("ALTER TABLE git_working_folders DROP COLUMN discovery")
    try store.connection.run("ALTER TABLE git_repositories DROP COLUMN reopen_blocked")
    try store.connection.run("DROP TABLE git_discovery_tombstones")
    try store.connection.run("PRAGMA user_version=13")
    task = nil; store = nil
    let url = root.appendingPathComponent("invented.sqlite")
    let before = try Data(contentsOf: url)
    store = try ActivityStorage(url: url, appDataDirectory: root, readOnly: true, databaseScope: .directory(root))
    XCTAssertTrue(try store.gitStatus().contains("git_commits=1"))
    XCTAssertEqual(try store.previewDeletion(in: TimeRange(now - 11, now - 9)).counts["git_repositories"], 1)
    XCTAssertEqual(try Data(contentsOf: url), before)
    XCTAssertEqual(try store.connection.integer("PRAGMA user_version"), 13)
  }

  func testPendingRefSnapshotInsideForgottenRangeCannotReplacePermittedOlderRefs() throws {
    try commit(); try observe(time: now - 100, scan: now - 20); try scan(now - 20)
    let repoID = try store.connection.integer("SELECT id FROM git_repositories")
    let before = try count("git_refs")
    let tips = root.appendingPathComponent("invented-pending-tips")
    FileManager.default.createFile(atPath: tips.path, contents: nil)
    let output = try FileHandle(forWritingTo: tips)
    defer { try? output.close() }
    try store.prepareGitRefs(repo: repoID, to: output, now: now)
    try store.stageGitRef(repo: repoID, name: "refs/heads/invented-pending", tip: String(repeating: "a", count: 40))
    let range = TimeRange(now - 1, now + 1)
    try store.deleteRecords(in: range, confirmation: store.previewDeletion(in: range).confirmation)
    XCTAssertEqual(try count("git_repositories"), 1)
    try store.finishGitRead(repo: repoID, now: now, succeeded: true)
    XCTAssertEqual(try count("git_refs"), before)
    XCTAssertEqual(try count("git_refs", "name='refs/heads/invented-pending'"), 0)
    XCTAssertEqual(try store.connection.integer("SELECT last_read FROM git_repositories"), now - 20)
  }
  func testLookaheadOwnershipBlocksSavedAndPreparedGitDiscoveryForBothTools() throws {
    try commit()
    for tool in AgentLogTool.allCases {
      for saved in [false, true] {
        for completed in [false, true] {
          let tag = "invented-merge-\(tool)-\(saved)-\(completed)"
          var state = AgentLogState(); state.tool = tool.rawValue; state.session = AgentLogIdentity.decoded(tag + "-early").session.subject
          state.ownershipSession = AgentLogIdentity.decoded(tag + "-lookahead").session.subject; state.ownershipScanOffset = 200
          state.project = repo.path; state.cwdObservedAt = now - 10
          let position = LogPosition(path: root.appendingPathComponent(tag).path, device: 7, inode: 88,
            offset: 10, state: try state.encoded(), seenAt: now)
          if saved { try store.saveLogPosition(position) }
          if completed {
            try store.purgeOwnLogSession(state.ownershipSession!, tool: tool)
          } else { try store.ownLogSources().registerSession(state.ownershipSession!, tool: tool) }
          let bytes = try JSONSerialization.data(withJSONObject: ["type": "assistant", "cwd": repo.path, "timestamp": now - 10])
          let event = try XCTUnwrap(AgentLogEventParser.parse(bytes, byteCount: bytes.count, offset: 0, observedAt: now,
            tool: tool, file: tag, state: &state, logsRelativePath: nil, fingerprint: { _ in tag }))
          try work { try self.task.observe([event], position: position) }
          task = GitCollectionTask(storage: store, secureInput: { false }, scratchDirectory: root); try scan()
          XCTAssertEqual(try count("git_repositories"), 0, tag)
          if saved {
            let retained = try AgentLogState.decode(XCTUnwrap(store.logPosition(path: position.path)).state)
            XCTAssertEqual(retained.cwdObservedAt, now - 10)
            XCTAssertEqual(retained.ownershipSession, state.ownershipSession)
          }
        }
      }
    }
  }

  func testCompletedRevocationRejectsStaleGitBatchWithoutFilesystemReceiptsForBothTools() throws {
    try commit()
    for tool in AgentLogTool.allCases {
      let session = "invented-completed-git-" + tool.rawValue
      let folder = GitWorkingFolder(folder: repo.path, session: session, source: "invented-stale-" + tool.rawValue,
        device: 7, inode: 88, time: now - 10, tool: tool)
      try work { try self.task.observe(folder, now: self.now) }
      XCTAssertEqual(try count("git_working_folders"), 1)
      var own = AgentLogState(); own.tool = tool.rawValue; own.ownershipSession = AgentLogIdentity.decoded(session).session.subject; own.ownedSession = AgentLogIdentity.decoded(session).session.subject; own.ownWorkingFolder = true
      let position = LogPosition(path: "invented-own-" + tool.rawValue, device: 7, inode: 99,
        offset: 100, state: try own.encoded(), seenAt: now)
      try store.appendLogEvents([], evidence: [], position: position)
      XCTAssertEqual(try count("git_repositories"), 0)
      try FileManager.default.removeItem(at: root.appendingPathComponent(AgentLogOwnSources.folderName))
      task = nil; store = nil
      store = try ActivityStorage(url: root.appendingPathComponent("invented.sqlite"), appDataDirectory: root, databaseScope: .directory(root))
      task = GitCollectionTask(storage: store, secureInput: { false }, scratchDirectory: root)
      XCTAssertFalse(try store.gitShouldResolve(folder, now: now))
      let location = try work { try GitRepositoryReader().locate(self.repo.path) }
      try store.rememberGitFolder(folder, location: location, status: "ready", now: now)
      try work { try self.task.observe(folder, now: self.now) }
      XCTAssertEqual(try count("git_repositories"), 0)
      XCTAssertEqual(try count("agent_log_revoked_sessions", "tool='\(tool.rawValue)' AND session_id='\(session)'"), 1)
    }
  }

  func testLookaheadLateRevocationRollsBackGitOnlyLinksWithCheckpointForBothTools() throws {
    try commit()
    for tool in AgentLogTool.allCases {
      let tag = "invented-transaction-" + tool.rawValue
      let folder = GitWorkingFolder(folder: repo.path, session: tag, source: tag + "-git-only",
        device: 7, inode: 88, time: now - 10, tool: tool)
      try work { try self.task.observe(folder, now: self.now) }
      try scan()
      var state = AgentLogState(); state.tool = tool.rawValue; state.ownershipSession = AgentLogIdentity.decoded(tag).session.subject; state.ownedSession = AgentLogIdentity.decoded(tag).session.subject; state.ownWorkingFolder = true
      let own = LogPosition(path: tag + "-own", device: 7, inode: 99, offset: 100, state: try state.encoded(), seenAt: now)
      try store.connection.run("CREATE TRIGGER invented_git_checkpoint_failure BEFORE INSERT ON log_positions BEGIN SELECT RAISE(ABORT,'invented failure'); END")
      XCTAssertThrowsError(try store.appendLogEvents([], evidence: [], position: own))
      XCTAssertEqual(try count("git_working_folders"), 1)
      XCTAssertEqual(try count("git_commits"), 1)
      XCTAssertEqual(try count("agent_log_revoked_sessions", "session_id='\(tag)'"), 0)
      try store.connection.run("DROP TRIGGER invented_git_checkpoint_failure")
      try store.appendLogEvents([], evidence: [], position: own)
      XCTAssertEqual(try count("git_repositories"), 0)
      XCTAssertEqual(try count("git_commits"), 0)
      XCTAssertEqual(try count("agent_log_revoked_sessions", "session_id='\(tag)'"), 1)
    }
  }

  func testCompletedReceiptStillPurgesLegacyGitLinksBeforeSkippingAgentLookupForBothTools() throws {
    try commit()
    for tool in AgentLogTool.allCases {
      let tag = "invented-pre-adoption-" + tool.rawValue
      let folder = GitWorkingFolder(folder: repo.path, session: tag, source: tag, device: 7, inode: 88, time: now - 10, tool: tool)
      try work { try self.task.observe(folder, now: self.now) }
      // Model Git rows predating adoption of the independently completed receipt.
      try store.connection.run("INSERT INTO agent_log_revoked_sessions VALUES(?,?)", [.key(tool.rawValue), .key(tag)])
      try store.connection.run("ALTER TABLE agent_log_events RENAME TO invented_unavailable_events")
      XCTAssertNoThrow(try store.purgeOwnLogSession(tag, tool: tool))
      XCTAssertEqual(try count("git_working_folders"), 0)
      XCTAssertEqual(try count("git_repositories"), 0)
      try store.connection.run("ALTER TABLE invented_unavailable_events RENAME TO agent_log_events")
    }
  }

  func testBranchIntermediateSchemasAreRefusedBeforeDatabaseWrites() throws {
    for version in [10, 11, 12, 13, 14, 15] {
      let directory = root.appendingPathComponent("invented-unsupported-\(version)")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let url = directory.appendingPathComponent("invented.sqlite")
      var fixture: ActivityStorage? = try ActivityStorage(url: url, appDataDirectory: directory, databaseScope: .directory(directory))
      try fixture!.appendEvidence([EvidenceText(ts: now - 10, kind: .prompt, source: "invented", text: "Invented retained")])
      try fixture!.connection.run("PRAGMA user_version=\(version)")
      fixture = nil
      let before = try Data(contentsOf: url)
      XCTAssertThrowsError(try ActivityStorage(url: url, appDataDirectory: directory, databaseScope: .directory(directory)))
      XCTAssertEqual(try Data(contentsOf: url), before)
    }
  }

  func testLaunchPathAndHomeReceiptsBlockGitForBothTools() throws {
    try commit()
    for tool in AgentLogTool.allCases {
      for kind in ["session", "launch-name", "path", "home"] {
        let tag = "invented-receipt-\(tool)-\(kind)"
        let directory = root.appendingPathComponent(tag)
        let source = directory.appendingPathComponent(tag + ".jsonl")
        let registry = store.ownLogSources()
        switch kind {
        case "session", "launch-name": try registry.registerSession(tag, tool: tool)
        case "path": try registry.registerPath(source, tool: tool)
        default: try registry.registerHome(directory, tool: tool)
        }
        let folder = GitWorkingFolder(folder: repo.path, session: kind == "session" ? tag : "",
          source: source.path, device: 7, inode: 88, time: now - 10, tool: tool)
        try work { try self.task.observe(folder, now: self.now) }
        XCTAssertEqual(try count("git_repositories"), 0, tag)
        XCTAssertEqual(try count("git_working_folders"), 0, tag)
      }
    }
  }

  func testLookaheadCheckpointForgetFreshnessAndOriginalTimeSurviveRestartForBothTools() throws {
    try commit()
    for tool in AgentLogTool.allCases {
      let tag = "invented-forget-lookahead-" + tool.rawValue
      let observed = now - (tool == .claude ? 10 : 30)
      var state = AgentLogState(); state.tool = tool.rawValue; state.session = AgentLogIdentity.decoded(tag).session.subject
      state.ownershipSession = AgentLogIdentity.decoded(tag + "-lookahead").session.subject; state.ownershipScanOffset = 200
      state.project = repo.path; state.cwdObservedAt = observed
      var position = LogPosition(path: tag, device: 7, inode: 88, offset: 10, state: try state.encoded(), seenAt: now)
      try store.saveLogPosition(position)
      task = GitCollectionTask(storage: store, secureInput: { false }, scratchDirectory: root); try scan()
      let range = TimeRange(observed - 1, observed + 1)
      let stale = try store.previewDeletion(in: range)
      state.ownershipSession = AgentLogIdentity.decoded(tag + "-later-lookahead").session.subject; state.ownershipScanOffset = 300
      position.state = try state.encoded(); position.seenAt = now + 300
      try store.saveLogPosition(position)
      XCTAssertThrowsError(try store.deleteRecords(in: range, confirmation: stale.confirmation))
      let fresh = try store.previewDeletion(in: range)
      XCTAssertEqual(fresh.counts["git_checkpoint_discoveries"], 1)
      try store.deleteRecords(in: range, confirmation: fresh.confirmation)
      task = nil; store = nil
      store = try ActivityStorage(url: root.appendingPathComponent("invented.sqlite"), appDataDirectory: root, databaseScope: .directory(root))
      task = GitCollectionTask(storage: store, secureInput: { false }, scratchDirectory: root); try scan(now + 300)
      XCTAssertEqual(try count("git_repositories"), 0)
      XCTAssertEqual(try count("git_refs"), 0)
      let retained = try AgentLogState.decode(XCTUnwrap(store.logPosition(path: tag)).state)
      XCTAssertEqual(retained.cwdObservedAt, observed)
      XCTAssertEqual(retained.ownershipSession, state.ownershipSession)
    }
  }

  func testCompletedRevocationReconcilesGitReceiptsAndPreservesOtherTool() throws {
    try commit()
    for tool in AgentLogTool.allCases {
      let folder = GitWorkingFolder(folder: repo.path, session: "invented-migration-revoked", source: "invented-migration-" + tool.rawValue,
        device: 7, inode: tool == .claude ? 88 : 89, time: now - 10, tool: tool)
      try work { try self.task.observe(folder, now: self.now) }
    }
    try store.connection.run("INSERT INTO agent_log_revoked_sessions VALUES('claude','invented-migration-revoked')")
    try store.purgeOwnLogSession("invented-migration-revoked", tool: .claude)
    task = nil; store = nil
    store = try ActivityStorage(url: root.appendingPathComponent("invented.sqlite"), appDataDirectory: root, databaseScope: .directory(root))
    task = GitCollectionTask(storage: store, secureInput: { false }, scratchDirectory: root)
    XCTAssertEqual(try count("git_working_folders", "tool='claude'"), 0)
    XCTAssertEqual(try count("git_working_folders", "tool='codex'"), 1)
    XCTAssertEqual(try count("git_repositories"), 1)
    try scan()
    XCTAssertEqual(try count("git_commits"), 1)
  }

  func testResolvedLookaheadObservationRechecksCompletedReceiptInsideRegistrationForBothTools() throws {
    try commit()
    let location = try work { try GitRepositoryReader().locate(self.repo.path) }
    for tool in AgentLogTool.allCases {
      let tag = "invented-resolved-lookahead-" + tool.rawValue
      var state = AgentLogState(); state.tool = tool.rawValue; state.ownershipSession = AgentLogIdentity.decoded(tag).session.subject
      let position = LogPosition(path: tag, device: 7, inode: 88, offset: 10, state: try state.encoded(), seenAt: now)
      let folder = GitWorkingFolder(folder: repo.path, session: "", source: tag, device: 7, inode: 88, time: now - 10, tool: tool)
      XCTAssertTrue(try store.validateGitObservation(folder, now: now, position: position))
      try store.purgeOwnLogSession(tag, tool: tool)
      try store.rememberGitFolder(folder, location: location, status: "ready", now: now, position: position)
      XCTAssertEqual(try count("git_repositories"), 0)
      XCTAssertEqual(try count("git_working_folders"), 0)
    }
  }

  private func ownershipSnapshot(_ table: String, where predicate: String = "1") throws -> [String] {
    var columns: [String] = []
    try store.connection.namedRows("PRAGMA table_info(\(table))") { columns.append(try $0.text("name")) }
    let expression = columns.map { "typeof(\($0))||':'||quote(\($0))" }.joined(separator: "||'|'||")
    var rows: [String] = []
    try store.connection.namedRows("SELECT \(expression) AS value FROM \(table) WHERE \(predicate) ORDER BY rowid") {
      rows.append(try $0.text("value"))
    }
    return rows
  }
  private func ownershipRead(_ url: URL, tool: AgentLogTool) throws -> AgentLogBatch {
    let source = try XCTUnwrap(AgentLogFiles.listing([url.deletingLastPathComponent().path]).files.first { $0.path == url.path })
    return try AgentLogFiles.read(source, tool: tool, position: store.logPosition(path: url.path), at: now,
      ownSources: AgentLogFiles.ownSources(appDataDirectory: root))
  }
  private func ownershipImport(_ url: URL, tool: AgentLogTool) throws -> AgentLogBatch {
    let batch = try ownershipRead(url, tool: tool)
    try store.appendLogEvents(batch.events, evidence: batch.evidence, position: batch.position)
    try work { try self.task.observe(batch.events, position: batch.position) }
    return batch
  }
  private func ownershipReopen() throws {
    task = nil; store = nil
    store = try ActivityStorage(url: root.appendingPathComponent("invented.sqlite"), appDataDirectory: root,
      databaseScope: .directory(root))
    task = GitCollectionTask(storage: store, secureInput: { false }, scratchDirectory: root)
  }

  func testChangingSessionGitOwnershipPreservesForeignRepositoryAllRolesBothOrders() throws {
    try commit()
    let ownedRepo = root.appendingPathComponent("invented-owned-repo")
    try FileManager.default.createDirectory(at: ownedRepo, withIntermediateDirectories: true)
    try git(["init", "-b", "main"], in: ownedRepo)
    try commit("Invented owned change", in: ownedRepo)
    func json(_ object: [String: Any]) throws -> String {
      String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }
    func metadata(_ tool: AgentLogTool, _ session: String, _ folder: URL) throws -> String {
      try json(tool == .claude ? ["type": "system", "timestamp": now - 10, "sessionId": session, "cwd": folder.path]
        : ["type": "session_meta", "timestamp": now - 10, "payload": ["id": session, "cwd": folder.path]])
    }
    func record(_ tool: AgentLogTool, _ role: String, _ id: String, session: String) throws -> String {
      let stamp = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(now - 10)))
      if tool == .claude {
        return try json(["type": role, "timestamp": stamp, "uuid": id,
          "message": ["role": role, "content": "Invented Git ownership instruction"]])
      }
      return try json(["type": "event_msg", "timestamp": stamp, "payload": ["type": "item_completed",
        "thread_id": session, "turn_id": "invented-turn", "item": ["type": role == "user" ? "UserMessage" : "InventedRecord",
          "role": role, "id": id, "content": [["type": "text", "text": "Invented Git ownership instruction"]]]]])
    }
    func write(_ lines: [String], to url: URL) throws { try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url) }
    for tool in AgentLogTool.allCases {
      for role in ["user", "assistant", "tool", "system"] {
        for ownFirst in [false, true] {
          let tag = "invented-git-changing-\(tool)-\(role)-\(ownFirst)"
          let a = tag + "-A", b = tag + "-B"
          let foreign = root.appendingPathComponent(tag + "-foreign.jsonl")
          let own = root.appendingPathComponent(tag + "-own.jsonl")
          let copy = root.appendingPathComponent(tag + "-copy.jsonl")
          try write([metadata(tool, a, repo), record(tool, "user", tag + "-foreign", session: a)], to: foreign)
          try write([metadata(tool, a, ownedRepo), record(tool, role, tag + "-own", session: a)], to: own)
          for url in ownFirst ? [own, foreign] : [foreign, own] { _ = try ownershipImport(url, tool: tool) }
          try write([metadata(tool, b, ownedRepo), record(tool, role, tag + "-copy", session: b)], to: copy)
          _ = try ownershipImport(copy, tool: tool)
          try scan()
          let repoID = try store.connection.integer("SELECT repo_id FROM git_working_folders WHERE source=?", [.key(AgentLogIdentity.decodedPath(foreign.path))])
          XCTAssertGreaterThan(repoID, 0)
          XCTAssertEqual(try count("git_working_folders", "source='\(AgentLogEventParser.pathIdentity(copy.path))'"), 1)
          let predicates = ["evidence": "source='\(foreign.deletingPathExtension().lastPathComponent)'",
            "agent_log_events": "source='\(AgentLogEventParser.pathIdentity(foreign.path))'",
            "agent_log_payloads": "id IN (SELECT payload_id FROM agent_log_events WHERE source='\(AgentLogEventParser.pathIdentity(foreign.path))')",
            "log_positions": "path='\(AgentLogEventParser.pathIdentity(foreign.path))'", "git_working_folders": "source='\(AgentLogEventParser.pathIdentity(foreign.path))'",
            "git_repositories": "id=\(repoID)", "git_commits": "repo_id=\(repoID)", "git_refs": "repo_id=\(repoID)",
            "git_files": "commit_id IN (SELECT id FROM git_commits WHERE repo_id=\(repoID))",
            "git_commit_refs": "commit_id IN (SELECT id FROM git_commits WHERE repo_id=\(repoID))"]
          var snapshots: [String: [String]] = [:]
          for (table, predicate) in predicates { snapshots[table] = try ownershipSnapshot(table, where: predicate) }
          XCTAssertFalse(snapshots["evidence"]!.isEmpty)
          XCTAssertFalse(snapshots["git_commits"]!.isEmpty)
          let verify = {
            for (table, predicate) in predicates {
              XCTAssertEqual(try self.ownershipSnapshot(table, where: predicate), snapshots[table], "\(tag) \(table)")
            }
          }
          try ownershipReopen()
          let handle = try FileHandle(forWritingTo: own)
          try handle.seekToEnd()
          try handle.write(contentsOf: Data((try metadata(tool, b, ownedRepo) + "\n" + json(["type": "system",
            "cwd": "/invented/" + AgentWindowIdentity.relativeFolder]) + "\n" + record(tool, role, tag + "-late", session: b) + "\n").utf8))
          try handle.close()
          let discovering = try ownershipRead(own, tool: tool)
          let state = try AgentLogState.decode(discovering.position.state)
          XCTAssertEqual(state.session?.storedKey, a); XCTAssertEqual(state.ownershipSession?.storedKey, b); XCTAssertEqual(state.ownedSession?.storedKey, b)
          XCTAssertTrue(discovering.events.isEmpty)
          let registry = store.ownLogSources()
          XCTAssertFalse(try registry.containsSession(a, tool: tool))
          try FileManager.default.removeItem(at: root.appendingPathComponent(AgentLogOwnSources.folderName))
          let folder = GitWorkingFolder(folder: ownedRepo.path, session: a, source: own.path,
            device: discovering.position.device, inode: discovering.position.inode, time: now - 10, tool: tool)
          let links = try ownershipSnapshot("git_working_folders")
          let commits = try ownershipSnapshot("git_commits")
          try store.connection.run("CREATE TRIGGER invented_git_changing_abort BEFORE INSERT ON log_positions BEGIN SELECT RAISE(ABORT,'invented failure'); END")
          XCTAssertThrowsError(try store.appendLogEvents([], evidence: [], position: discovering.position))
          XCTAssertEqual(try ownershipSnapshot("git_working_folders"), links)
          XCTAssertEqual(try ownershipSnapshot("git_commits"), commits)
          XCTAssertEqual(try count("agent_log_revoked_sessions", "session_id IN ('\(a)','\(b)')"), 0)
          try verify()
          try store.connection.run("DROP TRIGGER invented_git_changing_abort")
          try ownershipReopen()
          XCTAssertFalse(try store.validateGitObservation(folder, now: now, position: discovering.position))
          try store.appendLogEvents([], evidence: [], position: discovering.position)
          try verify()
          XCTAssertEqual(try count("git_working_folders", "source IN ('\(AgentLogEventParser.pathIdentity(own.path))','\(AgentLogEventParser.pathIdentity(copy.path))') OR session='\(b)'"), 0)
          XCTAssertEqual(try count("agent_log_events", "source IN ('\(AgentLogEventParser.pathIdentity(own.path))','\(AgentLogEventParser.pathIdentity(copy.path))') OR session_id='\(b)'"), 0)
          XCTAssertEqual(try count("agent_log_revoked_sessions", "session_id='\(a)'"), 0)
          XCTAssertEqual(try count("agent_log_revoked_sessions", "session_id='\(b)' AND tool='\(tool.rawValue)'"), 1)
          try ownershipReopen()
          try FileManager.default.removeItem(at: root.appendingPathComponent(AgentLogOwnSources.folderName))
          // Saved positive attribution and the physical receipt must not spread to A either.
          XCTAssertFalse(try store.validateGitObservation(folder, now: now))
          try verify()
          let future = root.appendingPathComponent(tag + "-future.jsonl")
          try write([metadata(tool, a, repo), record(tool, "user", tag + "-future", session: a)], to: future)
          _ = try ownershipImport(future, tool: tool)
          XCTAssertEqual(try count("git_working_folders", "source='\(AgentLogEventParser.pathIdentity(future.path))'"), 1)
          let blocked = GitWorkingFolder(folder: ownedRepo.path, session: b, source: tag + "-blocked", device: 9, inode: 99,
            time: now - 10, tool: tool)
          XCTAssertFalse(try store.validateGitObservation(blocked, now: now))
          XCTAssertFalse(try registry.containsSession(a, tool: tool))
          try verify()
        }
      }
    }
  }

  func testGitPhysicalExclusionAndNamedReceiptsNeverPromoteOtherCheckpointSessions() throws {
    try commit()
    for tool in AgentLogTool.allCases {
      for proof in ["path", "physical", "marker", "positive", "launch", "completed"] {
        for saved in [false, true] {
          let tag = "invented-git-scoped-\(tool)-\(proof)-\(saved)"
          let a = tag + "-A", b = tag + "-B"
          let foreign = GitWorkingFolder(folder: repo.path, session: a, source: tag + "-foreign",
            device: 7, inode: 88, time: now - 10, tool: tool)
          try work { try self.task.observe(foreign, now: self.now) }
          let links = try ownershipSnapshot("git_working_folders", where: "source='\(AgentLogEventParser.pathIdentity(foreign.source))'")
          var state = AgentLogState(); state.tool = tool.rawValue; state.session = AgentLogIdentity.decoded(a).session.subject; state.ownershipSession = AgentLogIdentity.decoded(b).session.subject
          state.project = repo.path
          if proof == "marker" { state.ownWorkingFolder = true }
          if proof == "positive" { state.ownedSession = AgentLogIdentity.decoded(b).session.subject }
          let position = LogPosition(path: root.appendingPathComponent(tag).path, device: 7, inode: 99,
            offset: 100, state: try state.encoded(), seenAt: now)
          if saved { try store.saveLogPosition(position) }
          if proof == "path" { try store.ownLogSources().registerPath(URL(fileURLWithPath: position.path), tool: tool) }
          if proof == "physical" { try store.connection.run("INSERT INTO agent_log_tool_own_sources VALUES(?,?,?,?)", [.key(tool.rawValue), .integer(7), .integer(99), .key(position.path)]) }
          if proof == "launch" { try store.ownLogSources().registerSession(b, tool: tool) }
          if proof == "completed" { try store.purgeOwnLogSession(b, tool: tool) }
          let folder = GitWorkingFolder(folder: repo.path, session: a, source: position.path, device: 7, inode: 99,
            time: now - 10, tool: tool)
          XCTAssertFalse(try store.validateGitObservation(folder, now: now, position: saved ? nil : position), tag)
          XCTAssertEqual(try ownershipSnapshot("git_working_folders", where: "source='\(AgentLogEventParser.pathIdentity(foreign.source))'"), links, tag)
          XCTAssertEqual(try count("agent_log_revoked_sessions", "session_id='\(a)'"), 0, tag)
          XCTAssertFalse(try store.ownLogSources().containsSession(a, tool: tool), tag)
          if ["path", "physical", "marker"].contains(proof) {
            XCTAssertEqual(try count("agent_log_revoked_sessions", "session_id='\(b)'"), 0, tag)
          } else {
            XCTAssertEqual(try count("agent_log_revoked_sessions", "session_id='\(b)' AND tool='\(tool.rawValue)'"), 1, tag)
          }
        }
      }
    }
  }

  private func explicitGitRecord(_ tool: AgentLogTool, role: String, session: String, folder: URL,
    id: String, marker: Bool = false) throws -> String {
    var line: [String: Any]
    if tool == .claude {
      line = ["type": role, "sessionId": session, "cwd": folder.path, "timestamp": now - 10,
        "uuid": id, "message": ["role": role, "content": "Invented explicit attribution"]]
      if marker { line["originator"] = AgentWindowIdentity.codexOriginator }
    } else {
      var item: [String: Any] = ["type": role == "user" ? "UserMessage" : "InventedRecord",
        "role": role, "id": id, "content": [["type": "text", "text": "Invented explicit attribution"]]]
      if marker { item["originator"] = AgentWindowIdentity.codexOriginator }
      line = ["type": "event_msg", "timestamp": now - 10, "payload": ["cwd": folder.path,
        "thread_id": session, "type": "item_completed", "turn_id": "invented-turn", "item": item]]
    }
    return String(decoding: try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]), as: UTF8.self) + "\n"
  }

  func testExplicitRecordGitOwnershipAllRolesBothToolsBothOrdersAndAbortRetry() throws {
    try commit()
    let ownedRepo = root.appendingPathComponent("invented-explicit-repo")
    try FileManager.default.createDirectory(at: ownedRepo, withIntermediateDirectories: true)
    try git(["init", "-b", "main"], in: ownedRepo)
    try commit("Invented explicit owned commit", in: ownedRepo)
    for tool in AgentLogTool.allCases {
      for role in ["user", "assistant", "tool", "system"] {
        for ownFirst in [false, true] {
          let tag = "invented-explicit-\(tool)-\(role)-\(ownFirst)"
          let a = tag + "-foreign", b = tag + "-owned"
          let foreign = root.appendingPathComponent(tag + "-foreign.jsonl")
          let copy = root.appendingPathComponent(tag + "-copy.jsonl")
          let marker = root.appendingPathComponent(tag + "-marker.jsonl")
          try Data(explicitGitRecord(tool, role: "user", session: a, folder: repo, id: a).utf8).write(to: foreign)
          _ = try ownershipImport(foreign, tool: tool)
          try scan()
          let repoID = try store.connection.integer("SELECT repo_id FROM git_working_folders WHERE source=?", [.key(AgentLogIdentity.decodedPath(foreign.path))])
          let predicates = ["agent_log_events": "source='\(AgentLogEventParser.pathIdentity(foreign.path))'", "log_positions": "path='\(AgentLogEventParser.pathIdentity(foreign.path))'",
            "evidence": "source='\(foreign.deletingPathExtension().lastPathComponent)'",
            "agent_log_payloads": "id IN (SELECT payload_id FROM agent_log_events WHERE source='\(AgentLogEventParser.pathIdentity(foreign.path))')",
            "git_working_folders": "source='\(AgentLogEventParser.pathIdentity(foreign.path))'", "git_repositories": "id=\(repoID)",
            "git_commits": "repo_id=\(repoID)", "git_refs": "repo_id=\(repoID)",
            "git_files": "commit_id IN (SELECT id FROM git_commits WHERE repo_id=\(repoID))",
            "git_commit_refs": "commit_id IN (SELECT id FROM git_commits WHERE repo_id=\(repoID))"]
          var snapshots: [String: [String]] = [:]
          for (table, predicate) in predicates { snapshots[table] = try ownershipSnapshot(table, where: predicate) }
          try Data(explicitGitRecord(tool, role: role, session: b, folder: ownedRepo, id: b).utf8).write(to: copy)
          let prepared = try ownershipRead(copy, tool: tool)
          XCTAssertEqual(prepared.events.first?.explicitSession?.storedKey, b)
          if tool == .codex { XCTAssertNil(prepared.events.first?.session) }
          if !ownFirst {
            _ = try ownershipImport(copy, tool: tool)
            XCTAssertEqual(try count("git_working_folders", "source='\(AgentLogEventParser.pathIdentity(copy.path))' AND session='\(b)'"), 1)
          }
          try ownershipReopen()
          let foreignHeader: [String: Any] = tool == .claude
            ? ["type": "system", "sessionId": a]
            : ["type": "session_meta", "payload": ["id": a]]
          let prefix = String(decoding: try JSONSerialization.data(withJSONObject: foreignHeader), as: UTF8.self) + "\n"
          try Data((prefix + explicitGitRecord(tool, role: role, session: b, folder: ownedRepo, id: tag, marker: true)).utf8).write(to: marker)
          let discovering = try ownershipRead(marker, tool: tool)
          XCTAssertEqual(try AgentLogState.decode(discovering.position.state).ownedSession?.storedKey, b)
          try store.connection.run("CREATE TRIGGER invented_explicit_abort BEFORE INSERT ON log_positions BEGIN SELECT RAISE(ABORT,'invented failure'); END")
          XCTAssertThrowsError(try store.appendLogEvents(discovering.events, evidence: discovering.evidence, position: discovering.position))
          XCTAssertEqual(try count("agent_log_revoked_sessions", "session_id='\(b)'"), 0)
          if !ownFirst { XCTAssertEqual(try count("git_working_folders", "source='\(AgentLogEventParser.pathIdentity(copy.path))'"), 1) }
          try store.connection.run("DROP TRIGGER invented_explicit_abort")
          try store.appendLogEvents(discovering.events, evidence: discovering.evidence, position: discovering.position)
          try ownershipReopen()
          try FileManager.default.removeItem(at: root.appendingPathComponent(AgentLogOwnSources.folderName))
          // Completed database receipts must reject both saved and stale prepared event-only links.
          try store.appendLogEvents(prepared.events, evidence: prepared.evidence, position: prepared.position)
          try work { try self.task.observe(prepared.events, position: prepared.position) }
          _ = try ownershipImport(copy, tool: tool)
          XCTAssertEqual(try count("git_working_folders", "source='\(AgentLogEventParser.pathIdentity(copy.path))'"), 0)
          XCTAssertEqual(try count("agent_log_events", "source='\(AgentLogEventParser.pathIdentity(copy.path))'"), 0)
          XCTAssertEqual(try count("agent_log_revoked_sessions", "session_id='\(a)'"), 0)
          for (table, predicate) in predicates {
            XCTAssertEqual(try ownershipSnapshot(table, where: predicate), snapshots[table], "\(tag) \(table)")
          }
        }
      }
    }
  }

  func testExplicitRecordGitPreparedFilesystemAndCompletedReceiptsBothToolsAllRoles() throws {
    try commit()
    for tool in AgentLogTool.allCases {
      for role in ["user", "assistant", "tool", "system"] {
        for database in [false, true] {
          let tag = "invented-prepared-\(tool)-\(role)-\(database)"
          let url = root.appendingPathComponent(tag + ".jsonl")
          try Data(explicitGitRecord(tool, role: role, session: tag, folder: repo, id: tag).utf8).write(to: url)
          let batch = try ownershipRead(url, tool: tool)
          if database { try store.purgeOwnLogSession(tag, tool: tool) }
          else { try store.ownLogSources().registerSession(tag, tool: tool) }
          try work { try self.task.observe(batch.events, position: batch.position) }
          XCTAssertEqual(try count("git_working_folders", "source='\(AgentLogEventParser.pathIdentity(url.path))'"), 0)
          _ = try ownershipImport(url, tool: tool)
          XCTAssertEqual(try count("git_working_folders", "source='\(AgentLogEventParser.pathIdentity(url.path))'"), 0)
        }
      }
    }
  }

  func testGitToolScopedPhysicalAndLegacyCheckpointOwnershipBothDirections() throws {
    try commit()
    for tool in AgentLogTool.allCases {
      let other: AgentLogTool = tool == .claude ? .codex : .claude
      for legacy in [false, true] {
        let tag = "invented-boundary-\(tool)-\(legacy)"
        let url = root.appendingPathComponent(tag + ".jsonl")
        try Data(explicitGitRecord(tool, role: "user", session: tag, folder: repo, id: tag).utf8).write(to: url)
        let batch = try ownershipImport(url, tool: tool)
        try scan()
        let links = try ownershipSnapshot("git_working_folders", where: "source='\(AgentLogEventParser.pathIdentity(url.path))'")
        let events = try ownershipSnapshot("agent_log_events", where: "source='\(AgentLogEventParser.pathIdentity(url.path))'")
        if legacy {
          try store.connection.run("UPDATE log_positions SET state=json_remove(state,'$.tool','$.ownershipSession','$.ownedSession') WHERE path=?", [.key(AgentLogIdentity.decodedPath(url.path))])
        }
        try store.ownLogSources().registerSession(tag, tool: other)
        try ownershipReopen()
        // A missing checkpoint namespace and the other tool's receipt cannot own this link.
        let original = GitWorkingFolder(folder: repo.path, session: tag, source: url.path,
          device: batch.position.device, inode: batch.position.inode, time: now - 10, tool: tool)
        XCTAssertTrue(try store.validateGitObservation(original, now: now))
        let switched = try ownershipRead(url, tool: other)
        XCTAssertEqual(switched.position.offset, batch.position.offset)
        try store.appendLogEvents(switched.events, evidence: switched.evidence, position: switched.position)
        XCTAssertEqual(try ownershipSnapshot("git_working_folders", where: "source='\(AgentLogEventParser.pathIdentity(url.path))'"), links)
        XCTAssertEqual(try ownershipSnapshot("agent_log_events", where: "source='\(AgentLogEventParser.pathIdentity(url.path))'"), events)
        let prepared = GitWorkingFolder(folder: repo.path, session: "invented-independent", source: url.path,
          device: batch.position.device, inode: batch.position.inode, time: now - 10, tool: other)
        try store.ownLogSources().registerPath(url, tool: other)
        XCTAssertFalse(try store.validateGitObservation(prepared, now: now))
        XCTAssertTrue(try store.validateGitObservation(original, now: now))
        try ownershipReopen()
        XCTAssertTrue(try store.validateGitObservation(original, now: now))
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(explicitGitRecord(tool, role: "user", session: tag, folder: repo, id: tag + "-later").utf8))
        try handle.close()
        let appended = try ownershipImport(url, tool: tool)
        XCTAssertGreaterThan(appended.position.offset, batch.position.offset)
        XCTAssertEqual(appended.events.count, 1)
        XCTAssertEqual(try AgentLogState.decode(XCTUnwrap(store.logPosition(path: url.path)).state).cwdObservedAt, now - 10)
        XCTAssertEqual(try count("agent_log_events", "source='\(AgentLogEventParser.pathIdentity(url.path))' AND tool='\(tool.rawValue)'"), 2)
        // A repeated completed purge in the other namespace still leaves original-tool links intact.
        try store.purgeOwnLogSession(tag, tool: other)
        XCTAssertTrue(try store.validateGitObservation(original, now: now))
        XCTAssertEqual(try count("git_working_folders", "source='\(AgentLogEventParser.pathIdentity(url.path))' AND tool='\(tool.rawValue)'"), links.count)
      }
    }
  }

  func testExplicitGitBackfillKeepsRecordThreadAndForgetDiscoveryTombstone() throws {
    try commit()
    for tool in AgentLogTool.allCases {
      let tag = "invented-backfill-explicit-\(tool)"
      let url = root.appendingPathComponent(tag + ".jsonl")
      let database = root.appendingPathComponent(tag + ".sqlite")
      task = nil; store = nil
      store = try ActivityStorage(url: database, appDataDirectory: root, databaseScope: .directory(root))
      try store.saveSettings(StorageSettings(), at: 0)
      task = GitCollectionTask(storage: store, secureInput: { false }, scratchDirectory: root)
      let header: [String: Any] = tool == .claude
        ? ["type": "system", "sessionId": tag + "-header"]
        : ["type": "session_meta", "payload": ["id": tag + "-header"]]
      let prefix = String(decoding: try JSONSerialization.data(withJSONObject: header), as: UTF8.self) + "\n"
      try Data((prefix + explicitGitRecord(tool, role: "user", session: tag, folder: repo, id: tag)).utf8).write(to: url)
      let batch = try ownershipRead(url, tool: tool)
      try store.appendLogEvents(batch.events, evidence: batch.evidence, position: batch.position)
      var cursor = 0
      var found: GitWorkingFolder?
      while let (id, folder) = try store.nextGitBackfill(after: cursor, checkpoints: false, now: now) {
        cursor = id
        if folder.physicalSource == AgentLogIdentity.decodedPath(url.path) && !folder.folder.isEmpty { found = folder }
      }
      let folder = try XCTUnwrap(found)
      XCTAssertEqual(folder.session, tag)
      try work { try self.task.observe(folder, now: self.now, fromStored: true) }
      let range = TimeRange(now - 11, now - 9)
      let preview = try store.previewDeletion(in: range)
      try store.deleteRecords(in: range, confirmation: preview.confirmation)
      task = nil; store = nil
      store = try ActivityStorage(url: database, appDataDirectory: root, databaseScope: .directory(root))
      task = GitCollectionTask(storage: store, secureInput: { false }, scratchDirectory: root)
      XCTAssertFalse(try store.validateGitObservation(folder, now: now))
      XCTAssertEqual(try count("git_working_folders", "source='\(AgentLogEventParser.pathIdentity(url.path))'"), 0)
    }
  }

  func testUnscopedGitOwnershipCannotBorrowEitherNamespaceReceiptOrLegacyPhysicalFact() throws {
    try commit()
    let tag = "invented-unscoped-git"
    let session = tag + "-session"
    let folder = GitWorkingFolder(folder: repo.path, session: session, source: tag, device: 7, inode: 12, time: now - 10)
    try work { try self.task.observe(folder, now: self.now) }
    XCTAssertEqual(try count("git_working_folders", "source='\(AgentLogEventParser.pathIdentity(tag))'"), 0)
    var qualified = folder; qualified.tool = .claude
    try work { try self.task.observe(qualified, now: self.now) }
    // Model an existing legacy link whose namespace was never recorded.
    try store.connection.run("UPDATE git_working_folders SET tool='' WHERE source=?", [.key(AgentLogIdentity.decodedPath(tag))])
    var state = AgentLogState(); state.session = AgentLogIdentity.decoded(session).session.subject; state.ownedSession = AgentLogIdentity.decoded(session).session.subject; state.ownWorkingFolder = true
    try store.saveLogPosition(LogPosition(path: tag, device: 7, inode: 12, offset: 100, state: try state.encoded(), seenAt: now))
    try store.connection.run("INSERT INTO agent_log_own_sources VALUES(7,12,?)", [.key(tag)])
    for tool in AgentLogTool.allCases {
      try store.ownLogSources().registerSession(session, tool: tool)
      try store.purgeOwnLogSession(session, tool: tool)
    }
    XCTAssertFalse(try store.validateGitObservation(folder, now: now))
    XCTAssertEqual(try count("git_working_folders", "source='\(AgentLogEventParser.pathIdentity(tag))'"), 1)
    try ownershipReopen()
    XCTAssertEqual(try count("git_working_folders", "source='\(AgentLogEventParser.pathIdentity(tag))' AND tool=''"), 1)
    for tool in AgentLogTool.allCases {
      let typed = GitWorkingFolder(folder: repo.path, session: "invented-independent", source: tag,
        device: 7, inode: 12, time: now - 10, tool: tool)
      XCTAssertTrue(try store.validateGitObservation(typed, now: now))
    }
  }

  func testLegacyNamespaceRecoveryDoesNotRefreshTimestampFreeCwdDiscovery() throws {
    try commit()
    for tool in AgentLogTool.allCases {
      let tag = "invented-recovered-cwd-\(tool)"
      let url = root.appendingPathComponent(tag + ".jsonl")
      let metadata: [String: Any] = tool == .claude
        ? ["type": "system", "sessionId": tag, "cwd": repo.path]
        : ["type": "session_meta", "payload": ["id": tag, "cwd": repo.path]]
      let data = try JSONSerialization.data(withJSONObject: metadata) + Data("\n".utf8)
      try data.write(to: url)
      let file = try XCTUnwrap(AgentLogFiles.listing([root.path]).files.first { $0.path == url.path })
      var state = AgentLogState(); state.project = repo.path; state.session = AgentLogIdentity.decoded(tag).session.subject; state.cwdObservedAt = now - 1000
      let position = LogPosition(path: url.path, device: file.device, inode: file.inode, offset: data.count,
        state: try state.encoded(), seenAt: now)
      try store.saveLogPosition(position)
      let batch = try ownershipRead(url, tool: tool)
      XCTAssertEqual(batch.position.offset, data.count)
      XCTAssertTrue(batch.events.isEmpty)
      XCTAssertNil(try AgentLogState.decode(batch.position.state).cwdObservedAt)
      try store.appendLogEvents([], evidence: [], position: batch.position)
      let range = TimeRange(now - 1001, now - 999)
      let preview = try store.previewDeletion(in: range)
      try store.deleteRecords(in: range, confirmation: preview.confirmation)
      let folder = GitWorkingFolder(folder: repo.path, session: tag, source: url.path,
        device: file.device, inode: file.inode, time: now - 1000, tool: tool)
      XCTAssertFalse(try store.validateGitObservation(folder, now: now))
      try ownershipReopen()
      XCTAssertFalse(try store.validateGitObservation(folder, now: now))
    }
  }

  func testGitLegacyMixedToolProvenanceCannotBorrowCurrentCheckpointNamespace() throws {
    try commit()
    for current in AgentLogTool.allCases {
      let original: AgentLogTool = current == .claude ? .codex : .claude
      let tag = "invented-mixed-legacy-\(current)"
      let source = root.appendingPathComponent(tag + ".jsonl").path
      for tool in [original, current] {
        var state = AgentLogState(); state.tool = tool.rawValue
        let data = Data(try explicitGitRecord(tool, role: "assistant", session: tag, folder: repo, id: tag).utf8)
        let event = try XCTUnwrap(AgentLogEventParser.parse(data, byteCount: data.count, offset: 0, observedAt: now,
          tool: tool, file: source, state: &state, logsRelativePath: nil, fingerprint: { _ in "invented" }))
        try store.appendLogEvents([event], evidence: [], position: LogPosition(path: source, device: 7, inode: 22,
          offset: data.count, state: try state.encoded(), seenAt: now))
      }
      let folder = GitWorkingFolder(folder: repo.path, session: tag, source: source,
        device: 7, inode: 22, time: now - 10, tool: original)
      try work { try self.task.observe(folder, now: self.now) }
      try store.connection.run("UPDATE git_working_folders SET tool='' WHERE source=?", [.key(AgentLogIdentity.decodedPath(source))])
      let links = try ownershipSnapshot("git_working_folders", where: "source='\(AgentLogEventParser.pathIdentity(source))'")
      XCTAssertEqual(links.count, 1)
      try store.connection.run("INSERT INTO agent_log_revoked_sessions VALUES(?,?)", [.key(current.rawValue), .key(tag)])
      try ownershipReopen()
      XCTAssertEqual(try ownershipSnapshot("git_working_folders", where: "source='\(AgentLogEventParser.pathIdentity(source))'"), links)
      try store.purgeOwnLogSession(tag, tool: current)
      XCTAssertEqual(try ownershipSnapshot("git_working_folders", where: "source='\(AgentLogEventParser.pathIdentity(source))'"), links)
    }
  }

}

private struct GitInventedVault: FileVaultStatusSource {
  func fileVaultStatus() -> FileVaultStatus { .unknown }

}
