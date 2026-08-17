import XCTest
@testable import Reclip

final class CaptionLayoutTests: XCTestCase {
    private func words(_ specs: [(String, Int, Int)]) -> [CaptionWord] {
        specs.map { CaptionWord(text: $0.0, startMs: $0.1, endMs: $0.2, leadingSpace: true) }
    }

    func testActiveWordIndex() {
        let w = words([("a", 0, 100), ("b", 100, 200), ("c", 200, 300)])
        XCTAssertEqual(CaptionLayout.activeWordIndex(w, timeMs: 150), 1)   // inside b
        XCTAssertEqual(CaptionLayout.activeWordIndex(w, timeMs: 0), 0)     // start of a
        XCTAssertEqual(CaptionLayout.activeWordIndex(w, timeMs: 500), 2)   // past the end → last
        // before the first word starts → clamps to 0
        let w2 = words([("a", 100, 200)])
        XCTAssertEqual(CaptionLayout.activeWordIndex(w2, timeMs: 0), 0)
        XCTAssertEqual(CaptionLayout.activeWordIndex([], timeMs: 0), -1)
    }

    func testWordStatesSpokenActiveUpcoming() {
        let w = words([("one", 0, 100), ("two", 100, 200), ("three", 200, 300), ("four", 300, 400)])
        let lines = CaptionLayout.build(words: w, timeMs: 250, maxCharsPerLine: 100, maxRows: 4)
        let flat = lines.flatMap(\.words)
        XCTAssertEqual(flat.map(\.text), ["one", "two", "three", "four"])
        XCTAssertEqual(flat[0].state, .spoken)     // before active
        XCTAssertEqual(flat[1].state, .spoken)
        XCTAssertEqual(flat[2].state, .active)     // "three" is active at 250ms
        XCTAssertEqual(flat[3].state, .upcoming)   // after active
    }

    func testLineWrapping() {
        let w = words([("alpha", 0, 1), ("bravo", 1, 2), ("charlie", 2, 3), ("delta", 3, 4)])
        // maxChars 12 → "alpha bravo" (11) fits; "charlie" pushes a new line.
        let lines = CaptionLayout.build(words: w, timeMs: 0, maxCharsPerLine: 12, maxRows: 4)
        XCTAssertGreaterThan(lines.count, 1)
        XCTAssertEqual(lines.first?.text, "alpha bravo")
    }

    func testRollingWindowCentersOnActive() {
        // 8 single-word lines (maxChars tiny), window of 2 rows around the active word.
        let w = words((0..<8).map { ("w\($0)", $0 * 100, $0 * 100 + 100) })
        let lines = CaptionLayout.build(words: w, timeMs: 550, maxCharsPerLine: 2, maxRows: 2)
        XCTAssertEqual(lines.count, 2, "window limited to maxRows")
        // The active word (w5 at 550ms) must be visible in the window.
        let hasActive = lines.flatMap(\.words).contains { $0.state == .active }
        XCTAssertTrue(hasActive, "active word stays within the rolling window")
    }
}
