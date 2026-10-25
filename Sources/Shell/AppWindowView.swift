import AppKit
import Core
import SwiftUI

public enum AppWindowLabel: String, CaseIterable {
  case timeline = "Timeline"
  case conversation = "Conversation"
  case showConversation = "Show conversation"
  case hideConversation = "Hide conversation"
  case settings = "Settings"
  case back = "Back to timeline"
  case newConversation = "New conversation"
  case closeConversation = "Close conversation"
  case resize = "Resize conversation panel"
  case loading = "Loading activity…"
  case readFailed = "Activity could not be read. Retrying…"
}
public struct AppWindowStrings {
  public let language: String
  public let resources: URL?
  public init(language: String, resources: URL? = Bundle.main.resourceURL) { self.language = language; self.resources = resources }
  public func text(_ label: AppWindowLabel) -> String {
    resources.flatMap { Bundle(path: $0.appendingPathComponent(language + ".lproj").path) }?
      .localizedString(forKey: label.rawValue, value: label.rawValue, table: "Localizable") ?? label.rawValue
  }
  public static func preferredLanguage(_ preferred: [String] = Locale.preferredLanguages) -> String {
    for code in preferred {
      let lower = code.lowercased()
      if lower.hasPrefix("zh") { return lower.contains("hant") || lower.contains("-tw") || lower.contains("-hk") ? "zh-Hant" : "zh-Hans" }
      let base = String(lower.prefix { $0 != "-" && $0 != "_" })
      if ["en", "ko", "ja", "de", "fr", "es", "ru"].contains(base) { return base }
    }
    return "en"
  }
}

struct AppWindowIcon: NSViewRepresentable {
  let symbol: String
  let label: String
  let identity: String
  let action: () -> Void
  var selected: Bool? = nil
  @Environment(\.isEnabled) private var enabled
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> NSButton {
    let button = NSButton(image: NSImage(), target: context.coordinator, action: #selector(Coordinator.invoke))
    button.isBordered = false; button.imagePosition = .imageOnly
    return button
  }
  func updateNSView(_ button: NSButton, context: Context) {
    context.coordinator.action = action
    button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    button.contentTintColor = .labelColor; button.isEnabled = enabled
    button.setButtonType(selected == nil ? .momentaryPushIn : .toggle); button.state = selected == true ? .on : .off
    ConversationControlName(action: label, identity: identity).assign(to: button)
  }
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> CGSize? { CGSize(width: 30, height: 30) }
  final class Coordinator: NSObject {
    var action: () -> Void = {}
    @objc func invoke() { action() }
  }
}

/// The real window and the invented renderer use the same title area, panel header and split layout.
struct AppWindowFrame<Primary: View, Panel: View>: View {
  let strings: AppWindowStrings
  let settingsVisible: Bool
  let panelOpen: Bool
  let layout: AppWindowLayout
  let toggle: () -> Void
  let settings: () -> Void
  let back: () -> Void
  let new: () -> Void
  let close: () -> Void
  let resize: (Double, Double) -> Void
  @ViewBuilder let primary: (Double) -> Primary
  @ViewBuilder let panel: (Double) -> Panel
  @Environment(\.colorScheme) private var scheme
  @State private var dragStart: Double?
  private var palette: TimelinePalette { TimelinePalette(dark: scheme == .dark) }
  var body: some View {
    GeometryReader { geometry in
      VStack(spacing: 0) {
        HStack(spacing: 12) {
          if settingsVisible {
            ConversationControlButton(title: strings.text(.back), name: .init(action: strings.text(.back), identity: "window.back"), action: back)
          } else { Text(verbatim: strings.text(.timeline)).font(.system(size: 13, weight: .medium)) }
          Spacer(minLength: 10)
          AppWindowIcon(symbol: "bubble.left.and.bubble.right", label: strings.text(panelOpen ? .hideConversation : .showConversation),
            identity: "window.conversation", action: toggle, selected: panelOpen)
          AppWindowIcon(symbol: "gearshape", label: strings.text(.settings), identity: "window.settings", action: settings, selected: settingsVisible)
        }.padding(.leading, 82).padding(.trailing, 14).frame(height: 44)
        Rectangle().fill(palette.ink.opacity(0.2)).frame(height: 1)
        HStack(spacing: 0) {
          let panelWidth = layout.panelWidth(in: geometry.size.width)
          primary(geometry.size.width - (panelOpen ? panelWidth + AppWindowLayout.divider : 0))
            .frame(maxHeight: .infinity)
          if panelOpen {
            Rectangle().fill(palette.ink.opacity(0.15)).frame(width: AppWindowLayout.divider)
              .overlay { Rectangle().fill(palette.ink.opacity(0.35)).frame(width: 1) }
              .contentShape(Rectangle())
              .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                if dragStart == nil { dragStart = panelWidth }
                resize((dragStart ?? panelWidth) - value.translation.width, geometry.size.width)
              }.onEnded { _ in dragStart = nil })
              .accessibilityElement().accessibilityLabel(Text(verbatim: ConversationControlName(action: strings.text(.resize), identity: "window.divider").name))
              .accessibilityHint(Text(verbatim: strings.text(.resize)))
              .accessibilityValue(Text(verbatim: String(Int(panelWidth))))
              .accessibilityAdjustableAction { direction in
                resize(panelWidth + (direction == .increment ? 20 : -20), geometry.size.width)
              }
              .onHover { hovering in if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
          }
          VStack(spacing: 0) {
              HStack(spacing: 10) {
                Text(verbatim: strings.text(.conversation)).font(.system(size: 16, weight: .semibold)).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
                AppWindowIcon(symbol: "square.and.pencil", label: strings.text(.newConversation), identity: "window.new", action: new)
                AppWindowIcon(symbol: "xmark", label: strings.text(.closeConversation), identity: "window.closePanel", action: close)
              }.padding(.horizontal, 16).frame(height: 46)
              Rectangle().fill(palette.ink.opacity(0.2)).frame(height: 1)
              panel(panelWidth).frame(maxHeight: .infinity)
          }.frame(width: panelWidth)
            .frame(width: panelOpen ? panelWidth : 0, alignment: .leading).clipped().accessibilityHidden(!panelOpen).allowsHitTesting(panelOpen).disabled(!panelOpen)
        }
      }.foregroundStyle(palette.ink).background(palette.paper)
    }
  }
}

public struct AppWindowView: View {
  @ObservedObject private var model: AppWindowModel
  private let strings: AppWindowStrings
  private let backup: SettingsBackupActions
  public init(model: AppWindowModel, strings: AppWindowStrings, backup: SettingsBackupActions) {
    self.model = model; self.strings = strings; self.backup = backup
  }
  public var body: some View {
    AppWindowFrame(strings: strings, settingsVisible: model.settingsVisible, panelOpen: model.panelOpen, layout: model.layout,
      toggle: { model.toggleConversation(); model.startConversationObservation() }, settings: { model.navigate(.settings(.recording)) }, back: model.back,
      new: { model.conversation?.newConversation() }, close: model.closePanel, resize: model.choosePanelWidth) { width in
        Group {
          if model.settingsVisible {
            SettingsView(controller: model.settings, strings: SettingsStrings(language: strings.language, resources: strings.resources),
              system: MacSettingsSystemActions(), appCatalog: MacSettingsAppCatalog(), backupActions: backup)
          } else {
            VStack(alignment: .leading, spacing: 0) {
              if model.readFailed { Text(verbatim: strings.text(.readFailed)).padding(20) }
              if let snapshot = model.snapshot {
                let navigation = TimelineDayNavigation(day: snapshot.day.range, now: snapshot.now,
                  dayStartHour: snapshot.dayStartHour, calendar: .current)
                TimelineDayControls(navigation: navigation,
                  strings: TimelineStrings(language: strings.language, resources: strings.resources),
                  gridWidth: width - (width < 600 ? 40 : 80), choose: { model.chooseDay($0) }, today: model.showToday,
                  step: { model.stepDay($0) }, readMonth: model.recordedDays)
                  .padding(.horizontal, width < 600 ? 20 : 40).padding(.top, 16).padding(.bottom, 4)
                TimelineView(model: TimelinePresentation(day: snapshot.day, language: strings.language,
                  resources: strings.resources, isToday: navigation.isToday), width: width,
                  goToSettings: { model.navigate(.settings($0)) }).id(snapshot.day.range.start)
                  .background(TimelineDayKeys(step: { model.stepDay($0) }).frame(width: 0, height: 0))
              } else if !model.readFailed { Text(verbatim: strings.text(.loading)).padding(20) }
            }
          }
        }.frame(width: width)
      } panel: { _ in
        if let conversation = model.conversation {
          ConversationView(controller: conversation, strings: ConversationStrings(language: strings.language, resources: strings.resources),
            managesLifecycle: false, openSettings: { model.navigate(.settings($0)) })
        }
      }
      .ignoresSafeArea()
      .task { model.start(); model.startConversationObservation() }
  }
}
