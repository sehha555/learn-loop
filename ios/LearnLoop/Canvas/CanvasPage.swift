import Foundation

/// 畫布的一頁。筆跡另外存成 canvas/<id>.drawing（PKDrawing 的二進位），這裡只記結構：
/// 圈選過哪些塊、各對到哪棵樹。一頁一個 topic 的邊界由使用者翻頁決定 —— 最笨但最可靠
struct CanvasPage: Identifiable, Codable, Hashable {
	let id: UUID
	var createdAt: Date
	var blocks: [CanvasBlock]
	/// 匯入的講義當底（像 GoodNotes 把 PDF 拿來寫）。nil = 白紙
	var background: CanvasBackground?

	init(id: UUID = UUID(), createdAt: Date = Date(), blocks: [CanvasBlock] = [], background: CanvasBackground? = nil) {
		self.id = id
		self.createdAt = createdAt
		self.blocks = blocks
		self.background = background
	}
}

/// 底圖來源：canvas/files/<fileID>.<ext> 的第幾頁（圖片永遠是第 0 頁）
struct CanvasBackground: Codable, Hashable {
	let fileID: UUID
	let ext: String
	let pageIndex: Int
}

/// 圈選過的一塊：框在畫布上的位置、送出後長出的樹。id 就是 Card.blockID。
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
