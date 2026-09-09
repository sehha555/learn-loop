import Foundation
import PencilKit

/// 畫布的儲存：頁的索引（canvas/index.json）＋每頁的筆跡（canvas/<pageID>.drawing）。
/// 只有主 app 用 —— 分享浮層不畫圖，所以不放 Shared/
@MainActor
final class CanvasStore: ObservableObject {
	@Published private(set) var pages: [CanvasPage] = []

	private let dir: URL
	private let indexURL: URL
	/// 筆跡存檔延後半秒：每一筆都寫檔太兇，停筆才寫
	private var pendingSaves: [UUID: Task<Void, Never>] = [:]

	init(dataDir: URL) {
		dir = dataDir.appendingPathComponent("canvas", isDirectory: true)
		indexURL = dir.appendingPathComponent("index.json")
		try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
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

	/// blockID → 哪一頁的哪一塊。下一輪把標註畫回紙上就靠這個查框
	func block(_ id: UUID) -> (page: CanvasPage, block: CanvasBlock)? {
		for page in pages {
			if let block = page.blocks.first(where: { $0.id == id }) { return (page, block) }
		}
		return nil
	}
}
