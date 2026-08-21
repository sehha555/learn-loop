import Foundation

// MARK: - 概念統計
extension CardStore {
	/// 餵給診斷 prompt 的概念名，讓模型重用既有名字
	/// （不然「和角公式」「和角定理」會變兩個節點）。
	///
	/// 兩段式而不是純時間：純時間會把「久違的舊弱點」擠出清單 ——
	/// 三個月前卡了 5 次的概念，中間換科目讀一陣子就掉出前 50，
	/// 回頭再碰時模型重新命名、計數從頭來，紅字永遠不會出現。
	/// 所以卡過的概念佔前 60% 名額（同分最近優先），剩的名額才給最近出現的。
	/// 只送名字不送次數 —— 送次數會讓模型往高頻概念靠，那是不想要的偏誤。
	func conceptNamesForPrompt() -> [String] {
		let limit = 50
		let stats = conceptStats()
		// byTime 的位置就是新舊，enumerated 的 offset 拿來當同分 tie-break
		let byStuck = stats.byTime.enumerated()
			.filter { stats.stuck[$0.element] != nil }
			.sorted {
				let a = stats.stuck[$0.element]!, b = stats.stuck[$1.element]!
				return a == b ? $0.offset < $1.offset : a > b
			}
			.prefix(limit * 3 / 5)
			.map(\.element)
		let picked = Set(byStuck)
		let rest = stats.byTime.filter { !picked.contains($0) }
		return byStuck + rest.prefix(limit - byStuck.count)
	}

	/// 用到這個概念的題目（最新在前，topics 本來就這順序）—— 病歷卡的紀錄清單
	func topics(withConcept name: String) -> [Card] {
		problems.filter { $0.concepts.contains(name) }
	}

	/// 概念統計一次算完。「什麼算卡一次」只寫在這裡（situation == .stuck，
	/// 舊資料 nil 不計入）—— 排序、紅字、prompt 選名全部從這份取，判準改了不會漏。
	/// byTime 是名字第一次出現的順序，topics 新到舊所以它就是新到舊。
	private func conceptStats()
		-> (appearances: [String: Int], stuck: [String: Int], byTime: [String]) {
		var appearances: [String: Int] = [:]
		var stuck: [String: Int] = [:]
		var byTime: [String] = []
		for topic in problems {
			for name in topic.concepts {
				if appearances[name] == nil { byTime.append(name) }
				appearances[name, default: 0] += 1
				if topic.situation == .stuck { stuck[name, default: 0] += 1 }
			}
		}
		return (appearances, stuck, byTime)
	}

	/// 這個概念出現在幾題裡（含筆記、含做對的）
	func appearanceCount(_ name: String) -> Int {
		conceptStats().appearances[name] ?? 0
	}

	/// 這個概念真的卡住幾次
	func stuckCount(_ name: String) -> Int {
		conceptStats().stuck[name] ?? 0
	}

	/// 「卡過」的門檻只在這裡定義 —— 紅字、紅框、紅色次數全問這一個。
	/// 手上已有次數的呼叫端（總覽列、紅字）直接餵數字，不用再查一次
	func isRepeated(stuckCount: Int) -> Bool {
		stuckCount >= 2
	}

	func isRepeated(_ name: String) -> Bool {
		isRepeated(stuckCount: stuckCount(name))
	}

	/// 最後一次卡這個概念是哪天 —— 總覽「該回頭看的」照這個排，越近越前面。
	/// topics 新到舊，所以第一個命中的就是最近的
	func lastStuckDate(_ name: String) -> Date? {
		problems.first { $0.situation == .stuck && $0.concepts.contains(name) }?.createdAt
	}

	/// 跟這個概念在同一題出現過的其他概念，常一起出現的排前面（同分照筆畫穩定排）。
	/// 只連使用者真的卡過的東西，不叫 AI 憑空列——這也是階段 3 graph 的邊
	func relatedConcepts(to name: String) -> [String] {
		var counts: [String: Int] = [:]
		for topic in topics(withConcept: name) {
			for other in topic.concepts where other != name {
				counts[other, default: 0] += 1
			}
		}
		return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
			.map(\.key)
	}

	/// 全部概念：真的卡住的排最上面，其次常出現的（同分照筆畫穩定排）—— 總覽頁用
	/// 這個概念底下的知識點數：概念頁問的＋題目裡標到它的＋直接問的
	func noteCount(for concept: String) -> Int {
		(noteTopic(for: concept)?.children.count ?? 0)
			+ taggedNotes(for: concept).count
			+ freeQuestions(for: concept).count
	}

	/// 概念總覽的資料。只靠直接問累積、還沒出現在任何題目裡的概念也要列出來
	func allConcepts() -> [(name: String, appearances: Int, stuck: Int, notes: Int)] {
		let stats = conceptStats()
		var names = Set(stats.appearances.keys)
		for tree in topics where tree.kind == .free { names.formUnion(tree.concepts) }
		return names
			.map {
				(name: $0, appearances: stats.appearances[$0] ?? 0,
				 stuck: stats.stuck[$0] ?? 0, notes: noteCount(for: $0))
			}
			.sorted {
				if $0.stuck != $1.stuck { return $0.stuck > $1.stuck }
				if $0.appearances != $1.appearances { return $0.appearances > $1.appearances }
				if $0.notes != $1.notes { return $0.notes > $1.notes }
				return $0.name < $1.name
			}
	}
}
