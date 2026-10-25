import Foundation

/// Native facts supplied by adapters, with no interpretation of a command's effects.
public struct ConversationRequestPresentation: Equatable {
  public enum Action: Equatable { case command, terminalInput, files, permissions, question, confirmation, tool, unknown }
  public struct File: Equatable {
    public let path: String
    public let diff: String
    public let proposedContents: String?
    public init(path: String, diff: String, proposedContents: String? = nil) {
      self.path = path; self.diff = diff; self.proposedContents = proposedContents
    }
  }
  public struct Fact: Equatable {
    public let name: String
    public let value: String
    // Retain types and field identities alongside the verbatim readable projection.
    public let nativeJSON: String?
    public init(name: String, value: String, nativeJSON: String? = nil) {
      self.name = name; self.value = value; self.nativeJSON = nativeJSON
    }
  }
  public let nativeFacts: [Fact]
  public let fieldsUnavailable: Bool
  public let interactionUnavailable: Bool
  public let action: Action
  public let command: String?
  public let files: [File]
  public let reason: String?
  public let target: String
  public let scope: String
  public init(action: Action = .tool, command: String? = nil, files: [File] = [], reason: String? = nil,
    target: String = "", scope: String = "", nativeFacts: [Fact] = [], interactionUnavailable: Bool = false, fieldsUnavailable: Bool = false) {
    self.action = action; self.command = command; self.files = files; self.reason = reason
    self.target = target; self.scope = scope; self.nativeFacts = nativeFacts
    self.interactionUnavailable = interactionUnavailable; self.fieldsUnavailable = fieldsUnavailable
  }
}
