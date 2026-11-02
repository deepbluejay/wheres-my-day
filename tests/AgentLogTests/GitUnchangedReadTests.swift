import Core
import Foundation
import SQLite3
@testable import Inbound
@testable import Shell
@testable import Storage
import XCTest

/// A repository whose files and policy did not change is not read again. Each test first
/// shows a skip happens, so none passes only because nothing was ever skipped.
extension GitCollectionTests {
  /// Past a change of the retention cutoff's day, so these tests have most of a day without one.
  private var start: Int { (now / 86400 + 1) * 86400 + 1 }
  private func settled() throws {
    try scan(start)
    try assertSkipped(at: start + 300)
  }
  private func assertSkipped(at time: Int, _ line: UInt = #line) throws {
    let skips = task.historySkips, reads = task.historyReads
    try scan(time)
    XCTAssertEqual(task.historyReads - reads, 0, "a read ran", line: line)
    XCTAssertEqual(task.historySkips - skips, 1, "no skip", line: line)
  }
  private func assertRead(at time: Int, _ line: UInt = #line) throws {
    let reads = task.historyReads
    try scan(time)
    XCTAssertEqual(task.historyReads - reads, 1, "no read ran", line: line)
  }
  private func commitIsStored(_ hash: String) throws -> Bool { try count("git_commits", "hash='\(hash)' AND complete=1") == 1 }
  private func frontierTips() throws -> [String] {
    var tips: [String] = []
    try store.connection.namedRows("SELECT r.tip FROM git_refs r JOIN git_repositories p ON p.id=r.repo_id AND r.frontier=p.frontier ORDER BY r.tip") { tips.append(try $0.text("tip")) }
    return tips
  }
  private func gitTips() throws -> [String] {
    var tips = try git(["for-each-ref", "--format=%(objectname)"]).split(separator: "\n").map(String.init)
    for line in try git(["worktree", "list", "--porcelain"]).split(separator: "\n") where line.hasPrefix("HEAD ") { tips.append(String(line.dropFirst(5))) }
    return tips.sorted()
  }
  private func scalarText(_ sql: String) throws -> String {
    var value = ""
    try store.connection.rows(sql) { value = SQLiteConnection.text($0, 0) }
    return value
  }
  private func fingerprint() throws -> String { try scalarText("SELECT fingerprint FROM git_read_fingerprints") }
  private func unchanged(_ repo: Int = 1, at time: Int) throws -> Bool {
    try work { try self.store.gitReadUnchanged(repo: repo, fingerprint: self.fingerprint(), now: time) }
  }
  private func snapshot() throws -> [String] {
    var rows: [String] = []
    for table in ["git_refs", "git_repositories", "git_commits", "git_read_fingerprints", "git_working_folders", "git_tombstones"] {
      try store.connection.rows("SELECT * FROM \(table)") { statement in
        rows.append(table + ":" + (0..<sqlite3_column_count(statement)).map { SQLiteConnection.text(statement, $0) }.joined(separator: "|"))
      }
    }
    return rows
  }

  // MARK: The run itself

  func testUnchangedRepositoryStartsNoGitChildAndWritesNothing() throws {
    try commit(); try observe(); try settled()
    let launches = task.reader.launches, publishes = store.gitPublishCalls, before = try snapshot()
    let revision = try store.connection.integer("SELECT value FROM git_privacy_revision")
    let scratch = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("activityprobe-git-task") }
    try assertSkipped(at: start + 600)
    XCTAssertEqual(task.reader.launches, launches)
    XCTAssertEqual(store.gitPublishCalls, publishes)
    XCTAssertEqual(try snapshot(), before)
    XCTAssertEqual(try store.connection.integer("SELECT value FROM git_privacy_revision"), revision)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("activityprobe-git-task") }, scratch)
  }

  // MARK: No commit lost

  func testNewCommitIsReadOnTheNextRun() throws {
    try commit(); try observe(); try settled()
    let hash = try commit("Invented new", file: "new.txt", author: start)
    try assertRead(at: start + 600)
    XCTAssertTrue(try commitIsStored(hash))
    XCTAssertEqual(try frontierTips(), try gitTips())
    try assertSkipped(at: start + 900)
  }
  func testNewCommitByAnyAuthorIsRead() throws {
    try commit(); try observe(); try settled()
    try Data("x".utf8).write(to: repo.appendingPathComponent("agent.txt"))
    try git(["add", "--", "agent.txt"])
    try git(["commit", "-m", "Invented agent change"], author: start, name: "Invented Agent", email: "agent@example.test")
    let hash = try git(["rev-parse", "HEAD"])
    try assertRead(at: start + 600)
    XCTAssertTrue(try commitIsStored(hash))
  }
  func testForcePushIsRead() throws {
    let first = try commit(); try commit("Invented second", file: "second.txt"); try observe(); try settled()
    try git(["reset", "--hard", first])
    let hash = try commit("Invented rewritten", file: "rewritten.txt", author: start)
    try assertRead(at: start + 600)
    XCTAssertTrue(try commitIsStored(hash))
    XCTAssertEqual(try frontierTips(), try gitTips())
  }
  func testDeletedRefIsRead() throws {
    try commit(); try git(["branch", "invented-gone"]); try observe(); try settled()
    let before = try frontierTips().count
    try git(["update-ref", "-d", "refs/heads/invented-gone"])
    try assertRead(at: start + 600)
    XCTAssertEqual(try frontierTips().count, before - 1)
    try assertSkipped(at: start + 900)
  }
  func testRefMovedBackAndForthIsReadEachTime() throws {
    let first = try commit(); let second = try commit("Invented second", file: "second.txt")
    try observe(); try settled()
    try git(["update-ref", "refs/heads/main", first])
    try assertRead(at: start + 600)
    XCTAssertEqual(try frontierTips(), try gitTips())
    try git(["update-ref", "refs/heads/main", second])
    try assertRead(at: start + 900)
    XCTAssertEqual(try frontierTips(), try gitTips())
    // Away and back between two runs ends where it began, and is still looked at.
    let token = try scalarText("SELECT frontier FROM git_repositories")
    try git(["update-ref", "refs/heads/main", first]); try git(["update-ref", "refs/heads/main", second])
    try assertRead(at: start + 1200)
    XCTAssertEqual(try scalarText("SELECT frontier FROM git_repositories"), token)
  }
  /// A fetch that moves a remote ref already there: only that ref's file changes, deep under refs/.
  func testFetchIsRead() throws {
    try commit()
    let other = root.appendingPathComponent("invented-upstream")
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    try git(["init", "-b", "main"], in: other)
    try commit("Invented upstream", in: other)
    try git(["fetch", other.path, "main:refs/remotes/invented/main"])
    try observe(); try settled()
    let upstream = try commit("Invented upstream second", file: "upstream.txt", in: other)
    try git(["fetch", other.path, "main:refs/remotes/invented/main"])
    try assertRead(at: start + 600)
    XCTAssertTrue(try commitIsStored(upstream))
    // A fetch that brings nothing writes no ref, and costs no read.
    try git(["fetch", other.path, "main:refs/remotes/invented/main"])
    try assertSkipped(at: start + 900)
  }
  func testNewWorktreeIsRead() throws {
    try commit(); try observe(); try settled()
    let tree = root.appendingPathComponent("invented-worktree")
    try git(["worktree", "add", "--detach", tree.path])
    try assertRead(at: start + 600)
    XCTAssertEqual(try frontierTips(), try gitTips())
    try assertSkipped(at: start + 900)
  }
  /// A detached commit in a worktree moves no file under refs/: only that worktree's HEAD.
  func testCommitOnADetachedWorktreeHeadIsRead() throws {
    try commit()
    let tree = root.appendingPathComponent("invented-worktree")
    try git(["worktree", "add", "--detach", tree.path])
    try observe(); try settled()
    let hash = try commit("Invented detached", file: "detached.txt", author: start, in: tree)
    try assertRead(at: start + 600)
    XCTAssertTrue(try commitIsStored(hash))
  }
  /// Under reftable a linked worktree's HEAD lives in worktrees/<id>/reftable, and no HEAD file
  /// moves. Leaving the commit for a branch that exists moves nothing else either.
  func testCommitOnADetachedReftableWorktreeHeadIsReadBeforeItIsLeft() throws {
    try FileManager.default.removeItem(at: repo.appendingPathComponent(".git"))
    try git(["init", "-b", "main", "--ref-format=reftable"])
    try commit(); try git(["branch", "invented-other"])
    let tree = root.appendingPathComponent("invented-worktree")
    try git(["worktree", "add", "--detach", tree.path])
    try observe(); try settled()
    let hash = try commit("Invented detached", file: "detached.txt", author: start, in: tree)
    try assertRead(at: start + 600)
    XCTAssertTrue(try commitIsStored(hash))
    try git(["checkout", "invented-other"], in: tree)
    try assertRead(at: start + 900)
    XCTAssertTrue(try commitIsStored(hash))
    try assertSkipped(at: start + 1200)
  }
  /// A moved worktree changes only its gitdir file; a lock only its locked file.
  func testMovedOrLockedWorktreeIsRead() throws {
    try commit()
    let tree = root.appendingPathComponent("invented-worktree")
    try git(["worktree", "add", "--detach", tree.path])
    try observe(); try settled()
    try git(["worktree", "move", tree.path, root.appendingPathComponent("invented-moved").path])
    try assertRead(at: start + 600)
    try assertSkipped(at: start + 900)
    try git(["worktree", "lock", root.appendingPathComponent("invented-moved").path])
    try assertRead(at: start + 1200)
    try assertSkipped(at: start + 1500)
  }
  /// A detached commit in the main worktree moves only the common directory's HEAD.
  func testCommitOnADetachedMainHeadIsRead() throws {
    try commit(); try git(["checkout", "--detach"]); try observe(); try settled()
    let hash = try commit("Invented detached", file: "detached.txt", author: start)
    try assertRead(at: start + 600)
    XCTAssertTrue(try commitIsStored(hash))
  }
  func testRebaseIsRead() throws {
    try commit()
    try git(["checkout", "-b", "invented-topic"])
    try commit("Invented topic", file: "topic.txt")
    try git(["checkout", "main"])
    try commit("Invented main", file: "main.txt")
    try git(["checkout", "invented-topic"])
    try observe(); try settled()
    try git(["rebase", "main"])
    let hash = try git(["rev-parse", "HEAD"])
    try assertRead(at: start + 600)
    XCTAssertTrue(try commitIsStored(hash))
    XCTAssertEqual(try frontierTips(), try gitTips())
  }
  func testSameRefCountWithDifferentTargetsIsRead() throws {
    let first = try commit(); try git(["branch", "invented-other"])
    let second = try commit("Invented second", file: "second.txt")
    try observe(); try settled()
    let counted = try frontierTips().count
    try git(["update-ref", "refs/heads/invented-other", second])
    try git(["update-ref", "refs/heads/main", first])
    try assertRead(at: start + 600)
    XCTAssertEqual(try frontierTips().count, counted)
    XCTAssertEqual(try frontierTips(), try gitTips())
  }
  /// Same names, same count and same file size; only the targets in packed-refs differ.
  func testPackedRefsTargetsSwappedInPlaceAreRead() throws {
    let first = try commit(); try git(["branch", "invented-other"])
    let second = try commit("Invented second", file: "second.txt")
    try git(["pack-refs", "--all"])
    try observe(); try settled()
    let file = repo.appendingPathComponent(".git/packed-refs")
    let text = try String(contentsOf: file, encoding: .utf8)
    let swapped = text.replacingOccurrences(of: first, with: "SWAP").replacingOccurrences(of: second, with: first).replacingOccurrences(of: "SWAP", with: second)
    XCTAssertEqual(swapped.utf8.count, text.utf8.count); XCTAssertNotEqual(swapped, text)
    try Data(swapped.utf8).write(to: file)
    try assertRead(at: start + 600)
    XCTAssertEqual(try frontierTips(), try gitTips())
  }
  func testPackedRefsRewriteWithNoChangeReadsOnceAndChangesNothing() throws {
    try commit(); try git(["branch", "invented-other"]); try observe(); try settled()
    let token = try scalarText("SELECT frontier FROM git_repositories"), commits = try count("git_commits")
    try git(["pack-refs", "--all"])
    try assertRead(at: start + 600)
    XCTAssertEqual(try scalarText("SELECT frontier FROM git_repositories"), token)
    XCTAssertEqual(try count("git_commits"), commits)
    try assertSkipped(at: start + 900)
    // With nothing loose left, a second pack rewrites packed-refs alone.
    try git(["pack-refs", "--all"])
    try assertRead(at: start + 1200)
    XCTAssertEqual(try scalarText("SELECT frontier FROM git_repositories"), token)
    try assertSkipped(at: start + 1500)
  }
  /// A ref moved after this read listed refs, before it finished. The digest was taken
  /// before the listing, so the next run differs and reads it.
  func testCommitMadeDuringAReadIsReadOnTheNextRun() throws {
    try commit(); try observe(); try settled()
    try commit("Invented new", file: "new.txt", author: start)
    var late = ""
    var done = false
    task.beforeMetadataRead = { [unowned self] in
      guard !done else { return }
      done = true
      late = try self.commit("Invented during the read", file: "late.txt", author: self.start)
    }
    try assertRead(at: start + 600)
    task.beforeMetadataRead = nil
    XCTAssertFalse(try commitIsStored(late))
    try assertRead(at: start + 900)
    XCTAssertTrue(try commitIsStored(late))
  }
  func testEverydayGitWorkThatMovesNoRefCostsNoRead() throws {
    try commit(); try observe(); try settled()
    try Data("x".utf8).write(to: repo.appendingPathComponent("staged.txt"))
    try git(["add", "--", "staged.txt"]); try git(["status"]); try git(["reflog"])
    try assertSkipped(at: start + 600)
  }

  // MARK: Privacy is live

  func testRecordingOffAndOnAppliesAtTheNextRun() throws {
    try commit(); try observe(); try settled()
    var off = StorageSettings(); off.recordingEnabled = false
    try store.saveSettings(off, at: start + 310)
    let before = try snapshot(), reads = task.historyReads, skips = task.historySkips
    try scan(start + 600)
    XCTAssertEqual(task.historyReads, reads); XCTAssertEqual(task.historySkips, skips)
    XCTAssertEqual(try snapshot(), before)
    try store.saveSettings(StorageSettings(), at: start + 700)
    try assertRead(at: start + 900)
  }
  func testSecureInputAllowsNoSkipAndNoRead() throws {
    try commit(); try observe(); try settled()
    store.setGitSecureInput { true }
    let reads = task.historyReads, skips = task.historySkips
    try scan(start + 600)
    XCTAssertEqual(task.historyReads, reads); XCTAssertEqual(task.historySkips, skips)
  }
  func testForgetAppliesAtTheNextRunAndNothingComesBack() throws {
    let hash = try commit("Invented forgotten", author: start - 40); try commit("Invented kept", file: "kept.txt", author: start - 20)
    try observe(); try settled()
    let range = TimeRange(start - 41, start - 39)
    let preview = try store.previewDeletion(in: range)
    try store.deleteRecords(in: range, confirmation: preview.confirmation)
    XCTAssertFalse(try commitIsStored(hash))
    try assertRead(at: start + 600)
    XCTAssertFalse(try commitIsStored(hash))
    XCTAssertEqual(try count("git_tombstones", "hash='\(hash)'"), 1)
    try assertSkipped(at: start + 900)
    XCTAssertFalse(try commitIsStored(hash))
  }
  /// A forget range holding no refs and no commit still changes what a read consults.
  func testForgetOfAnEmptyRangeStillIsReadNext() throws {
    try commit(); try observe(); try settled()
    try store.connection.run("INSERT INTO forgotten_ranges(start_ts,end_ts) VALUES(?,?)", [.integer(start - 900_000), .integer(start - 899_000)])
    try assertRead(at: start + 600)
  }
  func testRetentionChangeAppliesAtTheNextRun() throws {
    try commit(); try observe(); try settled()
    try store.saveSettings(StorageSettings(promptRetentionDays: 7), at: start + 310)
    try assertRead(at: start + 600)
    try assertSkipped(at: start + 900)
    try store.saveSettings(StorageSettings(promptRetentionDays: 30), at: start + 910)
    try assertRead(at: start + 1200)
  }
  /// The cutoff itself, with no setting changed, well inside the unchanged-read lifetime.
  func testRetentionCutoffMovingADayIsReadAgain() throws {
    try commit(); try observe(); try settled()
    let flip = start - 1 + 86400
    try assertRead(at: flip - 300)
    try assertSkipped(at: flip - 1)
    try assertRead(at: flip)
  }
  /// Retention removes refs not seen for its whole window. They are still seen often enough.
  func testRefsOutliveTheShortestRetentionWhenNothingChanges() throws {
    try store.saveSettings(StorageSettings(promptRetentionDays: 1), at: 0)
    let refresh = start
    try commit("Invented kept", author: refresh - 5); try observe(time: refresh - 5, scan: refresh - 5); try scan(refresh)
    let rows = try count("git_refs")
    XCTAssertGreaterThan(rows, 0)
    // Each hour: retention first, as when its timer fires before the Git tick. The folder
    // stays recently seen, so only the refs' own time is in question.
    // On the half hour, so the cutoff's new day alone would come after retention at hour 25.
    for hour in 1...30 {
      let time = refresh + hour * 3600 - 1800
      try store.connection.run("UPDATE git_working_folders SET last_seen=?", [.integer(time)])
      try store.cleanRetention(at: time)
      XCTAssertEqual(try count("git_refs"), rows, "refs expired at hour \(hour)")
      try scan(time)
    }
  }
  func testUnchangedReadLifetimeEndsInAFullRead() throws {
    try commit(); try observe(); try settled()
    try assertSkipped(at: start + ActivityStorage.gitUnchangedReadLifetime - 1)
    try assertRead(at: start + ActivityStorage.gitUnchangedReadLifetime)
    XCTAssertEqual(try count("git_refs", "ts=\(start + ActivityStorage.gitUnchangedReadLifetime)"), try count("git_refs"))
  }
  /// Back within the same day, so the retention cutoff day stays and only the clock check can tell.
  func testClockSetBackReadsAgain() throws {
    try commit(); try observe()
    try scan(start + 3600)
    try assertSkipped(at: start + 3900)
    try assertRead(at: start + 3500)
  }
  func testNewOwnReceiptAppliesAtTheNextRunWithoutARefChange() throws {
    try commit(); try observe(); try settled()
    XCTAssertEqual(try count("git_working_folders"), 1)
    try store.ownLogSources().registerSession(AgentLogIdentity.decoded("invented-session"), tool: .claude)
    let reads = task.historyReads, skips = task.historySkips
    try scan(start + 600)
    XCTAssertEqual(try count("git_working_folders"), 0)
    // Discovery removes the folder. With none left the repository is not visited, so no skip stands for it.
    XCTAssertEqual(task.historyReads - reads, 0)
    XCTAssertEqual(task.historySkips - skips, 0)
  }
  /// A receipt added after discovery and before history, as on the separate history queue:
  /// only the history fingerprint's own ownership input can tell, and the read applies it.
  func testReceiptBetweenDiscoveryAndHistoryIsReadByHistory() throws {
    try commit()
    let tree = root.appendingPathComponent("invented-worktree")
    try git(["worktree", "add", "-b", "invented-work", tree.path])
    let owned = GitWorkingFolder(folder: tree.path, session: "invented-owned-session", source: "invented-owned-source",
      device: 7, inode: 81, time: now - 10, tool: .claude)
    try observe(); try work { try self.task.observe(owned, now: self.now) }; try settled()
    XCTAssertEqual(try count("git_working_folders"), 2)
    task.beforeHistoryRun = { [unowned self] in
      self.task.beforeHistoryRun = nil
      try self.store.ownLogSources().registerSession(AgentLogIdentity.decoded("invented-owned-session"), tool: .claude)
    }
    try assertRead(at: start + 600)
    XCTAssertEqual(try count("git_working_folders"), 1)
    XCTAssertEqual(try count("git_working_folders", "session='invented-owned-session'"), 0)
  }
  /// The ownership authority the next publication would check, moved in a folder row alone.
  func testChangedFolderAuthorityIsReadAgain() throws {
    try commit(); try observe(); try settled()
    try store.connection.run("UPDATE git_working_folders SET ownership_authority=?", [.key("[\"\(ActivityStorage.gitDigest("invented-candidate"))\"]")])
    try assertRead(at: start + 600)
  }
  /// Masks are code. A new build rewrites stored names at its first run, with refs unchanged.
  func testMaskChangeRewritesStoredNamesAtTheNextRun() throws {
    try commit(); try observe(); try settled()
    XCTAssertFalse(ActivityStorage.gitBuildRevision.isEmpty)
    try store.connection.run("UPDATE git_refs SET name='invented-old-mask'")
    store.gitMaskRevision = "invented-other-build"
    try assertRead(at: start + 600)
    XCTAssertEqual(try count("git_refs", "name='invented-old-mask'"), 0)
    XCTAssertGreaterThan(try count("git_refs"), 0)
  }

  // MARK: What a skip leaves, and what stops one

  /// A read that did not finish saves no digest: the next run reads, and nothing is lost.
  func testInterruptedReadSavesNothingAndTheNextRunFinishesIt() throws {
    try commit(); try observe(); try settled()
    let saved = try fingerprint()
    let hash = try commit("Invented new", file: "new.txt", author: start)
    var failing = true
    task.afterCommitStarted = { _ in if failing { failing = false; throw GitReadError.failed } }
    try assertRead(at: start + 600)
    XCTAssertFalse(try commitIsStored(hash))
    XCTAssertEqual(try fingerprint(), saved)
    try assertRead(at: start + 900)
    XCTAssertTrue(try commitIsStored(hash))
    XCTAssertNotEqual(try fingerprint(), saved)
    XCTAssertEqual(try frontierTips(), try gitTips())
  }
  /// Certification and the digest are one transaction. A stop just before it leaves neither.
  func testFailedCertificationSavesNoDigest() throws {
    try commit(); try observe(); try settled()
    let saved = try fingerprint(), frontier = try scalarText("SELECT frontier FROM git_repositories")
    let hash = try commit("Invented new", file: "new.txt", author: start)
    store.beforeGitFrontierPublication = { throw StorageError.busy("invented") }
    XCTAssertThrowsError(try scan(start + 600))
    store.beforeGitFrontierPublication = nil
    XCTAssertEqual(try fingerprint(), saved)
    XCTAssertEqual(try scalarText("SELECT frontier FROM git_repositories"), frontier)
    try assertRead(at: start + 900)
    XCTAssertTrue(try commitIsStored(hash))
    try assertSkipped(at: start + 1200)
  }
  func testAnyDoubtInTheStoredStateRefusesTheSkip() throws {
    try commit(); try observe(); try settled()
    let time = start + 600
    XCTAssertTrue(try unchanged(at: time))
    let frontier = try scalarText("SELECT frontier FROM git_repositories")
    func refused(_ doubt: String, undo: String, _ line: UInt = #line) throws {
      try store.connection.run(doubt)
      XCTAssertFalse(try unchanged(at: time), line: line)
      try store.connection.run(undo)
      XCTAssertTrue(try unchanged(at: time), line: line)
    }
    try refused("UPDATE git_repositories SET frontier='invented-other'", undo: "UPDATE git_repositories SET frontier='\(frontier)'")
    try refused("UPDATE git_repositories SET pending_frontier='invented-pending'", undo: "UPDATE git_repositories SET pending_frontier=''")
    try refused("UPDATE git_repositories SET reopen_blocked=1", undo: "UPDATE git_repositories SET reopen_blocked=0")
    try refused("INSERT INTO git_commits(id,repo_id,hash,author_ts,ts,author,email,message,complete) VALUES(9999,1,'invented',1,1,'','','',0)", undo: "DELETE FROM git_commits WHERE id=9999")
    try refused("UPDATE git_read_fingerprints SET ref_count=ref_count+1", undo: "UPDATE git_read_fingerprints SET ref_count=ref_count-1")
    // A new frontier holding the same refs: the count matches, so only the stored frontier can tell.
    try store.connection.run("UPDATE git_repositories SET frontier='invented-other'")
    try store.connection.run("UPDATE git_refs SET frontier='invented-other' WHERE frontier='\(frontier)'")
    XCTAssertFalse(try unchanged(at: time))
    try store.connection.run("UPDATE git_refs SET frontier='\(frontier)' WHERE frontier='invented-other'")
    try store.connection.run("UPDATE git_repositories SET frontier='\(frontier)'")
    XCTAssertTrue(try unchanged(at: time))
    // Retention or forget removed a frontier row.
    let rows = try count("git_refs")
    try store.connection.run("UPDATE git_read_fingerprints SET ref_count=ref_count+1")
    XCTAssertFalse(try unchanged(at: time))
    try store.connection.run("UPDATE git_read_fingerprints SET ref_count=\(rows)")
    // Another repository's digest, or a repository no longer permitted.
    XCTAssertFalse(try work { try self.store.gitReadUnchanged(repo: 1, fingerprint: "invented-other", now: time) })
    XCTAssertFalse(try work { try self.store.gitReadUnchanged(repo: 2, fingerprint: try self.fingerprint(), now: time) })
    try store.setGitRepositoryCopy(1, true)
    XCTAssertFalse(try unchanged(at: time))
    try store.setGitRepositoryCopy(1, false)
    XCTAssertTrue(try unchanged(at: time))
  }
  func testRefsRemovedBehindTheDigestAreReadAgain() throws {
    try commit(); try git(["branch", "invented-other"]); try observe(); try settled()
    let rows = try count("git_refs")
    try store.connection.run("DELETE FROM git_refs WHERE id=(SELECT min(id) FROM git_refs)")
    try assertRead(at: start + 600)
    XCTAssertEqual(try count("git_refs"), rows)
    try assertSkipped(at: start + 900)
  }
  /// A repository needing its raw path, unknown after a restart, still goes through the read
  /// that reports it as blocked.
  func testRepositoryWithoutItsRawPathIsNotSkipped() throws {
    try commit(); try observe(); try settled()
    try store.connection.run("UPDATE git_repositories SET identity='invented-masked-path'")
    task = GitCollectionTask(storage: store, secureInput: { false }, scratchDirectory: root)
    try assertRead(at: start + 600)
    XCTAssertEqual(try count("git_repositories", "reopen_blocked=1"), 1)
  }
  func testDigestSurvivesARestart() throws {
    try commit(); try observe(); try settled()
    task = nil; store = nil
    store = try ActivityStorage(url: root.appendingPathComponent("invented.sqlite"), appDataDirectory: root, databaseScope: .directory(root))
    task = GitCollectionTask(storage: store, secureInput: { false }, scratchDirectory: root)
    try assertSkipped(at: start + 600)
  }
  func testLostOrSpoiledDigestReadsOnceAndIsWrittenAgain() throws {
    try commit(); try observe(); try settled()
    let token = try scalarText("SELECT frontier FROM git_repositories")
    try store.connection.run("DELETE FROM git_read_fingerprints")
    try assertRead(at: start + 600)
    try assertSkipped(at: start + 900)
    try store.connection.run("UPDATE git_read_fingerprints SET fingerprint='invented-spoiled'")
    try assertRead(at: start + 1200)
    try assertSkipped(at: start + 1500)
    try store.connection.run("UPDATE git_read_fingerprints SET read_at='invented-spoiled'")
    try assertRead(at: start + 1800)
    try assertSkipped(at: start + 2100)
    XCTAssertEqual(try scalarText("SELECT frontier FROM git_repositories"), token)
    // A database from before this table: opening it adds the table, and the next run reads.
    try store.connection.run("DROP TRIGGER git_read_fingerprint_cleanup"); try store.connection.run("DROP TABLE git_read_fingerprints")
    task = nil; store = nil
    store = try ActivityStorage(url: root.appendingPathComponent("invented.sqlite"), appDataDirectory: root, databaseScope: .directory(root))
    task = GitCollectionTask(storage: store, secureInput: { false }, scratchDirectory: root)
    try assertRead(at: start + 2400)
    try assertSkipped(at: start + 2700)
  }
  func testDeletingARepositoryDeletesItsDigest() throws {
    try commit(); try observe(); try settled()
    XCTAssertEqual(try count("git_read_fingerprints"), 1)
    try store.connection.run("DELETE FROM git_repositories")
    XCTAssertEqual(try count("git_read_fingerprints"), 0)
  }
  /// The stored pass and the live hand-off do not depend on the history read being needed.
  func testBackfillAdvancesOnARepositoryWhoseRefsDidNotChange() throws {
    try commit()
    let reader = ClaudeAgentLogReader(userHome: root.path, processes: InventedProcesses(), appDataDirectory: root)
    _ = try cpuFixtureLog("invented-first", records: cpuRecords(3, session: "invented-first", folder: repo, base: now - 500))
    try work { try AgentLogTask(reader: reader, storage: self.store).scan(at: self.now) }
    try scan(start); task.waitForBackfill()
    try scan(start + 100); task.waitForBackfill()
    try assertSkipped(at: start + 200)
    let mark = try store.gitBackfillProgress(nil)
    XCTAssertGreaterThan(mark, 0)
    // Stored while no Git task listens. A restart's stored pass offers it, though the repository's digest still matches.
    let stored = repo.appendingPathComponent("invented-stored")
    try FileManager.default.createDirectory(at: stored, withIntermediateDirectories: true)
    _ = try cpuFixtureLog("invented-stored", records: cpuRecords(3, session: "invented-stored", folder: stored, base: now - 200))
    try work { try AgentLogTask(reader: reader, storage: self.store).scan(at: self.start + 300) }
    task = GitCollectionTask(storage: store, secureInput: { false }, scratchDirectory: root)
    try scan(start + 400); task.waitForBackfill()
    XCTAssertGreaterThan(try store.gitBackfillProgress(nil), mark)
    XCTAssertEqual(try count("git_working_folders", "session='invented-stored' AND repo_id IS NOT NULL"), 1)
    XCTAssertEqual(try count("git_repositories"), 1)
    // Handed off live on an unchanged repository.
    let live = repo.appendingPathComponent("invented-live")
    try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
    _ = try cpuFixtureLog("invented-live", records: cpuRecords(3, session: "invented-live", folder: live, base: now - 100))
    try work { try AgentLogTask(reader: reader, storage: self.store, git: self.task).scan(at: self.start + 500) }
    task.waitForBackfill()
    XCTAssertEqual(try count("git_working_folders", "session='invented-live' AND repo_id IS NOT NULL"), 1)
    XCTAssertEqual(try count("git_repositories"), 1)
  }
  /// A resumed read after a stop works from the same frontier and finishes every commit.
  func testStoppedFirstReadResumesAfterARestart() throws {
    for index in 0..<4 { try commit("Invented \(index)", file: "file-\(index).txt", author: now - 100 + index) }
    try observe()
    var seen = 0
    task.beforeMetadataRead = { [unowned self] in
      seen += 1
      if seen == 2 { self.task.stop() }
    }
    try scan(start)
    XCTAssertEqual(try count("git_read_fingerprints"), 0)
    task = nil
    task = GitCollectionTask(storage: store, secureInput: { false }, scratchDirectory: root)
    try assertRead(at: start + 300)
    XCTAssertEqual(try count("git_commits", "complete=1"), 4)
    try assertSkipped(at: start + 600)
  }
  /// The copy check keeps its place ahead of the skip: a repository that became a copy is
  /// refused even though its files and digest are as they were.
  func testCopyRefusalAppliesToARepositoryThatWouldBeSkipped() throws {
    try commit()
    let outer = root.appendingPathComponent("invented-outer")
    let nested = outer.appendingPathComponent(".build/invented-pkg")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try inventedRepository(nested, commits: 2)
    try observe(nested); try settled()
    let id = try store.connection.integer("SELECT id FROM git_repositories")
    try git(["init", "-b", "main"], in: outer)
    try Data(".build/\n".utf8).write(to: outer.appendingPathComponent(".gitignore"))
    // A restart forgets the earlier verdict; the digest in the database still matches.
    let fresh = GitCollectionTask(storage: store, secureInput: { false }, scratchDirectory: root)
    task = fresh
    let skips = task.historySkips
    try scan(start + 600)
    XCTAssertEqual(task.historySkips, skips)
    XCTAssertTrue(store.gitCopyRepositories.contains(id))
  }

  // MARK: Where it runs

  private func manyRefs(_ count: Int = 2100) throws {
    let head = try git(["rev-parse", "HEAD"])
    let lines = (0..<count).map { "create refs/heads/invented-\($0) \(head)" }.joined(separator: "\n") + "\n"
    let file = root.appendingPathComponent("invented-update-" + UUID().uuidString)
    try Data(lines.utf8).write(to: file)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "/usr/bin/git -C \"$0\" update-ref --stdin < \"$1\"", repo.path, file.path]
    try process.run(); process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
  }
  /// The stage's own queue, no storage lock held, and a stop ends it within a bounded walk.
  func testDigestRunsOnTheGitQueueWithNoLockHeldAndStops() throws {
    try commit(); try manyRefs(); try observe()
    var labels = Set<String>(), blocked = 0, walked = 0
    task.duringFingerprint = { [unowned self] in
      walked += 1
      labels.insert(String(cString: __dispatch_queue_get_label(nil)))
      let free = DispatchSemaphore(value: 0)
      DispatchQueue.global().async {
        if self.store.lock.lock(before: Date(timeIntervalSinceNow: 2)) { self.store.lock.unlock(); free.signal() }
      }
      if free.wait(timeout: .now() + 3) == .timedOut { blocked += 1 }
    }
    try work { try self.task.maintenanceTask.run(self.start) }
    task.waitForBackfill()
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async { self.task.waitForBackfill(); done.signal() }
    done.wait()
    XCTAssertGreaterThan(walked, 0)
    XCTAssertEqual(labels, ["ActivityProbe.GitHistory"])
    XCTAssertEqual(blocked, 0)
    task.duringFingerprint = { [unowned self] in self.task.stop() }
    let reads = task.historyReads, skips = task.historySkips
    try scan(start + 300)
    XCTAssertEqual(task.historySkips, skips)
    XCTAssertLessThanOrEqual(task.historyReads - reads, 1)
    XCTAssertEqual(try count("git_commits", "complete=0"), 0)
  }
  func testDigestChecksForAStopWhileWalking() throws {
    try commit(); try manyRefs()
    let common = repo.appendingPathComponent(".git").path
    XCTAssertNotNil(try GitRefState.digest(commonDirectory: common))
    XCTAssertThrowsError(try GitRefState.digest(commonDirectory: common, check: { throw GitReadError.cancelled }))
  }

  // MARK: The digest

  func testDigestCannotVouchForWhatItCannotSee() throws {
    try commit()
    let common = repo.appendingPathComponent(".git")
    XCTAssertNotNil(try GitRefState.digest(commonDirectory: common.path))
    XCTAssertNil(try GitRefState.digest(commonDirectory: root.appendingPathComponent("invented-missing").path))
    // A linked refs folder, as an old-style shared working directory has.
    let moved = root.appendingPathComponent("invented-shared-refs")
    try FileManager.default.moveItem(at: common.appendingPathComponent("refs"), to: moved)
    XCTAssertNil(try GitRefState.digest(commonDirectory: common.path))
    try FileManager.default.createSymbolicLink(at: common.appendingPathComponent("refs"), withDestinationURL: moved)
    XCTAssertNil(try GitRefState.digest(commonDirectory: common.path))
    try FileManager.default.removeItem(at: common.appendingPathComponent("refs"))
    try FileManager.default.moveItem(at: moved, to: common.appendingPathComponent("refs"))
    // A link deeper down too.
    let link = common.appendingPathComponent("refs/heads/invented-link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: common.appendingPathComponent("refs/heads/main"))
    XCTAssertNil(try GitRefState.digest(commonDirectory: common.path))
    try FileManager.default.removeItem(at: link)
    // A ref format it does not know could keep refs anywhere. The two it knows still vouch.
    let config = common.appendingPathComponent("config")
    let original = try Data(contentsOf: config)
    for (format, known) in [("invented", false), ("Invented # comment", false), ("", false), ("files", true), ("reftable", true), ("\"reftable\" ; comment", true)] {
      try (original + Data("[extensions]\n\trefStorage = \(format)\n".utf8)).write(to: config)
      XCTAssertEqual(try GitRefState.digest(commonDirectory: common.path) != nil, known, format)
    }
    try (original + Data("[Extensions] refstorage=invented\n".utf8)).write(to: config)
    XCTAssertNil(try GitRefState.digest(commonDirectory: common.path))
    // The same key in another section is not the format.
    try (original + Data("[invented]\n\trefStorage = invented\n".utf8)).write(to: config)
    XCTAssertNotNil(try GitRefState.digest(commonDirectory: common.path))
    try original.write(to: config)
    try FileManager.default.removeItem(at: common.appendingPathComponent("HEAD"))
    XCTAssertNil(try GitRefState.digest(commonDirectory: common.path))
  }
  func testDigestIsTheSameWhenNothingMovedAndDiffersForEachFileItReads() throws {
    try commit()
    let tree = root.appendingPathComponent("invented-worktree")
    try git(["worktree", "add", "--detach", tree.path])
    let common = repo.appendingPathComponent(".git")
    func digest() throws -> String { try XCTUnwrap(GitRefState.digest(commonDirectory: common.path)) }
    XCTAssertEqual(try digest(), try digest())
    let id = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: common.appendingPathComponent("worktrees").path).first)
    for name in ["HEAD", "packed-refs", "config", "shallow", "refs/heads/invented-new", "reftable/tables.list",
      "worktrees/\(id)/HEAD", "worktrees/\(id)/gitdir", "worktrees/\(id)/locked", "worktrees/\(id)/refs/invented",
      "worktrees/\(id)/reftable/tables.list"] {
      let before = try digest()
      let file = common.appendingPathComponent(name)
      try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      let old = try? Data(contentsOf: file)
      try ((old ?? Data()) + Data()).write(to: file)
      XCTAssertNotEqual(try digest(), before, name)
    }
    // Files that hold no ref do not count, in the common directory or a worktree.
    let before = try digest()
    for name in ["index", "FETCH_HEAD", "ORIG_HEAD", "logs/HEAD", "worktrees/\(id)/index", "worktrees/\(id)/logs/HEAD", "objects/invented"] {
      let file = common.appendingPathComponent(name)
      try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("x".utf8).write(to: file)
      XCTAssertEqual(try digest(), before, name)
    }
  }
}
