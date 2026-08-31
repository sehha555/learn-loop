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

	// MARK: - 合併概念

	struct MergeResult {
		/// 動到幾棵題目樹
		var renamedCards = 0
		/// drop 那頁的 plot 圖檔 id —— 純函式不碰檔案，呼叫端負責刪
		var orphanFigureID: UUID?
	}

	/// 把 drop 併進 keep：題目標籤與 noteConcept 改名、兩棵知識點樹合併、
	/// wiki 頁併入（examTopics 以「考試＋型名」去重、links 去重去自連）、
	/// 全部頁指向 drop 的連結改指 keep、章只填空、考試涵蓋改名去重。
	/// keep == drop 或任一為空 → 什麼都不動
	@discardableResult
	static func merge(
		keep: String, drop: String,
		topics: inout [Card], wiki: inout [String: WikiPage],
		chapters: inout [String: String], exams: inout [Exam]
	) -> MergeResult {
		var result = MergeResult()
		guard keep != drop, !keep.isEmpty, !drop.isEmpty else { return result }

		// 1. 題目樹整棵改名；drop 的知識點樹（note）併進 keep 的那棵，不能留兩棵
		//    （noteTopic(for:) 用 first，第二棵會永遠被蓋住）
		var dropNote: Int?
		var keepNote: Int?
		for index in topics.indices {
			if topics[index].kind == .note {
				if topics[index].concepts == [drop] { dropNote = index }
				if topics[index].concepts == [keep] { keepNote = index }
			}
			if topics[index].renameConcept(drop, to: keep) { result.renamedCards += 1 }
		}
		if let dropIndex = dropNote, let keepIndex = keepNote, dropIndex != keepIndex {
			topics[keepIndex].children.append(contentsOf: topics[dropIndex].children)
			topics.remove(at: dropIndex)
		}

		// 2. wiki：drop 頁併進 keep 頁。兩邊都有時以 keep 的 what／uses／圖為主 ——
		//    keep 是使用者選擇留下的名字，他讀過的句子不動；材料數留 keep 的，
		//    這樣「多了 N 筆」會自己亮起來提醒重整
		if let dropped = wiki[drop] {
			if var kept = wiki[keep] {
				var seenTopics = Set(kept.examTopics.map { "\($0.examID)|\($0.name)" })
				for topic in dropped.examTopics
				where seenTopics.insert("\(topic.examID)|\(topic.name)").inserted {
					kept.examTopics.append(topic)
				}
				var seenLinks = Set(kept.links.map(\.concept))
				for link in dropped.links
				where link.concept != keep && seenLinks.insert(link.concept).inserted {
					kept.links.append(link)
				}
				wiki[keep] = kept
				result.orphanFigureID = dropped.figure?.pngID
			} else {
				var moved = dropped
				moved.links.removeAll { $0.concept == keep }
				wiki[keep] = moved
			}
			wiki[drop] = nil
		}
		// 全部頁：指向 drop 的連結改指 keep，再去重、去自連
		for name in wiki.keys {
			guard var page = wiki[name] else { continue }
			var seen = Set<String>()
			var kept: [ConceptLink] = []
			var changed = false
			for var link in page.links {
				if link.concept == drop {
					link.concept = keep
					changed = true
				}
				if link.concept == name || !seen.insert(link.concept).inserted {
					changed = true
					continue
				}
				kept.append(link)
			}
			if changed {
				page.links = kept
				wiki[name] = page
			}
		}

		// 3. 章：keep 已經有就不覆蓋（同一個概念不能一下在這章一下在那章）
		if chapters[keep] == nil { chapters[keep] = chapters[drop] }
		chapters[drop] = nil

		// 4. 考試涵蓋清單改名去重
		for index in exams.indices {
			guard var scope = exams[index].scope,
				let hit = scope.concepts.firstIndex(of: drop)
			else { continue }
			if scope.concepts.contains(keep) {
				scope.concepts.remove(at: hit)
			} else {
				scope.concepts[hit] = keep
			}
			exams[index].scope = scope
		}
		return result
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
