import Core
import Foundation

public struct AppCommandResult {
  public let status: Int32
  public let output: String
  public init(_ status: Int32, _ output: String) { self.status = status; self.output = output }
}
public enum AppCommandError: Error { case arguments, time, future, wide, empty, unsafePath, recorder, stale }

public struct ForgetCommandRequest {
  public let range: TimeRange
  public let confirmation: String?
  public let allowOver24Hours: Bool
  public static func parse(_ arguments: [String], now: Int, zone: TimeZone) throws -> Self {
    guard arguments.count >= 2 else { throw AppCommandError.arguments }
    var confirm: String?, wide = false, index = 2
    while index < arguments.count {
      switch arguments[index] {
      case "--allow-over-24h":
        guard !wide else { throw AppCommandError.arguments }; wide = true; index += 1
      case "--confirm":
        guard confirm == nil, index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else { throw AppCommandError.arguments }
        confirm = arguments[index + 1]; index += 2
      default: throw AppCommandError.arguments
      }
    }
    let from = try timestamp(arguments[0], zone: zone), to = try timestamp(arguments[1], zone: zone)
    guard from < to else { throw AppCommandError.empty }
    guard to <= now else { throw AppCommandError.future }
    guard to - from <= 86400 || wide else { throw AppCommandError.wide }
    return Self(range: TimeRange(from, to), confirmation: confirm, allowOver24Hours: wide)
  }
  public static func timestamp(_ text: String, zone: TimeZone) throws -> Int {
    if text.range(of: "^[0-9]+$", options: .regularExpression) != nil,
      let number = Int(text), number <= 253402300799 { return number }
    guard text.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$", options: .regularExpression) != nil else { throw AppCommandError.time }
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
    let numbers = text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    let components = DateComponents(year: numbers[0], month: numbers[1], day: numbers[2], hour: numbers[3], minute: numbers[4], second: numbers[5])
    guard let tentative = calendar.date(from: components) else { throw AppCommandError.time }
    let before = calendar.startOfDay(for: tentative).addingTimeInterval(-1)
    let first = calendar.nextDate(after: before, matching: components, matchingPolicy: .strict, repeatedTimePolicy: .first)
    let last = calendar.nextDate(after: before, matching: components, matchingPolicy: .strict, repeatedTimePolicy: .last)
    guard let first, first == last, local(Int(first.timeIntervalSince1970), zone: zone).hasPrefix(text + " ") else { throw AppCommandError.time }
    return Int(first.timeIntervalSince1970)
  }
  static func local(_ time: Int, zone: TimeZone) -> String {
    let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = zone
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss XXXXX"
    return formatter.string(from: Date(timeIntervalSince1970: Double(time)))
  }
}
