import Core
import Darwin
import Foundation
import SQLite3

/// One serialized attempt bridges a database write failure and the recorder's next process.
/// It contains billing counts and numeric table facts, never a prompt or answer.
final class ModelCallJournal {
  let directory: OperationalDirectory
  let leaf: String
  init(database: URL) throws {
    directory = try OperationalDirectory(database.deletingLastPathComponent())
    leaf = database.lastPathComponent + ".summary-attempt"
  }
  // Privacy plans survive collection checkpoints. Serialize only operations that
  // can invalidate those plans, using a different file from the publication lock.
  // Always acquire this barrier before the shared journal lock.
  func withPrivacyPlanLock<T>(_ body: () throws -> T) throws -> T {
    let file = try directory.open(leaf + ".privacy-plan.lock", flags: O_CREAT | O_RDWR)!
    defer { flock(file, LOCK_UN); Darwin.close(file) }
    guard flock(file, LOCK_EX) == 0 else { throw StorageError("Privacy planning lock unavailable") }
    return try body()
  }
  func withAccountingLock<T>(_ body: () throws -> T) throws -> T {
    try withPrivacyPlanLock { try withLock(body) }
  }
  func withLock<T>(_ body: () throws -> T) throws -> T {
    let file = try directory.open(leaf + ".lock", flags: O_CREAT | O_RDWR)!
    defer { flock(file, LOCK_UN); Darwin.close(file) }
    guard flock(file, LOCK_EX) == 0 else { throw StorageError("Summary accounting lock unavailable") }
    return try body()
  }
  func withMaintenanceLock<T>(_ connection: SQLiteConnection, _ body: () throws -> T) throws -> T {
    try withPrivacyPlanLock {
      let file = try directory.open(leaf + ".lock", flags: O_CREAT | O_RDWR)!
      defer { connection.collectionMaintenanceYield = nil; flock(file, LOCK_UN); Darwin.close(file) }
      guard flock(file, LOCK_EX) == 0 else { throw StorageError("Summary accounting lock unavailable") }
      connection.collectionMaintenanceYield = {
        guard flock(file, LOCK_UN) == 0 else { throw StorageError("Summary accounting unlock unavailable") }
        // Waiting publishers/recovery can hold the barrier through their SQL commit.
        do { try connection.collectionMaintenanceGap?() }
        catch { flock(file, LOCK_EX); throw error }
        Thread.sleep(forTimeInterval: 0.001)
        guard flock(file, LOCK_EX) == 0 else { throw StorageError("Summary accounting lock unavailable") }
      }
      return try body()
    }
  }
  func read() throws -> (ModelCall, Data)? {
    guard let file = try directory.open(leaf, flags: O_RDONLY, missingAllowed: true) else { return nil }
    let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
    defer { try? handle.close() }
    let bytes = try handle.read(upToCount: 1024 * 1024) ?? Data()
    let call = try JSONDecoder().decode(ModelCall.self, from: bytes)
    guard call.attemptID != nil else { throw StorageError("Summary accounting identity missing") }
    return (call, bytes)
  }
  func save(_ call: ModelCall) throws {
    let bytes = try JSONEncoder().encode(call)
    let temporary = leaf + "." + UUID().uuidString
    let file = try directory.open(temporary, flags: O_CREAT | O_EXCL | O_WRONLY)!
    let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
    defer { try? handle.close(); unlinkat(directory.descriptor, temporary, 0) }
    try handle.write(contentsOf: bytes)
    try handle.synchronize()
    try directory.validate(leaf)
    guard renameat(directory.descriptor, temporary, directory.descriptor, leaf) == 0 else {
      throw StorageError("Summary accounting journal unavailable")
    }
    guard fsync(directory.descriptor) == 0 else { throw StorageError("Summary accounting journal not synchronized") }
  }
  func clear() throws {
    try directory.validate(leaf)
    guard unlinkat(directory.descriptor, leaf, 0) == 0 || errno == ENOENT else {
      throw StorageError("Summary accounting journal could not be removed")
    }
  }
}

extension ActivityStorage {
  func recoverModelCalls(from journal: ModelCallJournal) throws {
    guard let (call, _) = try journal.read() else { return }
    if try !forgottenRanges(in: call.range).isEmpty { try journal.clear(); return }
    _ = try connection.transaction { try insertAccountedModelCall(call) }
    try journal.clear()
  }
  func insertAccountedModelCall(_ call: ModelCall) throws -> AppendResult {
    if call.attemptID != nil, try !forgottenRanges(in: call.range).isEmpty { return AppendResult(refused: 1) }
    try insertModelCall(call)
    return AppendResult(stored: 1)
  }
  public func recoverModelCalls() throws {
    try locked {
      guard sqlite3_db_readonly(connection.handle, "main") == 0 else { throw StorageError("Read-only accounting store") }
      let journal = try ModelCallJournal(database: url)
      try journal.withAccountingLock { try recoverModelCalls(from: journal) }
    }
  }
}
