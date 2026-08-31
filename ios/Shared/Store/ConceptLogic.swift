import Foundation

/// 概念層的純邏輯 —— 只吃值、回值，不碰 store、檔案、UIKit。
/// 拆出來是為了能在不建 CardStore（會讀寫沙盒、@MainActor）的情況下單元測試
enum ConceptLogic {
	/// 概念頁「你卡過的」一列：一個技巧、栽在哪幾題
	struct StuckSkill: Identifiable {
		let skill: String
		let cards: [Card]
		var count: Int { cards.count }
		var id: String { skill }
	}

	/// 某概念底下，按技巧統計栽過的題。次數多的在前，同分照筆畫穩定排
	static func stuckSkills(in topics: [Card], for concept: String) -> [StuckSkill] {
		var groups: [String: [Card]] = [:]
		for tree in topics where tree.kind == .topic && tree.concepts.contains(concept) {
			guard let skill = tree.stuckSkill, !skill.isEmpty else { continue }
			groups[skill, default: []].append(tree)
		}
		return groups
			.map { StuckSkill(skill: $0.key, cards: $0.value) }
			.sorted { $0.count == $1.count ? $0.skill < $1.skill : $0.count > $1.count }
	}

	/// 全部出現過的技巧名（去重、新到舊），餵給判題 prompt 對齊命名
	static func allStuckSkills(in topics: [Card], limit: Int = 40) -> [String] {
		var seen = Set<String>()
		var names: [String] = []
		for tree in topics {
			guard let skill = tree.stuckSkill, !skill.isEmpty, seen.insert(skill).inserted else { continue }
			names.append(skill)
			if names.count >= limit { break }
		}
		return names
	}
}
