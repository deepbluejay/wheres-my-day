import Core
import CryptoKit
import Foundation

public struct ConversionManifestLine: Equatable {
  public let metric: String
  public let expected: Int
  public let actual: Int
  public init(metric: String, expected: Int, actual: Int) {
    self.metric = metric; self.expected = expected; self.actual = actual
  }
  public var passed: Bool { expected == actual }
  public var text: String { "\(metric) expected=\(expected) actual=\(actual) \(passed ? "PASS" : "FAIL")" }
}
public struct ConversionManifest {
  public let lines: [ConversionManifestLine]
  public init(lines: [ConversionManifestLine]) { self.lines = lines }
  public var passed: Bool { lines.allSatisfy(\.passed) }
  public var text: String { (lines.map(\.text) + [passed ? "manifest PASS" : "manifest FAIL"]).joined(separator: "\n") }
}

// Aggregates carry no source strings. Four independent digest sums also catch row-level changes
// that leave counts and token totals unchanged, including projects and source identities.
private struct ConversionMetrics {
  var values: [String: Int] = [:]
  var seconds: [Int: Set<Int>] = [:]
  var calendar: Calendar
  mutating func add(_ key: String, _ amount: Int = 1) { values[key, default: 0] += amount }
  mutating func row(_ table: String, numbers: [Int], strings: [String] = []) throws {
    add(table + ".rows")
    let bytes = try JSONSerialization.data(withJSONObject: [numbers, strings], options: [.sortedKeys])
    let hash = Array(SHA256.hash(data: bytes))
    for word in 0..<4 {
      let value = hash[(word * 4)..<(word * 4 + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
      // Keep the sum bounded for arbitrarily large imports.
      let key = table + ".digest.\(word)"
      values[key] = Int(UInt32(truncatingIfNeeded: values[key, default: 0]) &+ value)
    }
  }
  mutating func sample(_ numbers: [Int], strings: [String], sumCounters: Bool = true) throws {
    try row("samples", numbers: numbers, strings: strings)
    let time = numbers[0], day = Int(calendar.startOfDay(for: Date(timeIntervalSince1970: Double(time))).timeIntervalSince1970)
    let prefix = "samples.day.\(day)."
    add(prefix + "rows")
    seconds[day, default: []].insert(time)
    values[prefix + "distinct"] = seconds[day]!.count
    values[prefix + "min"] = min(values[prefix + "min"] ?? time, time)
    values[prefix + "max"] = max(values[prefix + "max"] ?? time, time)
    for (index, name) in ["keys", "clicks", "scrolls", "moved", "synthetic", "awake", "excluded"].enumerated() {
      if sumCounters { add(prefix + name, numbers[index + 1]) }
    }
  }
  mutating func interval(_ start: Int, _ end: Int, kind: String, state: String, strings: [String], sumDurations: Bool = true) throws {
    try row("intervals", numbers: [start, end], strings: [kind, state] + strings)
    var cursor = start
    while cursor < end {
      let day = calendar.startOfDay(for: Date(timeIntervalSince1970: Double(cursor)))
      guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { throw StorageError("Calendar boundary unavailable") }
      let stop = min(end, Int(next.timeIntervalSince1970))
      add("intervals.day.\(Int(day.timeIntervalSince1970)).\(state == "private" ? "private" : kind).seconds", sumDurations ? stop - cursor : 0)
      cursor = stop
    }
  }
}

extension ActivityStorage {
  /// A separate projection of source facts, not a second run of the converter.
  /// The source must remain frozen at the same path for the entire operator run.
  public func conversionManifest(source: URL, calendar: Calendar = .current) throws -> ConversionManifest {
    let old = try SQLiteConnection(url: source, readOnly: true, immutable: true, scope: databaseScope)
    return try locked { try connection.transaction(write: false) {
      let types = [ConversionManifestLine(metric: "source.invalid_integer_values", expected: 0, actual: try old.invalidIntegerValues()),
        ConversionManifestLine(metric: "destination.invalid_integer_values", expected: 0, actual: try connection.invalidIntegerValues())]
      guard types.allSatisfy(\.passed) else { return ConversionManifest(lines: types) }
      var expected = ConversionMetrics(calendar: calendar), actual = ConversionMetrics(calendar: calendar)
      var lines: [ConversionManifestLine] = types
      func check(_ key: String, _ wanted: Int, _ found: Int) {
        lines.append(ConversionManifestLine(metric: key, expected: wanted, actual: found))
      }
      func integrity(_ db: SQLiteConnection) throws -> Int {
        var good = 1
        try db.namedRows("PRAGMA integrity_check") { if try $0.text("integrity_check") != "ok" { good = 0 } }
        return good
      }
      check("source.integrity", 1, try integrity(old)); check("destination.integrity", 1, try integrity(connection))
      check("source.application", 0, try old.integer("PRAGMA application_id"))
      check("source.version_supported", 1, (0...11).contains(try old.integer("PRAGMA user_version")) ? 1 : 0)
      check("destination.application", SQLiteConnection.applicationID, try connection.integer("PRAGMA application_id"))
      check("destination.version", SQLiteConnection.schemaVersion, try connection.integer("PRAGMA user_version"))
      check("finished", 1, try connection.integer("SELECT count(*) FROM conversion_progress WHERE layer='finished' AND last_row=1"))
      let counts = try conversionCounts()
      func columns(_ table: String) throws -> Set<String> {
        var result = Set<String>()
        try old.namedRows("PRAGMA table_info(\(table))") { result.insert(try $0.text("name")) }
        return result
      }
      func rows(_ table: String, defaults: [(String, String)] = [], order: String = "rowid",
        _ visit: (DatabaseRow) throws -> Void) throws {
        let names = try columns(table)
        guard !names.isEmpty else { return }
        let extra = defaults.filter { !names.contains($0.0) }.map { "\($0.1) AS \($0.0)" }
        try old.namedRows("SELECT " + (["*"] + extra).joined(separator: ",") + " FROM \(table) ORDER BY \(order)", [], visit)
      }
      let tableNames = ["forgotten", "forgotten_session_rows", "wanted", "log_cursors", "samples", "evidence", "activities", "llm_runs"]
      for table in tableNames {
        let total = try columns(table).isEmpty ? 0 : old.integer("SELECT count(*) FROM \(table)")
        check("source.\(table).rows", total,
          counts["table.\(table).carried", default: 0] + counts["table.\(table).refused", default: 0] + counts["table.\(table).notCarried", default: 0])
      }
      var projectedCounts: [String: Int] = [:]
      func disposition(_ table: String, _ kind: String) { projectedCounts["table.\(table).\(kind)", default: 0] += 1 }
      func mask(_ value: String) -> String { Redaction.apply(value).text }
      func key(_ value: String) -> String { Redaction.applyKnownSecrets(value).text }
      func pair(_ a: String, _ b: String) -> String { "\(a.utf8.count):\(a)\(b)" }
      func canonicalState(_ text: String) -> String {
        guard let object = try? JSONSerialization.jsonObject(with:Data(text.utf8),options:[.fragmentsAllowed]),
          let bytes = try? JSONSerialization.data(withJSONObject:object,options:[.sortedKeys,.fragmentsAllowed]) else { return text }
        return String(decoding:bytes,as:UTF8.self)
      }
      var forgotten: [TimeRange] = []
      var identities = Set<String>(), nativeIDs = Set<String>(), evidenceIDs = Set<String>(), seenNative = Set<String>()
      try rows("forgotten") { row in
        let start = try row.int("start_ts"), end = try row.int("end_ts")
        forgotten.append(TimeRange(start, end)); disposition("forgotten", "carried")
        try expected.row("forgotten_ranges", numbers: [start, end])
      }
      func isForgotten(_ start: Int, _ end: Int) -> Bool { forgotten.contains { $0.start < end && $0.end > start } }
      try rows("forgotten_session_rows") { row in
        let source = key(try row.text("bundle_id")), id = key(try row.text("source_id"))
        if identities.insert(pair(source, id)).inserted {
          nativeIDs.insert(id); disposition("forgotten_session_rows", "carried")
          try expected.row("forgotten_sources", numbers: [], strings: [source, id])
        } else { disposition("forgotten_session_rows", "refused") }
      }
      var wanted: Int?
      try rows("wanted") { row in wanted = try row.int("recording") == 0 ? 0 : 1; disposition("wanted", "carried") }
      // Operator intent deliberately supersedes the final old wanted value after stop.
      _ = wanted
      var paths = Set<String>()
      try rows("log_cursors") { row in
        let path = key(try row.text("path")), offset = try row.int("offset")
        if paths.contains(path) || offset < 0 { disposition("log_cursors", "refused"); return }
        paths.insert(path); disposition("log_cursors", "carried")
        let state = try row.text("state")
        let storedState: String
        if let object = try? JSONSerialization.jsonObject(with: Data(state.utf8)) as? [String: Any],
          !Set(object.keys).isDisjoint(with: ["session", "threadID", "project", "folder", "queued", "metadataRead"]) {
          var parsed = try AgentLogState.decode(state); parsed.project = mask(parsed.project)
          storedState = key(try parsed.encoded())
        } else { storedState = mask(state) }
        try expected.row("log_positions", numbers: [try row.int("device"), try row.int("inode"), offset, try row.int("seen_ts")], strings: [path, canonicalState(storedState)])
      }
      try rows("samples", defaults: [("watching", "0"), ("hidden_reason", "''")]) { row in
        let time = try row.int("ts"), keys = try row.int("keys"), clicks = try row.int("clicks"), scrolls = try row.int("scrolls"), synth = try row.int("synth")
        guard time < Int.max else { throw StorageError("Unsupported source timestamp") }
        if isForgotten(time, time + 1) || min(keys, clicks, scrolls, synth) < 0 { disposition("samples", "refused"); return }
        disposition("samples", "carried")
        let hidden = try !row.text("hidden_reason").isEmpty || row.text("doc_key") == "(비공개)"
        try expected.sample([time, keys, clicks, scrolls, try row.int("moved") == 0 ? 0 : 1, synth, try row.int("watching") == 0 ? 0 : 1, hidden ? 1 : 0],
          strings: [key(try row.text("bundle_id")), mask(try row.text("app")), hidden ? "" : mask(try row.text("title")), hidden ? "" : mask(try row.text("doc_key"))])
      }
      var diagnostic: [String: Int] = [:]
      try rows("evidence", defaults: [("source_id", "NULL"), ("project", "''")]) { row in
        let oldKind = try row.text("kind"), kind = ["ocr", "screen"].contains(oldKind) ? "screen" : oldKind == "prompt" ? "prompt" : ""
        let safeKind = ["ocr", "screen", "prompt", "input", "reply", "choice", "typed"].contains(oldKind) ? oldKind : "other"
        expected.add("source.evidence.kind." + safeKind)
        if kind.isEmpty {
          disposition("evidence", "notCarried"); diagnostic["skippedKind." + safeKind, default: 0] += 1; return
        }
        if try row.text("doc_key") == "(비공개)" {
          disposition("evidence", "notCarried"); diagnostic["skippedHiddenEvidence", default: 0] += 1; return
        }
        let source = key(try row.text("bundle_id")), id = key(try row.text("source_id")), time = try row.int("ts")
        guard time < Int.max else { throw StorageError("Unsupported source timestamp") }
        let native = kind == "prompt" && id.hasPrefix("claude:") && !id.hasPrefix("claude:legacy:") && !id.isEmpty
        if isForgotten(time, time + 1) {
          if native && identities.insert(pair(source, id)).inserted {
            nativeIDs.insert(id); try expected.row("forgotten_sources", numbers: [], strings: [source, id])
          }
          disposition("evidence", "refused"); diagnostic["evidence.forgotten", default: 0] += 1; return
        }
        if !id.isEmpty && (identities.contains(pair(source, id)) || evidenceIDs.contains(pair(source, id)) || (native && (nativeIDs.contains(id) || seenNative.contains(id)))) {
          disposition("evidence", "refused"); diagnostic["evidence.deduplicated", default: 0] += 1; return
        }
        if !id.isEmpty { evidenceIDs.insert(pair(source, id)); if kind == "prompt" { seenNative.insert(id) } }
        disposition("evidence", "carried"); expected.add("evidence.kind." + kind)
        try expected.row("evidence", numbers: [time, id.isEmpty ? 0 : 1], strings: [kind, source, id, mask(try row.text("doc_key")), mask(try row.text("project")), mask(try row.text("text"))])
      }
      var lastEnd = Int.min
      let activityColumns = try columns("activities")
      let activeColumn = activityColumns.contains("active_secs") ? "active_secs" : activityColumns.contains("active_seconds") ? "active_seconds" : "0"
      try rows("activities", defaults: [("away", "0"), ("kind", "''"), ("category", "''"), ("project", "''"), ("active_secs", activeColumn)], order: "start_ts,id") { row in
        let originalStart = try row.int("start_ts"), originalEnd = try row.int("end_ts")
        expected.add("baseline.old_interval_wall_seconds", originalEnd - originalStart)
        expected.add("baseline.old_active_seconds", try row.int("active_secs"))
        let startDay = calendar.startOfDay(for: Date(timeIntervalSince1970: Double(originalStart)))
        expected.add("baseline.active_start_day.\(Int(startDay.timeIntervalSince1970))", try row.int("active_secs"))
        var baselineCursor = originalStart
        while baselineCursor < originalEnd {
          let day = calendar.startOfDay(for: Date(timeIntervalSince1970: Double(baselineCursor)))
          guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { throw StorageError("Calendar boundary unavailable") }
          let end = min(originalEnd, Int(next.timeIntervalSince1970))
          expected.add("baseline.wall_day.\(Int(day.timeIntervalSince1970))", end - baselineCursor)
          baselineCursor = end
        }
        if try row.int("away") == 1 { disposition("activities", "notCarried"); diagnostic["skippedAway", default: 0] += 1; return }
        if try row.text("kind") == "unknown" { disposition("activities", "notCarried"); diagnostic["skippedUnknown", default: 0] += 1; return }
        let rounded = Int(floor(Double(originalStart) / 60)) * 60
        let start = max(rounded, lastEnd), end = Int(floor(Double(originalEnd) / 60)) * 60
        if start >= end { disposition("activities", "notCarried"); diagnostic["skippedEmpty", default: 0] += 1; return }
        if isForgotten(start, end) { disposition("activities", "refused"); return }
        let state = try row.text("kind") == "private" ? "private" : "named"
        let category = try row.text("category"), kind = state == "private" ? "" : category == "personal" ? "personal" : category == "leisure" ? "distraction" : "work"
        disposition("activities", "carried"); if start > rounded { diagnostic["shortened", default: 0] += 1 }
        lastEnd = end
        try expected.interval(start, end, kind: kind, state: state, strings: [mask(try row.text("title")), mask(try row.text("summary")), mask(try row.text("project"))])
      }
      try rows("llm_runs", defaults: [("from_ts", "NULL"), ("to_ts", "NULL")]) { row in
        let ts = try row.int("created_at"), from: Int, to: Int
        if case .integer(let v) = try row.value("from_ts") { from = v } else { from = ts }
        guard from < Int.max else { throw StorageError("Unsupported source range") }
        if case .integer(let v) = try row.value("to_ts") { to = max(from + 1, v) } else { to = from + 1 }
        let input = try row.int("input_tokens"), cached = try row.int("cached_tokens"), output = try row.int("output_tokens")
        if min(input, cached, output) < 0 { disposition("llm_runs", "refused"); return }
        disposition("llm_runs", "carried")
        let success = try row.int("ok") == 0 ? 0 : 1
        try expected.row("model_calls", numbers: [ts, from, to, input, cached, output, success], strings: [mask(try row.text("model"))])
        for (key, value) in [("input", input), ("cached", cached), ("output", output), ("successes", success), ("failures", 1 - success)] { expected.add("model_calls." + key, value) }
      }
      for table in tableNames {
        for kind in ["carried", "refused", "notCarried"] {
          let metric = "table.\(table).\(kind)"
          check(metric, projectedCounts[metric, default: 0], counts[metric, default: 0])
        }
      }
      for metric in ["shortened", "skippedAway", "skippedUnknown", "skippedEmpty", "skippedHiddenEvidence", "skippedKind.input", "skippedKind.reply", "skippedKind.choice", "skippedKind.typed", "skippedKind.other"] {
        check(metric, diagnostic[metric, default: 0], counts[metric, default: 0])
      }
      for metric in ["evidence.forgotten", "evidence.deduplicated"] { check(metric, diagnostic[metric, default: 0], counts[metric, default: 0]) }
      try connection.namedRows("SELECT * FROM samples") { row in
        try actual.sample([try row.int("ts"), try row.int("keys"), try row.int("clicks"), try row.int("scrolls"), try row.int("moved"), try row.int("synthetic"), try row.int("keeping_awake"), try row.int("excluded")], strings: [try row.text("bundle_id"), try row.text("app"), try row.text("window"), try row.text("document_key")], sumCounters: false)
      }
      for day in actual.seconds.keys {
        guard let next = calendar.date(byAdding: .day, value: 1, to: Date(timeIntervalSince1970: Double(day))) else { throw StorageError("Calendar boundary unavailable") }
        let columns = ["keys", "clicks", "scrolls", "moved", "synthetic", "keeping_awake", "excluded"]
        let sums = columns.map { "COALESCE(SUM(\($0)),0) AS \($0)" }.joined(separator: ",")
        try connection.namedRows("SELECT " + sums + " FROM samples WHERE ts>=? AND ts<?", [.integer(day), .integer(Int(next.timeIntervalSince1970))]) { row in
          for column in columns {
            actual.values["samples.day.\(day)." + (column == "keeping_awake" ? "awake" : column)] = try row.int(column)
          }
        }
      }
      try connection.namedRows("SELECT * FROM evidence") { row in
        let kind = try row.text("kind"), id = try row.optionalText("source_id")
        actual.add("evidence.kind." + kind)
        try actual.row("evidence", numbers: [try row.int("ts"), id == nil ? 0 : 1], strings: [kind, try row.text("source"), id ?? "", try row.text("document_key"), try row.text("project"), try row.text("text")])
      }
      try connection.namedRows("SELECT * FROM intervals") { row in
        try actual.interval(try row.int("start_ts"), try row.int("end_ts"), kind: try row.text("kind"), state: try row.text("state"), strings: [try row.text("name"), try row.text("description"), try row.text("project")], sumDurations: false)
      }
      try connection.namedRows("SELECT * FROM log_positions") { row in
        try actual.row("log_positions", numbers: [try row.int("device"), try row.int("inode"), try row.int("offset"), try row.int("seen_ts")], strings: [try row.text("path"), canonicalState(try row.text("state"))])
      }
      try connection.namedRows("SELECT * FROM forgotten_ranges") { try actual.row("forgotten_ranges", numbers: [try $0.int("start_ts"), try $0.int("end_ts")]) }
      try connection.namedRows("SELECT * FROM forgotten_sources") { try actual.row("forgotten_sources", numbers: [], strings: [try $0.text("source"), try $0.text("source_id")]) }
      try connection.namedRows("SELECT * FROM model_calls") { row in
        let input = try row.int("input_tokens"), cached = try row.int("cached_tokens"), output = try row.int("output_tokens"), success = try row.int("succeeded")
        try actual.row("model_calls", numbers: [try row.int("ts"), try row.int("start_ts"), try row.int("end_ts"), input, cached, output, success], strings: [try row.text("model")])
      }
      for (metric, expression) in [("input", "input_tokens"), ("cached", "cached_tokens"), ("output", "output_tokens"),
        ("successes", "succeeded"), ("failures", "1-succeeded")] {
        actual.values["model_calls." + metric] = try connection.integer("SELECT COALESCE(SUM(\(expression)),0) FROM model_calls")
      }
      check("model_calls.table_facts", 0, try connection.integer("SELECT count(*) FROM model_calls WHERE table_facts IS NOT NULL"))
      for key in Set(expected.values.keys).union(actual.values.keys).sorted() {
        if key.hasPrefix("intervals.day.") {
          let parts = key.split(separator: "."), day = Int(parts[2])!, kind = String(parts[3])
          guard let next = calendar.date(byAdding: .day, value: 1, to: Date(timeIntervalSince1970: Double(day))) else { throw StorageError("Calendar boundary unavailable") }
          let end = Int(next.timeIntervalSince1970)
          actual.values[key] = try connection.integer("""
            SELECT COALESCE(SUM(MIN(end_ts,?)-MAX(start_ts,?)),0) FROM intervals
            WHERE start_ts<? AND end_ts>? AND CASE WHEN state='private' THEN 'private' ELSE kind END=?
            """, [.integer(end), .integer(day), .integer(end), .integer(day), .key(kind)])
        } else if key == "baseline.old_interval_wall_seconds" {
          actual.values[key] = try old.integer("SELECT COALESCE(SUM(end_ts-start_ts),0) FROM activities")
        } else if key == "baseline.old_active_seconds" {
          actual.values[key] = try old.integer("SELECT COALESCE(SUM(\(activeColumn)),0) FROM activities")
        } else if key.hasPrefix("baseline.wall_day.") || key.hasPrefix("baseline.active_start_day.") {
          let day = Int(key.split(separator:".").last!)!
          guard let next = calendar.date(byAdding:.day,value:1,to:Date(timeIntervalSince1970:Double(day))) else { throw StorageError("Calendar boundary unavailable") }
          let end = Int(next.timeIntervalSince1970)
          if key.hasPrefix("baseline.wall_day.") {
            actual.values[key] = try old.integer("SELECT COALESCE(SUM(MIN(end_ts,?)-MAX(start_ts,?)),0) FROM activities WHERE start_ts<? AND end_ts>? AND end_ts>start_ts", [.integer(end),.integer(day),.integer(end),.integer(day)])
          } else {
            actual.values[key] = try old.integer("SELECT COALESCE(SUM(\(activeColumn)),0) FROM activities WHERE start_ts>=? AND start_ts<?", [.integer(day),.integer(end)])
          }
        }
        if key.hasPrefix("source.evidence.kind.") {
          let kind = String(key.dropFirst("source.evidence.kind.".count))
          actual.values[key] = ["carried", "refused", "notCarried"].reduce(0) { $0 + counts["evidenceKind.\(kind).\($1)", default: 0] }
        }
        check(key, expected.values[key, default: 0], actual.values[key, default: 0])
      }
      return ConversionManifest(lines: lines)
    } }
  }
}
