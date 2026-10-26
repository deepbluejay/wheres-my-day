import Core
import Foundation
import SQLite3

public enum StorageError: Error, CustomStringConvertible {
  case busy(String)
  case broken(String)
  case constraint(String)
  init(_ description: String) { self = .broken(description) }
  public var description: String {
    switch self {
    case .busy(let message), .broken(let message), .constraint(let message): return message
    }
  }
}

enum SQLValue {
  case integer(Int)
  case blob(Data)
  case text(String)
  case key(String)
  case maskedText(String)
  case null
}

struct DatabaseRow {
  private let values: [String: SQLValue]
  init(_ statement: OpaquePointer) {
    var values: [String: SQLValue] = [:]
    for index in 0..<sqlite3_column_count(statement) {
      let name = String(cString: sqlite3_column_name(statement, index))
      switch sqlite3_column_type(statement, index) {
      case SQLITE_NULL: values[name] = .null
      case SQLITE_INTEGER: values[name] = .integer(SQLiteConnection.int(statement, index))
      case SQLITE_BLOB:
        let size = Int(sqlite3_column_bytes(statement, index))
        values[name] = .blob(sqlite3_column_blob(statement, index).map { Data(bytes: $0, count: size) } ?? Data())
      default: values[name] = .text(SQLiteConnection.text(statement, index))
      }
    }
    self.values = values
  }
  func value(_ name: String) throws -> SQLValue {
    guard let value = values[name] else { throw StorageError("Missing column: \(name)") }
    return value
  }
  func data(_ name: String) throws -> Data {
    if case .blob(let data) = try value(name) { return data }; return Data()
  }
  func int(_ name: String) throws -> Int {
    if case .integer(let value) = try value(name) { return value }
    return 0
  }
  func optionalText(_ name: String) throws -> String? {
    if case .text(let value) = try value(name) { return value }
    return nil
  }
  func text(_ name: String) throws -> String { try optionalText(name) ?? "" }
}

final class SQLiteConnection {
  var handle: OpaquePointer?
  var collectionAccountingEnabled = false
  var collectionCommitClock: () -> Int = { Int(Date().timeIntervalSince1970) }
  var collectionProofs: [String: () throws -> Void] = [:]
  var collectionRowContracts: [String: CollectionRowContract] = [:]
  var collectionRefusalExpected: [String: Int]?
  var collectionMaintenanceProof: CollectionMaintenanceProof?
  var collectionMaintenanceAuthorized = false
  var collectionBatchingAuthorized = false
  var collectionBatchChanges = 0
  var collectionBatchTotalBefore = 0
  var collectionLastChanges = 0
  var collectionCheckpointing = false
  var collectionMaintenanceYield: (() throws -> Void)?
  var collectionMaintenanceGap: (() throws -> Void)?
  var collectionPrivacyProgressProof: (() throws -> Void)?
  var collectionPrivacyChangeObserver: ((String, Int64) -> Void)?
  var collectionWriteAuthorized = false
  private var collectionSnapshotURL: URL?
  private var collectionSnapshotScope: DatabaseOpenScope?
  var verifyingCollectionMaintenance = false
  var collectionChangeObserver: ((String, Int64) -> Void)?
  private let busyMilliseconds: Int32
  init(url: URL, readOnly: Bool = false, immutable: Bool = false, scope: DatabaseOpenScope, busyMilliseconds: Int32 = 3000) throws {
    self.busyMilliseconds = busyMilliseconds
    collectionSnapshotURL = url; collectionSnapshotScope = scope
    guard try DatabaseOpenBoundary.open(url, scope: scope,
      readOnly: readOnly, immutable: immutable, handle: &handle) == SQLITE_OK else {
      let error = failure()
      sqlite3_close(handle)
      handle = nil
      throw error
    }
    sqlite3_busy_timeout(handle, busyMilliseconds)
    installCollectionUpdateHook()
    sqlite3_set_authorizer(handle, { context, action, table, _, _, trigger in
      guard let context, let table,
        [SQLITE_INSERT, SQLITE_UPDATE, SQLITE_DELETE].contains(action) else { return SQLITE_OK }
      let owner = Unmanaged<SQLiteConnection>.fromOpaque(context).takeUnretainedValue()
      let collection = CollectionMaintenanceProof.tables.contains(String(cString: table))
      if owner.collectionMaintenanceProof != nil && !owner.collectionWriteAuthorized && trigger == nil && collection { return SQLITE_DENY }
      // SQLite's truncate optimization skips row hooks. Force per-row DELETEs,
      // including deletes issued by a trigger, so absence is still an effect.
      let privacyCalls = String(cString: table) == "model_calls" && owner.collectionPrivacyChangeObserver != nil
      if action == SQLITE_DELETE && (collection || privacyCalls) && owner.collectionMaintenanceProof != nil { return SQLITE_IGNORE }
      return SQLITE_OK
    }, Unmanaged.passUnretained(self).toOpaque())
  }
  init(temporaryCollectionProof: Void) throws {
    busyMilliseconds = 0
    guard sqlite3_open("", &handle) == SQLITE_OK else { throw failure() }
    installCollectionUpdateHook()
  }
  func collectionEntrySnapshot() throws -> SQLiteConnection? {
    guard let url = collectionSnapshotURL, let scope = collectionSnapshotScope else { return nil }
    let snapshot = try SQLiteConnection(url: url, readOnly: true, scope: scope, busyMilliseconds: 0)
    try snapshot.run("BEGIN")
    _ = try snapshot.integer("SELECT count(*) FROM sqlite_master")
    return snapshot
  }
  private func installCollectionUpdateHook() {
    sqlite3_update_hook(handle, { context, _, database, table, row in
      guard let context else { return }
      let owner = Unmanaged<SQLiteConnection>.fromOpaque(context).takeUnretainedValue()
      guard owner.collectionMaintenanceProof != nil || owner.collectionChangeObserver != nil,
        let database, String(cString: database) == "main", let table else { return }
      let name = String(cString: table)
      owner.collectionMaintenanceProof?.noteChange(name, row)
      owner.collectionChangeObserver?(name, row)
      owner.collectionPrivacyChangeObserver?(name, row)
    }, Unmanaged.passUnretained(self).toOpaque())
  }
  deinit { sqlite3_close(handle) }
  func close() throws {
    guard sqlite3_close(handle) == SQLITE_OK else { throw failure() }
    handle = nil
  }
  /// A snapshot can prevent truncation. Limit this attempt to 25 ms, then restore the caller's wait.
  func truncateWAL() -> Bool {
    sqlite3_busy_timeout(handle, min(busyMilliseconds, 25))
    defer { sqlite3_busy_timeout(handle, busyMilliseconds) }
    var logFrames: Int32 = -1
    var checkpointed: Int32 = -1
    let result = sqlite3_wal_checkpoint_v2(handle, nil, SQLITE_CHECKPOINT_TRUNCATE, &logFrames, &checkpointed)
    return result == SQLITE_OK && logFrames == 0 && checkpointed == 0
  }
  func failure() -> StorageError {
    let message = handle.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "Database unavailable"
    let code = sqlite3_errcode(handle)
    if code == SQLITE_BUSY || code == SQLITE_LOCKED { return .busy(message) }
    return code == SQLITE_CONSTRAINT ? .constraint(message) : .broken(message)
  }
  func run(_ sql: String, _ values: [SQLValue] = []) throws {
    try rows(sql, values) { _ in }
  }
  func rows(_ sql: String, _ values: [SQLValue] = [], _ visit: (OpaquePointer) throws -> Void) throws {
    if !collectionWriteAuthorized && sql != "ROLLBACK" { try verifyPendingCollectionChanges() }
    if let proof = collectionMaintenanceProof {
      let command = sql.trimmingCharacters(in: .whitespacesAndNewlines).prefix(7).uppercased()
      if ["CREATE ", "ALTER ", "DROP "].contains(where: command.hasPrefix) { try proof.applySchema(sql) }
    }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
    defer { sqlite3_finalize(statement) }
    for (offset, value) in values.enumerated() {
      let index = Int32(offset + 1)
      let result: Int32
      switch value {
      case .integer(let number): result = sqlite3_bind_int64(statement, index, Int64(number))
      case .null: result = sqlite3_bind_null(statement, index)
      case .blob(let data):
        result = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
      case .text(let text), .key(let text), .maskedText(let text):
        // Lookup keys must retain identity. Only keys use .key; every free-text value is masked.
        let masked: String
        if case .text = value { masked = Redaction.apply(text).text }
        else if case .key = value { masked = Redaction.applyKnownSecrets(text).text }
        else { masked = text }
        result = masked.withCString {
          sqlite3_bind_text(
            statement, index, $0, Int32(masked.utf8.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
      }
      guard result == SQLITE_OK else { throw failure() }
    }
    var result = sqlite3_step(statement)
    while result == SQLITE_ROW {
      try visit(statement)
      result = sqlite3_step(statement)
    }
    guard result == SQLITE_DONE else { throw failure() }
  }
  func namedRows(_ sql: String, _ values: [SQLValue] = [], _ visit: (DatabaseRow) throws -> Void) throws {
    try rows(sql, values) { try visit(DatabaseRow($0)) }
  }
  func integer(_ sql: String, _ values: [SQLValue] = []) throws -> Int {
    var value = 0
    try rows(sql, values) { value = Self.int($0, 0) }
    return value
  }
  func transaction<T>(write: Bool = true, collectionMaintenance: Bool = false, collectionFullBaseline: Bool = false, _ body: () throws -> T) throws -> T {
    try run(write ? "BEGIN IMMEDIATE" : "BEGIN")
    collectionProofs.removeAll()
    collectionRowContracts.removeAll(); collectionRefusalExpected = nil
    defer { collectionPrivacyChangeObserver = nil; collectionPrivacyProgressProof = nil; collectionBatchingAuthorized = false; collectionBatchChanges = 0; collectionMaintenanceAuthorized = false; collectionMaintenanceProof = nil; collectionProofs.removeAll(); collectionRowContracts.removeAll(); collectionRefusalExpected = nil }
    do {
      collectionBatchChanges = 0; collectionBatchTotalBefore = Int(sqlite3_total_changes(handle)); collectionBatchingAuthorized = false
      collectionMaintenanceAuthorized = collectionMaintenance
      if write { collectionMaintenanceProof = try CollectionMaintenanceProof(self, full: collectionFullBaseline) }
      let result = try body()
      collectionCheckpointing = true
      defer { collectionCheckpointing = false }
      if collectionMaintenanceAuthorized, collectionMaintenanceProof?.full == false {
        try collectionMaintenanceProof?.cleanupErasedReferences(self)
      }
      if write && collectionAccountingEnabled { try commitCollectionIngestion(at: collectionCommitClock()) }
      // Accounting can fire triggers too. Nothing writes after these proofs.
      for key in collectionProofs.keys.sorted() { try collectionProofs[key]!() }
      try verifyCollectionMaintenance()
      try collectionPrivacyProgressProof?()
      try run("COMMIT")
      return result
    } catch {
      try? run("ROLLBACK")
      throw error
    }
  }
  static func int(_ s: OpaquePointer, _ c: Int32) -> Int { Int(sqlite3_column_int64(s, c)) }
  static func text(_ s: OpaquePointer, _ c: Int32) -> String {
    guard let text = sqlite3_column_text(s, c) else { return "" }
    let bytes = UnsafeBufferPointer(start: text, count: Int(sqlite3_column_bytes(s, c)))
    return String(decoding: bytes, as: UTF8.self)
  }
  static func optionalText(_ s: OpaquePointer, _ c: Int32) -> String? {
    sqlite3_column_type(s, c) == SQLITE_NULL ? nil : text(s, c)
  }
}

// Exact identities serialize only at the SQL boundary; callers cannot compare their text by accident.
extension SQLValue {
  static func key<Kind>(_ identity: AgentLogExactIdentity<Kind>) -> SQLValue { .key(identity.storedKey) }
  static func text<Kind>(_ identity: AgentLogExactIdentity<Kind>) -> SQLValue { .text(identity.storedKey) }
  static func maskedText<Kind>(_ identity: AgentLogExactIdentity<Kind>) -> SQLValue { .maskedText(identity.storedKey) }
}
