import Foundation

/// 一場考試：日期、範圍（章）、附上的講義／作業檔，以及模型整理出這場涵蓋哪些概念。
/// 這是 learn-loop 第一次知道「範圍」——之前它只認識你貼過的題
struct Exam: Identifiable, Codable, Hashable {
	let id: UUID
	var name: String
	var date: Date
	/// 範圍裡的章（章名，對應 chapters.json 的值）
	var chapters: [String]
	var files: [ExamFile]
	/// 模型讀附檔整理出來的範圍。nil = 還沒整理
	var scope: ExamScope?

	init(id: UUID = UUID(), name: String, date: Date, chapters: [String] = [], files: [ExamFile] = [], scope: ExamScope? = nil) {
		self.id = id
		self.name = name
		self.date = date
		self.chapters = chapters
		self.files = files
		self.scope = scope
	}

	/// 距離考試幾天（今天＝0，過了是負數）
	var daysLeft: Int {
		let calendar = Calendar.current
		return calendar.dateComponents([.day], from: calendar.startOfDay(for: Date()), to: calendar.startOfDay(for: date)).day ?? 0
	}
}

/// 附在考試底下的檔案（PDF 或圖），實體存在 materials/<examID>/<id>.<ext>
struct ExamFile: Identifiable, Codable, Hashable {
	let id: UUID
	var name: String
	/// 副檔名（pdf / jpg / png）
	var ext: String
	var addedAt: Date

	init(id: UUID = UUID(), name: String, ext: String, addedAt: Date = Date()) {
		self.id = id
		self.name = name
		self.ext = ext
		self.addedAt = addedAt
	}

	var isPDF: Bool { ext.lowercased() == "pdf" }
}

/// 模型整理出的範圍：這場考試涵蓋哪些概念。
/// 題型的內容（例題、口訣）寫在各概念頁的「會怎麼考」（wiki），考試底下只記涵蓋清單
struct ExamScope: Codable, Hashable {
	var concepts: [String]
	var compiledAt: Date
	var fallbackNote: String?
}

/// 手寫 decode 放 extension（保住合成的 memberwise init）：
/// 舊存檔是題型版（topics），沒有 concepts —— 缺的給空陣列、舊欄位忽略，
/// 不然整份 exams.json 解不出來、所有考試消失
extension ExamScope {
	init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		concepts = try c.decodeIfPresent([String].self, forKey: .concepts) ?? []
		compiledAt = try c.decodeIfPresent(Date.self, forKey: .compiledAt) ?? Date()
		fallbackNote = try c.decodeIfPresent(String.self, forKey: .fallbackNote)
	}
}

/// 整理範圍時模型回的一型（wire 型別，不再存進 exams.json）：
/// 內容進概念頁的 examTopics，concepts 記這型對到誰
struct ScopeTopic: Codable, Hashable {
	/// 題型名，粒度像教科書小節
	var name: String
	/// 屬於哪一章（對齊既有章名）
	var chapter: String
	/// 講義／作業裡這一型的例題，一行一題（LaTeX）
	var examples: String
	/// 這一型的判斷口訣或解法骨幹，一兩句
	var howTo: String
	/// 這一型用到的概念名（1–2 個）
	var concepts: [String]

	enum CodingKeys: String, CodingKey {
		case name, chapter, examples, concepts
		case howTo = "how_to"
	}
}

/// 中繼站那條字串解析的路漏了 concepts 也不讓整場整理白跑 —— 缺的當空、後面用章名擋著
extension ScopeTopic {
	init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		name = try c.decode(String.self, forKey: .name)
		chapter = try c.decodeIfPresent(String.self, forKey: .chapter) ?? ""
		examples = try c.decodeIfPresent(String.self, forKey: .examples) ?? ""
		howTo = try c.decodeIfPresent(String.self, forKey: .howTo) ?? ""
		concepts = try c.decodeIfPresent([String].self, forKey: .concepts) ?? []
	}
}
