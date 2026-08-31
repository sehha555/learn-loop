import Foundation

// MARK: - 合併概念
extension CardStore {
	/// 把 drop 併進 keep：題目標籤、wiki 頁、章、考試涵蓋全部改名。
	/// 長按「併入…」和之後的「整理概念清單」都走這一個入口
	func mergeConcept(keep: String, drop: String) {
		let result = ConceptLogic.merge(
			keep: keep, drop: drop,
			topics: &topics, wiki: &wiki, chapters: &chapters, exams: &exams)
		if let orphan = result.orphanFigureID, orphan != wiki[keep]?.figure?.pngID {
			try? FileManager.default.removeItem(at: figureFileURL(orphan))
		}
		save()
		saveWiki()
		saveChapters()
		saveExams()
	}

	/// 「整理概念清單」：組整份清單（名稱＋章＋前 5 題標題）給模型找同義與太細的。
	/// 只回提案——套不套、套哪幾筆由使用者在確認頁勾
	func lintConcepts() async throws -> [AIClient.ConceptMerge] {
		let summary = allConcepts()
			.map { item in
				let titles = topics(withConcept: item.name).prefix(5)
					.map { $0.problem ?? $0.title }
					.joined(separator: "／")
				let chapter = chapters[item.name].map { "（\($0)）" } ?? ""
				return "\(item.name)\(chapter)：\(titles)"
			}
			.joined(separator: "\n")
		return try await ai.lintConcepts(summary: summary)
	}
}
