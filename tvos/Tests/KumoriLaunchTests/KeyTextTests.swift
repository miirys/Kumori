import XCTest
@testable import KumoriLaunch

final class KeyTextTests: XCTestCase {
    func testLettersAndDigits() {
        XCTAssertEqual(KeyText.keys("aZ9"), [KeyText.Key(0x41), KeyText.Key(0x5A, shift: true), KeyText.Key(0x39)])
    }

    func testEmailAddress() {
        XCTAssertEqual(KeyText.keys("me@x.io").map(\.code), [0x4D, 0x45, 0x32, 0x58, 0xBE, 0x49, 0x4F])
        XCTAssertTrue(KeyText.keys("@")[0].shift)
    }

    func testSymbolsAndUnknown() {
        XCTAssertEqual(KeyText.key("?"), KeyText.Key(0xBF, shift: true))
        XCTAssertEqual(KeyText.key("\u{2019}"), KeyText.Key(0xDE))
        XCTAssertNil(KeyText.key("é"))
        XCTAssertEqual(KeyText.keys("a\n"), [KeyText.Key(0x41), KeyText.enter])
    }
}
