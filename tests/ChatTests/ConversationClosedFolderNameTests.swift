import Foundation
import XCTest
@testable import Outbound

/// Claude's any-case rule writes a closed folder's name into a pattern unescaped, so a name with a pattern
/// character would match some other folder and leave the closed one open. Invented names only.
final class ConversationClosedFolderNameTests: XCTestCase {
  func testOnlyPlainNamesAreAccepted() {
    for name in ["Invented", "invented-folder_2.d", "A", "0"] { XCTAssertTrue(ConversationConfiguration.isPlainFolderName(name), name) }
    for name in ["", ".", "..", "in*vented", "in?vented", "[Ii]nvented", "in]vented", "{a,b}", "in vented", "in\\vented",
      "in/vented", "in!vented", "invent\u{e9}d", "in\u{a0}vented", "in\u{0}vented"] {
      XCTAssertFalse(ConversationConfiguration.isPlainFolderName(name), name)
    }
  }

  func testEveryClosedFolderNameIsPlain() {
    XCTAssertTrue(ConversationConfiguration.closedAppDataFolderNames.allSatisfy(ConversationConfiguration.isPlainFolderName))
  }

  func testAnyCaseKeepsPlainCharactersAndBracketsOnlyLetters() {
    let url = URL(fileURLWithPath: "/invented/app-data/In-v.1_d")
    XCTAssertEqual(ConversationConfiguration.anyCase(url).first, "/invented/app-data/[iI][nN]-[vV].1_[dD]")
  }
}
