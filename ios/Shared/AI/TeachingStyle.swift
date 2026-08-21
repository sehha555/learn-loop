import Foundation

/// 講法只有兩種：給提示讓他自己算，或直接給做法。兩種都分步驟。
/// 之前四種（白話／引導／精簡／講義）混了「多詳細」「給不給答案」「版式」三個軸，選不乾淨，8/21 砍掉
enum TeachingStyle: String, CaseIterable {
	case hint, direct

	/// 舊存檔的值對回來：引導→提示，其他都是直接給
	static func from(stored raw: String?) -> TeachingStyle {
		switch raw {
		case "hint", "guided": .hint
		default: .direct
		}
	}

	var label: String {
		switch self {
		case .hint: "給提示"
		case .direct: "直接給做法"
		}
	}

	/// body 的形狀，兩種一樣：一步一行
	var bodyRule: String {
		"""
		body 拆成 2 到 5 個步驟，一步一行、用換行分開。每行不要自己加編號或符號，
		前面會自動有記號。每步直接對他說「你」，不要前言不要總結。
		"""
	}

	/// 每一步講到什麼程度
	var modeRule: String {
		switch self {
		case .hint:
			"""
			每一步只給提示：講這一步要做什麼、為什麼往這走，不把算式算完、不給結果 ——
			他要的是自己算出來。卡關的那一步可以結尾留一個有明確方向的小問題
			（「代哪兩個 x 值最快解出 A 和 B？」這種，不是「你覺得呢」）。
			"""
		case .direct:
			"""
			每一步直接給做法：這一步做什麼、怎麼算、得到什麼，寫到他照著就能做。不要反問他。
			"""
		}
	}

	/// 直接問（沒有題目）時的開場句與點怎麼出
	var askStatusRule: String {
		switch self {
		case .hint:
			"""
			- status：一句話，直接對他說「你」—— 不給答案，講這個問題的切入點在哪，
			  結尾留一個有明確方向的小問題推他想。
			- points：2 到 4 個可以點開的點，依他該想的順序排列，每個是往下想的一步。
			"""
		case .direct:
			"""
			- status：一到兩句，直接對他說「你」—— 直接回答他問的事，給做法的骨幹
			  （例如「這是多項式乘三角函數，分部積分做兩次，第一次把 $u^2$ 當 f」）。
			  不要複述他的問題、不要只說「你在問的是…」。
			- points：2 到 4 個可以點開的點，依理解順序排列，是骨幹裡每一步的展開
			  （為什麼這樣選、下一步怎麼算、容易錯在哪），不是重講一次骨幹。
			"""
		}
	}
}
