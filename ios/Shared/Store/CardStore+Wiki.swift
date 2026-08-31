import Foundation

// MARK: - 概念的模型整理頁
extension CardStore {
	func loadWiki() {
		guard let data = try? Data(contentsOf: wikiURL),
		      let decoded = try? JSONDecoder().decode([String: WikiPage].self, from: data)
		else { return }
		wiki = decoded
	}

	private func saveWiki() {
		guard let data = try? JSONEncoder().encode(wiki) else { return }
		try? data.write(to: wikiURL, options: .atomic)
	}

	/// 這個概念底下的原始材料，一棵樹一段文字，新到舊。整理頁讀的就是這份。
	/// 只取最近 20 棵 —— 再多 prompt 會長到模型開始漏看，而且舊題的價值本來就低
	func wikiMaterial(for concept: String) -> [String] {
		var blocks: [String] = []
		for tree in topics where tree.concepts.contains(concept) && tree.kind != .note {
			var lines: [String] = []
			if tree.kind == .topic {
				lines.append("【題目】\(tree.problem ?? tree.title)")
				if let situation = tree.situation { lines.append("他當時的狀態：\(situation.label)") }
				if let asked = tree.asked { lines.append("他貼題時說：\(asked)") }
				if let body = tree.body { lines.append("助教第一句：\(body)") }
			} else {
				lines.append("【他問】\(tree.asked ?? tree.problem ?? tree.title)")
				if let body = tree.body { lines.append("助教第一句：\(body)") }
			}
			// 點開過的內容；他自己打的追問另外標出來 —— 那是他腦中疑問的原文
			lines.append(contentsOf: tree.explainedLines().map { "  \($0)" })
			for question in tree.children where question.kind == .custom {
				lines.append("  他追問：\(question.title)")
			}
			blocks.append(lines.joined(separator: "\n"))
		}
		// 在別的樹裡問、被模型歸到這個概念的；以及舊的知識點樹
		for item in taggedNotes(for: concept) {
			blocks.append("【他在「\(item.topic.title)」裡問】\(item.card.title)\n  \(item.card.body ?? "")")
		}
		for question in noteTopic(for: concept)?.children ?? [] {
			blocks.append("【他問】\(question.title)\n  \(question.body ?? "")")
		}
		return Array(blocks.prefix(20))
	}

	/// 自上次整理後多了幾筆材料（沒整理過就是全部）
	func wikiNewCount(for concept: String) -> Int {
		wikiMaterial(for: concept).count - (wiki[concept]?.materialCount ?? 0)
	}

	/// 重寫一個概念的整理頁。有上一版就讓模型修訂，不是每次從零寫
	func compileWiki(for concept: String) async throws {
		let material = wikiMaterial(for: concept)
		let known = allConcepts().map(\.name).filter { $0 != concept }
		let result = try await ai.compileWiki(
			concept: concept, material: material, previous: wiki[concept], knownConcepts: known)
		// links 只留真的存在的概念 —— 模型自創的名字不進資料（地圖畫連線時會指到空節點）
		var seen = Set<String>()
		let links = result.links.filter {
			known.contains($0.concept) && seen.insert($0.concept).inserted
		}
		// 圖：kind 不認得、none、或空 content 都不存；plot 有跑出 PNG 才留檔
		var figure: WikiFigure?
		if let raw = result.figure, let kind = WikiFigure.Kind(rawValue: raw.kind),
			!raw.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
		{
			figure = WikiFigure(kind: kind, content: raw.content, pngID: nil)
			if kind == .plot {
				if let data = result.figureData {
					let id = UUID()
					saveFigure(data, for: id)
					figure?.pngID = id
				} else {
					figure = nil  // 座標圖沒畫出來，code 本身給使用者看沒意義
				}
			}
		}
		// 換掉舊圖檔
		if let oldID = wiki[concept]?.figure?.pngID, oldID != figure?.pngID {
			try? FileManager.default.removeItem(at: figureFileURL(oldID))
		}
		wiki[concept] = WikiPage(
			what: result.what, figure: figure, links: links, uses: result.uses,
			examTopics: wiki[concept]?.examTopics ?? [],
			compiledAt: Date(), materialCount: material.count, fallbackNote: result.fallbackNote)
		saveWiki()
	}
}
