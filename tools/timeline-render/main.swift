import Core
import Foundation
import Shell

// Invented minutes only. This tool has no recorder or storage entry point.
@main struct TimelineRenderTool {
  @MainActor static func main() throws {
    let args = Array(CommandLine.arguments.dropFirst())
    guard args.count == 2 || (args.count == 3 && ["--unhovered", "--sizes-review"].contains(args[2])) else {
      fputs("usage: TimelineRender OUTPUT_DIRECTORY COMPILED_RESOURCES_DIRECTORY [--unhovered|--sizes-review]\n", stderr)
      exit(2)
    }
    let unhovered = args.last == "--unhovered"
    let output = URL(fileURLWithPath: args[0], isDirectory: true)
    let resources = URL(fileURLWithPath: args[1], isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    // Day navigation fixtures use a fixed invented month, never the machine's activity.
    let navigationNow = Int(calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 18))!.timeIntervalSince1970)
    let recorded = Set([2, 5, 9, 14, 18, 19, 21].map {
      calendar.date(from: DateComponents(year: 2026, month: 10, day: $0))!
    })
    if args.last == "--sizes-review" {
      for language in ["en", "ko", "ja", "zh-Hans", "zh-Hant", "de", "fr", "es", "ru"] {
        for width in [360.0, 1120] {
          for dark in [false, true] {
            for scale in [1.0, 2.0] {
              for (state, number) in [("today", 21), ("past", 18)] {
                let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: number))!
                let range = try TimelineDay.range(on: date, dayStartHour: 4, calendar: calendar)
                let minutes = Dictionary(uniqueKeysWithValues: (240..<695).map { (range.start + $0 * 60, SummaryMinuteKind.work) })
                let day = TimelineDay.make(range: range, minutes: minutes,
                  intervals: [NamedInterval(range: TimeRange(range.start + 240 * 60, range.start + 695 * 60), name: "Invented activity", kind: .work)],
                  now: navigationNow, calendar: calendar)
                let model = TimelinePresentation(day: day, language: language, resources: resources, calendar: calendar, isToday: number == 21)
                let file = "sizes-\(state)-\(language)-\(Int(width))-\(dark ? "dark" : "light")-\(Int(scale))x.png"
                guard let data = TimelineOffscreenRender.navigationPNG(model: model, width: width, dark: dark,
                  scale: scale, now: navigationNow, calendarOpen: false, records: recorded) else { exit(1) }
                try data.write(to: output.appendingPathComponent(file))
              }
            }
          }
        }
      }
      print("144 invented day views rendered without windows")
      return
    }
    for language in ["en", "ko"] {
      for width in [360.0, 1280.0] {
        for dark in [false, true] {
          for scale in [1.0, 2.0] {
            for (state, dayNumber, open) in [("today", 21, false), ("past", 18, false), ("calendar", 18, true)] {
              let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: dayNumber))!
              let range = try TimelineDay.range(on: date, dayStartHour: 4, calendar: calendar)
              let minutes = Dictionary(uniqueKeysWithValues: (240..<300).map { (range.start + $0 * 60, SummaryMinuteKind.work) })
              let day = TimelineDay.make(range: range, minutes: minutes,
                intervals: [NamedInterval(range: TimeRange(range.start + 240 * 60, range.start + 300 * 60), name: "Invented activity", kind: .work)],
                now: navigationNow, calendar: calendar)
              let model = TimelinePresentation(day: day, language: language, resources: resources, calendar: calendar, isToday: dayNumber == 21)
              let file = "daynav-\(state)-\(language)-\(Int(width))-\(dark ? "dark" : "light")-\(Int(scale))x.png"
              guard let png = TimelineOffscreenRender.navigationPNG(model: model, width: width, dark: dark,
                scale: scale, now: navigationNow, calendarOpen: open, records: recorded) else { exit(1) }
              try png.write(to: output.appendingPathComponent(file))
            }
          }
        }
      }
    }
    let start = 4 * 3600
    func fixture(pending: Bool = false, notices: Bool = false) -> TimelineDay {
      var minutes: [Int: SummaryMinuteKind] = [:]
      var intervals: [NamedInterval] = []
      func add(_ at: Int, _ count: Int, _ state: SummaryMinuteKind, _ name: String? = nil) {
        let range = TimeRange(start + at * 60, start + (at + count) * 60)
        for minute in stride(from: range.start, to: range.end, by: 60) { minutes[minute] = state }
        if let name, let kind = ActivityKind(rawValue: state.rawValue) {
          intervals.append(NamedInterval(range: range, name: name, kind: kind))
        }
      }
      add(120, 1, .rest)
      add(240, 80, .work, "Invented draft")
      add(320, 3, .distraction, "Invented diversion")
      add(323, 67, .work, "Invented draft")
      add(410, 35, .personal, "Invented errand")
      add(470, 85, .work, "Invented review")
      add(570, 12, .private)
      add(600, 8, .unnamed)
      add(625, 20, .distraction, "Invented diversion")
      add(660, 94, .work, "Invented outline")
      if pending { add(780, 51, .unsummarized) }
      var day = TimelineDay.make(range: TimeRange(start, start + 86400), minutes: minutes,
        intervals: intervals, now: start + (pending ? 831 : 900) * 60, calendar: calendar)
      if notices {
        var settings = StorageSettings()
        settings.subscriptionConnected = false
        var security = DeviceSecurityHealth()
        security.fileVault = .off
        day.notices = TimelineNotices.make(settings: settings,
          health: TimelineHealth(missingPermissions: [.screenRecording], security: security))
      }
      return day
    }
    for (file, pending, notices, dark, width, language, scale) in [
      ("full-light", false, false, false, 1280.0, "en", 2.0),
      ("full-dark", false, false, true, 1280.0, "en", 2.0),
      ("pending", true, false, false, 1280.0, "en", 2.0),
      ("notices", true, true, false, 1280.0, "en", 2.0),
      ("narrow", true, true, false, 480.0, "en", 2.0),
      ("korean", true, true, true, 1280.0, "ko", 2.0),
      ("w1088", true, true, false, 1088.0, "en", 2.0),
      ("w1000", true, true, false, 1000.0, "en", 2.0),
      ("w480", true, true, false, 480.0, "en", 2.0),
      ("w1088-1x", true, true, false, 1088.0, "en", 1.0),
      ("w480-1x", true, true, false, 480.0, "en", 1.0),
      ("w872", true, true, false, 872.0, "en", 2.0),
      ("w800", true, true, false, 800.0, "en", 2.0),
      ("german-narrow", true, true, false, 360.0, "de", 2.0)
    ] {
      let model = TimelinePresentation(day: fixture(pending: pending, notices: notices), language: language,
        resources: resources, calendar: calendar)
      guard let png = TimelineOffscreenRender.png(model: model, width: width, dark: dark, scale: scale) else {
        fputs("Offscreen rendering failed.\n", stderr); exit(1)
      }
      try png.write(to: output.appendingPathComponent(file + ".png"))
      print("\(file): \(model.day.totalMinutes) minutes, \(model.day.entries.count) lines, \(model.notices.count) notices")
    }
    for width in [480.0, 1280.0] {
      for dark in [false, true] {
        for scale in [1.0, 2.0] {
          let model = TimelinePresentation(day: fixture(pending: true), language: "en", resources: resources, calendar: calendar)
          for (state, target) in [("group", TimelineHoverTarget.group(0)), ("piece", .square(.init(column: 32, minute: 5)))] {
            let file = "split-\(Int(width))-\(dark ? "dark" : "light")-\(Int(scale))x-\(state).png"
            guard let png = TimelineOffscreenRender.png(model: model, width: width, dark: dark,
              scale: scale, hovered: target, expanded: [0], height: 720) else { exit(1) }
            try png.write(to: output.appendingPathComponent(file))
          }
        }
      }
    }
    let hoverModel = TimelinePresentation(day: fixture(pending: true), language: "en",
      resources: resources, calendar: calendar)
    var hoverCases: [(String, Bool, Double, Double, TimelineHoverTarget?)] = [
      ("hover-group-light", false, 1280.0, 2.0, TimelineHoverTarget.square(.init(column: 24, minute: 0))),
      ("hover-group-dark", true, 1280.0, 2.0, .square(.init(column: 24, minute: 0))),
      ("hover-group-row", false, 1280.0, 2.0, .entry(0)),
      ("hover-wrap-light", false, 480.0, 2.0, .square(.init(column: 72, minute: 0))),
      ("hover-wrap-row-light", false, 480.0, 2.0, .entry(8)),
      ("hover-wrap-dark", true, 480.0, 2.0, .entry(8)),
      ("hover-wrap-1x", false, 480.0, 1.0, .entry(8)),
      ("hover-pending", false, 1280.0, 2.0, .entry(9)),
      ("hover-private", false, 1280.0, 2.0, .entry(5)),
      ("hover-empty", false, 1280.0, 2.0, .square(.init(column: 0, minute: 0))),
      ("hover-rest", false, 1280.0, 2.0, .square(.init(column: 12, minute: 0))),
      ("hover-none", false, 1280.0, 2.0, nil)
    ]
    hoverCases += hoverCases.filter { $0.3 == 2 }.map { ($0.0 + "-1x", $0.1, $0.2, 1.0, $0.4) }
    var hoverImages: [String: Data] = [:]
    for (file, dark, width, scale, target) in hoverCases {
      guard let png = TimelineOffscreenRender.png(model: hoverModel, width: width, dark: dark,
        scale: scale, hovered: unhovered ? nil : target) else {
        fputs("Offscreen hover rendering failed.\n", stderr); exit(1)
      }
      try png.write(to: output.appendingPathComponent(file + ".png"))
      hoverImages[file] = png
      print("\(file): injected hover state")
    }
    guard hoverImages["hover-group-light"] == hoverImages["hover-group-row"],
      hoverImages["hover-wrap-light"] == hoverImages["hover-wrap-row-light"],
      hoverImages["hover-empty"] == hoverImages["hover-none"],
      hoverImages["hover-rest"] == hoverImages["hover-none"] else {
      fputs("Square, list and blank hover render equivalence failed.\n", stderr); exit(1)
    }

    var adjacentMinutes: [Int: SummaryMinuteKind] = [:]
    for minute in 300..<400 { adjacentMinutes[start + minute * 60] = .work }
    adjacentMinutes[start + 450 * 60] = .personal
    for minute in 460..<500 { adjacentMinutes[start + minute * 60] = .private }
    let adjacentDay = TimelineDay.make(range: TimeRange(start, start + 86400), minutes: adjacentMinutes,
      intervals: [
        NamedInterval(range: TimeRange(start + 300 * 60, start + 400 * 60), name: "Invented A", kind: .work),
        NamedInterval(range: TimeRange(start + 450 * 60, start + 451 * 60), name: "Invented B", kind: .personal)
      ], now: start + 900 * 60, calendar: calendar)
    let adjacentModel = TimelinePresentation(day: adjacentDay, language: "en", resources: resources, calendar: calendar)
    for scale in [1.0, 2.0] {
      for width in [480.0, 1088.0, 1280.0] {
        for hovered in [false, true] {
          let file = "adjacent-\(Int(width))-\(Int(scale))x-\(hovered ? "hover" : "plain").png"
          guard let png = TimelineOffscreenRender.png(model: adjacentModel, width: width, dark: false,
            scale: scale, hovered: !unhovered && hovered ? .entry(1) : nil) else {
            fputs("Offscreen adjacent-line rendering failed.\n", stderr); exit(1)
          }
          try png.write(to: output.appendingPathComponent(file))
        }
      }
    }

    let longName = String(("Invented " + String(repeating: "long name ", count: 30)).prefix(250))
    var longMinutes = Dictionary(uniqueKeysWithValues: (600..<720).map { ($0 * 60, SummaryMinuteKind.work) })
    longMinutes[300 * 60] = .distraction
    for minute in 730..<760 { longMinutes[minute * 60] = minute == 745 ? .distraction : .work }
    let longDay = TimelineDay.make(range: TimeRange(0, 86400), minutes: longMinutes, intervals: [
      NamedInterval(range: TimeRange(600 * 60, 720 * 60), name: "Invented first band", kind: .work),
      NamedInterval(range: TimeRange(730 * 60, 745 * 60), name: longName, kind: .work),
      NamedInterval(range: TimeRange(745 * 60, 746 * 60), name: "Invented interruption", kind: .distraction),
      NamedInterval(range: TimeRange(746 * 60, 760 * 60), name: longName, kind: .work)
    ], now: 50000, calendar: calendar)
    let labelCases = [(480.0, "en")] + ["en", "ko", "ja", "zh-Hans", "zh-Hant", "de", "fr", "es", "ru"].flatMap {
      [(360.0, $0), (400.0, $0)]
    }
    for (width, language) in labelCases {
      let model = TimelinePresentation(day: longDay, language: language, resources: resources, calendar: calendar)
      for scale in [1.0, 2.0] {
        for dark in [false, true] {
          for band in [0, 1] {
            let index = longDay.entries.firstIndex { band == 1 ? $0.name == longName : $0.name == "Invented first band" }!
            let file = "label-\(language)-\(Int(width))-\(Int(scale))x-\(dark ? "dark" : "light")-band\(band).png"
            guard let png = TimelineOffscreenRender.png(model: model, width: width, dark: dark,
              scale: scale, hovered: unhovered ? nil : band == 1 ? .square(.init(column: 74, minute: 4)) : .entry(index)) else {
              fputs("Offscreen label rendering failed.\n", stderr); exit(1)
            }
            try png.write(to: output.appendingPathComponent(file))
          }
        }
      }
    }
    for language in ["en", "ko", "ja", "zh-Hans", "zh-Hant", "de", "fr", "es", "ru"] {
      let model = TimelinePresentation(day: fixture(pending: true), language: language,
        resources: resources, calendar: calendar)
      for width in [360.0, 400.0] {
        for scale in [1.0, 2.0] {
          for dark in [false, true] {
            for (label, index) in [("private", 5), ("pending", 9)] {
              let file = "fixed-\(label)-\(language)-\(Int(width))-\(Int(scale))x-\(dark ? "dark" : "light").png"
              guard let png = TimelineOffscreenRender.png(model: model, width: width, dark: dark,
                scale: scale, hovered: unhovered ? nil : .entry(index)) else {
                fputs("Offscreen fixed-label rendering failed.\n", stderr); exit(1)
              }
              try png.write(to: output.appendingPathComponent(file))
            }
          }
        }
      }
    }
  }
}
