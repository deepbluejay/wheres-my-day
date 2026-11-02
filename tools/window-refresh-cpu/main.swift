// What one open window costs, without a window: drives the window model on an invented database in a
// temporary folder, while a child process commits one invented sample a second as the recorder would.
// Usage: WindowRefreshCPU <visible|hidden> <seconds> <empty folder under /tmp>
// Passive health is a constant here, so permission checks and SwiftUI drawing are not part of the number.
import Core
import Darwin
import Foundation
import Outbound
import Shell
import SQLite3
import Storage

func fail(_ message: String) -> Never { FileHandle.standardError.write(Data((message + "\n").utf8)); exit(2) }
func check(_ code: Int32, _ db: OpaquePointer?) {
  guard code == SQLITE_OK || code == SQLITE_DONE || code == SQLITE_ROW else { fail("sqlite: " + String(cString: sqlite3_errmsg(db))) }
}
func openRaw(_ path: String) -> OpaquePointer? {
  var db: OpaquePointer?
  check(sqlite3_open(path, &db), db)
  sqlite3_busy_timeout(db, 3000)
  return db
}
let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
func insert(_ db: OpaquePointer?, _ sql: String, rows: Int, bind: (OpaquePointer, Int) -> Void) {
  var statement: OpaquePointer?
  check(sqlite3_prepare_v2(db, sql, -1, &statement, nil), db)
  defer { sqlite3_finalize(statement) }
  for row in 0..<rows {
    sqlite3_reset(statement)
    bind(statement!, row)
    check(sqlite3_step(statement), db)
  }
}
func text(_ statement: OpaquePointer, _ index: Int32, _ value: String) { sqlite3_bind_text(statement, index, value, -1, transient) }
func int(_ statement: OpaquePointer, _ index: Int32, _ value: Int) { sqlite3_bind_int64(statement, index, Int64(value)) }
let sampleSQL = """
  INSERT INTO samples(ts,bundle_id,app,window,document_key,keys,clicks,scrolls,moved,synthetic,keeping_awake,excluded,observed_ts)
  VALUES(?,?,?,?,?,?,?,0,?,0,0,0,?)
  """

/// The last 86,400 seconds at one row a second: ten active hours, ending an hour ago, so the person is away now.
/// One call and one interval per quarter hour for 30 days. Returns the seconds the window's day already covers.
func seed(root: URL, database: URL, now: Int, measuredSeconds: Int) throws -> Int {
  let store = try ActivityStorage(url: database, appDataDirectory: root, databaseScope: .directory(root))
  // A day start in the next hour makes "today" nearly a full day. If that hour is too close, the one after.
  var calendar = Calendar.current
  calendar.timeZone = .current
  let clock = calendar.dateComponents([.hour, .minute, .second], from: Date(timeIntervalSince1970: Double(now)))
  let left = 3600 - clock.minute! * 60 - clock.second!
  let hour = (clock.hour! + (left > measuredSeconds + 60 ? 1 : 2)) % 24
  _ = try store.patchSettings(.edit(.dayStart(hour), ownBundleID: AppPaths.bundleID, now: now))
  let day = try TimelineDay.range(containing: now, dayStartHour: hour, calendar: calendar)
  let db = openRaw(database.path)
  defer { sqlite3_close(db) }
  check(sqlite3_exec(db, "BEGIN", nil, nil, nil), db)
  let first = now - 86400, activeEnd = now - 3600, activeStart = activeEnd - 10 * 3600
  insert(db, sampleSQL, rows: 86400) { statement, row in
    let ts = first + row, active = ts >= activeStart && ts < activeEnd
    int(statement, 1, ts); text(statement, 2, "invented.editor"); text(statement, 3, "Invented editor")
    text(statement, 4, "Invented window title number \(row / 600)"); text(statement, 5, "invented/document/\(row / 900)")
    int(statement, 6, active && row % 3 == 0 ? 1 : 0); int(statement, 7, active && row % 11 == 0 ? 1 : 0)
    int(statement, 8, active && row % 2 == 0 ? 1 : 0); int(statement, 9, ts)
  }
  let quarter = 900, pieces = 30 * 96, encoder = JSONEncoder()
  let aligned = now - now % quarter
  insert(db, "INSERT INTO model_calls(ts,start_ts,end_ts,model,input_tokens,cached_tokens,output_tokens,succeeded,table_facts,pending) VALUES(?,?,?,'invented',1,0,1,1,?,0)", rows: pieces) { statement, row in
    let end = aligned - row * quarter, start = end - quarter
    let minutes = Array(stride(from: start, to: end, by: 60))
    let facts = SummaryCallFacts(through: end, sentRanges: [TimeRange(start, end)], endsAtRest: false, activeMinutes: minutes)
    int(statement, 1, end + 30); int(statement, 2, start); int(statement, 3, end)
    text(statement, 4, String(decoding: try! encoder.encode(facts), as: UTF8.self))
  }
  insert(db, "INSERT INTO intervals(start_ts,end_ts,name,description,kind,project,state) VALUES(?,?,?,'Invented description','work','invented','named')", rows: pieces) { statement, row in
    let end = aligned - row * quarter
    int(statement, 1, end - quarter); int(statement, 2, end); text(statement, 3, "Invented task \(row % 7)")
  }
  check(sqlite3_exec(db, "COMMIT", nil, nil, nil), db)
  return now - max(day.start, first)
}

/// Stands in for the recorder: a commit a second from another process, with no input, until the time limit.
func writer(database: URL, seconds: Int) -> Never {
  let db = openRaw(database.path)
  for _ in 0..<seconds {
    sleep(1)
    let now = Int(Date().timeIntervalSince1970)
    insert(db, sampleSQL, rows: 1) { statement, _ in
      int(statement, 1, now); text(statement, 2, "invented.editor"); text(statement, 3, "Invented editor")
      text(statement, 4, "Invented window title"); text(statement, 5, "invented/document")
      int(statement, 6, 0); int(statement, 7, 0); int(statement, 8, 0); int(statement, 9, now)
    }
  }
  exit(0)
}
func cpu() -> Double {
  var usage = rusage()
  getrusage(RUSAGE_SELF, &usage)
  return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
}
final class Counter {
  private let lock = NSLock(); private var value = 0
  func add() { lock.lock(); value += 1; lock.unlock() }
  var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

@MainActor func measure(mode: String, seconds: Int, root: URL) async throws {
  let database = root.appendingPathComponent("invented.sqlite")
  let now = Int(Date().timeIntervalSince1970), warm = 15
  let rows = try seed(root: root, database: database, now: now, measuredSeconds: seconds + warm + 30)
  let child = Process()
  child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
  child.arguments = ["writer", String(seconds + warm + 5), root.path]
  try child.run()
  defer { if child.isRunning { child.terminate() } }
  let paths = AppPaths(userHome: root.appendingPathComponent("user"), appData: root, database: database,
    appBinary: root.appendingPathComponent("bin/ActivityProbe"), queryHelper: root.appendingPathComponent("bin/ActivityQueryServer"))
  var factories = AppFactories()
  // Accounts in memory and no connector: nothing here reaches a Keychain, a CLI or a browser.
  final class Connector: SubscriptionConnector { func connect() throws {}; func cancel() {} }
  factories.claudeConnector = { _, _ in Connector() }
  let session = { ChatGPTSession(store: InMemoryChatGPTCredentialStore(), lock: ChatGPTCredentialLock(file: nil), openBrowser: { _ in false }) }
  factories.chatGPT = { _ in session() }
  factories.chatGPTTokens = { _ in session() }
  let reads = Counter()
  let (model, _) = try AppComposition(paths: paths, factories: factories).windowModel(
    codex: .absent("codex"), claude: .absent("claude"), health: { reads.add(); return TimelineHealth() })
  model.start()
  try await Task.sleep(for: .seconds(5))
  guard let shown = model.snapshot, !model.readFailed else { fail("the first read failed") }
  if mode == "hidden" { model.setWindowVisible(false) }
  try await Task.sleep(for: .seconds(warm - 5))
  let cpuBefore = cpu(), readsBefore = reads.count, wallBefore = Date()
  try await Task.sleep(for: .seconds(seconds))
  let spent = cpu() - cpuBefore, wall = Date().timeIntervalSince(wallBefore)
  print(String(format: "mode=%@ wall=%.1fs cpu=%.3fs percentOfOneCore=%.2f reads=%d visibleSeconds=%d entries=%d readFailed=%@",
    mode, wall, spent, spent / wall * 100, reads.count - readsBefore, rows, shown.day.entries.count, model.readFailed ? "true" : "false"))
  model.close()
}

let arguments = CommandLine.arguments
guard arguments.count == 4, let seconds = Int(arguments[2]), seconds > 0 else { fail("Usage: WindowRefreshCPU <visible|hidden> <seconds> <empty folder under /tmp>") }
let root = URL(fileURLWithPath: arguments[3]).resolvingSymlinksInPath()
guard root.path.hasPrefix("/tmp/") || root.path.hasPrefix("/private/tmp/") else { fail("Invented data only: the folder must be under /tmp") }
if arguments[1] == "writer" { writer(database: root.appendingPathComponent("invented.sqlite"), seconds: seconds) }
guard ["visible", "hidden"].contains(arguments[1]) else { fail("Mode is visible or hidden") }
Task { @MainActor in
  do { try await measure(mode: arguments[1], seconds: seconds, root: root); exit(0) }
  catch { fail("Failed: \(error)") }
}
dispatchMain()
