import XCTest

@testable import LearnLoop

final class ConceptLogicTests: XCTestCase {
	private func topic(_ concept: String, skill: String? = nil, kind: Card.Kind = .topic) -> Card {
		var card = Card(title: "題", kind: kind, concepts: [concept])
		card.stuckSkill = skill
		return card
	}

	func testStuckSkillsGroupsAndSorts() {
		let topics = [
			topic("變數代換法", skill: "換算上下限"),
			topic("變數代換法", skill: "換算上下限"),
			topic("變數代換法", skill: "代值正負"),
		]
		let result = ConceptLogic.stuckSkills(in: topics, for: "變數代換法")
		XCTAssertEqual(result.map(\.skill), ["換算上下限", "代值正負"])
		XCTAssertEqual(result.map(\.count), [2, 1])
	}

	func testStuckSkillsIgnoresOtherConceptsAndEmpty() {
		let topics = [
			topic("變數代換法", skill: "換算上下限"),
			topic("分部積分", skill: "換算上下限"),  // 別的概念
			topic("變數代換法", skill: nil),  // 沒栽
			topic("變數代換法", skill: ""),  // 空字串也是沒栽
		]
		let result = ConceptLogic.stuckSkills(in: topics, for: "變數代換法")
		XCTAssertEqual(result.count, 1)
		XCTAssertEqual(result[0].count, 1)
	}

	/// 題目栽的技巧跟問答理解的破洞是同一欄，統計要合在一起
	func testStuckSkillsMixesTopicAndFreeTrees() {
		let topics = [
			topic("分部積分", skill: "當公式背沒推導", kind: .free),
			topic("分部積分", skill: "當公式背沒推導"),
			topic("分部積分", skill: "選錯 u"),
		]
		let result = ConceptLogic.stuckSkills(in: topics, for: "分部積分")
		XCTAssertEqual(result.map(\.skill), ["當公式背沒推導", "選錯 u"])
		XCTAssertEqual(result[0].count, 2)
	}

	func testAllStuckSkillsDedupsKeepsOrder() {
		let topics = [
			topic("a", skill: "換算上下限"),
			topic("b", skill: "代值正負"),
			topic("c", skill: "換算上下限"),
			topic("d", skill: nil),
		]
		XCTAssertEqual(ConceptLogic.allStuckSkills(in: topics), ["換算上下限", "代值正負"])
	}

	/// 久違但栽最多次的技巧要留在清單裡 —— 純時間截斷會把它擠掉
	func testAllStuckSkillsKeepsOldFrequentSkill() {
		var topics = (0..<45).map { topic("c\($0)", skill: "新技巧\($0)") }
		topics += (0..<5).map { _ in topic("舊", skill: "分部積分選 u") }
		let result = ConceptLogic.allStuckSkills(in: topics)
		XCTAssertTrue(result.contains("分部積分選 u"))
		XCTAssertEqual(result.count, 40)
		XCTAssertEqual(result[0], "分部積分選 u")
	}

	/// 同分時較近的排前面；第二段照時間補、不重複
	func testAllStuckSkillsTiesByRecency() {
		let topics = [
			topic("a", skill: "近"),
			topic("b", skill: "遠"),
			topic("c", skill: "近"),
			topic("d", skill: "遠"),
			topic("e", skill: "只一次"),
		]
		XCTAssertEqual(ConceptLogic.allStuckSkills(in: topics), ["近", "遠", "只一次"])
	}

	func testAllStuckSkillsRespectsLimit() {
		let topics = (0..<10).map { topic("c\($0)", skill: "技巧\($0)") }
		XCTAssertEqual(ConceptLogic.allStuckSkills(in: topics, limit: 5).count, 5)
	}

	/// 問答樹的標籤也要進 prompt 清單（跟 stuckSkills(in:for:) 同一個判準），空的跳過
	func testAllStuckSkillsIncludesFreeTrees() {
		let topics = [
			topic("a", skill: "當公式背沒推導", kind: .free),
			topic("b", skill: "", kind: .free),
			topic("c", skill: "換算上下限"),
		]
		XCTAssertEqual(ConceptLogic.allStuckSkills(in: topics), ["當公式背沒推導", "換算上下限"])
	}

	// MARK: - 合併概念

	private func page(
		what: String = "說明", links: [ConceptLink] = [], examTopics: [ExamTopic] = []
	) -> WikiPage {
		WikiPage(
			what: what, figure: nil, links: links, uses: "", examTopics: examTopics,
			compiledAt: Date(), materialCount: 3, fallbackNote: nil)
	}

	func testMergeRenamesCardsIncludingChildren() {
		var child = Card(title: "問", kind: .custom)
		child.noteConcept = "積分順序交換"
		var tree = Card(title: "題", kind: .topic, children: [child], concepts: ["積分順序交換", "交換積分順序"])
		var topics = [tree]
		var wiki: [String: WikiPage] = [:]
		var chapters: [String: String] = [:]
		var exams: [Exam] = []
		ConceptLogic.merge(
			keep: "交換積分順序", drop: "積分順序交換",
			topics: &topics, wiki: &wiki, chapters: &chapters, exams: &exams)
		XCTAssertEqual(topics[0].concepts, ["交換積分順序"])  // 改名後去重
		XCTAssertEqual(topics[0].children[0].noteConcept, "交換積分順序")
	}

	func testMergeWikiBothSides() {
		let examID = UUID()
		var wiki: [String: WikiPage] = [
			"keep": page(
				links: [ConceptLink(concept: "drop", why: "舊連結")],
				examTopics: [ExamTopic(name: "型A", examples: "", howTo: "", examID: examID)]),
			"drop": page(
				links: [ConceptLink(concept: "keep", why: "自連"), ConceptLink(concept: "別的", why: "帶過來")],
				examTopics: [
					ExamTopic(name: "型A", examples: "", howTo: "", examID: examID),  // 重複，不併
					ExamTopic(name: "型B", examples: "", howTo: "", examID: examID),
				]),
			"別的": page(links: [ConceptLink(concept: "drop", why: "指向 drop")]),
		]
		var topics: [Card] = []
		var chapters: [String: String] = [:]
		var exams: [Exam] = []
		ConceptLogic.merge(
			keep: "keep", drop: "drop",
			topics: &topics, wiki: &wiki, chapters: &chapters, exams: &exams)
		XCTAssertNil(wiki["drop"])
		XCTAssertEqual(wiki["keep"]?.examTopics.map(\.name), ["型A", "型B"])  // (examID, name) 去重
		XCTAssertEqual(wiki["keep"]?.links.map(\.concept), ["別的"])  // 自連被丟掉
		XCTAssertEqual(wiki["別的"]?.links.map(\.concept), ["keep"])  // 指向 drop 的改指 keep
	}

	func testMergeChaptersKeepNotOverwritten() {
		var chapters = ["keep": "積分技巧", "drop": "重積分"]
		var topics: [Card] = []
		var wiki: [String: WikiPage] = [:]
		var exams: [Exam] = []
		ConceptLogic.merge(
			keep: "keep", drop: "drop",
			topics: &topics, wiki: &wiki, chapters: &chapters, exams: &exams)
		XCTAssertEqual(chapters, ["keep": "積分技巧"])
	}

	func testMergeExamConceptsRenameAndDedup() {
		var exams = [
			Exam(name: "期中", date: Date(), scope: ExamScope(concepts: ["drop", "keep"], compiledAt: Date(), fallbackNote: nil)),
			Exam(name: "期末", date: Date(), scope: ExamScope(concepts: ["drop"], compiledAt: Date(), fallbackNote: nil)),
		]
		var topics: [Card] = []
		var wiki: [String: WikiPage] = [:]
		var chapters: [String: String] = [:]
		ConceptLogic.merge(
			keep: "keep", drop: "drop",
			topics: &topics, wiki: &wiki, chapters: &chapters, exams: &exams)
		XCTAssertEqual(exams[0].scope?.concepts, ["keep"])
		XCTAssertEqual(exams[1].scope?.concepts, ["keep"])
	}

	func testMergeNoteTreesCombined() {
		var keepNote = Card(title: "keep", kind: .note, concepts: ["keep"])
		keepNote.children = [Card(title: "問1", kind: .custom)]
		var dropNote = Card(title: "drop", kind: .note, concepts: ["drop"])
		dropNote.children = [Card(title: "問2", kind: .custom)]
		var topics = [keepNote, dropNote]
		var wiki: [String: WikiPage] = [:]
		var chapters: [String: String] = [:]
		var exams: [Exam] = []
		ConceptLogic.merge(
			keep: "keep", drop: "drop",
			topics: &topics, wiki: &wiki, chapters: &chapters, exams: &exams)
		XCTAssertEqual(topics.count, 1)
		XCTAssertEqual(topics[0].children.map(\.title), ["問1", "問2"])
	}

	func testMergeSameNameIsNoop() {
		var topics = [topic("同名", skill: nil)]
		var wiki: [String: WikiPage] = ["同名": page()]
		var chapters = ["同名": "積分技巧"]
		var exams: [Exam] = []
		ConceptLogic.merge(
			keep: "同名", drop: "同名",
			topics: &topics, wiki: &wiki, chapters: &chapters, exams: &exams)
		XCTAssertEqual(topics[0].concepts, ["同名"])
		XCTAssertNotNil(wiki["同名"])
		XCTAssertEqual(chapters["同名"], "積分技巧")
	}
}
