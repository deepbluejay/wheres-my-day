import Foundation

extension SQLiteConnection {
  /// Check declared integer columns before a decoder can coerce malformed values.
  func invalidIntegerValues() throws -> Int {
    func quoted(_ identifier: String) -> String { "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
    var checks: [String] = []
    try namedRows("""
      SELECT m.name AS table_name,p.name AS column_name FROM sqlite_schema AS m
      JOIN pragma_table_info(m.name) AS p WHERE m.type='table' AND instr(upper(p.type),'INT')>0
      """) { row in
      let table = quoted(try row.text("table_name")), column = quoted(try row.text("column_name"))
      checks.append("SELECT count(*) AS invalid FROM \(table) WHERE typeof(\(column)) NOT IN ('integer','null')")
    }
    guard !checks.isEmpty else { return 0 }
    return try integer("SELECT COALESCE(SUM(invalid),0) FROM (" + checks.joined(separator: " UNION ALL ") + ")")
  }
}
