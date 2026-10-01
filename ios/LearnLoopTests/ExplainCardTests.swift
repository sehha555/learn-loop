import XCTest

@testable import LearnLoop

/// 講解卡片：一句一行、步驟一打開先亮幾步、[名詞] 去括號但數學式和區間不碰
final class ExplainCardTests: XCTestCase {
	func testSentencesSkipBlankLines() {
		XCTAssertEqual(ExplainCard.sentences("第一句。\n\n  第二句。 \n"), ["第一句。", "第二句。"])
	}

	func testInitiallyShownFollowsStuckStep() {
		XCTAssertEqual(ExplainCard.initiallyShown(stuckStep: nil, count: 4), 0, "舊卡、看不出來：全藏")
		XCTAssertEqual(ExplainCard.initiallyShown(stuckStep: 1, count: 4), 0, "第一步就卡：全藏")
		XCTAssertEqual(ExplainCard.initiallyShown(stuckStep: 3, count: 4), 2, "前兩步做對了先亮")
		XCTAssertEqual(ExplainCard.initiallyShown(stuckStep: 0, count: 4), 4, "全對：全部攤開")
		XCTAssertEqual(ExplainCard.initiallyShown(stuckStep: 9, count: 4), 4, "模型給超過也不爆")
	}

	func testConceptMarkup() {
		XCTAssertEqual(ConceptMarkup.plain("導通時處在 [順向偏壓]，壓降 0.7 V。"), "導通時處在 順向偏壓，壓降 0.7 V。")
		let segments = ConceptMarkup.segments("用 [KVL] 和 [歐姆定律]")
		XCTAssertEqual(segments.filter(\.isConcept).map(\.text), ["KVL", "歐姆定律"])
		XCTAssertEqual(ConceptMarkup.plain("算 $\\sqrt[3]{x}$ 在 [0, 1] 上"), "算 $\\sqrt[3]{x}$ 在 [0, 1] 上")
		XCTAssertEqual(ConceptMarkup.plain("沒有標記的句子"), "沒有標記的句子")
		XCTAssertEqual(ConceptMarkup.plain("落單的 [ 括號"), "落單的 [ 括號")
	}
}
