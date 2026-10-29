import Core
import Darwin
import Foundation
@testable import Shell
@testable import Storage
import XCTest

extension GitCollectionTests {
  /// The authority discovery stores for an invented Claude log of this session.
  private func inventedAuthority(session: String) throws -> String {
    let source = root.appendingPathComponent(".claude/projects/invented-project/\(session).jsonl").path
    let subjects = [AgentLogIdentity.decoded(session).session.subject].compactMap { $0 }
    let authority = store.ownLogSources().authority(path: source, sessions: subjects, tool: .claude)
    return String(decoding: try JSONEncoder().encode(authority), as: UTF8.self)
  }

  /// Copies the linked row of `repository` as `rows` more linked folders, each with its own
  /// session, source and authority, as many agent sessions in one checkout leave behind.
  private func cloneFolders(of repository: URL, rows: Int, prefix: String, linked: Bool = true) throws {
    // Unlinked folders sit outside every repository, as the owner's do.
    let parent = linked ? repository : root.appendingPathComponent("invented-outside")
    var template = 0
    try store.connection.namedRows("SELECT id FROM git_working_folders WHERE folder=? ORDER BY id LIMIT 1", [.key(repository.path)]) {
      template = try $0.int("id")
    }
    XCTAssertGreaterThan(template, 0)
    for index in 0..<rows {
      let session = "\(prefix)-\(index)"
      let folder = parent.appendingPathComponent("invented-sub-\(index)")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let source = root.appendingPathComponent(".claude/projects/invented-project/\(session).jsonl").path
      try store.connection.run("""
        INSERT INTO git_working_folders(identity,source,device,inode,session,folder,repo_id,top_level,branch,head,ts,last_seen,
          attempt_ts,status,failures,tool,discovery,complete,ownership_authority)
        SELECT ?,?,device,?,?,?,\(linked ? "repo_id" : "NULL"),top_level,branch,head,ts,last_seen,attempt_ts,
          \(linked ? "status" : "'unversioned'"),failures,tool,discovery,complete,? FROM git_working_folders WHERE id=?
        """, [.key("invented-identity-\(session)"), .key(source), .integer(1000 + index), .key(session), .key(folder.path),
          .key(try inventedAuthority(session: session)), .integer(template)])
    }
  }

  private func addRefs(_ count: Int, in folder: URL) throws {
    let head = try git(["rev-parse", "HEAD"], in: folder)
    let heads = folder.appendingPathComponent(".git/refs/heads")
    for index in 1..<count {
      try Data((head + "\n").utf8).write(to: heads.appendingPathComponent("invented-\(index)"))
    }
  }

  private func frontierRows() throws -> [String] {
    var rows: [String] = []
    try store.connection.namedRows("SELECT r.id,r.identity,r.tip FROM git_refs r JOIN git_repositories p ON p.id=r.repo_id AND r.frontier=p.frontier ORDER BY r.id") {
      rows.append("\(try $0.int("id"))|\(try $0.text("identity"))|\(try $0.text("tip"))")
    }
    return rows
  }

  /// A steady tick on a repository whose refs did not move used to stage every ref and then
  /// write a whole new frontier with fresh row ids, every five minutes, forever.
  func testUnchangedRefsSettleAfterTheFirstRead() throws {
    try commit()
    try addRefs(6, in: repo)
    try observe()
    try scan()
    let settled = try frontierRows()
    // Five invented branches, main and the worktree head.
    XCTAssertEqual(settled.count, 7)
    let calls = store.gitPublishCalls
    try scan(now + 300)
    XCTAssertEqual(try frontierRows(), settled, "an unchanged frontier is rewritten")
    XCTAssertEqual(try count("git_refs"), 7)
    // The observation time still moves with each read, as a rewrite would have stored it.
    XCTAssertEqual(try count("git_refs", "ts=\(now + 300)"), 7)
    XCTAssertEqual(try count("git_repositories", "last_read=\(now + 300)"), 1)
    // One diagnostic, one staging per ref, one refresh.
    XCTAssertLessThanOrEqual(store.gitPublishCalls - calls, 7 + 2)
    // A moved ref still rewrites the frontier.
    let moved = try commit("Invented moved", file: "moved.txt", author: now + 400)
    try scan(now + 600)
    XCTAssertNotEqual(try frontierRows(), settled)
    XCTAssertEqual(try count("git_refs", "tip='\(moved)'"), 2)
    XCTAssertEqual(try count("git_refs"), 7)
    XCTAssertEqual(try count("git_commits", "complete=1"), 2)
  }

  /// A refresh is a publication like any other: under Secure Input or revoked, the frontier stays as it was.
  func testUnchangedFrontierRefreshIsRefusedUnderSecureInputAndAfterRevocation() throws {
    try commit()
    try addRefs(3, in: repo)
    try observe()
    try scan()
    store.setGitSecureInput { true }
    try scan(now + 300)
    XCTAssertEqual(try count("git_repositories", "last_read=\(now + 300)"), 0)
    XCTAssertEqual(try count("git_refs", "ts=\(now + 300)"), 0)
    store.setGitSecureInput { false }
    try store.purgeOwnLogSession("invented-session", tool: .claude)
    try scan(now + 600)
    XCTAssertEqual(try count("git_repositories", "last_read=\(now + 600)"), 0)
    XCTAssertEqual(try count("git_refs", "ts=\(now + 600)"), 0)
  }

  private func ownershipFixture() throws -> (Int, String) {
    try commit()
    try observe()
    try cloneFolders(of: repo, rows: 4, prefix: "invented-clone")
    try scan()
    XCTAssertEqual(try count("git_working_folders"), 5)
    let repoID = try store.connection.integer("SELECT id FROM git_repositories")
    // Warm: a second read with nothing changed looks nothing up.
    try scan(now + 300)
    return (repoID, "invented-clone-2")
  }

  private func publishOnce(_ repoID: Int, at time: Int) throws {
    try work { try self.store.gitReopenBlocked(repo: repoID, blocked: false, now: time) }
  }

  func testSteadyReadLooksUpNoOwnershipReceipts() throws {
    let (repoID, _) = try ownershipFixture()
    let lookups = store.gitOwnershipLookups
    try scan(now + 600)
    try publishOnce(repoID, at: now + 601)
    XCTAssertEqual(store.gitOwnershipLookups, lookups)
    XCTAssertEqual(try count("git_working_folders"), 5)
  }

  func testNewReceiptFileTakesEffectAtTheNextPublish() throws {
    let (repoID, owned) = try ownershipFixture()
    try store.ownLogSources().registerSession(owned, tool: .claude)
    try publishOnce(repoID, at: now + 301)
    XCTAssertEqual(try count("git_working_folders", "session='\(owned)'"), 0)
    XCTAssertEqual(try count("git_working_folders"), 4)
  }

  func testNewBaselineRowTakesEffectAtTheNextPublish() throws {
    let (repoID, owned) = try ownershipFixture()
    var mine = Set<String>(), others = Set<String>()
    try store.connection.namedRows("SELECT session,ownership_authority FROM git_working_folders") {
      let candidates = try JSONDecoder().decode([String].self, from: Data(try $0.text("ownership_authority").utf8))
      if try $0.text("session") == owned { mine.formUnion(candidates) } else { others.formUnion(candidates) }
    }
    // Only the database knows this receipt, and only this row consults it.
    let receipt = try XCTUnwrap(mine.subtracting(others).sorted().first)
    try store.connection.run("INSERT INTO agent_log_own_baseline VALUES(?)", [.key(receipt)])
    try publishOnce(repoID, at: now + 301)
    XCTAssertEqual(try count("git_working_folders", "session='\(owned)'"), 0)
    XCTAssertEqual(try count("git_working_folders"), 4)
  }

  func testRevocationTakesEffectAtTheNextPublish() throws {
    let (repoID, owned) = try ownershipFixture()
    try store.purgeOwnLogSession(owned, tool: .claude)
    XCTAssertEqual(try count("git_working_folders", "session='\(owned)'"), 0)
    try publishOnce(repoID, at: now + 301)
    XCTAssertEqual(try count("git_working_folders"), 4)
    // Every source revoked: the next read cannot publish its frontier refresh.
    for index in [0, 1, 3] { try store.purgeOwnLogSession("invented-clone-\(index)", tool: .claude) }
    try store.purgeOwnLogSession("invented-session", tool: .claude)
    try scan(now + 600)
    XCTAssertEqual(try count("git_repositories", "last_read=\(now + 600)"), 0)
  }

  /// A row whose authority changes after a clean check is checked again, against receipts
  /// that were already answered under the same registry state.
  func testChangedFolderRowIsCheckedAgainAtTheNextPublish() throws {
    let (repoID, owned) = try ownershipFixture()
    try store.ownLogSources().registerSession("invented-elsewhere", tool: .claude)
    try publishOnce(repoID, at: now + 301)
    XCTAssertEqual(try count("git_working_folders"), 5)
    try store.connection.run("UPDATE git_working_folders SET ownership_authority=? WHERE session=?",
      [.key(try inventedAuthority(session: "invented-elsewhere")), .key(owned)])
    try publishOnce(repoID, at: now + 302)
    XCTAssertEqual(try count("git_working_folders", "session='\(owned)'"), 0)
    XCTAssertEqual(try count("git_working_folders"), 4)
  }

  private static func cpu() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
  }

  /// Owner-shape Git history and ownership cost, measured only with ACTIVITYPROBE_GIT_OWN_CPU=1. Invented:
  /// one repository with 128 refs and 295 linked folders, one with 44 refs and 13 folders,
  /// 293 folders outside any repository, 116 unrelated receipts and 6 baseline rows.
  func testOwnerShapeGitOwnershipTickCost() throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["ACTIVITYPROBE_GIT_OWN_CPU"] == "1")
    try commit()
    try addRefs(128, in: repo)
    try observe()
    try cloneFolders(of: repo, rows: 294, prefix: "invented-large")
    try cloneFolders(of: repo, rows: 293, prefix: "invented-unlinked", linked: false)
    let small = root.appendingPathComponent("invented-small")
    try FileManager.default.createDirectory(at: small, withIntermediateDirectories: true)
    try git(["init", "-b", "main"], in: small)
    try commit("Invented small", in: small)
    try addRefs(44, in: small)
    try observe(small, source: "invented-small-source")
    try cloneFolders(of: small, rows: 12, prefix: "invented-small")
    for index in 0..<116 { try store.ownLogSources().registerSession("invented-unrelated-\(index)", tool: .claude) }
    for index in 0..<6 {
      try store.connection.run("INSERT INTO agent_log_own_baseline VALUES(?)", [.key(ActivityStorage.gitDigest("invented-baseline-\(index)"))])
    }
    print("GIT-OWN-CPU shape folders=\(try count("git_working_folders")) linked=\(try count("git_working_folders", "repo_id IS NOT NULL")) repositories=\(try count("git_repositories"))")
    let usage = StageUsage()
    task.usage = usage
    for tick in 0..<4 {
      let time = now + 300 * tick
      let calls = store.gitPublishCalls, lookups = store.gitOwnershipLookups, start = Self.cpu()
      try scan(time)
      let stages = usage.roll(at: time).stages
      let history = stages["git_history"].map { Double($0.lastCPUNanoseconds) / 1e9 } ?? 0
      print("GIT-OWN-CPU tick=\(tick) process_cpu=\(String(format: "%.3f", Self.cpu() - start)) git_history_cpu=\(String(format: "%.3f", history)) publishes=\(store.gitPublishCalls - calls) lookups=\(store.gitOwnershipLookups - lookups) refs=\(try count("git_refs"))")
    }
  }
}
