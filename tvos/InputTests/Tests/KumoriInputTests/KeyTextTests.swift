import XCTest
@testable import KumoriInput

final class KeyTextTests: XCTestCase {
    func testLettersDigitsAndShift() {
        XCTAssertEqual(KeyText.keys("aB1!"), [KeyText.Key(0x41), KeyText.Key(0x42, shift: true), KeyText.Key(0x31), KeyText.Key(0x31, shift: true)])
    }

    func testEveryLineEndIsOneEnter() {
        XCTAssertEqual(KeyText.keys("a\r\nb"), [KeyText.Key(0x41), KeyText.enter, KeyText.Key(0x42)])
        XCTAssertEqual(KeyText.keys("\n"), [KeyText.enter])
        XCTAssertEqual(KeyText.keys("\r"), [KeyText.enter])
    }

    func testCharactersAUSKeyboardCantTypeAreLeftOut() {
        XCTAssertEqual(KeyText.keys("é🙂x"), [KeyText.Key(0x58)])
    }

    func testDictationPunctuation() {
        XCTAssertEqual(KeyText.keys("\u{2019}\u{201C}\u{2014}"), [KeyText.Key(0xDE), KeyText.Key(0xDE, shift: true), KeyText.Key(0xBD)])
    }
}
