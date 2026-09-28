import XCTest

@testable import LearnLoop

/// 慣用手決定側欄放哪邊：右撇子放左、左撇子放右，改慣用手就跟著換
@MainActor
final class HandednessTests: XCTestCase {
	func testPanelFollowsHandedness() throws {
		let suite = "HandednessTests-\(UUID().uuidString)"
		let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
		defer { defaults.removePersistentDomain(forName: suite) }
		let store = CardStore(defaults: defaults)

		XCTAssertNil(store.handedness, "沒問過 → 要跳問卷")
		store.handedness = .right
		XCTAssertTrue(store.canvasPanelOnLeft, "右撇子：側欄放左邊")
		store.handedness = .left
		XCTAssertFalse(store.canvasPanelOnLeft, "左撇子：側欄放右邊")
		XCTAssertEqual(CardStore(defaults: defaults).handedness, .left, "重開還記得")
	}
}
