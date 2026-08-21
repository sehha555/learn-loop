import Foundation

/// 一個概念的「模型整理頁」—— 讀這個概念底下所有原始材料（題目樹、問答樹、你問過的）寫成的
/// 固定三塊。原始材料永遠留著，這頁只是上面多一層整理；按一下才重寫，不自動跑。
struct WikiPage: Codable {
	/// 這概念是什麼 —— 用他自己問過的例子講
	var what: String
	/// 重點：這招怎麼用、步驟骨幹、該記的式子，一行一條。舊存檔沒有這欄所以 optional
	var keyPoints: String?
	/// 他實際卡過的地方，一行一條，具體到哪一步
	var stuck: String
	/// 材料裡露出來、但他還沒追問到的洞，一行一條
	var gaps: String
	var compiledAt: Date
	/// 整理當時讀了幾筆材料。之後材料變多，概念頁就能標「多了 N 筆」
	var materialCount: Int
	var fallbackNote: String?
}
