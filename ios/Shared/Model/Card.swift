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
		case note        // 一個概念的知識點（不針對題目的問答都掛在這棵樹下），每個概念最多一棵
		case free        // 直接問的（沒貼題目）—— 自成一棵樹，歸到模型判的概念下
	}

	/// 這一題當下的狀態。診斷時模型判斷，存下來當「卡過幾次」的依據。
	enum Situation: String, Codable {
		case stuck   // 寫到一半停住
		case done    // 寫完了
		case blank   // 只有題目還沒動筆

		/// 餵回模型或顯示用的白話
		var label: String {
			switch self {
			case .stuck: "寫到一半卡住"
			case .done: "寫完了"
			case .blank: "只有題目、還沒動筆"
			}
		}
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
	/// nil = 這題是本欄位上線前存的，狀態不明。
	/// 刻意用 optional 而不是給預設值：把舊資料算進 stuck 會虛報，算進 done 會漏報，
	/// 兩種都是在編造沒發生過的事實。不知道就是不知道。
	/// 跟 concepts 同樣的約定：只有 topic 層有值，子節點一律 nil。
	var situation: Situation?
	/// 診斷時把圖片抄成的文字（LaTeX）。追問時送這段代替重傳圖。
	/// nil = 本欄位上線前存的題目。只有 topic 層有值。
	var transcript: String?
	/// 題目原文（只有題目、不含他寫的過程）。清單預覽顯示這個。nil = 上線前的舊題或筆記
	var problem: String?
	/// 使用者把這個節點收起來了。存檔而不是放在畫面狀態裡 —— 離開再回來要記得
	var collapsed: Bool
	/// 這個問答不只關這一題、屬於某個概念的知識 —— 模型答題時順便判斷，判錯可手動改。
	/// 節點留在原樹不搬，概念的知識點頁同時列出它
	var noteConcept: String?
	/// 這個節點的內容是中繼站失敗後退回雲端答的（含原因）。nil = 正常路徑
	var fallbackNote: String?
	/// 他送進來時打的字（只貼圖沒打字就 nil）。只有樹根有；改問題重送時顯示、重生時重送
	var asked: String?
	/// 判題時模型看他寫到哪：第幾個解題步驟開始出錯或停下（1 起算）。前面的步驟標「已經對了」、
	/// 直接給做法時從這步開始自動展開。nil = 舊資料或不是題目；0 = 全對
	var stuckStep: Int?

	init(
		id: UUID = UUID(),
		title: String,
		body: String? = nil,
		kind: Kind = .question,
		children: [Card] = [],
		createdAt: Date = Date(),
		concepts: [String] = [],
		situation: Situation? = nil,
		transcript: String? = nil,
		problem: String? = nil,
		collapsed: Bool = false,
		noteConcept: String? = nil,
		fallbackNote: String? = nil,
		asked: String? = nil
	) {
		self.id = id
		self.title = title
		self.body = body
		self.kind = kind
		self.children = children
		self.createdAt = createdAt
		self.concepts = concepts
		self.situation = situation
		self.transcript = transcript
		self.problem = problem
		self.collapsed = collapsed
		self.noteConcept = noteConcept
		self.fallbackNote = fallbackNote
		self.asked = asked
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
		situation = try container.decodeIfPresent(Situation.self, forKey: .situation)
		transcript = try container.decodeIfPresent(String.self, forKey: .transcript)
		problem = try container.decodeIfPresent(String.self, forKey: .problem)
		collapsed = try container.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false
		noteConcept = try container.decodeIfPresent(String.self, forKey: .noteConcept)
		fallbackNote = try container.decodeIfPresent(String.self, forKey: .fallbackNote)
		asked = try container.decodeIfPresent(String.self, forKey: .asked)
		stuckStep = try container.decodeIfPresent(Int.self, forKey: .stuckStep)
	}

	var isExpanded: Bool { body != nil }

	/// 這棵子樹裡還沒展開的節點數 —— 就是「數得出來的 TODO」
	var pendingCount: Int {
		(isExpanded ? 0 : 1) + children.reduce(0) { $0 + $1.pendingCount }
	}

	/// 子樹裡點開過的 AI 節點數（不含自己）。自己打的 custom 不算 ——
	/// 病歷卡把那些當「你問過的問題」全文另列
	var expandedDescendants: Int {
		children.reduce(0) {
			$0 + (($1.isExpanded && $1.kind != .custom) ? 1 : 0) + $1.expandedDescendants
		}
	}
}

extension Card {
	/// 剝掉題目開頭的題號（「1.」「(3)」「第 2 題」「Q1」「例 3」），模型忘了也擋得住。
	/// 清單大標只要題目本體
	static func stripProblemNumber(_ text: String) -> String {
		let pattern = #"^\s*(?:第\s*[0-9一二三四五六七八九十]+\s*題|[例題]\s*[0-9]+|[Qq]\s*[0-9]+|[(（]\s*[0-9a-zA-Z]+\s*[)）]|[0-9]+\s*[.、)）]|[a-zA-Z]\s*[.)）])[\s.、:：]*"#
		var stripped = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
		// 結尾的等號是他準備開始算的記號，不是題目的一部分（「$\int … dx =$」「… = ?」）
		stripped = stripped.replacingOccurrences(
			of: #"[\s=＝?？]+(\$?)\s*$"#, with: "$1", options: .regularExpression)
		stripped = stripped.replacingOccurrences(
			of: #"[\s=＝?？]+\$\s*$"#, with: "$", options: .regularExpression)
		stripped = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
		// 模型偶爾整句是 LaTeX 卻忘了包 $（「\int_0^1 … dx」）——沒包的 MathText 當純文字顯示原始碼
		if !stripped.contains("$"), stripped.contains("\\"),
		   stripped.range(of: #"\p{Han}"#, options: .regularExpression) == nil {
			stripped = "$" + stripped + "$"
		}
		// 或整句用 unicode 符號寫假數學（「∫∫_Ω 1/(1+x+y)^2 dA，0≤x≤2」）：換成 LaTeX 再包
		stripped = LatexNormalize.latexifyPlainMath(stripped)
		return stripped.isEmpty ? text : stripped
	}

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

	/// 子樹裡所有已展開節點的「路徑：內容」，追問時整包餵給模型當脈絡。
	/// 樹很小（幾個節點、各幾行），全送比挑選便宜又不會漏
	func explainedLines(prefix: [String] = []) -> [String] {
		let here = prefix + [title]
		var lines: [String] = []
		// 題目本身的 body 是診斷那一句，已另外以「先前的診斷」送出，不重複
		if let body, kind != .topic {
			lines.append("\(here.joined(separator: " → "))：\(body)")
		}
		for child in children { lines.append(contentsOf: child.explainedLines(prefix: here)) }
		return lines
	}

	/// 找到指定節點（唯讀）
	func find(_ target: UUID) -> Card? {
		if id == target { return self }
		for child in children {
			if let hit = child.find(target) { return hit }
		}
		return nil
	}

	/// 子樹裡被標成某概念知識的節點（含自己）
	func cards(taggedWith concept: String) -> [Card] {
		(noteConcept == concept ? [self] : []) + children.flatMap { $0.cards(taggedWith: concept) }
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
