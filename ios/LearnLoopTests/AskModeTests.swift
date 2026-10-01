import XCTest

@testable import LearnLoop

/// 畫布圈完按 [解釋][批改][打字問]：各自換掉第三步的規則，其他入口（.auto）維持原本的不給答案
final class AskModeTests: XCTestCase {
	private func prompt(_ mode: AIClient.AskMode, text: String = "") -> String {
		AIClient.ingestPrompt(
			text: text, hasImage: true, understanding: nil, hintConcept: nil,
			knownConcepts: [], knownChapters: [], knownSkills: [], style: .hint, mode: mode)
	}

	func testAutoKeepsNoAnswerRule() {
		let auto = prompt(.auto)
		XCTAssertTrue(auto.contains("絕對不要直接給答案"))
		XCTAssertTrue(auto.contains("還沒開始算。\n\n第三步，status 和 points，依 is_problem 分兩套"), "接縫不能多空行或少空行")
		XCTAssertTrue(auto.contains("內容是他點下去才生的。\n\n第四步"))
		XCTAssertFalse(auto.contains("半形中括號"))
	}

	func testCanvasModesAllowAnswersInHiddenSteps() {
		for mode in [AIClient.AskMode.explain, .grade, .question] {
			let canvas = prompt(mode)
			XCTAssertFalse(canvas.contains("絕對不要直接給答案"), "\(mode)：步驟先藏著，可以給答案")
			XCTAssertTrue(canvas.contains("半形中括號"), "\(mode)：概念名要標起來，2b 變連結")
			XCTAssertTrue(canvas.contains("一句一行"))
			XCTAssertTrue(canvas.contains("還沒開始算。\n\n第三步"))
			XCTAssertTrue(canvas.contains("\n\n第四步"))
		}
	}

	func testEachModeHasItsOwnStatusRule() {
		XCTAssertTrue(prompt(.explain).contains("按了「解釋」"))
		XCTAssertTrue(prompt(.grade).contains("對照他手寫的過程批改"))
		let question = prompt(.question, text: "這步為什麼要變號")
		XCTAssertTrue(question.contains("按了「打字問」"))
		XCTAssertTrue(question.contains("「這步為什麼要變號」"))
	}
}
