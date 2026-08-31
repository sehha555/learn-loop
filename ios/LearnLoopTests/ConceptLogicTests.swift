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
			topic("變數代換法", skill: "換算上下限", kind: .note),  // 不是題目樹
		]
		let result = ConceptLogic.stuckSkills(in: topics, for: "變數代換法")
		XCTAssertEqual(result.count, 1)
		XCTAssertEqual(result[0].count, 1)
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
}
