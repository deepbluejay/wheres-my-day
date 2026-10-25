import Core
import Foundation

public enum ChatLabel: String, CaseIterable {
  case title = "Conversation", person = "You", agent = "Agent", send = "Send", message = "Message"
  case newConversation = "New conversation", stop = "Stop", provider = "Provider", model = "Model", reasoning = "Reasoning level"
  case empty = "Ask about your day or your Mac."
  case privacy = "Your questions and the parts of your record needed to answer them, including personal and leisure activity, are sent to the model provider."
  case notConnected = "Not connected", settings = "Settings", loading = "Loading models…", retry = "Retry"
  case running = "Running", done = "Done", failed = "Failed", cancelled = "Cancelled", expired = "Expired, denied automatically"
  case requestReference = "Request %lld"
  case approval = "Approval requested", remaining = "Automatic denial in %lld seconds"
  case allow = "Allow once", deny = "Deny", session = "Allow for this session", answered = "Answered", submit = "Submit answer"
  case interactionUnavailable = "Denied: this request requires a session-local interaction that this host cannot provide."
  case invalidForm = "Enter an answer for every question."
  case fieldsUnavailable = "Unsupported form request. The request was declined."
  case skip = "Approvals are skipped. Actions run without asking."
  case risk = "Skipping approvals removes the last defense against prompt injection and direct deletion."
  case skipToggle = "Skip approvals", claude = "Claude connection"
  case claudeConsent = "Conversations use your own Claude Code login on this Mac. The app never reads or stores your Claude login."
  case claudeRetained = "Disconnecting stops Claude conversations. Your Claude Code login is not changed."
  case catalogFailed = "Models could not be loaded. Try again."
  case notInstalled = "The command-line tool was not found. Install it, then try again."
  case claudeNotLoggedIn = "Claude Code is not logged in on this Mac. In Settings, log in to Claude in Terminal, then send again."
  case historyLimit = "This conversation exceeds the history limit. Start a new conversation to continue; this transcript stays visible until then."
  case turnFailed = "The conversation stopped with an error. You can try again."
  case saveFailed = "Settings could not be saved. Try again."
  case external = "This agent reports billing outside your subscription."
  case formAnswer = "Answer"
  case singleFileAction = "Change this file?", unknownFilesAction = "Change files?"
  case commandAction = "Run this command?", filesAction = "Change %lld files?", permissionsAction = "Grant these permissions?"
  case unknownAction = "Unknown request", confirmationAction = "Confirm this destination?", terminalInputAction = "Send input to this terminal?"
  case questionAction = "Answer the agent’s question", toolAction = "Allow this tool?"
  case contents = "Proposed file contents"
  case reason = "Agent’s reason", scope = "Permission scope", fullDetails = "Full details", changes = "Changed lines"
  case grant = "Allow the specified permission", turn = "Allow for this turn", cancelChoice = "Cancel request"
  case unspecified = "See the native request in full details."
  case newOutput = "New output", newRequest = "New request", providerBoundary = "Continue with %@. Earlier messages stay here; the new provider starts with your next message."
  case readFailed = "Settings could not be read. Try again."
  case connectionStopped = "Stopped because the provider disconnected. Actions already executed are not undone."
  case approvalStopped = "Stopped because the approval setting changed. Actions already executed are not undone."
  case settingsStopped = "Stopped because settings could not be read. Actions already executed are not undone."
  case low = "Low", medium = "Medium", high = "High", max = "Maximum", none = "None", minimal = "Minimal", xhigh = "Extra high"
}
public struct ConversationStrings {
  private let base: SettingsStrings
  public init(language: String, resources: URL? = Bundle.main.resourceURL) { base = SettingsStrings(language: language, resources: resources) }
  public func text(_ label: ChatLabel) -> String { base.text(key: label.rawValue) }
  public func reasoning(_ level: String) -> String {
    let labels: [String: ChatLabel] = ["low": .low, "medium": .medium, "high": .high, "max": .max, "none": .none, "minimal": .minimal, "xhigh": .xhigh]
    return labels[level].map(text) ?? level
  }
  public func requestReference(_ number: Int) -> String { String(format: text(.requestReference), Int64(number)) }
  public func remaining(_ seconds: Int) -> String { String(format: text(.remaining), Int64(seconds)) }
  public func choice(_ choice: ConversationApprovalChoice) -> String {
    switch choice.meaning {
    case .once: return text(.allow)
    case .turn: return text(.turn)
    case .deny: return text(.deny)
    case .session: return text(.session)
    case .cancel: return text(.cancelChoice)
    case .grant: return text(.grant)
    case .native: return choice.label
    }
  }
  public func action(_ presentation: ConversationRequestPresentation) -> String {
    switch presentation.action {
    case .command: return text(.commandAction)
    case .terminalInput: return text(.terminalInputAction)
    case .confirmation: return text(.confirmationAction)
    case .unknown: return text(.unknownAction)
    case .files:
      if presentation.files.isEmpty { return text(.unknownFilesAction) }
      if presentation.files.count == 1 { return text(.singleFileAction) }
      return String(format: text(.filesAction), Int64(presentation.files.count))
    case .permissions: return text(.permissionsAction)
    case .question: return text(.questionAction)
    case .tool: return text(.toolAction)
    }
  }
  public func boundary(_ provider: ChatProvider) -> String { String(format: text(.providerBoundary), provider == .claude ? "Claude" : "Codex") }

  public func outcome(_ request: ConversationApproval) -> String {
    let outcome = request.outcome
    if request.presentation.interactionUnavailable && outcome == .answered("deny") { return text(.interactionUnavailable) }
    switch outcome {
    case .pending: return remaining(request.remainingSeconds)
    case .expired: return text(.expired)
    case .cancelled: return text(.cancelled)
    case .answered(let id):
      return text(.answered) + ": " + (request.choices.firstIndex { $0.id == id }.map { "[\($0 + 1)] " + choice(request.choices[$0]) } ?? "[0] " + text(.formAnswer))
    }
  }
}
