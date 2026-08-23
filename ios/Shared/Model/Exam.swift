import Foundation

/// 一場考試：日期、範圍（章）、附上的講義／作業檔，以及模型從檔案整理出的題型清單。
/// 這是 learn-loop 第一次知道「範圍」——之前它只認識你貼過的題
struct Exam: Identifiable, Codable, Hashable {
	let id: UUID
	var name: String
	var date: Date
	/// 範圍裡的章（章名，對應 chapters.json 的值）
	var chapters: [String]
	var files: [ExamFile]
	/// 模型讀附檔整理出來的題型清單。nil = 還沒整理
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

/// 模型整理出的範圍：會考的題型，每型附講義裡的例題
struct ExamScope: Codable, Hashable {
	var topics: [ScopeTopic]
	var compiledAt: Date
	var fallbackNote: String?
}

struct ScopeTopic: Codable, Hashable {
	/// 題型名，粒度像教科書小節
	var name: String
	/// 屬於哪一章（對齊既有章名）
	var chapter: String
	/// 講義／作業裡這一型的例題，一行一題（LaTeX）
	var examples: String
	/// 這一型的判斷口訣或解法骨幹，一兩句
	var howTo: String

	enum CodingKeys: String, CodingKey {
		case name, chapter, examples
		case howTo = "how_to"
	}
}
