import AppKit
import Core
import SwiftUI

public enum AppWindowRenderState: String, CaseIterable { case timeline, conversation, settings }
public enum AppWindowOffscreenRender {
  /// Invented values only. Never constructs a window, controller, storage client or agent.
  @MainActor public static func png(day: TimelineDay, settings: StorageSettings, health: TimelineHealth,
    strings: AppWindowStrings, state: AppWindowRenderState, width: Double, height: Double = 820, dark: Bool,
    conversation: ConversationPresentation = ConversationPresentation()) -> Data? {
    let chat = ConversationStrings(language: strings.language, resources: strings.resources)
    let selection = ChatSelection(provider: .codex, model: "invented-model", reasoning: "low")
    let view = AppWindowFrame(strings: strings, settingsVisible: state == .settings, panelOpen: state == .conversation,
      layout: AppWindowLayout(), toggle: {}, settings: {}, back: {}, new: {}, close: {}, resize: { _, _ in }) { contentWidth in
        Group {
          if state == .settings {
            ScrollView {
              SettingsPage(model: SettingsViewModel(settings: settings, health: health, ownBundleID: AppPaths.bundleID, now: 1800000000),
                strings: SettingsStrings(language: strings.language, resources: strings.resources), width: contentWidth)
            }
          } else {
            TimelineView(model: TimelinePresentation(day: day, language: strings.language, resources: strings.resources), width: contentWidth)
          }
        }.frame(width: contentWidth)
      } panel: { panelWidth in
        Group {
          ConversationPage(presentation: conversation, strings: chat, provider: .codex, selection: selection,
            catalog: [.init(id: selection.model, reasoningLevels: ["low"])], connected: true,
            skipApprovals: false, width: panelWidth, showHeader: false, renderBottom: false)
        }
      }
      .environment(\.colorScheme, dark ? .dark : .light).environment(\.locale, Locale(identifier: strings.language))
      .frame(width: width, height: height)
    let host = NSHostingView(rootView: view)
    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    host.frame = NSRect(x: 0, y: 0, width: width, height: height)
    host.layoutSubtreeIfNeeded()
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    return bitmap.representation(using: .png, properties: [:])
  }
}
