import PDFKit
import PencilKit
import XCTest

@testable import LearnLoop

/// 畫布資料層：匯入 PDF 每頁一張紙、底圖畫得出來、筆跡與書架重開還在
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
		XCTAssertTrue(store.library.materials.isEmpty)  // 新裝的書架是空的
		let material = try store.importMaterial(from: makePDF(in: dir), in: nil)
		XCTAssertEqual(material.name, "講義")
		XCTAssertEqual(material.pages.map { $0.background?.pageIndex }, [0, 1, 2])
		// 頁大小照 PDF 比例（595×842），寬統一 768
		XCTAssertEqual(material.pages[0].size.width, 768)
		XCTAssertEqual(material.pages[0].size.height, 768 * 842 / 595, accuracy: 0.5)

		let image = store.backgroundImage(for: material.pages[1])
		XCTAssertNotNil(image)
		XCTAssertEqual(image!.size.width, CanvasStore.backgroundWidth * 2, accuracy: 1)

		// 落地：重開一個 store 材料還在、底圖檔還在
		let reopened = CanvasStore(dataDir: dir)
		XCTAssertEqual(reopened.material(material.id)?.pages.count, 3)
		XCTAssertNotNil(reopened.backgroundImage(for: reopened.material(material.id)!.pages[2]))
	}

	@MainActor
	func testBlocksPersistAndLookup() {
		let dir = tempDir()
		let store = CanvasStore(dataDir: dir)
		let pageID = store.createNotebook(named: "筆記", in: nil).pages[0].id
		let cardID = UUID()
		let block = CanvasBlock(rect: CGRect(x: 10, y: 20, width: 300, height: 120), cardID: cardID)
		store.addBlock(block, to: pageID)
		let saved = CanvasStore(dataDir: dir).material(containing: pageID)?.pages.first?.blocks.first
		XCTAssertEqual(saved?.id, block.id)
		XCTAssertEqual(saved?.rect, CGRect(x: 10, y: 20, width: 300, height: 120))
		XCTAssertEqual(saved?.cardID, cardID)
	}

	/// 停筆後的半秒內 app 進背景：flushSaves 要馬上落地，不等計時器
	@MainActor
	func testFlushSavesWritesPendingDrawingImmediately() {
		let dir = tempDir()
		let store = CanvasStore(dataDir: dir)
		let pageID = store.createNotebook(named: "筆記", in: nil).pages[0].id
		let ink = PKInk(.pen, color: .black)
		let points = [CGPoint(x: 10, y: 10), CGPoint(x: 200, y: 80)].map {
			PKStrokePoint(location: $0, timeOffset: 0, size: CGSize(width: 3, height: 3),
				opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
		}
		let drawing = PKDrawing(strokes: [PKStroke(ink: ink, path: PKStrokePath(controlPoints: points, creationDate: Date()))])
		store.saveDrawing(drawing, for: pageID)
		XCTAssertTrue(CanvasStore(dataDir: dir).drawing(for: pageID).strokes.isEmpty, "還在等半秒，檔案不該已經寫了")
		store.flushSaves()
		XCTAssertEqual(CanvasStore(dataDir: dir).drawing(for: pageID).strokes.count, 1)
	}
}
