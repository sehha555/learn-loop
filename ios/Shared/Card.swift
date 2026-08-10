import Foundation

/// 知識點節點。整個 app 只有這一種資料 —— 題目、診斷、追問全都是同一棵樹上的節點。
///
/// 這是「不要變成滾動式聊天記錄」的關鍵：追問的答案掛在被問的那個節點底下，
/// 而不是接在對話最後面。三天後回來看到的是分層的知識點，不是要往上滑的訊息串。
struct Card: Identifiable, Codable, Hashable {
	let id: UUID
	/// 標題。待展開的節點只有這個，內容要點了才生。
	var title: String
	/// 展開後的內容。nil = 還沒展開（畫面上顯示成灰色方塊）。
	var body: String?
	var children: [Card]
	var createdAt: Date

	init(
		id: UUID = UUID(),
		title: String,
		body: String? = nil,
		children: [Card] = [],
		createdAt: Date = Date()
	) {
		self.id = id
		self.title = title
		self.body = body
		self.children = children
		self.createdAt = createdAt
	}

	var isExpanded: Bool { body != nil }

	/// 這棵子樹裡還沒展開的節點數 —— 就是「數得出來的 TODO」
	var pendingCount: Int {
		(isExpanded ? 0 : 1) + children.reduce(0) { $0 + $1.pendingCount }
	}
}

extension Card {
	/// 在樹裡找到指定節點並就地改寫。找不到回傳 false。
	@discardableResult
	mutating func update(id target: UUID, _ transform: (inout Card) -> Void) -> Bool {
		if id == target {
			transform(&self)
			return true
		}
		for index in children.indices where children[index].update(id: target, transform) {
			return true
		}
		return false
	}

	/// 把子樹攤成一維清單，每筆帶著自己的層級。
	/// SwiftUI 的 View 不能遞迴（opaque 型別會自我參照），所以層級改用縮排表達。
	func flattened(depth: Int = 0) -> [(card: Card, depth: Int)] {
		[(self, depth)] + children.flatMap { $0.flattened(depth: depth + 1) }
	}

	/// 從根到指定節點的標題路徑 —— 追問時要把這條路徑餵給模型當脈絡
	func path(to target: UUID) -> [String]? {
		if id == target { return [title] }
		for child in children {
			if let rest = child.path(to: target) { return [title] + rest }
		}
		return nil
	}
}
