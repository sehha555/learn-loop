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
}
