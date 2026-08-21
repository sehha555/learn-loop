import Foundation

// MARK: - 概念分章
extension CardStore {
	func loadChapters() {
		guard let data = try? Data(contentsOf: chaptersURL),
		      let decoded = try? JSONDecoder().decode([String: String].self, from: data)
		else { return }
		chapters = decoded
	}

	private func saveChapters() {
		guard let data = try? JSONEncoder().encode(chapters) else { return }
		try? data.write(to: chaptersURL, options: .atomic)
	}

	/// 既有的章名（給模型對齊用）
	var knownChapters: [String] { Array(Set(chapters.values)).sorted() }

	/// ingest 回來的章：只給還沒分章的概念，已經定了的不改 —— 同一個概念不能一下在這章一下在那章
	func assignChapter(_ chapter: String, to concepts: [String]) {
		let name = chapter.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !name.isEmpty else { return }
		var changed = false
		for concept in concepts where chapters[concept] == nil {
			chapters[concept] = name
			changed = true
		}
		if changed { saveChapters() }
	}

	/// 「章」欄上線前累積的概念一次補分章。app 啟動時跑，一個呼叫
	func backfillChapters() async {
		guard !backfillingChapters else { return }
		backfillingChapters = true
		defer { backfillingChapters = false }
		let missing = allConcepts().map(\.name).filter { chapters[$0] == nil }
		guard !missing.isEmpty,
			let assignments = try? await ai.assignChapters(
				concepts: missing, knownChapters: knownChapters)
		else { return }
		for item in assignments where missing.contains(item.concept) {
			assignChapter(item.chapter, to: [item.concept])
		}
	}
}
