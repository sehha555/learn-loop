import Foundation

/// 概念統計，所有樹掃一次算完。「什麼算卡」只寫在 `CardStore.conceptStats()` 裡。
///
/// 卡住的證據分兩種，可信度不同所以分開存、UI 也分開寫：
/// - stuck：模型從截圖推的（題目樹 situation == .stuck）
/// - asked：他自己打字問的（.free 樹）—— 會主動問就是卡住了，這是最強的訊號
struct ConceptStats {
	var appearances: [String: Int] = [:]
	var stuck: [String: Int] = [:]
	var asked: [String: Int] = [:]
	/// 概念底下的知識點數：概念頁問的＋題目裡標到它的＋直接問的
	var notes: [String: Int] = [:]
	/// 最後一次卡這個概念（不管哪種證據）
	var lastTrouble: [String: Date] = [:]
	/// 同一題一起出現過幾次
	var cooccur: [String: [String: Int]] = [:]
	/// 名字第一次出現的順序；topics 新到舊所以它就是新到舊
	var byTime: [String] = []

	func trouble(_ name: String) -> Int { (stuck[name] ?? 0) + (asked[name] ?? 0) }

	/// 同一題一起出現過的其他概念，常一起的排前面（同分照筆畫穩定排）
	func related(_ name: String) -> [String] {
		(cooccur[name] ?? [:])
			.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
			.map(\.key)
	}
}

// MARK: - 概念統計
extension CardStore {
	func conceptStats() -> ConceptStats {
		var s = ConceptStats()
		for tree in topics {
			switch tree.kind {
			case .note:
				if let name = tree.concepts.first, tree.concepts.count == 1 {
					s.notes[name, default: 0] += tree.children.count
				}
			case .free:
				for name in tree.concepts {
					if s.appearances[name] == nil && s.asked[name] == nil { s.byTime.append(name) }
					s.asked[name, default: 0] += 1
					s.notes[name, default: 0] += 1
					if s.lastTrouble[name] == nil { s.lastTrouble[name] = tree.createdAt }
				}
			default:
				for name in tree.concepts {
					if s.appearances[name] == nil && s.asked[name] == nil { s.byTime.append(name) }
					s.appearances[name, default: 0] += 1
					if tree.situation == .stuck {
						s.stuck[name, default: 0] += 1
						if s.lastTrouble[name] == nil { s.lastTrouble[name] = tree.createdAt }
					}
					for other in tree.concepts where other != name {
						s.cooccur[name, default: [:]][other, default: 0] += 1
					}
				}
			}
			// 被標到某概念的問答節點（概念自己的知識點樹不算，它的 children 上面已經數過）
			Self.countTagged(tree, skipping: tree.kind == .note ? tree.concepts.first : nil, into: &s.notes)
		}
		return s
	}

	private static func countTagged(_ card: Card, skipping: String?, into notes: inout [String: Int]) {
		if let name = card.noteConcept, name != skipping { notes[name, default: 0] += 1 }
		for child in card.children { countTagged(child, skipping: skipping, into: &notes) }
	}

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
		let byTrouble = stats.byTime.enumerated()
			.filter { stats.trouble($0.element) > 0 }
			.sorted {
				let a = stats.trouble($0.element), b = stats.trouble($1.element)
				return a == b ? $0.offset < $1.offset : a > b
			}
			.prefix(limit * 3 / 5)
			.map(\.element)
		let picked = Set(byTrouble)
		let rest = stats.byTime.filter { !picked.contains($0) }
		return byTrouble + rest.prefix(limit - byTrouble.count)
	}

	/// 用到這個概念的題目（最新在前，topics 本來就這順序）—— 病歷卡的紀錄清單
	func topics(withConcept name: String) -> [Card] {
		problems.filter { $0.concepts.contains(name) }
	}

	/// 概念頁「你卡過的」：技巧 → 栽的題（次數降冪）
	func stuckSkills(for concept: String) -> [ConceptLogic.StuckSkill] {
		ConceptLogic.stuckSkills(in: topics, for: concept)
	}

	/// 全部技巧名（新到舊），判題 prompt 用
	func allStuckSkills() -> [String] {
		ConceptLogic.allStuckSkills(in: topics)
	}

	/// 「卡過」的門檻只在這裡定義 —— 紅字、紅框、紅色次數全問這一個。
	/// 手上已有次數的呼叫端直接餵數字，不用再掃一次
	func isRepeated(trouble: Int) -> Bool {
		trouble >= 2
	}

	func isRepeated(_ name: String) -> Bool {
		isRepeated(trouble: conceptStats().trouble(name))
	}

	/// 跟這個概念在同一題出現過的其他概念，常一起出現的排前面（同分照筆畫穩定排）。
	/// 只連使用者真的碰過的東西，不叫 AI 憑空列
	func relatedConcepts(to name: String) -> [String] {
		conceptStats().related(name)
	}

	/// 總覽頁一列的資料
	struct ConceptItem {
		let name: String
		let appearances: Int
		let stuck: Int
		let asked: Int
		let notes: Int
		let lastTrouble: Date?
		let related: [String]
		var trouble: Int { stuck + asked }
		/// 「該回頭看的」排序：次數 × 放了幾天。最近才卡的記憶最新鮮，反而最不需要回頭；
		/// 三個月前卡 5 次、之後沒再碰的那個才該浮上來
		func reviewScore(now: Date) -> Double {
			let days = max(0, now.timeIntervalSince(lastTrouble ?? now) / 86400)
			return Double(trouble) * (days + 1)
		}
	}

	/// 全部概念，卡過的排最上面，其次常出現的（同分照筆畫穩定排）
	func allConcepts() -> [ConceptItem] {
		let s = conceptStats()
		return s.byTime
			.map { name in
				ConceptItem(
					name: name, appearances: s.appearances[name] ?? 0,
					stuck: s.stuck[name] ?? 0, asked: s.asked[name] ?? 0,
					notes: s.notes[name] ?? 0, lastTrouble: s.lastTrouble[name],
					related: s.related(name))
			}
			.sorted {
				if $0.trouble != $1.trouble { return $0.trouble > $1.trouble }
				if $0.appearances != $1.appearances { return $0.appearances > $1.appearances }
				if $0.notes != $1.notes { return $0.notes > $1.notes }
				return $0.name < $1.name
			}
	}
}
