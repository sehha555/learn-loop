import XCTest

@testable import LearnLoop

/// 慣用手決定側欄放哪邊；手動換過邊照舊，改慣用手就重新跟著它
@MainActor
final class HandednessTests: XCTestCase {
	func testPanelFollowsHandednessUntilMovedByHand() throws {
		let suite = "HandednessTests-\(UUID().uuidString)"
		let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
		defer { defaults.removePersistentDomain(forName: suite) }
		let store = CardStore(defaults: defaults)

		XCTAssertNil(store.handedness, "沒問過 → 要跳問卷")
		store.handedness = .right
		XCTAssertTrue(store.canvasPanelOnLeft, "右撇子：側欄放左邊")
		store.handedness = .left
		XCTAssertFalse(store.canvasPanelOnLeft, "左撇子：側欄放右邊")

		store.canvasPanelOnLeft = true
		XCTAssertTrue(store.canvasPanelOnLeft, "手動換過邊就照手動的")
		store.handedness = .right
		store.handedness = .left
		XCTAssertFalse(store.canvasPanelOnLeft, "改了慣用手，重新跟著它")
	}
}
