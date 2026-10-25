import AppKit
import Core
import Foundation
import Outbound

public extension AppPaths {
  /// The app's own Keychain service for the ChatGPT sign-in.
  static let chatGPTKeychainService = bundleID + ".chatgpt"
  /// Empty; only serializes credential writes between the window and the recorder.
  var chatGPTLock: URL { appData.appendingPathComponent("chatgpt.lock") }
  /// ChatGPT's own usage settings, opened only by the person's click on "Manage usage".
  static let chatGPTUsageSettings = URL(string: "https://chatgpt.com/settings/usage")!
}

public enum ChatGPTSignInHost {
  /// The production account: the person's default browser, the app's Keychain items and lock.
  public static func session(paths: AppPaths, language: String = AppWindowStrings.preferredLanguage()) -> ChatGPTSession {
    let strings = SettingsStrings(language: language)
    return ChatGPTSession(store: KeychainChatGPTCredentialStore(service: AppPaths.chatGPTKeychainService),
      lock: ChatGPTCredentialLock(file: paths.chatGPTLock),
      openBrowser: { url in NSWorkspace.shared.open(url) },
      callbackPage: { page(strings.text(.chatGPTCallbackReturn), language: language) })
  }
  /// The recorder's token port: the same Keychain items and lock as the window's session. It never signs in,
  /// so it has no browser. The recorder is the same signed executable as the window, so the Keychain's
  /// default access list (the creating app) lets it read the items without asking.
  public static func tokens(paths: AppPaths) -> ChatGPTSession {
    ChatGPTSession(store: KeychainChatGPTCredentialStore(service: AppPaths.chatGPTKeychainService),
      lock: ChatGPTCredentialLock(file: paths.chatGPTLock), openBrowser: { _ in false })
  }
  /// The page the browser shows after any callback request. Neutral, because the exchange and ID-token
  /// checks run after it is sent; the result is shown in the app. Holds no value from the request.
  static func page(_ message: String, language: String) -> String {
    let escaped = message.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
    let lang = language.filter { $0.isLetter || $0 == "-" }
    return "<!doctype html><html lang=\"\(lang)\"><meta charset=\"utf-8\"><title>ActivityProbe</title>"
      + "<body style=\"font-family:-apple-system,sans-serif;margin:48px\"><p>\(escaped)</p></body></html>"
  }
}
