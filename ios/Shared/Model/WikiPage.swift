import Foundation

/// 概念頁第 2 塊的一條連結：連到哪個概念、一句為什麼連
struct ConceptLink: Codable, Hashable {
	var concept: String
	var why: String
}

/// 概念頁第 4 塊的一筆：這個概念在某場考試會怎麼考（「整理範圍」寫進來的）
struct ExamTopic: Codable, Hashable {
	var name: String
	/// 講義／作業裡這一型的例題，一行一題（LaTeX）
	var examples: String
	/// 判斷口訣或解法骨幹
	var howTo: String
	/// 哪場考試整理出來的。重跑同一場先清掉這個 id 的舊項
	var examID: UUID
}

/// 第 1 塊「是什麼」配的小圖。kind 決定 content 是什麼、view 怎麼畫
struct WikiFigure: Codable, Hashable {
	enum Kind: String, Codable {
		case diff   // 變換前後對照：兩行 $$，只標變的部分
		case plot   // 座標圖：matplotlib code，中繼站跑成 PNG（pngID）
		case tree   // 步驟樹：縮排純文字
		case table  // 對照表：「｜」分欄
	}
	var kind: Kind
	var content: String
	/// plot 跑成功存下的圖檔 id（走 figureFileURL 同一套）。nil = 沒圖
	var pngID: UUID?
}

/// 一個概念的「模型整理頁」＝概念頁五塊裡模型寫的那幾塊（1 是什麼、2 相連、3 哪裡用、4 會怎麼考）。
/// 原始材料永遠留著，這頁只是上面多一層整理；按一下才重寫，不自動跑。
/// 第 5 塊「你卡過的」不在這裡 —— 程式從 Card.stuckSkill 即時統計
struct WikiPage: Codable {
	/// 1 是什麼 —— 最多兩句
	var what: String
	/// 1 的配圖
	var figure: WikiFigure?
	/// 2 相連的概念
	var links: [ConceptLink]
	/// 3 哪裡用得上。空字串 = 材料裡還看不出來
	var uses: String
	/// 4 會怎麼考 —— 整理考試範圍時寫進來；compileWiki 不動這塊
	var examTopics: [ExamTopic]
	var compiledAt: Date
	/// 整理當時讀了幾筆材料。之後材料變多，概念頁就能標「多了 N 筆」
	var materialCount: Int
	var fallbackNote: String?
}

/// 手寫 decode 放 extension（保住合成的 memberwise init）：
/// 舊存檔是四塊版（what／keyPoints／stuck／gaps），缺的新欄位全部給預設 ——
/// 不然整份 wiki.json 解不出來、所有整理頁消失。舊的 keyPoints 等欄位被自然忽略
extension WikiPage {
	init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		what = try c.decodeIfPresent(String.self, forKey: .what) ?? ""
		figure = try c.decodeIfPresent(WikiFigure.self, forKey: .figure)
		links = try c.decodeIfPresent([ConceptLink].self, forKey: .links) ?? []
		uses = try c.decodeIfPresent(String.self, forKey: .uses) ?? ""
		examTopics = try c.decodeIfPresent([ExamTopic].self, forKey: .examTopics) ?? []
		compiledAt = try c.decodeIfPresent(Date.self, forKey: .compiledAt) ?? Date()
		materialCount = try c.decodeIfPresent(Int.self, forKey: .materialCount) ?? 0
		fallbackNote = try c.decodeIfPresent(String.self, forKey: .fallbackNote)
	}
}
