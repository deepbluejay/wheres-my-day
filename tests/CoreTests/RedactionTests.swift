import Foundation
import XCTest
@testable import Core

final class RedactionTests: XCTestCase {
  func testEmailOCRAndPasswordShapes() {
    let text = "로그아웃 someone12348naver.com / a.b@example.org / password: hunter2"
    XCTAssertEqual(redactSecrets(text), "로그아웃 [email] / [email] / [secret]")
  }

  func testCardAndPrivateKeyShapes() {
    let masked = Redaction.apply("card 4111 1111 1111 1111, order 1234 5678 9012 3456\n-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXk\n-----END OPENSSH PRIVATE KEY-----")
    XCTAssertTrue(!masked.text.contains("4111") && masked.text.contains("1234 5678 9012 3456") && !masked.text.contains("b3Blbn"))
    XCTAssertEqual(Set(masked.rules), ["payment-card", "private-key"])
  }

  func testCredentialLabels() {
    XCTAssertFalse(redactSecrets("token=abc123 ghp_" + String(repeating: "a", count: 30)).contains("ghp_a"))
  }

  func testVendorFormatsAndRegressionCorpora() {
    let failures = RedactionFormatsTest.failures()
    XCTAssertTrue(failures.isEmpty, failures.joined(separator: "; "))
  }
}
