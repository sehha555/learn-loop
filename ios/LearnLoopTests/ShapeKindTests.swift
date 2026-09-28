import PencilKit
import XCTest

@testable import LearnLoop

/// 圖形工具轉出來的筆畫：數量、外框，以及細筆也要畫得出來
final class ShapeKindTests: XCTestCase {
	private let start = CGPoint(x: 100, y: 200)
	private let end = CGPoint(x: 300, y: 320)

	func testStrokeCount() {
		// 方框拆成四條邊，轉角才不會被 B-spline 磨圓
		let counts: [ShapeKind: Int] = [.line: 1, .rect: 4, .ellipse: 1]
		for (kind, count) in counts {
			XCTAssertEqual(kind.strokes(from: start, to: end, color: .black, width: 4).count, count, "\(kind)")
		}
	}

	func testBoundsCoverDraggedBox() {
		// 往左上拉也一樣：起終點當對角線
		for kind in ShapeKind.allCases {
			let bounds = kind.strokes(from: end, to: start, color: .black, width: 4)
				.reduce(CGRect.null) { $0.union($1.renderBounds) }
			XCTAssertEqual(bounds.minX, 100, accuracy: 4, "\(kind)")
			XCTAssertEqual(bounds.minY, 200, accuracy: 4, "\(kind)")
			XCTAssertEqual(bounds.maxX, 300, accuracy: 4, "\(kind)")
			XCTAssertEqual(bounds.maxY, 320, accuracy: 4, "\(kind)")
		}
	}

	func testThinPenStillRendersOnCanvas() {
		// 點大小 2pt 以下畫布不顯示（minPointSize 是 3）；滑桿最細是 1pt
		for kind in ShapeKind.allCases {
			for width in [1, 1.5, 3, 7, 12] as [CGFloat] {
				let sizes = kind.strokes(from: start, to: end, color: .black, width: width).flatMap { $0.path.map(\.size.width) }
				XCTAssertGreaterThanOrEqual(sizes.min() ?? 0, max(width, ShapeKind.minPointSize), "\(kind) \(width)")
			}
		}
	}
}
