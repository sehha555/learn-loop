import Foundation
import PDFKit
import PencilKit
import UIKit

/// 畫布的儲存：書架（canvas/library.json：資料夾＋材料＋每份材料的頁）＋每頁的筆跡（canvas/<pageID>.drawing）
/// ＋匯入的原檔（canvas/files/）。只有主 app 用 —— 分享浮層不畫圖，所以不放 Shared/
@MainActor
final class CanvasStore: ObservableObject {
	@Published private(set) var library = Library()

	private let dir: URL
	private let libraryURL: URL
	private let filesDir: URL
	/// 筆跡存檔延後半秒：每一筆都寫檔太兇，停筆才寫
	private var pendingSaves: [UUID: Task<Void, Never>] = [:]
	/// 還沒寫下去的筆跡：app 進背景時要立刻補寫，不然這半秒內被砍就丟筆畫
	private var pendingData: [UUID: Data] = [:]
	/// 底圖渲染很貴（PDF 一頁畫成 2388px 寬），翻回來不重畫；照佔的記憶體算上限，捲過很多頁時舊的會被清
	private let backgroundCache: NSCache<NSString, UIImage> = {
		let cache = NSCache<NSString, UIImage>()
		cache.totalCostLimit = 150 * 1024 * 1024
		return cache
	}()
	/// 封面、頁面總覽的小圖。那一頁的筆跡改了就丟掉重畫
	private let thumbnailCache = NSCache<NSUUID, UIImage>()
	/// 開過的 PDF 留著：每畫一頁都重開整份檔很慢
	private var pdfs: [UUID: PDFDocument] = [:]

	init(dataDir: URL) {
		dir = dataDir.appendingPathComponent("canvas", isDirectory: true)
		libraryURL = dir.appendingPathComponent("library.json")
		filesDir = dir.appendingPathComponent("files", isDirectory: true)
		try? FileManager.default.createDirectory(at: filesDir, withIntermediateDirectories: true)
		if let data = try? Data(contentsOf: libraryURL), let decoded = try? JSONDecoder().decode(Library.self, from: data) {
			library = decoded
		} else {
			migrateLegacyIndex()
		}
	}

	private func saveLibrary() {
		guard let data = try? JSONEncoder().encode(library) else { return }
		try? data.write(to: libraryURL, options: .atomic)
	}

	/// 書架出現前只有一本全域筆記（canvas/index.json）：整本搬成書架最上層的「舊畫布」。
	/// 舊頁沒有固定大小，寬用舊底圖的 1194、高要蓋得住底圖和寫過的筆跡。index.json 改名留著，不刪
	private func migrateLegacyIndex() {
		let indexURL = dir.appendingPathComponent("index.json")
		/// 舊格式的頁：沒有大小、沒有橫線設定
		struct LegacyPage: Decodable {
			let id: UUID
			let createdAt: Date
			let blocks: [CanvasBlock]
			let background: CanvasBackground?
		}
		guard let data = try? Data(contentsOf: indexURL),
			let legacy = try? JSONDecoder().decode([LegacyPage].self, from: data), !legacy.isEmpty
		else { return }
		let width = Self.backgroundWidth
		let pages = legacy.map { old in
			let ink = drawing(for: old.id).bounds
			let paper = old.background.flatMap(backgroundImage).map { CanvasPage.backgroundRect(for: $0, pageWidth: width).height }
				?? width * 1.414
			return CanvasPage(
				id: old.id, createdAt: old.createdAt, blocks: old.blocks, background: old.background,
				size: CGSize(width: width, height: max(ink.isNull ? 0 : ink.maxY + 200, paper)))
		}
		library.materials = [Material(name: "舊畫布", folderID: nil, pages: pages)]
		saveLibrary()
		try? FileManager.default.moveItem(at: indexURL, to: dir.appendingPathComponent("index.migrated.json"))
	}

	// MARK: - 查

	func material(_ id: UUID) -> Material? {
		library.materials.first { $0.id == id }
	}

	/// 這一頁在哪份材料裡（記得停在哪一頁時，要從頁找回材料）
	func material(containing pageID: UUID) -> Material? {
		library.materials.first { $0.pages.contains { $0.id == pageID } }
	}

	private func materialIndex(_ id: UUID) -> Int? {
		library.materials.firstIndex { $0.id == id }
	}

	// MARK: - 資料夾

	@discardableResult
	func createFolder(named name: String, in parentID: UUID?) -> Folder {
		let folder = Folder(name: name, parentID: parentID)
		library.folders.append(folder)
		saveLibrary()
		return folder
	}

	func renameFolder(_ id: UUID, to name: String) {
		guard let index = library.folders.firstIndex(where: { $0.id == id }) else { return }
		library.folders[index].name = name
		saveLibrary()
	}

	/// 資料夾連同底下每一層的資料夾與材料一起刪（材料的筆跡、原檔也刪）
	func deleteFolder(_ id: UUID) {
		let tree = library.folderTree(id)
		for material in library.materials where material.folderID.map(tree.contains) == true {
			deleteMaterial(material.id)
		}
		library.folders.removeAll { tree.contains($0.id) }
		saveLibrary()
	}

	// MARK: - 材料

	/// 新的空白筆記本，先給一頁橫線紙
	@discardableResult
	func createNotebook(named name: String, in folderID: UUID?) -> Material {
		let material = Material(name: name, folderID: folderID, pages: [CanvasPage()])
		library.materials.append(material)
		saveLibrary()
		return material
	}

	/// 匯入 PDF（每頁一張紙）或圖片（一張紙）成一份新材料，名字用檔名
	@discardableResult
	func importMaterial(from source: URL, in folderID: UUID?) throws -> Material {
		let material = Material(
			name: source.deletingPathExtension().lastPathComponent, folderID: folderID, pages: try copyAsPages(source))
		library.materials.append(material)
		saveLibrary()
		return material
	}

	func renameMaterial(_ id: UUID, to name: String) {
		guard let index = materialIndex(id) else { return }
		library.materials[index].name = name
		saveLibrary()
	}

	func deleteMaterial(_ id: UUID) {
		guard let index = materialIndex(id) else { return }
		let removed = library.materials.remove(at: index)
		removed.pages.forEach(removeDrawing)
		removeUnusedFiles(Set(removed.pages.compactMap(\.background)))
		saveLibrary()
	}

	// MARK: - 頁

	/// 在某頁後面插一頁，大小跟那一頁一樣；回傳新頁的索引
	@discardableResult
	func addPage(to materialID: UUID, after index: Int, ruled: Bool = true) -> Int {
		let pages = material(materialID)?.pages ?? []
		let size = pages.indices.contains(index) ? pages[index].size : CanvasPage.blankSize
		return insert([CanvasPage(size: size, ruled: ruled)], into: materialID, after: index)
	}

	/// 把 PDF 或圖片的頁插進這份材料的某頁後面，回傳第一張新頁的索引
	func insertFile(from source: URL, into materialID: UUID, after index: Int) throws -> Int {
		insert(try copyAsPages(source), into: materialID, after: index)
	}

	private func insert(_ newPages: [CanvasPage], into materialID: UUID, after index: Int) -> Int {
		guard let m = materialIndex(materialID) else { return index }
		let at = min(index + 1, library.materials[m].pages.count)
		library.materials[m].pages.insert(contentsOf: newPages, at: at)
		saveLibrary()
		return at
	}

	/// 這一頁在第幾份材料的第幾頁
	private func locate(_ pageID: UUID, in materialID: UUID) -> (m: Int, p: Int)? {
		guard let m = materialIndex(materialID),
			let p = library.materials[m].pages.firstIndex(where: { $0.id == pageID })
		else { return nil }
		return (m, p)
	}

	/// 刪一頁（連筆跡檔）。每份材料至少留一頁
	func deletePage(_ pageID: UUID, from materialID: UUID) {
		guard let (m, p) = locate(pageID, in: materialID), library.materials[m].pages.count > 1 else { return }
		let removed = library.materials[m].pages.remove(at: p)
		removeDrawing(removed)
		removeUnusedFiles(removed.background.map { [$0] } ?? [])
		saveLibrary()
	}

	/// 複製一頁插在它後面：底、大小、筆跡都一樣，圈選過的塊不帶（那是對到原頁的題）
	@discardableResult
	func duplicatePage(_ pageID: UUID, in materialID: UUID) -> Int? {
		guard let (m, p) = locate(pageID, in: materialID) else { return nil }
		let source = library.materials[m].pages[p]
		let copy = CanvasPage(background: source.background, size: source.size, ruled: source.ruled)
		let ink = drawing(for: pageID).dataRepresentation()
		try? ink.write(to: drawingURL(copy.id), options: .atomic)
		library.materials[m].pages.insert(copy, at: p + 1)
		saveLibrary()
		return p + 1
	}

	func movePages(in materialID: UUID, from offsets: IndexSet, to destination: Int) {
		guard let m = materialIndex(materialID) else { return }
		library.materials[m].pages.move(fromOffsets: offsets, toOffset: destination)
		saveLibrary()
	}

	// MARK: - 筆跡

	private func drawingURL(_ pageID: UUID) -> URL {
		dir.appendingPathComponent("\(pageID.uuidString).drawing")
	}

	/// 還沒寫下去的筆跡優先：畫布在半秒內被收掉又建回來時，才不會讀到舊檔、再把舊的存回去
	func drawing(for pageID: UUID) -> PKDrawing {
		guard let data = pendingData[pageID] ?? (try? Data(contentsOf: drawingURL(pageID))),
			let drawing = try? PKDrawing(data: data)
		else { return PKDrawing() }
		return drawing
	}

	func saveDrawing(_ drawing: PKDrawing, for pageID: UUID) {
		thumbnailCache.removeObject(forKey: pageID as NSUUID)
		pendingSaves[pageID]?.cancel()
		pendingData[pageID] = drawing.dataRepresentation()
		pendingSaves[pageID] = Task {
			try? await Task.sleep(for: .milliseconds(500))
			guard !Task.isCancelled else { return }
			writePending(pageID)
		}
	}

	/// 還在等半秒的全部馬上寫（app 要進背景了）
	func flushSaves() {
		for (pageID, task) in pendingSaves {
			task.cancel()
			writePending(pageID)
		}
		pendingSaves = [:]
	}

	private func writePending(_ pageID: UUID) {
		guard let data = pendingData.removeValue(forKey: pageID) else { return }
		try? data.write(to: drawingURL(pageID), options: .atomic)
	}

	private func removeDrawing(_ page: CanvasPage) {
		pendingSaves.removeValue(forKey: page.id)?.cancel()
		pendingData[page.id] = nil
		try? FileManager.default.removeItem(at: drawingURL(page.id))
	}

	// MARK: - 塊

	func addBlock(_ block: CanvasBlock, to pageID: UUID) {
		for m in library.materials.indices {
			guard let p = library.materials[m].pages.firstIndex(where: { $0.id == pageID }) else { continue }
			library.materials[m].pages[p].blocks.append(block)
			saveLibrary()
			return
		}
	}

	// MARK: - 匯入的原檔與底圖

	/// 底圖固定用 iPad 橫向最寬的 1194pt 畫、@2x 像素；顯示時縮到頁的大小
	static let backgroundWidth: CGFloat = 1194

	private func fileURL(_ background: CanvasBackground) -> URL {
		filesDir.appendingPathComponent("\(background.fileID.uuidString).\(background.ext)")
	}

	/// 原檔複製進 canvas/files/，每頁（圖片就一頁）變一張紙，大小照原檔比例、寬 768
	private func copyAsPages(_ source: URL) throws -> [CanvasPage] {
		let accessing = source.startAccessingSecurityScopedResource()
		defer { if accessing { source.stopAccessingSecurityScopedResource() } }
		let fileID = UUID()
		let ext = source.pathExtension.lowercased()
		let target = filesDir.appendingPathComponent("\(fileID.uuidString).\(ext)")
		try FileManager.default.copyItem(at: source, to: target)
		let sizes: [CGSize]
		if ext == "pdf" {
			guard let pdf = PDFDocument(url: target) else { throw CocoaError(.fileReadCorruptFile) }
			pdfs[fileID] = pdf
			sizes = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.bounds(for: .mediaBox).size }
		} else {
			sizes = UIImage(contentsOfFile: target.path).map { [$0.size] } ?? []
		}
		guard !sizes.isEmpty else {
			try? FileManager.default.removeItem(at: target)
			throw CocoaError(.fileReadCorruptFile)
		}
		let width = CanvasPage.blankSize.width
		return sizes.enumerated().map { index, size in
			CanvasPage(
				background: CanvasBackground(fileID: fileID, ext: ext, pageIndex: index),
				size: CGSize(width: width, height: width * size.height / max(size.width, 1)))
		}
	}

	/// 沒有任何一頁還墊著的原檔就刪掉
	private func removeUnusedFiles(_ candidates: Set<CanvasBackground>) {
		let inUse = Set(library.materials.flatMap(\.pages).compactMap { $0.background?.fileID })
		for background in candidates where !inUse.contains(background.fileID) {
			pdfs[background.fileID] = nil
			try? FileManager.default.removeItem(at: fileURL(background))
		}
	}

	private func pdfPage(_ background: CanvasBackground) -> PDFPage? {
		if pdfs[background.fileID] == nil { pdfs[background.fileID] = PDFDocument(url: fileURL(background)) }
		return pdfs[background.fileID]?.page(at: background.pageIndex)
	}

	/// 一頁（或頁上的一塊）畫成圖：白底＋底圖（或淡橫線）＋筆跡。
	/// 封面、頁面總覽、圈一題送去問的圖都用這個，三邊看到的紙長一樣
	func render(_ page: CanvasPage, drawing: PKDrawing, rect: CGRect, scale: CGFloat, background: UIImage?) -> UIImage {
		let size = CGSize(width: rect.width * scale, height: rect.height * scale)
		let ink = drawing.image(from: rect, scale: scale * UIScreen.main.scale)
		return UIGraphicsImageRenderer(size: size).image { context in
			UIColor.white.setFill()
			context.fill(CGRect(origin: .zero, size: size))
			let origin = CGPoint(x: -rect.minX * scale, y: -rect.minY * scale)
			if let background {
				background.draw(in: CanvasPage.backgroundRect(for: background, pageWidth: page.size.width * scale).offsetBy(dx: origin.x, dy: origin.y))
			} else if page.ruled {
				UIColor.systemGray5.setFill()
				let spacing = CanvasPage.lineSpacing * scale
				for y in stride(from: origin.y + spacing, to: size.height, by: spacing) where y > 0 {
					context.fill(CGRect(x: 0, y: y, width: size.width, height: 1))
				}
			}
			ink.draw(in: CGRect(origin: .zero, size: size))
		}
	}

	static let thumbnailWidth: CGFloat = 150

	/// 封面、頁面總覽用的小圖。底圖直接從 PDF 畫小張，不經過畫布用的大圖快取
	func thumbnail(for page: CanvasPage) -> UIImage {
		if let cached = thumbnailCache.object(forKey: page.id as NSUUID) { return cached }
		let scale = Self.thumbnailWidth / max(page.size.width, 1)
		let background: UIImage? = page.background.flatMap { background in
			guard background.ext == "pdf" else { return backgroundImage(for: page) }
			guard let pdfPage = pdfPage(background) else { return nil }
			let bounds = pdfPage.bounds(for: .mediaBox)
			let width = Self.thumbnailWidth * UIScreen.main.scale
			return pdfPage.thumbnail(of: CGSize(width: width, height: width * bounds.height / max(bounds.width, 1)), for: .mediaBox)
		}
		let image = render(page, drawing: drawing(for: page.id), rect: CGRect(origin: .zero, size: page.size), scale: scale, background: background)
		thumbnailCache.setObject(image, forKey: page.id as NSUUID)
		return image
	}

	/// 這一頁的底圖（沒匯入就 nil）
	func backgroundImage(for page: CanvasPage) -> UIImage? {
		page.background.flatMap(backgroundImage)
	}

	private func backgroundImage(_ background: CanvasBackground) -> UIImage? {
		let key = "\(background.fileID.uuidString)-\(background.pageIndex)" as NSString
		if let cached = backgroundCache.object(forKey: key) { return cached }
		let image: UIImage?
		if background.ext == "pdf" {
			guard let pdfPage = pdfPage(background) else { return nil }
			let bounds = pdfPage.bounds(for: .mediaBox)
			let width = Self.backgroundWidth * 2
			image = pdfPage.thumbnail(of: CGSize(width: width, height: width * bounds.height / max(bounds.width, 1)), for: .mediaBox)
		} else {
			image = UIImage(contentsOfFile: fileURL(background).path)
		}
		guard let image, let cg = image.cgImage else { return image }
		backgroundCache.setObject(image, forKey: key, cost: cg.bytesPerRow * cg.height)
		return image
	}
}
