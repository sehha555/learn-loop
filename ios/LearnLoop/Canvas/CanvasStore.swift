import Foundation
import PDFKit
import PencilKit
import UIKit

/// 畫布的儲存：頁的索引（canvas/index.json）＋每頁的筆跡（canvas/<pageID>.drawing）。
/// 只有主 app 用 —— 分享浮層不畫圖，所以不放 Shared/
@MainActor
final class CanvasStore: ObservableObject {
	@Published private(set) var pages: [CanvasPage] = []

	private let dir: URL
	private let indexURL: URL
	private let filesDir: URL
	/// 筆跡存檔延後半秒：每一筆都寫檔太兇，停筆才寫
	private var pendingSaves: [UUID: Task<Void, Never>] = [:]
	/// 底圖渲染很貴（PDF 一頁畫成 2388px 寬），翻回來不重畫
	private var backgroundCache: [String: UIImage] = [:]

	init(dataDir: URL) {
		dir = dataDir.appendingPathComponent("canvas", isDirectory: true)
		indexURL = dir.appendingPathComponent("index.json")
		filesDir = dir.appendingPathComponent("files", isDirectory: true)
		try? FileManager.default.createDirectory(at: filesDir, withIntermediateDirectories: true)
		load()
		if pages.isEmpty { pages = [CanvasPage()] }
	}

	private func load() {
		guard let data = try? Data(contentsOf: indexURL),
			let decoded = try? JSONDecoder().decode([CanvasPage].self, from: data)
		else { return }
		pages = decoded
	}

	private func savePages() {
		guard let data = try? JSONEncoder().encode(pages) else { return }
		try? data.write(to: indexURL, options: .atomic)
	}

	// MARK: - 筆跡

	private func drawingURL(_ pageID: UUID) -> URL {
		dir.appendingPathComponent("\(pageID.uuidString).drawing")
	}

	func drawing(for pageID: UUID) -> PKDrawing {
		guard let data = try? Data(contentsOf: drawingURL(pageID)),
			let drawing = try? PKDrawing(data: data)
		else { return PKDrawing() }
		return drawing
	}

	func saveDrawing(_ drawing: PKDrawing, for pageID: UUID) {
		pendingSaves[pageID]?.cancel()
		let data = drawing.dataRepresentation()
		let url = drawingURL(pageID)
		pendingSaves[pageID] = Task {
			try? await Task.sleep(for: .milliseconds(500))
			guard !Task.isCancelled else { return }
			try? data.write(to: url, options: .atomic)
		}
	}

	// MARK: - 頁與塊

	/// 在某頁後面插一頁，回傳新頁的索引
	@discardableResult
	func addPage(after index: Int) -> Int {
		let at = min(index + 1, pages.count)
		pages.insert(CanvasPage(), at: at)
		savePages()
		return at
	}

	func addBlock(_ block: CanvasBlock, to pageID: UUID) {
		guard let index = pages.firstIndex(where: { $0.id == pageID }) else { return }
		pages[index].blocks.append(block)
		savePages()
	}

	// MARK: - 匯入講義當底

	/// 底圖固定用 iPad 橫向最寬的 1194pt 畫、@2x 像素；顯示時縮到紙的寬度
	static let backgroundWidth: CGFloat = 1194

	private func fileURL(_ background: CanvasBackground) -> URL {
		filesDir.appendingPathComponent("\(background.fileID.uuidString).\(background.ext)")
	}

	/// 把 PDF（每頁一張紙）或圖片（一張紙）插在某頁後面，回傳第一張新頁的索引
	func importFile(from source: URL, after index: Int) throws -> Int {
		let accessing = source.startAccessingSecurityScopedResource()
		defer { if accessing { source.stopAccessingSecurityScopedResource() } }
		let fileID = UUID()
		let ext = source.pathExtension.lowercased()
		let target = filesDir.appendingPathComponent("\(fileID.uuidString).\(ext)")
		try FileManager.default.copyItem(at: source, to: target)
		let pageCount = ext == "pdf" ? (PDFDocument(url: target)?.pageCount ?? 0) : 1
		guard pageCount > 0 else { throw CocoaError(.fileReadCorruptFile) }
		let at = min(index + 1, pages.count)
		let newPages = (0..<pageCount).map { page in
			CanvasPage(background: CanvasBackground(fileID: fileID, ext: ext, pageIndex: page))
		}
		pages.insert(contentsOf: newPages, at: at)
		savePages()
		return at
	}

	/// 這一頁的底圖（沒匯入就 nil）
	func backgroundImage(for page: CanvasPage) -> UIImage? {
		guard let background = page.background else { return nil }
		let key = "\(background.fileID.uuidString)-\(background.pageIndex)"
		if let cached = backgroundCache[key] { return cached }
		let url = fileURL(background)
		let image: UIImage?
		if background.ext == "pdf" {
			guard let pdfPage = PDFDocument(url: url)?.page(at: background.pageIndex) else { return nil }
			let bounds = pdfPage.bounds(for: .mediaBox)
			let width = Self.backgroundWidth * 2
			let size = CGSize(width: width, height: width * bounds.height / max(bounds.width, 1))
			image = pdfPage.thumbnail(of: size, for: .mediaBox)
		} else {
			image = UIImage(contentsOfFile: url.path)
		}
		if let image { backgroundCache[key] = image }
		return image
	}

	/// blockID → 哪一頁的哪一塊。下一輪把標註畫回紙上就靠這個查框
	func block(_ id: UUID) -> (page: CanvasPage, block: CanvasBlock)? {
		for page in pages {
			if let block = page.blocks.first(where: { $0.id == id }) { return (page, block) }
		}
		return nil
	}
}
