@testable import Core
import Foundation
import SQLite3
@testable import Storage
import XCTest

private final class GitScheduleReplay {
  let root: URL
  var store: ActivityStorage!
  var model = GitPublicationModel()
  var owner = GitTaskCancellation()
  var policy: GitPreparationPolicy?
  var repository: Int?
  var commitID: Int?
  var armed: (String, GitScheduleEvent)?
  var previous = [String: Data]()
  var previousRead = 0
  var authority = false
  var checking = false
  var family = ""
  var pendingReopen = false
  var crashImage: URL?
  var discoverySource = 0
  var discoveryReceipt: GitPublicationModel.Receipt?
  struct Crash: Error {}
  var preview: String?
  var malformed = false
  var events = Set<String>()
  var snapshots = 0
  let bytes: Int
  init(bytes: Int) throws {
    self.bytes = bytes
    root = FileManager.default.temporaryDirectory.appendingPathComponent("activityprobe-git-schedule-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    try open()
    try store.saveSettings(StorageSettings(), at: 0)
    try snapshot()
  }
  func close() {
    store?.afterGitUnit = nil; store?.beforeGitCommitCompletion = nil; store?.beforeGitFrontierPublication = nil
    store = nil
    try? FileManager.default.removeItem(at: root)
  }
  private func open() throws {
    store = try ActivityStorage(url: root.appendingPathComponent("invented.sqlite"), appDataDirectory: root, databaseScope: .directory(root))
    store.setGitSecureInput { [weak self] in self?.model.secure ?? nil }
    store.afterGitUnit = { [unowned self] phase in
      try self.snapshot()
      if self.armed?.0 == phase {
        let event = self.armed!.1; self.armed = nil
        try self.event(event)
      }
    }
    store.beforeGitCommitCompletion = { [unowned self] in try self.fire("completion") }
    store.beforeGitFrontierPublication = { [unowned self] in try self.fire("certification") }
  }
  private func fire(_ phase: String) throws {
    try snapshot()
    if armed?.0 == phase { let value = armed!.1; armed = nil; try event(value) }
  }
  private func fail(_ property: String, _ detail: String) throws -> Never {
    throw GitScheduleViolation(property: property, detail: detail)
  }
  private func scalar(_ sql: String) throws -> Int { try store.connection.integer(sql) }
  private func text(_ byte: UInt8, count: Int? = nil) throws -> GitMaskedText {
    let file = root.appendingPathComponent(UUID().uuidString)
    try gitSchedulePayload(byte, count: count ?? bytes).write(to: file)
    return GitMaskedText(maskedFile: file, byteCount: count ?? bytes)
  }
  private func content() throws -> [String: Data] {
    var values = [String: Data]()
    let fields = [
      ("git_repositories", ["common_dir"]),
      ("git_working_folders", ["source", "session", "folder", "top_level", "branch", "head"]),
      ("git_commits", ["author", "email", "message"]),
      ("git_files", ["old_path", "path"]),
      ("git_commit_refs", ["name"]), ("git_refs", ["name"])
    ]
    for (table, columns) in fields {
      try store.connection.namedRows("SELECT id," + columns.joined(separator: ",") + " FROM " + table) { row in
        for column in columns { values["\(table):\(try row.int("id")):\(column)"] = Data(try row.text(column).utf8) }
      }
    }
    for table in ["git_commit_text", "git_value_text"] {
      try store.connection.rows("SELECT id,payload FROM " + table) { row in
        let size = Int(sqlite3_column_bytes(row, 1))
        if let pointer = sqlite3_column_blob(row, 1) {
          values["\(table):\(SQLiteConnection.int(row, 0))"] = Data(bytes: pointer, count: size)
        }
      }
    }
    return values
  }
  private func payload(_ sql: String) throws -> Data {
    var result = Data()
    try store.connection.rows(sql) { row in
      let size = Int(sqlite3_column_bytes(row, 0))
      if let pointer = sqlite3_column_blob(row, 0) { result.append(Data(bytes: pointer, count: size)) }
    }
    return result
  }
  func snapshot() throws {
    guard !checking else { return }; checking = true; defer { checking = false }
    snapshots += 1
    let next = try content()
    for erased in model.erased {
      if try scalar("SELECT count(*) FROM git_commits WHERE hash='\(erased)'") != 0 {
        try fail("erasure", "forgotten identity reappeared")
      }
    }
    if next.contains(where: { previous[$0.key] != $0.value }), !authority {
      if model.cancelled || model.producerCancelled { try fail("interruption", "cancelled producer published durable content") }
      try fail("admission", "durable content changed without current model authority: \(next.keys.filter { previous[$0] != next[$0] }.sorted()) family=\(family) outcome=\(model.outcome)")
    }
    previous = next
    try store.connection.namedRows("SELECT id FROM git_working_folders WHERE complete=1") { row in
      let id = try row.int("id")
      let branch = try payload("SELECT payload FROM git_value_text WHERE kind=4 AND owner_id=\(id) ORDER BY ordinal")
      if branch != gitSchedulePayload(100, count: bytes) { try fail("completion", "initial branch chunks differ") }
    }
    try store.connection.namedRows("SELECT id,hash FROM git_commits WHERE complete=1") { row in
      let id = try row.int("id")
      for field in 0..<3 {
        let actual = try payload("SELECT payload FROM git_commit_text WHERE commit_id=\(id) AND field=\(field) ORDER BY ordinal")
        if actual != gitSchedulePayload(UInt8(97 + field), count: bytes) { try fail("completion", "metadata digest or ordered chunks differ") }
      }
      if try scalar("SELECT count(*) FROM git_files WHERE commit_id=\(id)") != 2 { try fail("completion", "required file child missing") }
      for index in 0..<2 {
        let actual = try payload("SELECT v.payload FROM git_value_text v JOIN git_files f ON f.id=v.owner_id WHERE v.kind=1 AND v.field=1 AND f.commit_id=\(id) AND f.added=\(index + 1) ORDER BY ordinal")
        if actual != gitSchedulePayload(UInt8(112 + index), count: bytes) { try fail("completion", "file child chunks differ") }
      }
      if try scalar("SELECT count(*) FROM git_commit_refs WHERE commit_id=\(id)") != 1 { try fail("completion", "required reached-ref child missing") }
      let ref = try payload("SELECT v.payload FROM git_value_text v JOIN git_commit_refs r ON r.id=v.owner_id WHERE v.kind=2 AND r.commit_id=\(id) ORDER BY ordinal")
      if ref != gitSchedulePayload(114, count: bytes) { try fail("completion", "reached-ref chunks differ") }
    }
    let read = try scalar("SELECT COALESCE(max(last_read),0) FROM git_repositories")
    if read > previousRead {
      let complete = try scalar("SELECT count(*) FROM git_commits WHERE hash='\(model.hash)' AND complete=1") > 0
      let refused = try scalar("SELECT count(*) FROM git_tombstones WHERE hash='\(model.hash)'") > 0
      if !model.frontierAllowed || (!complete && !refused && !model.expired) {
        try fail("frontier", "frontier certified an unaccounted or interrupted traversal")
      }
      let ref = try payload("SELECT v.payload FROM git_value_text v JOIN git_refs r ON r.id=v.owner_id JOIN git_repositories p ON p.id=r.repo_id WHERE v.kind=3 AND r.frontier=p.frontier ORDER BY ordinal")
      if ref != gitSchedulePayload(118, count: bytes) { try fail("frontier", "frontier lacks ordered staged chunks") }
    }
    previousRead = read
    if !model.nativePrivacy && !model.erased.contains(model.hash),
      try scalar("SELECT count(*) FROM git_tombstones WHERE hash='\(model.hash)'") > 0 {
      try fail("retention", "expiry or interruption created permanent refusal")
    }
  }
  private func save(enabled: Bool, pause: Int?, at time: Int) throws {
    model.settings(enabled: enabled, pause: pause, at: time)
    try store.saveSettings(StorageSettings(pausedUntil: pause, recordingEnabled: enabled, promptRetentionDays: model.days), at: time)
  }
  func event(_ event: GitScheduleEvent) throws {
    do { try performEvent(event) }
    catch let failure as GitScheduleViolation { throw failure }
    catch is Crash where pendingReopen { throw Crash() }
    catch { throw GitScheduleViolation(property: "harness", detail: "policy transition \(event.rawValue) failed: \(error)") }
  }
  private func performEvent(_ event: GitScheduleEvent) throws {
    events.insert(event.rawValue)
    // Capture the preceding committed unit before changing the reference policy.
    try snapshot()
    switch event {
    case .secureOn: model.secure = true
    case .secureUnknown: model.secure = nil
    case .secureOff: model.secure = false
    case .recordingOff: try save(enabled: false, pause: nil, at: model.now)
    case .recordingOn, .resume: try save(enabled: true, pause: nil, at: model.now)
    case .roundTrip:
      try save(enabled: false, pause: nil, at: model.now)
      try save(enabled: true, pause: nil, at: model.now)
    case .pause: try save(enabled: true, pause: model.now + 3600, at: model.now)
    case .authorOff, .commitOff, .authorPause, .commitPause:
      let time = event == .authorOff || event == .authorPause ? model.author : model.committed
      try save(enabled: event == .authorPause || event == .commitPause, pause: event == .authorPause || event == .commitPause ? time + 1 : nil, at: time)
      try save(enabled: true, pause: nil, at: time + 1)
    case .own:
      model.revoked.insert(0); model.linked.remove(0)
      var state = AgentLogState(); state.tool = "claude"; state.session = AgentLogIdentity.decoded("invented-0").session.subject; state.ownWorkingFolder = true
      let position = LogPosition(path: "invented-source-0", device: 7, inode: 8, offset: 0, state: try state.encoded(), seenAt: model.now)
      try store.saveLogPosition(position)
      _ = try store.validateGitObservation(folder(0), now: model.now, position: position)
    case .revoke:
      model.revoked.insert(0); model.linked.remove(0)
      try store.locked { try store.connection.transaction { try store.purgeOwnLogSession("invented-0", tool: .claude) } }
    case .retain:
      model.now += 2 * 86400; model.maintained = model.now; model.days = 1
      try save(enabled: model.enabled, pause: model.pause, at: model.now)
      try store.cleanRetention(at: model.now)
      model.linked = []
    case .expand:
      model.days = 30
      try save(enabled: model.enabled, pause: model.pause, at: model.now)
    case .preview:
      preview = try store.previewDeletion(in: TimeRange(model.author, model.author + 1)).confirmation
      model.stalePreview = false
    case .forget:
      let range = TimeRange(model.author, model.author + 1)
      let fresh = try store.previewDeletion(in: range)
      try store.deleteRecords(in: range, confirmation: fresh.confirmation)
      model.forgotten.append(model.author..<(model.author + 1)); model.forgetRevision += 1
      model.erased.insert(model.hash); model.outcome = .refused
    case .staleConfirm:
      if let preview {
        do {
          try store.deleteRecords(in: TimeRange(model.author, model.author + 1), confirmation: preview)
          if model.stalePreview { try fail("erasure", "stale preview accepted") }
        } catch let error as GitScheduleViolation { throw error }
        catch { if !model.stalePreview { throw error } }
      }
    case .cancel, .stop:
      owner.cancel(); model.cancelled = true; model.producerCancelled = true; model.readInterrupted = true; model.outcome = .debt
      if event == .stop { try? store.cancelGitStaging(owner) }
    case .replacement:
      owner = GitTaskCancellation(); model.cancelled = false
    case .crash:
      if !family.isEmpty {
        // Preserve exactly the committed image, before Swift unwinds cleanup
        // defers. Restoring it discards all volatile receipts, like a process crash.
        let image = root.appendingPathComponent("crash-" + UUID().uuidString + ".sqlite")
        let destination = try SQLiteConnection(url: image, scope: .directory(root))
        guard let backup = sqlite3_backup_init(destination.handle, "main", store.connection.handle, "main") else { throw Crash() }
        let copied = sqlite3_backup_step(backup, -1)
        let finished = sqlite3_backup_finish(backup)
        guard copied == SQLITE_DONE, finished == SQLITE_OK else { throw Crash() }
        try destination.close(); crashImage = image
        owner.cancel(); model.cancelled = true; model.producerCancelled = true; model.readInterrupted = true
        pendingReopen = true; throw Crash()
      }
      let before = previousRead
      store.afterGitUnit = nil; store.beforeGitCommitCompletion = nil; store.beforeGitFrontierPublication = nil
      store = nil
      if let image = crashImage {
        for suffix in ["", "-wal", "-shm"] {
          let file = root.appendingPathComponent("invented.sqlite" + suffix)
          if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
        try FileManager.default.moveItem(at: image, to: root.appendingPathComponent("invented.sqlite")); crashImage = nil
      }
      owner = GitTaskCancellation(); commitID = nil; policy = nil
      model.cancelled = false; model.producerCancelled = false; model.commitReceipt = nil; model.readReceipt = nil
      model.readInterrupted = true; model.outcome = .debt
      try open(); try store.cleanGitCancelledWork()
      if try scalar("SELECT count(*) FROM git_commits WHERE complete!=1") != 0 || (try scalar("SELECT COALESCE(max(last_read),0) FROM git_repositories")) > before {
        try fail("interruption", "reopen certified or retained unrecoverable work")
      }
    case .brokenStream: malformed = true
    case .busy: try busyCancellation()
    }
    switch family {
    case "commit": authority = model.commitAllowed && model.outcome == .publishing
    case "frontier": authority = model.frontierAllowed
    case "discovery": authority = model.discoveryAllowed(discoverySource) && discoveryReceipt == model.receipt
    default: authority = false
    }
    try snapshot()
  }
  private func folder(_ source: Int) -> GitWorkingFolder {
    GitWorkingFolder(folder: root.appendingPathComponent("invented-repository").path, session: "invented-\(source)", source: "invented-source-\(source)", device: 7, inode: source + 8, time: model.now - 100, tool: .claude)
  }
  private func busyCancellation() throws {
    guard let repository else { return }
    let writer = try SQLiteConnection(url: root.appendingPathComponent("invented.sqlite"), scope: .directory(root), busyMilliseconds: 0)
    try writer.run("BEGIN IMMEDIATE")
    defer { try? writer.run("ROLLBACK") }
    let entered = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
    let active = store!, token = owner
    let id = commitID
    DispatchQueue.global(qos: .utility).async {
      entered.signal()
      try? active.withGitCancellation(token) {
        if let id { _ = try active.finishGitCommit(id, now: self.model.now) }
        else { try active.stageGitRef(repo: repository, name: "refs/heads/invented-busy", tip: self.model.hash) }
      }
      done.signal()
    }
    _ = entered.wait(timeout: .now() + 1)
    Thread.sleep(forTimeInterval: 0.02)
    owner.cancel(); model.cancelled = true; model.producerCancelled = true; model.readInterrupted = true
    if done.wait(timeout: .now() + 0.5) != .success { try fail("interruption", "busy admission did not return after cancellation") }
  }
  func step(_ step: GitScheduleStep) throws {
    events.insert(step.description)
    defer { family = "" }
    switch step {
    case .event(let value): try event(value); return
    case .arm(let phase, let event): armed = (phase, event); return
    case .retime: model.author = model.now - 10; model.committed = model.now - 20; return
    case .retry:
      owner = GitTaskCancellation(); model.cancelled = false; model.producerCancelled = false; malformed = false
      try store.cleanGitCancelledWork()
      commitID = nil; policy = nil; model.readInterrupted = false
      return
    case .discover(let source):
      family = "discovery"; discoverySource = source; discoveryReceipt = model.receipt
      authority = model.discoveryAllowed(source)
      let permitted = authority
      let location = GitRepositoryLocation(commonDirectory: root.appendingPathComponent("invented-common").path, topLevel: folder(source).folder, branch: "invented", head: model.hash)
      do {
        try store.withGitCancellation(owner) { try store.rememberGitFolder(folder(source), location: location, status: "ready", now: model.now, preparedBranch: text(100)) }
      } catch let failure as GitScheduleViolation { throw failure }
      catch is Crash where pendingReopen { throw Crash() }
      catch {
        if model.discoveryAllowed(source), discoveryReceipt == model.receipt {
          try fail("progress", "permitted discovery unexpectedly failed")
        }
        throw error
      }
      if permitted && model.discoveryAllowed(source) && discoveryReceipt == model.receipt {
        if try scalar("SELECT count(*) FROM git_working_folders WHERE session='invented-\(source)' AND complete=1") != 1 {
          try fail("progress", "permitted discovery did not become durable")
        }
        model.linked.insert(source)
      }
      repository = try scalar("SELECT COALESCE(max(id),0) FROM git_repositories")
      if repository == 0 { repository = nil }
    case .prepare:
      guard let repository else { return }
      model.readReceipt = model.receipt; model.readAt = model.now
      if commitID == nil { model.commitReceipt = model.receipt; model.producerCancelled = false; model.outcome = .prepared }
      model.readInterrupted = false
      policy = try store.gitPreparationPolicy()
      let file = root.appendingPathComponent(UUID().uuidString); FileManager.default.createFile(atPath: file.path, contents: nil)
      let out = try FileHandle(forWritingTo: file); defer { try? out.close() }
      try store.withGitCancellation(owner) { try store.prepareGitRefs(repo: repository, to: out, now: model.now) }
    case .parent:
      family = "commit"
      guard let repository, let policy else { return }
      authority = model.commitAllowed
      if (model.nativePrivacy || model.erased.contains(model.hash)) && model.current && model.provenance && model.commitReceipt?.generation == model.generation { model.outcome = .refused }
      else if model.expired { model.outcome = .expired }
      else if !authority { model.outcome = .interrupted; model.readInterrupted = true }
      else { model.outcome = .publishing }
      let fields = try (0..<3).map { try text(UInt8(97 + $0)) }
      commitID = try store.withGitCancellation(owner) { try store.beginGitCommit(repo: repository, prepared: GitPreparedMetadata(hash: model.hash, authorTime: model.author, commitTime: model.committed, fields: fields), generation: policy.generation, now: model.now, preparationPolicy: policy) }
      if authority, commitID == nil, try scalar("SELECT count(*) FROM git_commits WHERE hash='\(model.hash)' AND complete=1") == 0 {
        try fail("progress", "permitted new parent was silently omitted")
      }
    case .file(let index):
      family = "commit"
      guard let commitID else { return }
      authority = model.commitAllowed && model.outcome == .publishing
      let value: GitMaskedText
      if malformed {
        let file = root.appendingPathComponent(UUID().uuidString)
        try Data(repeating: UInt8(112 + index), count: 65536).write(to: file)
        value = GitMaskedText(maskedFile: file, byteCount: bytes)
        model.outcome = .interrupted; model.readInterrupted = true
      } else { value = try text(UInt8(112 + index)) }
      do { try store.withGitCancellation(owner) { try store.appendGitFile(GitPreparedChangedFile(oldPath: nil, path: value, added: index + 1, deleted: 0), commit: commitID, now: model.now) } }
      catch let error as GitScheduleViolation { throw error }
      catch { model.outcome = .interrupted; model.readInterrupted = true }
      if model.erased.contains(model.hash) || model.nativePrivacy { model.outcome = .refused }
      else if !model.commitAllowed { model.outcome = .interrupted; model.readInterrupted = true }
      model.stalePreview = preview != nil
    case .ref:
      family = "commit"
      guard let commitID else { return }
      authority = model.commitAllowed && model.outcome == .publishing
      try store.withGitCancellation(owner) { try store.appendGitCommitRef(text(114), identity: "invented-ref", commit: commitID, now: model.now) }
    case .complete:
      family = "commit"
      guard let commitID else { return }
      authority = model.commitAllowed && model.outcome == .publishing
      let result = try store.withGitCancellation(owner) { try store.finishGitCommit(commitID, now: model.now) }
      try snapshot()
      if result == .complete && (!model.commitAllowed || model.outcome != .publishing) { try fail("interruption", "interrupted producer completed") }
      if result == .complete { model.outcome = .complete }
      else if result == .retry { model.readInterrupted = true }
      self.commitID = nil
    case .stage:
      family = "frontier"
      guard let repository else { return }
      authority = model.frontierAllowed
      try store.withGitCancellation(owner) { try store.stageGitRef(repo: repository, name: text(118), identity: "invented-frontier", tip: model.hash) }
    case .certify:
      family = "frontier"
      guard let repository else { return }
      authority = model.frontierAllowed
      try store.withGitCancellation(owner) { try store.finishGitRead(repo: repository, now: model.now, outcome: .accounted) }
    }
    try snapshot()
    authority = false
  }
  func run(_ schedule: [GitScheduleStep]) throws {
    for step in schedule {
      do { try self.step(step) }
      catch let violation as GitScheduleViolation { throw violation }
      catch {
        if pendingReopen { pendingReopen = false; family = ""; try event(.crash) }
        // Rejected publication and cancellation are legal. Still examine durable
        // state so an implementation cannot hide a partial write behind an error.
        model.readInterrupted = true
        try snapshot(); authority = false
      }
    }
    if schedule.suffix(3) == [.complete, .stage, .certify], model.commitAllowed,
      !model.nativePrivacy, !model.expired, !model.erased.contains(model.hash) {
      if try scalar("SELECT count(*) FROM git_commits WHERE hash='\(model.hash)' AND complete=1") != 1 {
        try fail("interruption", "permitted fresh retry did not recover full commit")
      }
      if previousRead != model.now { try fail("frontier", "permitted accounted traversal did not certify") }
    }
  }
}

final class GitPublicationScheduleTests: XCTestCase {
  private let seeds: [UInt64] = [1, 7, 19, 41, 97, 313, 2027, 0xdecafbad]
  private let prefix: [GitScheduleStep] = [.discover(0), .discover(1), .prepare]
  private let payload: [GitScheduleStep] = [.parent, .file(0), .file(1), .ref, .complete, .stage, .certify]
  private func verify(_ schedules: [[GitScheduleStep]], label: String, required: [GitScheduleEvent] = []) throws {
    var totalSnapshots = 0, coverage = Set<String>()
    for (index, schedule) in schedules.enumerated() {
      let replay = try GitScheduleReplay(bytes: 65537 + index % 3 * 16384)
      defer { replay.close() }
      do { try replay.run(schedule) }
      catch let violation as GitScheduleViolation {
        print("original failure=\(schedule.map(\.description).joined(separator: " -> "))")
        let minimal = try shrinkGitSchedule(schedule) { candidate in
          guard gitScheduleIsReplayable(candidate) else { return false }
          let copy = try GitScheduleReplay(bytes: 65537 + index % 3 * 16384); defer { copy.close() }
          do { try copy.run(candidate); return false }
          catch let failure as GitScheduleViolation { return failure.property == violation.property }
        }
        // The last pass proves 1-minimality against deletion, including dependencies.
        for offset in minimal.indices {
          var candidate = minimal; candidate.remove(at: offset)
          guard gitScheduleIsReplayable(candidate) else { continue }
          let copy = try GitScheduleReplay(bytes: 65537 + index % 3 * 16384); defer { copy.close() }
          do { try copy.run(candidate) }
          catch let failure as GitScheduleViolation { XCTAssertNotEqual(failure.property, violation.property, "shrinker did not reach 1-minimality") }
        }
        XCTFail("MODEL \(label) case=\(index) \(violation)\n1-minimal=\(minimal.map(\.description).joined(separator: " -> "))")
        return
      }
      totalSnapshots += replay.snapshots; coverage.formUnion(replay.events)
    }
    XCTAssertTrue(Set(required.map(\.rawValue)).isSubset(of: coverage), "required event was never executed: \(Set(required.map(\.rawValue)).subtracting(coverage))")
    print("generated Git model \(label): schedules=\(schedules.count) snapshots=\(totalSnapshots) distinct_steps=\(coverage.count) seeds=\(seeds.map(String.init).joined(separator: ","))")
  }
  func testGeneratedAdmissionSchedules() throws {
    let disturbances: [GitScheduleEvent] = [.secureOn, .secureUnknown, .recordingOff, .pause, .roundTrip, .authorOff, .commitOff, .authorPause, .commitPause, .own, .revoke]
    var schedules = [[GitScheduleStep]]()
    for seed in seeds {
      var random = GitScheduleRandom(state: seed)
      for event in disturbances {
        let phases = ["author", "email", "message", "file", "commit-ref", "staging", "frontier", "completion", "certification"]
        let phase = phases[random.next(phases.count)]
        schedules.append(prefix + [.arm(phase, event)] + payload + [.event(.secureOff), .event(.recordingOn), .event(.resume), .retry, .discover(1), .prepare] + payload)
      }
      schedules.append([.event(.secureUnknown), .discover(0), .event(.secureOff), .discover(0), .event(.own), .discover(0), .discover(1), .prepare] + payload)
    }
    for event in disturbances {
      schedules.append([.arm("branch", event), .discover(0), .event(.secureOff), .event(.recordingOn), .retry, .discover(1), .prepare] + payload)
    }
    try verify(schedules, label: "admission", required: disturbances)
  }
  func testGeneratedCompletionSchedules() throws {
    try verify(seeds.map { seed in
      var random = GitScheduleRandom(state: seed)
      let index = random.next(2)
      return prefix + [.parent, .event(.brokenStream), .file(index), .complete, .stage, .certify, .event(.crash), .retry, .prepare] + payload
    }, label: "completion")
  }
  func testGeneratedFrontierSchedules() throws {
    var schedules = [[GitScheduleStep]]()
    for seed in seeds {
      var random = GitScheduleRandom(state: seed)
      let partial = Array(payload.prefix(1 + random.next(4)))
      schedules.append(prefix + partial + [.stage, .certify, .event(.crash), .retry, .prepare] + payload)
      schedules.append(prefix + [.arm("frontier", .secureUnknown)] + payload + [.event(.crash), .event(.secureOff), .retry, .prepare] + payload)
    }
    try verify(schedules, label: "frontier")
  }
  func testGeneratedInterruptionSchedules() throws {
    var schedules = [[GitScheduleStep]]()
    for seed in seeds {
      var random = GitScheduleRandom(state: seed)
      for event: GitScheduleEvent in [.cancel, .stop, .crash, .busy] {
        let phase = ["message", "file", "commit-ref", "staging"][random.next(4)]
        schedules.append(prefix + [.arm(phase, event)] + payload + [.event(.replacement), .complete, .stage, .certify, .event(.crash), .retry, .prepare] + payload)
      }
      schedules.append(prefix + Array(payload.prefix(1 + random.next(4))) + [.event(.crash), .retry, .prepare] + payload)
      schedules.append(prefix + [.parent, .event(.cancel), .event(.replacement), .file(0), .file(1), .ref, .complete, .stage, .certify])
    }
    try verify(schedules, label: "interruption", required: [.cancel, .stop, .crash, .busy, .replacement])
  }
  func testGeneratedErasureSchedules() throws {
    var schedules = [[GitScheduleStep]]()
    for seed in seeds {
      var random = GitScheduleRandom(state: seed)
      let phase = ["message", "file", "commit-ref", "staging", "frontier"][random.next(5)]
      schedules.append(prefix + [.arm(phase, .forget)] + payload + [.event(.crash), .retry, .retime, .prepare] + payload)
      schedules.append(prefix + [.parent, .event(.preview), .file(0), .event(.staleConfirm), .file(1), .ref, .complete, .stage, .certify, .event(.forget), .event(.crash), .retry, .retime, .prepare] + payload)
    }
    try verify(schedules, label: "erasure", required: [.forget, .preview, .staleConfirm])
  }
  func testGeneratedRetentionSchedules() throws {
    var schedules = [[GitScheduleStep]]()
    for seed in seeds {
      var random = GitScheduleRandom(state: seed)
      let phase = ["author", "message", "file", "commit-ref", "staging", "frontier"][random.next(6)]
      schedules.append(prefix + [.arm(phase, .retain)] + payload + [.event(.expand), .retry, .discover(1), .prepare] + payload)
      schedules.append(prefix + [.event(.retain), .discover(1), .prepare] + payload + [.event(.expand), .retry, .discover(1), .prepare] + payload)
    }
    try verify(schedules, label: "retention", required: [.retain, .expand])
  }
  func testScheduleShrinkerPreservesPropertyAndFindsMinimalTrace() throws {
    let input: [GitScheduleStep] = [.discover(0), .event(.secureOn), .prepare, .parent, .event(.secureOff), .file(0), .certify]
    let result = shrinkGitSchedule(input) { $0.contains(.event(.secureOn)) && $0.contains(.parent) }
    XCTAssertEqual(result, [.event(.secureOn), .parent])
  }
}
