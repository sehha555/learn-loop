import Foundation

/// 畫布的一頁。筆跡另外存成 canvas/<id>.drawing（PKDrawing 的二進位），這裡只記結構：
/// 頁多大、底下墊什麼、圈選過哪些塊、各對到哪棵樹
struct CanvasPage: Identifiable, Codable, Hashable {
	let id: UUID
	var createdAt: Date
	var blocks: [CanvasBlock]
	/// 匯入的講義當底（像 GoodNotes 把 PDF 拿來寫）。nil = 白紙
	var background: CanvasBackground?
	/// 頁的固定大小（pt）。筆跡、圈選框都是這個座標系，顯示時整頁等比例縮放
	var size: CGSize
	/// 白紙要不要畫淡橫線；墊講義的頁不看這個
	var ruled: Bool

	/// 空白頁的預設大小：寬 768、A4 比例
	static let blankSize = CGSize(width: 768, height: 1086)

	init(
		id: UUID = UUID(), createdAt: Date = Date(), blocks: [CanvasBlock] = [], background: CanvasBackground? = nil,
		size: CGSize = CanvasPage.blankSize, ruled: Bool = true
	) {
		self.id = id
		self.createdAt = createdAt
		self.blocks = blocks
		self.background = background
		self.size = size
		self.ruled = ruled
	}

	// 舊的 index.json 沒有 size、ruled：先給零，搬家時再依筆跡補上大小
	init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		id = try container.decode(UUID.self, forKey: .id)
		createdAt = try container.decode(Date.self, forKey: .createdAt)
		blocks = try container.decode([CanvasBlock].self, forKey: .blocks)
		background = try container.decodeIfPresent(CanvasBackground.self, forKey: .background)
		size = try container.decodeIfPresent(CGSize.self, forKey: .size) ?? .zero
		ruled = try container.decodeIfPresent(Bool.self, forKey: .ruled) ?? true
	}
}

/// 底圖來源：canvas/files/<fileID>.<ext> 的第幾頁（圖片永遠是第 0 頁）
struct CanvasBackground: Codable, Hashable {
	let fileID: UUID
	let ext: String
	let pageIndex: Int
}

/// 圈選過的一塊：框在頁上的位置（頁內座標）、送出後長出的樹。id 就是 Card.blockID。
/// 座標只留在這裡 —— 模型拿到的是裁好的圖，它永遠不知道座標系存在
struct CanvasBlock: Identifiable, Codable, Hashable {
	let id: UUID
	var x: Double
	var y: Double
	var width: Double
	var height: Double
	var cardID: UUID

	init(id: UUID = UUID(), rect: CGRect, cardID: UUID) {
		self.id = id
		x = rect.minX
		y = rect.minY
		width = rect.width
		height = rect.height
		self.cardID = cardID
	}

	var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}
