import Foundation

/// 用哪隻手寫字。講解、樹欄這類側邊的東西放在反邊，寫字時手掌才不會蓋住
enum Handedness: String, CaseIterable {
	case left, right

	var label: String {
		switch self {
		case .left: "左手"
		case .right: "右手"
		}
	}
}
