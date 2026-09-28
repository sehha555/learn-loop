import Foundation

/// 書架：資料夾可以一直往下開（照 GoodNotes），材料（講義或筆記本）放在某個資料夾裡。
/// 存成 canvas/library.json；筆跡、原檔的位置跟以前一樣，不跟著資料夾搬
struct Library: Codable, Equatable {
	var folders: [Folder] = []
	var materials: [Material] = []

	/// 某資料夾底下（不含更深層）的子資料夾，nil = 書架最上層
	func subfolders(of parentID: UUID?) -> [Folder] {
		folders.filter { $0.parentID == parentID }.sorted { $0.createdAt < $1.createdAt }
	}

	func materials(in folderID: UUID?) -> [Material] {
		materials.filter { $0.folderID == folderID }.sorted { $0.createdAt < $1.createdAt }
	}

	/// 這個資料夾自己加上底下每一層的資料夾
	func folderTree(_ id: UUID) -> Set<UUID> {
		var ids: Set<UUID> = [id]
		for child in folders where child.parentID == id { ids.formUnion(folderTree(child.id)) }
		return ids
	}
}

struct Folder: Identifiable, Codable, Hashable {
	let id: UUID
	var name: String
	/// nil = 書架最上層
	var parentID: UUID?
	var createdAt: Date

	init(id: UUID = UUID(), name: String, parentID: UUID?, createdAt: Date = Date()) {
		self.id = id
		self.name = name
		self.parentID = parentID
		self.createdAt = createdAt
	}
}

/// 一份材料＝一串固定大小的頁（匯入的講義頁＋自己插的空白頁）
struct Material: Identifiable, Codable, Hashable {
	let id: UUID
	var name: String
	var folderID: UUID?
	var createdAt: Date
	var pages: [CanvasPage]

	init(id: UUID = UUID(), name: String, folderID: UUID?, createdAt: Date = Date(), pages: [CanvasPage]) {
		self.id = id
		self.name = name
		self.folderID = folderID
		self.createdAt = createdAt
		self.pages = pages
	}
}
