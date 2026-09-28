import XCTest

@testable import LearnLoop

/// 整疊頁：圈選框（畫面座標）換成「哪一頁、頁內哪一塊」，捲動、縮放都不影響頁內座標
@MainActor
final class PageStackTests: XCTestCase {
	func testHitConvertsScreenRectToPageRect() throws {
		let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let store = CanvasStore(dataDir: dir)
		let notebook = store.createNotebook(named: "筆記", in: nil)
		store.addPage(to: notebook.id, after: 0)
		let pages = try XCTUnwrap(store.material(notebook.id)?.pages)

		// 寬 816 的畫面：左右各留 24，768 寬的頁剛好 1 倍；頁從 y = 20 開始，頁跟頁之間 20
		let stack = PageStackView(store: store)
		stack.frame = CGRect(x: 0, y: 0, width: 816, height: 1000)
		stack.setPages(pages)
		stack.layoutIfNeeded()

		let first = try XCTUnwrap(stack.hit(CGRect(x: 124, y: 120, width: 200, height: 100)))
		XCTAssertEqual(first.page.id, pages[0].id)
		XCTAssertEqual(first.rect, CGRect(x: 100, y: 100, width: 200, height: 100))

		// 捲到第二頁：第二頁頂端在 20 + 1086 + 20 = 1126
		stack.scroll(toPage: 1)
		let second = try XCTUnwrap(stack.hit(CGRect(x: 24, y: 70, width: 100, height: 50)))
		XCTAssertEqual(second.page.id, pages[1].id)
		XCTAssertEqual(second.rect.minX, 0, accuracy: 0.5)
		XCTAssertEqual(second.rect.minY, 70 + stack.contentOffset.y - 1126, accuracy: 0.5)
	}
}
