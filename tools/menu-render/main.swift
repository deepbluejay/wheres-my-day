import Foundation
import Shell

@main struct MenuRenderTool {
  @MainActor static func main() throws {
    guard CommandLine.arguments.count == 3 else { exit(2) }
    let output = URL(fileURLWithPath: CommandLine.arguments[1]), resources = URL(fileURLWithPath: CommandLine.arguments[2])
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    for language in ["en", "ko", "ja", "zh-Hans", "zh-Hant", "de", "fr", "es", "ru"] {
      for state in RecorderMenuState.allCases {
        for dark in [false, true] {
          guard let data = RecorderMenuDrawing.png(state: state, strings: SettingsStrings(language: language, resources: resources), dark: dark) else { exit(1) }
          let name = "\(language)-\(state.rawValue)-\(dark ? "dark" : "light").png"
          try data.write(to: output.appendingPathComponent(name)); print(name)
        }
      }
    }
  }
}
