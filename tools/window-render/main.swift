import Core
import Foundation
import Shell

@main struct WindowRenderTool {
  @MainActor static func main() throws {
    guard CommandLine.arguments.count == 3 || (CommandLine.arguments.count == 4 && CommandLine.arguments[3] == "--sizes-review") else {
      fputs("usage: WindowRender OUTPUT_DIRECTORY COMPILED_RESOURCES_DIRECTORY [--sizes-review]\n", stderr); exit(2)
    }
    let output = URL(fileURLWithPath: CommandLine.arguments[1])
    let resources = URL(fileURLWithPath: CommandLine.arguments[2])
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let calendar = Calendar.current
    let start = try TimelineDay.range(containing: 1800000000, dayStartHour: 4, calendar: calendar).start
    var minutes: [Int: SummaryMinuteKind] = [:]
    var intervals: [NamedInterval] = []
    for (offset, count, kind, name) in [(240, 80, ActivityKind.work, "Invented draft"),
      (320, 3, .distraction, "Invented diversion"), (323, 67, .work, "Invented draft"),
      (410, 35, .personal, "Invented errand"), (470, 85, .work, "Invented review")] {
      for minute in offset..<(offset + count) { minutes[start + minute * 60] = SummaryMinuteKind(rawValue: kind.rawValue)! }
      intervals.append(NamedInterval(range: TimeRange(start + offset * 60, start + (offset + count) * 60), name: name, kind: kind))
    }
    for minute in 600..<640 { minutes[start + minute * 60] = .unsummarized }
    var day = TimelineDay.make(range: TimeRange(start, start + 86400), minutes: minutes, intervals: intervals,
      now: start + 650 * 60, calendar: calendar)
    let settings = StorageSettings(excludedApps: ["org.example.invented"], subscriptionConnected: false)
    var security = DeviceSecurityHealth(); security.fileVault = .on
    let health = TimelineHealth(missingPermissions: [.screenRecording], security: security)
    day.notices = TimelineNotices.make(settings: settings, health: health)
    let sizesReview = CommandLine.arguments.last == "--sizes-review"
    let languages = sizesReview ? ["en", "ko"] : ["en", "ko", "ja", "zh-Hans", "zh-Hant", "de", "fr", "es", "ru"]
    let widths = sizesReview ? [360.0, 1120.0] : [480.0, 800.0, 1280.0]
    for language in languages {
      for width in widths {
        for dark in [false, true] {
          for state in AppWindowRenderState.allCases {
            if width < 600 && state != .timeline { continue }
            let file = "\(language)-\(state.rawValue)-\(Int(width))-\(dark ? "dark" : "light").png"
            guard let data = AppWindowOffscreenRender.png(day: day, settings: settings, health: health,
              strings: AppWindowStrings(language: language, resources: resources), state: state, width: width, dark: dark) else { exit(1) }
            try data.write(to: output.appendingPathComponent(file))
            print(file)
          }
        }
      }
    }
  }
}
