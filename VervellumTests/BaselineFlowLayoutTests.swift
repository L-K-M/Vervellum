import AppKit
import SwiftUI
import XCTest
@testable import Vervellum

final class BaselineFlowLayoutTests: XCTestCase {
    @MainActor
    func testCitationButtonsWrapAtChipBoundaries() {
        let row = BaselineFlowLayout(spacing: 6, lineSpacing: 4) {
            ForEach(1...5, id: \.self) { number in
                Button("[\(number)]") {}
                    .buttonStyle(.plain)
                    .frame(width: 30, height: 20)
            }
        }
        let host = NSHostingController(rootView: row)
        // Exactly five fit on a wide line, two fit at 66pt, and one at 30pt.
        for (width, height) in [(174, 20), (66, 68), (30, 116)] {
            let size = host.sizeThatFits(in: CGSize(width: width, height: 500))
            XCTAssertEqual(size.width, CGFloat(width), accuracy: 0.5)
            XCTAssertEqual(size.height, CGFloat(height), accuracy: 0.5)
        }
    }
}
