import AppKit
import Core
import SwiftUI

public struct ConversationPage: View {
  public let presentation: ConversationPresentation
  public let strings: ConversationStrings
  public let provider: ChatProvider
  public let selection: ChatSelection?
  public let catalog: [ChatModel]
  public let connected: Bool
  public let skipApprovals: Bool
  public let loading: Bool
  public let error: ChatLabel?
  public let width: Double
  public let revision: Int
  public let showSkipNotice: Bool
  public let showHeader: Bool
  public let scrolls: Bool
  public let renderBottom: Bool?
  @State private var follow = ConversationScrollState()
  private let chooseProvider: (ChatProvider) -> Void
  private let choose: (String, String) -> Void
  private let send: (String) -> Bool
  private let stop: () -> Void
  private let new: () -> Void
  private let settings: () -> Void
  private let retry: () -> Void
  private let answer: (ConversationApproval, String) -> Void
  private let formAnswer: (ConversationApproval, String) -> Bool
  @State private var draft = ""
  @State private var headerHeight = 200.0
  @Environment(\.colorScheme) private var scheme
  private var palette: TimelinePalette { .init(dark: scheme == .dark) }
  public init(presentation: ConversationPresentation, strings: ConversationStrings, provider: ChatProvider, selection: ChatSelection?,
    catalog: [ChatModel], connected: Bool, skipApprovals: Bool, loading: Bool = false, error: ChatLabel? = nil, width: Double, revision: Int = 0, showSkipNotice: Bool = true, showHeader: Bool = true, scrolls: Bool = false, renderBottom: Bool? = nil, initialDraft: String = "",
    chooseProvider: @escaping (ChatProvider) -> Void = { _ in }, choose: @escaping (String, String) -> Void = { _, _ in },
    send: @escaping (String) -> Bool = { _ in false }, stop: @escaping () -> Void = {}, new: @escaping () -> Void = {},
    settings: @escaping () -> Void = {}, retry: @escaping () -> Void = {},
    answer: @escaping (ConversationApproval, String) -> Void = { _, _ in },
    formAnswer: @escaping (ConversationApproval, String) -> Bool = { _, _ in false }) {
    self._draft = State(initialValue: initialDraft)
    self.presentation = presentation; self.strings = strings; self.provider = provider; self.selection = selection
    self.catalog = catalog; self.connected = connected; self.skipApprovals = skipApprovals; self.loading = loading; self.error = error; self.width = width; self.revision = revision; self.showSkipNotice = showSkipNotice; self.showHeader = showHeader; self.scrolls = scrolls; self.renderBottom = renderBottom
    self.chooseProvider = chooseProvider; self.choose = choose; self.send = send; self.stop = stop; self.new = new
    self.settings = settings; self.retry = retry; self.answer = answer; self.formAnswer = formAnswer
  }
  private func label(_ key: ChatLabel) -> Text { Text(verbatim: strings.text(key)) }
  private func action(_ key: ChatLabel, identity: String? = nil, _ work: @escaping () -> Void) -> some View {
    ConversationControlButton(title: strings.text(key), name: .init(action: strings.text(key), identity: identity ?? key.rawValue),
      key: key == .send ? "\r" : key == .stop ? "\u{1b}" : "", modifiers: key == .send ? .command : [], action: work)
      .padding(.vertical, 4)
  }
  private var rule: some View { Rectangle().fill(palette.ink.opacity(0.3)).frame(height: 1) }
  private var inset: Double { width < 500 ? 20 : 36 }
  public var body: some View {
    Group {
      if scrolls || renderBottom != nil {
        GeometryReader { panel in
          // Reserve 120pt for messages and budget the editor plus its controls separately.
          let chrome = 112 + inset
          let headerLimit = max(0, panel.size.height - 120 - max(27, panel.size.height / 3 - chrome) - chrome)
          let scrollHeader = panel.size.height < 600 || headerHeight > headerLimit
          let compactWarning = scrollHeader && skipApprovals && showSkipNotice
          let warningHeight = compactWarning ? 34.0 : 0
          let editorLimit = max(27, (panel.size.height - warningHeight) / 3 - chrome)
          VStack(alignment: .leading, spacing: 0) {
            if !scrollHeader { measuredHeader }
            if compactWarning {
              ConversationCompactSkipNotice(strings: strings)
                .frame(height: 22).padding(.horizontal, inset).padding(.vertical, 6)
            }
            messageViewport(includingHeader: scrollHeader)
            composer(maximumEditorHeight: editorLimit).padding(.horizontal, inset).padding(.top, 12).padding(.bottom, inset)
          }
          .onPreferenceChange(ConversationHeaderHeightPreference.self) { headerHeight = $0 }
        }
      } else {
        VStack(alignment: .leading, spacing: 0) {
          paddedHeader
          messages.padding(.horizontal, inset)
          composer().padding(.horizontal, inset).padding(.top, 12).padding(.bottom, inset)
        }
      }
    }
    .frame(width: width, alignment: .leading)
    .font(.system(size: 14)).foregroundStyle(palette.ink).tint(palette.ink).background(palette.paper)
  }
  private var paddedHeader: some View {
    header.padding(.horizontal, inset).padding(.top, inset).padding(.bottom, 12)
  }
  private var measuredHeader: some View {
    paddedHeader.fixedSize(horizontal: false, vertical: true).background {
      GeometryReader { header in
        Color.clear.preference(key: ConversationHeaderHeightPreference.self, value: header.size.height)
      }
    }
  }
  @ViewBuilder private func messageViewport(includingHeader: Bool) -> some View {
      if let renderBottom {
        GeometryReader { viewport in
          VStack(alignment: .leading, spacing: 0) {
            if includingHeader { measuredHeader }
            messages.padding(.horizontal, inset).padding(.vertical, 6)
          }
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: viewport.size.width, height: viewport.size.height, alignment: renderBottom ? .bottom : .top)
            .clipped()
        }
      } else if scrolls { scrollingMessages(includingHeader: includingHeader) }
      else { messages.padding(.horizontal, inset) }
  }
  private var header: some View {
    VStack(alignment: .leading, spacing: 18) {
      if showHeader {
        ViewThatFits(in: .horizontal) {
          HStack { title; Spacer(); controls }
          VStack(alignment: .leading, spacing: 8) { title; controls }
        }
      } else if presentation.isRunning { action(.stop, stop) }
      selectionMenu(.provider, value: provider == .claude ? "Claude" : "Codex", items: ChatProvider.allCases.map(\.rawValue),
        label: { $0 == "claude" ? "Claude" : "Codex" }) { id in
          if let value = ChatProvider(rawValue: id) { chooseProvider(value) }
        }.disabled(presentation.isRunning)
      if connected {
        if loading { label(.loading) }
        else if !catalog.isEmpty {
          ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 20) { modelPicker; reasoningPicker }
            VStack(alignment: .leading, spacing: 12) { modelPicker; reasoningPicker }
          }.disabled(presentation.isRunning)
        }
      } else {
        HStack { label(.notConnected); Spacer(); action(.settings, settings) }
      }
      if skipApprovals && showSkipNotice {
        VStack(alignment: .leading, spacing: 6) { label(.skip).fontWeight(.semibold); label(.risk) }
          .fixedSize(horizontal: false, vertical: true).accessibilityElement(children: .combine)
          .accessibilityLabel(strings.text(.skip) + " " + strings.text(.risk))
      }
      rule
    }
  }
  private var messages: some View {
    Group {
      if scrolls { LazyVStack(alignment: .leading, spacing: 18) { messageRows } }
      else { VStack(alignment: .leading, spacing: 18) { messageRows } }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
  @ViewBuilder private var messageRows: some View {
      if presentation.rows.isEmpty {
        label(.empty).font(.system(size: 23, weight: .medium)).padding(.top, 12)
        label(.privacy).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.bottom, 20)
      }
      if presentation.billing == .external { label(.external).fontWeight(.semibold).fixedSize(horizontal: false, vertical: true) }
      ForEach(presentation.rows) { row in
        VStack(alignment: .leading, spacing: 9) {
          switch row.kind {
          case .person, .agent:
            label(row.kind == .person ? .person : .agent).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            Group {
              if renderBottom != nil { Text(verbatim: row.text) }
              else { Text(verbatim: row.text).textSelection(.enabled) }
            }.fixedSize(horizontal: false, vertical: true).lineSpacing(4)
          case .tool(let status):
            Text(verbatim: row.text + " · " + strings.text(toolLabel(status)))
              .font(.system(size: 12, design: .monospaced)).fixedSize(horizontal: false, vertical: true)
          case .boundary(let provider):
            Text(verbatim: strings.boundary(provider)).fontWeight(.medium).fixedSize(horizontal: false, vertical: true)
          case .notice(let reason):
            label(reason).fontWeight(.medium).fixedSize(horizontal: false, vertical: true)
          case .approval:
            if let request = row.approval, let state = row.formState {
              ConversationApprovalView(requestNumber: row.requestNumber ?? row.id + 1, request: request, form: row.form, state: state, strings: strings, revision: revision, answer: answer, formAnswer: formAnswer)

            }
          }
        }.frame(maxWidth: .infinity, alignment: .leading).id(row.approval?.id ?? "row-\(row.id)")
        rule
      }
      if let error {
        label(error).fontWeight(.medium).fixedSize(horizontal: false, vertical: true)
        if error == .catalogFailed || error == .notInstalled { action(.retry, retry) }
        if error == .claudeNotLoggedIn { action(.settings, settings) }
        if error == .historyLimit { action(.newConversation, identity: "history-recovery") { draft = ""; new() } }
      }

  }
  private func composer(maximumEditorHeight: Double = .greatestFiniteMagnitude) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      label(.message).font(.caption)
      ConversationControlText(name: .init(action: strings.text(.message), identity: "message"), text: $draft, multiline: true, grows: true, maximumHeight: maximumEditorHeight)
        .disabled(!canSend)
      HStack {
        if presentation.isRunning { label(.running).foregroundStyle(.secondary) }
        Spacer()
        action(.send, submit)
          .disabled(!canSend || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(12)
    .overlay { Rectangle().strokeBorder(palette.ink, lineWidth: 2) }
    .fixedSize(horizontal: false, vertical: true)
  }
  private var bottomMarker: some View {
      Color.clear.frame(height: 1).id("end").background {
        GeometryReader { marker in
          Color.clear.preference(key: ConversationBottomPreference.self, value: marker.frame(in: .named("conversationViewport")).maxY)
        }
      }
  }
  private func scrollingMessages(includingHeader: Bool) -> some View {
    ScrollViewReader { proxy in
      GeometryReader { viewport in
        ScrollView {
          VStack(alignment: .leading, spacing: 0) {
            if includingHeader { measuredHeader }
            messages.padding(.horizontal, inset).padding(.vertical, 6)
            bottomMarker
          }
        }
        .coordinateSpace(name: "conversationViewport")
        .onPreferenceChange(ConversationBottomPreference.self) { bottom in follow.observeBottom(distance: bottom - viewport.size.height) }
        .overlay(alignment: .bottom) {
          if follow.hasNewOutput || follow.pendingRequest != nil && !follow.nearBottom {
            let number = presentation.rows.first { $0.approval?.id == follow.pendingRequest }?.requestNumber
            ConversationRevealControl(strings: strings, request: follow.pendingRequest != nil,
              requestReference: number.map(strings.requestReference) ?? "") { scroll(follow.showLatest(), proxy: proxy) }
          }
        }
        .onChange(of: presentation.outputVersion) { _, version in
          scroll(follow.changed(outputVersion: version, requestID: presentation.pendingRequestID), proxy: proxy)
        }
        .onChange(of: presentation.pendingRequestID) { _, request in
          scroll(follow.changed(outputVersion: presentation.outputVersion, requestID: request), proxy: proxy)
        }
      }
    }
  }
  private func scroll(_ target: ConversationScrollState.Target, proxy: ScrollViewProxy) {
    switch target {
    case .none: break
    case .bottom: proxy.scrollTo("end", anchor: .bottom)
    case .request(let id): proxy.scrollTo(id, anchor: .top)
    }
  }
  private var title: some View { label(.title).font(.system(size: 30, weight: .semibold)).accessibilityAddTraits(.isHeader) }
  private var controls: some View {
    HStack(spacing: 18) {
      action(.newConversation) { draft = ""; new() }
      if presentation.isRunning { action(.stop, stop) }
    }
  }
  private func selectionMenu(_ title: ChatLabel, value: String, items: [String],
    label: @escaping (String) -> String, change: @escaping (String) -> Void) -> some View {
    HStack(spacing: 6) {
      Text(verbatim: strings.text(title))
      ConversationControlPicker(name: .init(action: strings.text(title), context: value, identity: title.rawValue),
        items: items.enumerated().map { index, id in
          .init(id: id, title: label(id), name: .init(action: strings.text(title), context: label(id), identity: title.rawValue + ".o\(index + 1)"))
        }, selection: items.first(where: { label($0) == value || $0 == value }) ?? "", change: change)
    }
  }
  private var modelPicker: some View {
    selectionMenu(.model, value: selection?.model ?? "", items: catalog.map(\.id), label: { id in catalog.first { $0.id == id }?.displayName ?? id }) { id in
      if let model = catalog.first(where: { $0.id == id }), let level = model.reasoningLevels.first { choose(id, level) }
    }
  }
  private var reasoningPicker: some View {
    selectionMenu(.reasoning, value: strings.reasoning(selection?.reasoning ?? ""),
      items: catalog.first(where: { $0.id == selection?.model })?.reasoningLevels ?? [], label: strings.reasoning) {
        choose(selection?.model ?? "", $0)
      }
  }
  private var canSend: Bool {
    error != .historyLimit && connected && !presentation.isRunning && !loading && selection.map { selected in catalog.contains { $0.accepts(selected) } } == true
  }
  private func submit() {
    guard canSend, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    if send(draft) { draft = "" }
  }
  private func toolLabel(_ status: ConversationToolState) -> ChatLabel {
    switch status { case .running: return .running; case .done: return .done; case .failed: return .failed; case .cancelled: return .cancelled }
  }
}

public struct ConversationView: View {
  @ObservedObject private var controller: ConversationController
  private let strings: ConversationStrings
  private let openSettings: (SettingsSection) -> Void
  private let managesLifecycle: Bool
  public init(controller: ConversationController, strings: ConversationStrings, managesLifecycle: Bool = true, openSettings: @escaping (SettingsSection) -> Void) {
    self.controller = controller; self.strings = strings; self.openSettings = openSettings; self.managesLifecycle = managesLifecycle
  }
  public var body: some View {
    GeometryReader { geometry in
      VStack(spacing: 0) {
        ConversationPage(presentation: controller.presentation, strings: strings, provider: controller.provider, selection: controller.selection,
          catalog: controller.catalog, connected: controller.connected, skipApprovals: controller.skipApprovals,
          loading: controller.isLoadingCatalog, error: controller.error, width: geometry.size.width, revision: controller.revision,
          showSkipNotice: true, showHeader: managesLifecycle, scrolls: true,
          chooseProvider: { provider in Task { await controller.chooseProvider(provider) } }, choose: controller.choose,
          send: controller.send, stop: controller.stop, new: controller.newConversation,
          settings: { openSettings(controller.provider.settingsSection) }, retry: { Task { await controller.loadCatalog() } },
          answer: { controller.answer($0, choice: $1) }, formAnswer: { controller.answer($0, json: $1) })
          .id(controller.conversationID)
      }
    }
    .task { if managesLifecycle { await controller.loadCatalog() } }
    .task {
      guard managesLifecycle else { return }
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(1)); try Task.checkCancellation() } catch { return }
        await controller.refreshAccountCatalogIfNeeded()
      }
    }
    .onDisappear { if managesLifecycle { controller.stop() } }
  }
}

struct ConversationRevealControl: View {
  let strings: ConversationStrings
  let request: Bool
  var requestReference: String = ""
  let action: () -> Void
  var body: some View {
    ConversationControlButton(title: strings.text(request ? .newRequest : .newOutput) + (requestReference.isEmpty ? "" : " · " + requestReference),
      name: .init(action: strings.text(request ? .newRequest : .newOutput), identity: "reveal"), action: action)
      .padding(10).frame(maxWidth: .infinity).background(.background)
      .environment(\.conversationRequestReference, requestReference)
  }
}
private struct ConversationBottomPreference: PreferenceKey {
  static var defaultValue: Double = 0
  static func reduce(value: inout Double, nextValue: () -> Double) { value = nextValue() }
}
private struct ConversationHeaderHeightPreference: PreferenceKey {
  static var defaultValue: Double = 200
  static func reduce(value: inout Double, nextValue: () -> Double) { value = nextValue() }
}

public enum ConversationOffscreenRender {
  @MainActor public static func png(presentation: ConversationPresentation, strings: ConversationStrings, provider: ChatProvider = .codex,
    connected: Bool = true, skipApprovals: Bool = false, width: Double = 760, dark: Bool = false, viewportHeight: Double? = nil, bottom: Bool = false, initialDraft: String = "", showHeader: Bool = true, scale: Double? = nil) -> Data? {
    snapshot(panelHost(presentation: presentation, strings: strings, provider: provider, connected: connected,
      skipApprovals: skipApprovals, width: width, dark: dark, viewportHeight: viewportHeight, bottom: bottom, initialDraft: initialDraft, showHeader: showHeader, scale: scale ?? 1), scale: scale)
  }
  // Clip the shared message view directly: native SwiftUI scroll documents have no window here.
  @MainActor static func panelHost(presentation: ConversationPresentation, strings: ConversationStrings, provider: ChatProvider = .codex,
    connected: Bool = true, skipApprovals: Bool = false, width: Double = 760, dark: Bool = false, viewportHeight: Double? = nil, bottom: Bool = false, initialDraft: String = "", showHeader: Bool = true, scale: Double = 1) -> NSView {
    let selection = ChatSelection(provider: provider, model: "invented-model", reasoning: "low")
    let content = ConversationPage(presentation: presentation, strings: strings, provider: provider, selection: connected ? selection : nil,
      catalog: connected ? [.init(id: selection.model, reasoningLevels: ["low", "high"])] : [], connected: connected,
      skipApprovals: skipApprovals, width: width, showHeader: showHeader, renderBottom: viewportHeight == nil ? nil : bottom, initialDraft: initialDraft)
      .environment(\.colorScheme, dark ? .dark : .light)
      .environment(\.displayScale, scale)
      .frame(height: viewportHeight.map { CGFloat($0) }).fixedSize(horizontal: false, vertical: viewportHeight == nil)
    let host = NSHostingView(rootView: content)
    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    host.frame = NSRect(x: 0, y: 0, width: width, height: viewportHeight ?? host.fittingSize.height)
    for _ in 0..<3 { host.layoutSubtreeIfNeeded() }
    return host
  }
  @MainActor public static func lazyViewportPNG(presentation: ConversationPresentation, strings: ConversationStrings, width: Double = 760, height: Double = 620) -> Data? {
    let selection = ChatSelection(provider: .codex, model: "invented-model", reasoning: "low")
    let content = Group {
      ConversationPage(presentation: presentation, strings: strings, provider: .codex, selection: selection,
        catalog: [.init(id: selection.model, reasoningLevels: ["low"])] , connected: true, skipApprovals: false, width: width, scrolls: true)
    }.frame(width: width, height: height)
    let host = NSHostingView(rootView: content); host.frame = NSRect(x: 0, y: 0, width: width, height: height)
    host.layoutSubtreeIfNeeded(); return snapshot(host)
  }
  @MainActor public static func requestHeight(_ request: ConversationApproval, strings: ConversationStrings, width: Double = 760, state: ConversationQuestionState = ConversationQuestionState()) -> Double {
    requestHost(request, strings: strings, width: width, state: state).frame.height
  }
  @MainActor public static func requestPNG(_ request: ConversationApproval, strings: ConversationStrings, width: Double = 760, height: Double = 620, state: ConversationQuestionState = ConversationQuestionState()) -> Data? {
    viewport(host: requestHost(request, strings: strings, width: width, state: state), width: width, height: height, bottom: false)
  }
  @MainActor static func requestHost(_ request: ConversationApproval, strings: ConversationStrings, width: Double, state: ConversationQuestionState) -> NSView {
    let view = ConversationApprovalView(request: request, form: ConversationQuestions(request: request), state: state, strings: strings, revision: 0,
      answer: { _, _ in }, formAnswer: { _, _ in false }).padding(36).frame(width: width).font(.system(size: 14)).environment(\.colorScheme, .light)
    let host = NSHostingView(rootView: view)
    host.frame = NSRect(x: 0, y: 0, width: width, height: host.fittingSize.height); host.layoutSubtreeIfNeeded()
    return host
  }
  @MainActor static func viewport(host: NSView, width: Double, height: Double, bottom: Bool) -> Data? {
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
    scroll.drawsBackground = true; scroll.backgroundColor = .white; scroll.appearance = NSAppearance(named: .aqua)
    scroll.documentView = host; scroll.layoutSubtreeIfNeeded()
    let end = max(0, host.frame.height - height)
    scroll.contentView.scroll(to: NSPoint(x: 0, y: host.isFlipped ? (bottom ? end : 0) : (bottom ? 0 : end)))
    scroll.reflectScrolledClipView(scroll.contentView); scroll.layoutSubtreeIfNeeded()
    return snapshot(scroll)
  }
  @MainActor private static func snapshot(_ view: NSView, scale: Double? = nil) -> Data? {
    let bitmap: NSBitmapImageRep?
    if let scale {
      bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(view.bounds.width * scale)),
        pixelsHigh: Int(ceil(view.bounds.height * scale)), bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
      bitmap?.size = view.bounds.size
    } else {
      bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
    }
    guard let bitmap else { return nil }
    view.cacheDisplay(in: view.bounds, to: bitmap); return bitmap.representation(using: .png, properties: [:])
  }
}
