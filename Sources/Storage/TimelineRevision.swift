import Core
import Darwin
import Foundation
import SQLite3

/// What a day's grid is computed from, small enough to compare every second.
/// The counts and hashes are only ever compared with each other in this process.
public struct TimelineDayRevision: Equatable {
  /// Every model call overlapping the day, each column of each row.
  public var calls: Int
  /// Every interval overlapping what the grid reads, each column of each row.
  public var intervals: Int
  /// Every forgotten range, whichever day it is on, with its row id.
  public var forgotten: Int
  /// Sample rows in the seconds the visible minutes depend on. A row in the unfinished minute is not counted.
  public var samples: Int
}

extension ActivityStorage {
  /// Reads no window title, no application name and no decoded call facts, and no sample row: the
  /// count walks the time index. Call it in the same query snapshot as the read it stands for.
  ///
  /// Forget commits in batches, so each batch is seen on its own: its marker in `forgotten`, its
  /// intervals in `intervals`, a rewritten call in `calls`, and its samples in `samples`.
  public func timelineDayRevision(day: TimeRange, visible: TimeRange) throws -> TimelineDayRevision {
    try locked {
      let overlapping: [SQLValue] = [.integer(day.end), .integer(day.start)]
      // Same span as SummaryTimeline.minutes, widened from the visible part to the whole day.
      var earliest = visible.start, latest = visible.end, unfactedEnd: Int?
      try connection.rows("""
        SELECT min(start_ts), max(end_ts), max(CASE WHEN table_facts IS NULL THEN end_ts END)
        FROM model_calls WHERE start_ts<? AND end_ts>? AND pending=0 AND succeeded=1
        """, overlapping) {
        guard sqlite3_column_type($0, 0) != SQLITE_NULL else { return }
        earliest = min(earliest, SQLiteConnection.int($0, 0)); latest = max(latest, SQLiteConnection.int($0, 1))
        if sqlite3_column_type($0, 2) != SQLITE_NULL { unfactedEnd = SQLiteConnection.int($0, 2) }
      }
      earliest -= RestPolicy.inputAgeSeconds + 1
      latest += 60
      // A row in a later minute reaches a finished minute only through a call without sent-table facts,
      // whose rest tail is rebuilt from what follows the call's end.
      let samplesEnd = (unfactedEnd ?? Int.min) >= visible.end ? latest : visible.end
      var samples = 0
      try connection.rows("SELECT count(*) FROM samples WHERE ts>=? AND ts<?", [.integer(earliest), .integer(samplesEnd)]) {
        samples = SQLiteConnection.int($0, 0)
      }
      return TimelineDayRevision(
        calls: try rowsHash("SELECT * FROM model_calls WHERE start_ts<? AND end_ts>? ORDER BY id", overlapping),
        intervals: try rowsHash("SELECT * FROM intervals WHERE start_ts<? AND end_ts>? ORDER BY id", [.integer(latest), .integer(earliest)]),
        forgotten: try rowsHash("SELECT rowid,start_ts,end_ts FROM forgotten_ranges ORDER BY rowid", []),
        samples: samples)
    }
  }

  private func rowsHash(_ sql: String, _ values: [SQLValue]) throws -> Int {
    var hasher = Hasher()
    try connection.rows(sql, values) { row in
      for column in 0..<sqlite3_column_count(row) {
        hasher.combine(sqlite3_column_type(row, column))
        let bytes = sqlite3_column_blob(row, column)
        let size = Int(sqlite3_column_bytes(row, column))
        hasher.combine(size)
        if let bytes, size > 0 { hasher.combine(bytes: UnsafeRawBufferPointer(start: bytes, count: size)) }
      }
    }
    return hasher.finalize()
  }

  /// False once the database's path names another file, as after a conversion. A long-lived connection
  /// would keep reading the old file, with whatever was removed since.
  public var openedFileIsCurrent: Bool {
    var info = stat()
    guard stat(url.path, &info) == 0, let openedIdentity else { return false }
    return openedIdentity == [UInt64(info.st_dev), UInt64(info.st_ino)]
  }
}
