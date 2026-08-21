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

	/// 還沒分章的概念在 UI 上的段名；補分章時模型漏掉的也填這個，不然每次開 app 都重打一次全量呼叫
	static let unassigned = "還沒分章"

	/// 既有的章名（給模型對齊用）
	var knownChapters: [String] {
		Array(Set(chapters.values)).filter { $0 != Self.unassigned }.sorted()
	}

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

	/// 「章」欄上線前累積的概念補分章。app 啟動時跑，30 個一批——一次塞 200 個模型會漏。
	/// 模型回了但漏掉的填「還沒分章」記號，之後不再重問；呼叫失敗的那批留 nil，下次啟動再試
	func backfillChapters() async {
		guard !backfillingChapters else { return }
		backfillingChapters = true
		defer { backfillingChapters = false }
		let missing = allConcepts().map(\.name).filter { chapters[$0] == nil }
		for start in stride(from: 0, to: missing.count, by: 30) {
			let batch = Array(missing[start..<min(start + 30, missing.count)])
			guard let assignments = try? await ai.assignChapters(
				concepts: batch, knownChapters: knownChapters)
			else { return }
			for item in assignments where batch.contains(item.concept) {
				assignChapter(item.chapter, to: [item.concept])
			}
			assignChapter(Self.unassigned, to: batch.filter { chapters[$0] == nil })
		}
	}
}
