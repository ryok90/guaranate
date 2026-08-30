import XCTest
@testable import GuaranateCore

final class ProgressBarTests: XCTestCase {
    // Counts characters (grapheme clusters) so multi-byte block glyphs count as 1 column.
    private func columns(_ s: String) -> Int { s.count }

    func testUnicodeBarIsAlwaysWidthColumns() {
        let bar = ProgressBar(width: 20, style: .unicode)
        for fraction in [0.0, 0.13, 0.5, 0.777, 1.0] {
            let (filled, empty) = bar.segments(fraction: fraction)
            XCTAssertEqual(columns(filled) + columns(empty), 20, "fraction \(fraction)")
            XCTAssertEqual(columns(bar.render(fraction: fraction)), 20, "fraction \(fraction)")
        }
    }

    func testUnicodeEndpoints() {
        let bar = ProgressBar(width: 8, style: .unicode)
        XCTAssertEqual(bar.render(fraction: 0), "░░░░░░░░")
        XCTAssertEqual(bar.render(fraction: 1), "████████")
    }

    func testUnicodePartialLeadingCell() {
        // Half of an 8-cell bar is 4 full cells, no partial.
        let bar = ProgressBar(width: 8, style: .unicode)
        XCTAssertEqual(bar.render(fraction: 0.5), "████░░░░")
        // 1/16 of an 8-cell bar = 4 eighths = a half-cell partial as the first glyph.
        XCTAssertEqual(bar.render(fraction: 1.0 / 16.0), "▌░░░░░░░")
    }

    func testFractionIsClamped() {
        let bar = ProgressBar(width: 5, style: .ascii)
        XCTAssertEqual(bar.render(fraction: -3), "-----")
        XCTAssertEqual(bar.render(fraction: 42), "#####")
    }

    func testAsciiHasNoPartialCells() {
        let bar = ProgressBar(width: 10, style: .ascii)
        let (filled, empty) = bar.segments(fraction: 0.54)
        XCTAssertEqual(filled, "#####")
        XCTAssertEqual(empty, "-----")
        XCTAssertEqual(filled.count + empty.count, 10)
    }

    func testZeroWidthIsEmpty() {
        let bar = ProgressBar(width: 0, style: .unicode)
        XCTAssertEqual(bar.render(fraction: 0.5), "")
    }
}
