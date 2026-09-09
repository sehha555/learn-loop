import PDFKit
import XCTest

@testable import LearnLoop

/// 畫布資料層：匯入 PDF 每頁一張紙、底圖畫得出來、筆跡與索引重開還在
final class CanvasStoreTests: XCTestCase {
	private func tempDir() -> URL {
		let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
		return url
	}

	/// 三頁的假講義
	private func makePDF(in dir: URL) -> URL {
		let url = dir.appendingPathComponent("講義.pdf")
		let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842))
		let data = renderer.pdfData { context in
			for page in 1...3 {
				context.beginPage()
				"第 \(page) 頁".draw(at: CGPoint(x: 40, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 24)])
			}
		}
		try! data.write(to: url)
		return url
	}

	@MainActor
	func testImportPDFMakesOnePagePerPDFPage() throws {
		let dir = tempDir()
		let store = CanvasStore(dataDir: dir)
		XCTAssertEqual(store.pages.count, 1)  // 新開就有一張白紙
		let first = try store.importFile(from: makePDF(in: dir), after: 0)
		XCTAssertEqual(first, 1)
		XCTAssertEqual(store.pages.count, 4)
		XCTAssertEqual(store.pages[1...3].map { $0.background?.pageIndex }, [0, 1, 2])
		XCTAssertNil(store.pages[0].background)

		let image = store.backgroundImage(for: store.pages[2])
		XCTAssertNotNil(image)
		XCTAssertEqual(image!.size.width, CanvasStore.backgroundWidth * 2, accuracy: 1)

		// 索引落地：重開一個 store 頁還在、底圖檔還在
		let reopened = CanvasStore(dataDir: dir)
		XCTAssertEqual(reopened.pages.count, 4)
		XCTAssertNotNil(reopened.backgroundImage(for: reopened.pages[3]))
	}

	@MainActor
	func testBlocksPersistAndLookup() {
		let dir = tempDir()
		let store = CanvasStore(dataDir: dir)
		let pageID = store.pages[0].id
		let cardID = UUID()
		let block = CanvasBlock(rect: CGRect(x: 10, y: 20, width: 300, height: 120), cardID: cardID)
		store.addBlock(block, to: pageID)
		let hit = CanvasStore(dataDir: dir).block(block.id)
		XCTAssertEqual(hit?.page.id, pageID)
		XCTAssertEqual(hit?.block.rect, CGRect(x: 10, y: 20, width: 300, height: 120))
		XCTAssertEqual(hit?.block.cardID, cardID)
	}
}
