import Core
import Foundation
import Shell

// Invented events only. This tool never constructs storage, adapters or a window.
@main struct ConversationRenderTool {
  @MainActor static func main() throws {
    guard (3...4).contains(CommandLine.arguments.count) else { fputs("usage: ConversationRender OUTPUT_DIRECTORY RESOURCES_DIRECTORY [--minimum-height|--composer-scroller|--sizes-review]\n", stderr); exit(2) }
    let output = URL(fileURLWithPath: CommandLine.arguments[1]), resources = URL(fileURLWithPath: CommandLine.arguments[2])
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    if CommandLine.arguments.last == "--sizes-review" {
      for language in ["en", "ko"] {
        for width in [360.0, 760] {
          for dark in [false, true] {
            for scale in [1.0, 2.0] {
              for lines in [0, 8] {
                let draft = Array(repeating: "Invented draft line", count: lines).joined(separator: "\n")
                guard let data = ConversationOffscreenRender.png(presentation: .init(), strings: .init(language: language, resources: resources),
                  width: width, dark: dark, viewportHeight: 620, initialDraft: draft, showHeader: false, scale: scale) else { exit(1) }
                let file = "sizes-\(language)-\(lines == 0 ? "empty" : "draft")-\(Int(width))-\(dark ? "dark" : "light")-\(Int(scale))x.png"
                try data.write(to: output.appendingPathComponent(file))
              }
            }
          }
        }
      }
      print("32 invented composer panels rendered without windows")
      return
    }
    if CommandLine.arguments.dropFirst(3).first == "--composer-scroller" {
      for height in [480.0, 820] {
        for scale in [1.0, 2] {
          for dark in [false, true] {
            for lines in [0, 30] {
              let draft = Array(repeating: "Invented draft line", count: lines).joined(separator: "\n")
              guard let png = ConversationOffscreenRender.png(presentation: .init(), strings: .init(language: "en", resources: resources),
                width: 480, dark: dark, viewportHeight: height, initialDraft: draft, scale: scale) else { exit(1) }
              let file = "composer-\(lines == 0 ? "empty" : "over-cap")-480x\(Int(height))-\(dark ? "dark" : "light")-\(Int(scale))x.png"
              try png.write(to: output.appendingPathComponent(file))
            }
          }
        }
      }
      print("16 invented composer panels rendered at 480pt wide, 480/820pt tall, 1x/2x, light/dark, without windows")
      return
    }
    if CommandLine.arguments.dropFirst(3).first == "--minimum-height" {
      for width in [360.0, 480, 760] {
        for dark in [false, true] {
          for state in ["empty", "draft", "running", "warning", "warning-idle"] {
            var model = ConversationPresentation()
            if state == "running" || state == "warning" {
              model.begin("Invented question")
              model.receive(.text("Invented response in progress."))
            }
            let draft = state == "draft" ? Array(repeating: "Invented draft line", count: 8).joined(separator: "\n") : ""
            guard let png = ConversationOffscreenRender.png(presentation: model, strings: .init(language: "en", resources: resources),
              skipApprovals: state.hasPrefix("warning"), width: width, dark: dark, viewportHeight: 388,
              initialDraft: draft, showHeader: false) else { exit(1) }
            try png.write(to: output.appendingPathComponent("\(state)-\(Int(width))-\(dark ? "dark" : "light").png"))
          }
        }
      }
      print("30 invented minimum-height panels rendered without windows or external actions")
      return
    }
    let cases = ["empty", "streaming", "command", "file-change", "answered-expired", "question", "skip", "disconnected", "dark", "narrow", "long-request", "long-stream", "long-question", "long-question-narrow", "question-edited", "question-secret", "confirmation", "refused-fields"]
    var count = 0
    for language in ["en", "ko", "ja", "zh-Hans", "zh-Hant", "de", "fr", "es", "ru"] {
      for name in cases {
        if name.hasPrefix("long-question") {
          let width = name.hasSuffix("narrow") ? 360.0 : 760.0
          let question = String(repeating: "Invented context sentence. ", count: 300)
          let native: [String: Any] = ["questions": [["id": "q", "question": question, "options": [["label": "First", "description": question], ["label": "Second", "description": question]]]]]
          let schema = String(decoding: try JSONSerialization.data(withJSONObject: native), as: UTF8.self)
          let request = ConversationApproval(method: "item/tool/requestUserInput", details: schema, choices: [.init(id: "deny", label: "decline")],
            presentation: .init(action: .question, target: question), responseSchema: schema)
          let state = ConversationQuestionState()
          let strings = ConversationStrings(language: language, resources: resources)
          guard let png = ConversationOffscreenRender.requestPNG(request, strings: strings, width: width, state: state) else { exit(1) }
          try png.write(to: output.appendingPathComponent(language + "-" + name + ".png")); count += 1
          print("\(language) \(name) height: \(ConversationOffscreenRender.requestHeight(request, strings: strings, width: width, state: state))pt in \(width)x620pt viewport; question_bytes=\(question.utf8.count)")
          continue
        }
        var model = ConversationPresentation()
        if !["empty", "disconnected", "skip"].contains(name) {
          model.begin(language == "ko" ? "오늘 한 일을 알려 주세요." : "What did I do today?")
          model.receive(.started)
          model.receive(.text(language == "ko" ? "기록된 활동을 확인하겠습니다." : "I will check the recorded activity."))
          model.receive(.toolStarted(id: "query", name: "activity_recent"))
          model.receive(.toolFinished(id: "query", failed: false))
          model.receive(.text(language == "ko" ? "오늘의 기록에는 두 가지 활동이 있습니다." : "The record contains two activities today. Here is the first part of the answer…"))
        }
        let choices: [ConversationApprovalChoice] = [.init(id: "approve", label: "accept"), .init(id: "deny", label: "decline"), .init(id: "session", label: "acceptForSession")]
        if ["command", "file-change", "answered-expired", "dark", "narrow"].contains(name) {
          let file = name == "file-change"
          let details = file ? "{\"reason\":\"Update an invented note\",\"changes\":{\"example.txt\":{\"diff\":\"- First line\\n+ Revised line\"}}}" : "{\"command\":\"printf 'invented example'\",\"reason\":\"Run an invented command\"}"
          let approval = ConversationApproval(method: file ? "item/fileChange/requestApproval" : "item/commandExecution/requestApproval", details: details, choices: choices,
            presentation: .init(action: file ? .files : .command, command: file ? nil : "printf 'invented example'",
              files: file ? [.init(path: "example.txt", diff: "- First line\n+ Revised line")] : [], reason: file ? "Update an invented note" : "Run an invented command"))
          model.receive(.approval(approval))
          if file { model.rows.last?.formState?.changesExpanded = true }
          if name == "answered-expired" {
            _ = approval.answer(choiceID: "approve"); _ = approval.takeAnswer(expired: false)
            let expired = ConversationApproval(method: "item/commandExecution/requestApproval", details: "{\"command\":\"printf 'second invented example'\"}", choices: choices, presentation: .init(action: .command, command: "printf 'second invented example'"))
            _ = expired.takeAnswer(expired: true); model.receive(.approval(expired))
            let cancelled = ConversationApproval(method: "item/fileChange/requestApproval", details: "{\"reason\":\"Invented cancelled change\"}", choices: choices, presentation: .init(action: .files, files: [.init(path: "invented.txt", diff: "")]))
            cancelled.invalidate(); model.receive(.approval(cancelled))
          }
        }
        if ["question", "question-edited", "question-secret"].contains(name) {
          let schema = String(decoding: try JSONSerialization.data(withJSONObject: ["questions": [["id": "scope", "question": "Which period should I use?", "isSecret": name == "question-secret", "options": [["label": "Today", "description": "Use today’s record"], ["label": "This week", "description": "Use this week’s record"]]]]]), as: UTF8.self)
          model.receive(.approval(ConversationApproval(method: "item/tool/requestUserInput", details: "{\"question\":\"Which period should I use?\"}", choices: [.init(id: "deny", label: "decline")], presentation: .init(action: .question, target: "Which period should I use?"), responseSchema: schema)))
        }
        if name == "question-edited" || name == "question-secret" { model.rows.last?.formState?.values["scope"] = "Use the last two days, please." }
        if name == "confirmation" {
          model.receive(.approval(ConversationApproval(method: "mcpServer/elicitation/request", details: "Invented confirmation", choices: [.init(id: "approve", label: "accept"), .init(id: "deny", label: "decline"), .init(id: "cancel", label: "cancel")],
            presentation: .init(action: .confirmation, reason: "Invented confirmation", target: "Confirm an invented tool action", nativeFacts: [.init(name: "requestedSchema", value: "properties: {}"), .init(name: "title", value: "Invented confirmation"), .init(name: "_meta", value: "tool: Invented tool\naction: Invented action")]))))
        }
        if name == "refused-fields" {
          let request = ConversationApproval(method: "mcpServer/elicitation/request", details: "Invented form", choices: [.init(id: "deny", label: "decline")],
            presentation: .init(action: .question, target: "Provide invented details", nativeFacts: [.init(name: "requestedSchema", value: "properties.count.type: integer\nproperties.count.minimum: 1\nrequired[1]: count")], fieldsUnavailable: true))
          request.answer(choiceID: "deny"); model.receive(.approval(request))
        }
        if name == "long-request" {
          let files = (0..<40).map { ConversationRequestPresentation.File(path: "invented-\($0).txt", diff: String(repeating: "- Before\n+ After\n", count: 20)) }
          let request = ConversationApproval(method: "item/fileChange/requestApproval", details: String(repeating: "invented native payload ", count: 5000), choices: choices,
            presentation: .init(action: .files, files: files, reason: "Update invented notes"))
          guard let png = ConversationOffscreenRender.requestPNG(request, strings: .init(language: language, resources: resources)) else { exit(1) }
          try png.write(to: output.appendingPathComponent(language + "-" + name + ".png")); count += 1
          print("\(language) long-request summary/actions height: \(ConversationOffscreenRender.requestHeight(request, strings: .init(language: language, resources: resources)))pt in 620pt viewport")
          continue
        }
        if name == "long-stream" {
          for _ in 0..<200 { model.receive(.text("Invented streamed answer continues with another sentence. ")) }
        }
        guard let png = ConversationOffscreenRender.png(presentation: model, strings: .init(language: language, resources: resources),
          connected: name != "disconnected", skipApprovals: name == "skip", width: name == "narrow" ? 360 : 760, dark: name == "dark", viewportHeight: name == "long-stream" ? 620 : nil, bottom: name == "long-stream") else { exit(1) }
        try png.write(to: output.appendingPathComponent(language + "-" + name + ".png")); count += 1
      }
    }
    for width in [480.0, 760] {
      for dark in [false, true] {
        for (name, turns) in [("empty", 0), ("short", 1), ("long", 30)] {
          var model = ConversationPresentation()
          for index in 0..<turns {
            model.begin("Invented question \(index + 1)")
            model.receive(.text(String(repeating: "Invented answer continues. ", count: 12)))
            model.finish()
          }
          let file = "composer-\(name)-\(Int(width))-\(dark ? "dark" : "light").png"
          guard let png = ConversationOffscreenRender.png(presentation: model, strings: .init(language: "en", resources: resources),
            width: width, dark: dark, viewportHeight: 820, bottom: turns > 0) else { exit(1) }
          try png.write(to: output.appendingPathComponent(file)); count += 1
        }
      }
    }
    for language in ["en", "ko"] {
      for enabled in [false, true] {
        let settings = StorageSettings(subscriptionConnected: enabled,
          general: ["chat.claude.connected": enabled ? "1" : "0", "chat.skipApprovals": enabled ? "1" : "0"])
        var security = DeviceSecurityHealth(); security.fileVault = .on
        let model = SettingsViewModel(settings: settings, health: TimelineHealth(security: security), ownBundleID: "org.example.self", now: 1800000000)
        guard let png = SettingsOffscreenRender.png(model: model, strings: .init(language: language, resources: resources), width: 360, dark: false) else { exit(1) }
        try png.write(to: output.appendingPathComponent(language + (enabled ? "-settings-on.png" : "-settings-off.png"))); count += 1
      }
    }
    print("\(count) invented conversation and settings PNGs rendered without windows or external actions")
  }
}
