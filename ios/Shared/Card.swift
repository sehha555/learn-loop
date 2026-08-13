import Foundation

/// 知識點節點。整個 app 只有這一種資料 —— 題目、診斷、追問全都是同一棵樹上的節點。
///
/// 這是「不要變成滾動式聊天記錄」的關鍵：追問的答案掛在被問的那個節點底下，
/// 而不是接在對話最後面。三天後回來看到的是分層的知識點，不是要往上滑的訊息串。
struct Card: Identifiable, Codable, Hashable {
	/// 這個點是哪一種。全部都生成疑問句的話，「想補充一下」「這裡有雷」
	/// 這些同樣有用的方向就永遠出不來。
	enum Kind: String, Codable {
		case topic       // 題目本身
		case step        // 解這題客觀要走的一步 —— 不是猜的，題目診斷時才會出現
		case question    // 你可能正想問的 —— 只在追問（expand）新冒出的點裡出現
		case supplement  // 這題沒寫到但接得上的
		case trap        // 很多人在這裡踩雷
		case extend      // 更難或更一般的版本
		case custom      // 你自己加的 —— AI 沒猜到的才是最有價值的資料
	}

	let id: UUID
	/// 標題。待展開的節點只有這個，內容要點了才生。
	var title: String
	/// 展開後的內容。nil = 還沒展開（畫面上顯示成一顆等著被點的方塊）。
	var body: String?
	var kind: Kind
	var children: [Card]
	var createdAt: Date
	/// 這一題用到的概念名（AI 抽的，2-4 個）。只有 topic 層有，子節點都是空的。
	/// 跨題目累積起來就是之後 wiki / graph 的地基。
	var concepts: [String]

	init(
		id: UUID = UUID(),
		title: String,
		body: String? = nil,
		kind: Kind = .question,
		children: [Card] = [],
		createdAt: Date = Date(),
		concepts: [String] = []
	) {
		self.id = id
		self.title = title
		self.body = body
		self.kind = kind
		self.children = children
		self.createdAt = createdAt
		self.concepts = concepts
	}

	/// 手寫的 init —— kind 是後來才加的欄位，舊存檔沒有它。
	/// 用合成的 Codable 會直接解不出來，整棵樹跟著消失。
	init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		id = try container.decode(UUID.self, forKey: .id)
		title = try container.decode(String.self, forKey: .title)
		body = try container.decodeIfPresent(String.self, forKey: .body)
		kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .question
		children = try container.decodeIfPresent([Card].self, forKey: .children) ?? []
		createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
		concepts = try container.decodeIfPresent([String].self, forKey: .concepts) ?? []
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

	/// 從根到指定節點的標題路徑 —— 追問時要把這條路徑餵給模型當脈絡
	func path(to target: UUID) -> [String]? {
		if id == target { return [title] }
		for child in children {
			if let rest = child.path(to: target) { return [title] + rest }
		}
		return nil
	}
}
