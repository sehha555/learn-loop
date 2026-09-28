import PencilKit
import XCTest

@testable import LearnLoop

/// 書架：資料夾一層層開、刪資料夾連底下一起刪、頁的加刪複製搬、舊的單本畫布搬進書架
@MainActor
final class LibraryTests: XCTestCase {
	private func tempDir() -> URL {
		let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
		return url
	}

	private func oneStroke(to point: CGPoint) -> PKDrawing {
		let points = [CGPoint(x: 10, y: 10), point].map {
			PKStrokePoint(location: $0, timeOffset: 0, size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
		}
		return PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: Date()))])
	}

	private func drawingFiles(in dir: URL) -> Int {
		let canvas = dir.appendingPathComponent("canvas")
		let names = (try? FileManager.default.contentsOfDirectory(atPath: canvas.path)) ?? []
		return names.filter { $0.hasSuffix(".drawing") }.count
	}

	func testNestedFoldersPersist() {
		let dir = tempDir()
		let store = CanvasStore(dataDir: dir)
		let subject = store.createFolder(named: "電子學", in: nil)
		let midterm = store.createFolder(named: "期中範圍", in: subject.id)
		store.createNotebook(named: "Ch3 筆記", in: midterm.id)

		let reopened = CanvasStore(dataDir: dir).library
		XCTAssertEqual(reopened.subfolders(of: nil).map(\.name), ["電子學"])
		XCTAssertEqual(reopened.subfolders(of: subject.id).map(\.name), ["期中範圍"])
		XCTAssertEqual(reopened.materials(in: midterm.id).map(\.name), ["Ch3 筆記"])
	}

	func testDeleteFolderRemovesEverythingBelow() {
		let dir = tempDir()
		let store = CanvasStore(dataDir: dir)
		let subject = store.createFolder(named: "電子學", in: nil)
		let midterm = store.createFolder(named: "期中範圍", in: subject.id)
		let notebook = store.createNotebook(named: "Ch3 筆記", in: midterm.id)
		let kept = store.createNotebook(named: "別科", in: nil)
		store.saveDrawing(oneStroke(to: CGPoint(x: 100, y: 100)), for: notebook.pages[0].id)
		store.saveDrawing(oneStroke(to: CGPoint(x: 100, y: 100)), for: kept.pages[0].id)
		store.flushSaves()
		XCTAssertEqual(drawingFiles(in: dir), 2)

		store.deleteFolder(subject.id)
		XCTAssertTrue(store.library.folders.isEmpty)
		XCTAssertEqual(store.library.materials.map(\.id), [kept.id])
		XCTAssertEqual(drawingFiles(in: dir), 1, "刪掉的筆記本筆跡檔也要刪")
	}

	func testAddDeleteDuplicateMovePages() {
		let dir = tempDir()
		let store = CanvasStore(dataDir: dir)
		let notebook = store.createNotebook(named: "筆記", in: nil)
		let first = notebook.pages[0].id
		store.addPage(to: notebook.id, after: 0, ruled: false)
		store.addPage(to: notebook.id, after: 1)
		var pages = store.material(notebook.id)!.pages
		XCTAssertEqual(pages.count, 3)
		XCTAssertEqual(pages.map(\.ruled), [true, false, true])

		// 複製：筆跡一樣、id 不同、插在原頁後面
		store.saveDrawing(oneStroke(to: CGPoint(x: 200, y: 300)), for: first)
		XCTAssertEqual(store.duplicatePage(first, in: notebook.id), 1)
		pages = store.material(notebook.id)!.pages
		XCTAssertNotEqual(pages[1].id, first)
		XCTAssertEqual(store.drawing(for: pages[1].id).strokes.count, 1)

		// 搬：最後一頁搬到最前面，重開順序一樣
		store.movePages(in: notebook.id, from: [3], to: 0)
		let order = store.material(notebook.id)!.pages.map(\.id)
		XCTAssertEqual(CanvasStore(dataDir: dir).material(notebook.id)?.pages.map(\.id), order)

		// 刪：刪到剩一頁就不能再刪
		for page in store.material(notebook.id)!.pages { store.deletePage(page.id, from: notebook.id) }
		XCTAssertEqual(store.material(notebook.id)?.pages.count, 1)
	}

	/// 書架出現前的單本畫布：整本變成「舊畫布」，筆跡都在，頁高蓋得住寫過的地方
	func testMigratesLegacyIndex() throws {
		let dir = tempDir()
		let canvas = dir.appendingPathComponent("canvas", isDirectory: true)
		try FileManager.default.createDirectory(at: canvas, withIntermediateDirectories: true)
		// 第三頁墊一張橫的 PDF 投影片：頁高要照投影片比例，不能被拉成 A4
		let fileID = UUID()
		try FileManager.default.createDirectory(at: canvas.appendingPathComponent("files"), withIntermediateDirectories: true)
		try UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 842, height: 595)).pdfData { $0.beginPage() }
			.write(to: canvas.appendingPathComponent("files/\(fileID.uuidString).pdf"))
		let legacy = [CanvasPage(), CanvasPage(), CanvasPage()]
		// 舊格式沒有 size、ruled：手寫 JSON，確定讀得進來
		var json = legacy.map { #"{"id":"\#($0.id.uuidString)","createdAt":0,"blocks":[]"# }
		json[2] += #","background":{"fileID":"\#(fileID.uuidString)","ext":"pdf","pageIndex":0}"#
		try Data("[\(json.map { $0 + "}" }.joined(separator: ","))]".utf8).write(to: canvas.appendingPathComponent("index.json"))
		try oneStroke(to: CGPoint(x: 300, y: 3000)).dataRepresentation()
			.write(to: canvas.appendingPathComponent("\(legacy[1].id.uuidString).drawing"))

		let store = CanvasStore(dataDir: dir)
		let material = try XCTUnwrap(store.library.materials.first)
		XCTAssertEqual(material.name, "舊畫布")
		XCTAssertNil(material.folderID)
		XCTAssertEqual(material.pages.map(\.id), legacy.map(\.id))
		XCTAssertEqual(material.pages[0].size, CGSize(width: 1194, height: 1194 * 1.414))
		XCTAssertGreaterThanOrEqual(material.pages[1].size.height, 3000)
		XCTAssertEqual(material.pages[2].size.height, 1194 * 595 / 842, accuracy: 1)
		XCTAssertEqual(store.drawing(for: legacy[1].id).strokes.count, 1)
		XCTAssertFalse(FileManager.default.fileExists(atPath: canvas.appendingPathComponent("index.json").path))
		XCTAssertTrue(FileManager.default.fileExists(atPath: canvas.appendingPathComponent("index.migrated.json").path))

		// 再開一次不會重搬
		XCTAssertEqual(CanvasStore(dataDir: dir).library.materials.count, 1)
	}
}
