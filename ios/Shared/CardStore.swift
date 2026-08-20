import Foundation
import UIKit

/// 樹的儲存。主 app 和分享浮層要看到同一份資料，所以放在 App Group 的共享目錄。
///
/// 免費 Apple ID 簽章拿不到 App Group（那是付費開發者帳號的權限），
/// 這時會退回各自的沙盒 —— 浮層裡問的東西主 app 看不到。
/// 功能不會壞，只是樹不共用；付費之後自動接起來。
@MainActor
final class CardStore: ObservableObject {
	static let appGroupID = "group.com.sehha555.learnloop"

	@Published private(set) var topics: [Card] = []

	/// 真正的題目（不含概念知識點那種樹）。清單、統計、病歷卡的題目紀錄都看這個
	var problems: [Card] { topics.filter { $0.kind != .note } }

	/// 是否真的拿到共享目錄。false 代表現在是免費簽章，主 app 與浮層各存各的。
	let isShared: Bool

	private let fileURL: URL
	private let imagesDir: URL
	private let defaults: UserDefaults

	init() {
		let shared = FileManager.default.containerURL(
			forSecurityApplicationGroupIdentifier: Self.appGroupID)
		isShared = shared != nil
		let dir = shared ?? FileManager.default.urls(
			for: .documentDirectory, in: .userDomainMask)[0]
		fileURL = dir.appendingPathComponent("topics.json")
		imagesDir = dir.appendingPathComponent("images", isDirectory: true)
		try? FileManager.default.createDirectory(
			at: imagesDir, withIntermediateDirectories: true)
		defaults = UserDefaults(suiteName: Self.appGroupID) ?? .standard
		load()
	}

	// MARK: - API key

	var apiKey: String {
		get { defaults.string(forKey: "anthropicAPIKey") ?? "" }
		set { defaults.set(newValue, forKey: "anthropicAPIKey") }
	}

	/// Mac 中繼站位址（走 Claude Code 訂閱，不吃 API）。空字串＝沒在用
	var relayAddress: String {
		get { defaults.string(forKey: "relayAddress") ?? "" }
		set { defaults.set(newValue, forKey: "relayAddress") }
	}

	/// 設定頁填的是「機器名」或「機器名:port」，這裡補上 scheme 和預設 port
	var relayURL: URL? {
		let raw = relayAddress.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !raw.isEmpty else { return nil }
		var components = URLComponents(string: raw.contains("://") ? raw : "http://\(raw)")
		if components?.port == nil { components?.port = 8787 }
		return components?.url
	}

	/// 有任一條路能打模型（key 或中繼站）就能開始分析
	var hasProvider: Bool { !apiKey.isEmpty || relayURL != nil }

	/// 打模型一律從這拿 client，中繼站設定才不會漏帶
	var ai: AIClient { AIClient(apiKey: apiKey, relay: relayURL) }

	/// 教學口吻，設定頁切換
	var teachingStyle: TeachingStyle {
		get {
			defaults.string(forKey: "teachingStyle")
				.flatMap(TeachingStyle.init(rawValue:)) ?? .plain
		}
		set { defaults.set(newValue.rawValue, forKey: "teachingStyle") }
	}

	// MARK: - 讀寫

	func load() {
		guard let data = try? Data(contentsOf: fileURL),
		      let decoded = try? JSONDecoder().decode([Card].self, from: data)
		else { return }
		topics = decoded
	}

	private func save() {
		guard let data = try? JSONEncoder().encode(topics) else { return }
		try? data.write(to: fileURL, options: .atomic)
	}

	/// 新的一題插在最前面 —— 最近問的要在最上面，不用捲到底
	func insert(_ topic: Card) {
		topics.insert(topic, at: 0)
		save()
	}

	/// 展開某個節點：填上內容，並把模型延伸出來的新問題掛成子節點；
	/// noteConcept 是模型判斷「這問答屬於哪個概念的知識」，nil = 就是這題的事
	func expand(
		cardID: UUID, body: String, followUps: [AIClient.Point], noteConcept: String? = nil
	) {
		for index in topics.indices {
			let hit = topics[index].update(id: cardID) { card in
				card.body = body
				card.noteConcept = noteConcept
				card.children.append(
					contentsOf: followUps.map { Card(title: $0.title, kind: $0.kind) })
			}
			if hit { break }
		}
		save()
	}

	/// 使用者自己加的點。AI 沒猜到的那些，正好告訴我們猜得準不準。
	/// parentID 是接點：接在某個節點下就串成一條線（CoT），nil 接在題目根部＝另起一條。
	/// 回傳新節點的 id，讓呼叫端接著展開它。
	func addCustom(topicID: UUID, parentID: UUID?, title: String) -> UUID? {
		guard let index = topics.firstIndex(where: { $0.id == topicID }) else { return nil }
		let card = Card(title: title, kind: .custom)
		let hit = topics[index].update(id: parentID ?? topicID) { parent in
			parent.children.append(card)
			// 接點收著的話新問題會被藏起來，順手打開
			parent.collapsed = false
		}
		guard hit else { return nil }
		save()
		return card.id
	}

	/// 收合／展開一個節點，落地存檔
	func toggleCollapsed(cardID: UUID) {
		for index in topics.indices {
			if topics[index].update(id: cardID, { $0.collapsed.toggle() }) { break }
		}
		save()
	}

	// MARK: - 概念知識點

	/// 某個概念的知識點樹（不針對題目的問答）。沒有就是還沒問過
	func noteTopic(for concept: String) -> Card? {
		topics.first { $0.kind == .note && $0.concepts == [concept] }
	}

	/// 拿到（必要時建立）概念的知識點樹。一個概念一棵，掛在 topics 裡跟題目同一套樹機制，
	/// 但 kind 是 note，清單與統計都會略過它
	func ensureNoteTopic(for concept: String) -> UUID {
		if let existing = noteTopic(for: concept) { return existing.id }
		let note = Card(title: concept, kind: .note, concepts: [concept])
		topics.append(note)  // 放最後面，不擠掉題目的時間序
		save()
		return note.id
	}

	/// 手動改模型的判斷：標成某概念的知識（nil = 取消）
	func setNoteConcept(cardID: UUID, concept: String?) {
		for index in topics.indices {
			if topics[index].update(id: cardID, { $0.noteConcept = concept }) { break }
		}
		save()
	}

	/// 題目樹裡被標成這個概念知識的問答，附上來源題目 —— 知識點頁連同概念頁自己問的一起列
	func taggedNotes(for concept: String) -> [(card: Card, topic: Card)] {
		problems.flatMap { topic in topic.cards(taggedWith: concept).map { ($0, topic) } }
	}

	/// 使用者改過的抄錄。模型抄錯根號、上下標時，改這裡一次，之後追問全用對的版本
	func updateTranscript(topicID: UUID, text: String) {
		guard let index = topics.firstIndex(where: { $0.id == topicID }) else { return }
		topics[index].transcript = text
		save()
	}

	/// 找出某個節點所在的題目與路徑，追問時當脈絡送給模型
	func context(for cardID: UUID) -> (topic: Card, path: [String])? {
		for topic in topics {
			if let path = topic.path(to: cardID) { return (topic, path) }
		}
		return nil
	}

	func delete(topicID: UUID) {
		topics.removeAll { $0.id == topicID }
		try? FileManager.default.removeItem(at: imageFileURL(topicID))
		save()
	}

	/// 餵給診斷 prompt 的概念名，讓模型重用既有名字
	/// （不然「和角公式」「和角定理」會變兩個節點）。
	///
	/// 兩段式而不是純時間：純時間會把「久違的舊弱點」擠出清單 ——
	/// 三個月前卡了 5 次的概念，中間換科目讀一陣子就掉出前 50，
	/// 回頭再碰時模型重新命名、計數從頭來，紅字永遠不會出現。
	/// 所以卡過的概念佔前 60% 名額（同分最近優先），剩的名額才給最近出現的。
	/// 只送名字不送次數 —— 送次數會讓模型往高頻概念靠，那是不想要的偏誤。
	func conceptNamesForPrompt(limit: Int) -> [String] {
		let stats = conceptStats()
		// byTime 的位置就是新舊，enumerated 的 offset 拿來當同分 tie-break
		let byStuck = stats.byTime.enumerated()
			.filter { stats.stuck[$0.element] != nil }
			.sorted {
				let a = stats.stuck[$0.element]!, b = stats.stuck[$1.element]!
				return a == b ? $0.offset < $1.offset : a > b
			}
			.prefix(limit * 3 / 5)
			.map(\.element)
		let picked = Set(byStuck)
		let rest = stats.byTime.filter { !picked.contains($0) }
		return byStuck + rest.prefix(limit - byStuck.count)
	}

	/// 用到這個概念的題目（最新在前，topics 本來就這順序）—— 病歷卡的紀錄清單
	func topics(withConcept name: String) -> [Card] {
		problems.filter { $0.concepts.contains(name) }
	}

	/// 概念統計一次算完。「什麼算卡一次」只寫在這裡（situation == .stuck，
	/// 舊資料 nil 不計入）—— 排序、紅字、prompt 選名全部從這份取，判準改了不會漏。
	/// byTime 是名字第一次出現的順序，topics 新到舊所以它就是新到舊。
	private func conceptStats()
		-> (appearances: [String: Int], stuck: [String: Int], byTime: [String]) {
		var appearances: [String: Int] = [:]
		var stuck: [String: Int] = [:]
		var byTime: [String] = []
		for topic in problems {
			for name in topic.concepts {
				if appearances[name] == nil { byTime.append(name) }
				appearances[name, default: 0] += 1
				if topic.situation == .stuck { stuck[name, default: 0] += 1 }
			}
		}
		return (appearances, stuck, byTime)
	}

	/// 這個概念出現在幾題裡（含筆記、含做對的）
	func appearanceCount(_ name: String) -> Int {
		conceptStats().appearances[name] ?? 0
	}

	/// 這個概念真的卡住幾次
	func stuckCount(_ name: String) -> Int {
		conceptStats().stuck[name] ?? 0
	}

	/// 「卡過」的門檻只在這裡定義 —— 紅字、紅框、紅色次數全問這一個。
	/// 手上已有次數的呼叫端（總覽列、紅字）直接餵數字，不用再查一次
	func isRepeated(stuckCount: Int) -> Bool {
		stuckCount >= 2
	}

	func isRepeated(_ name: String) -> Bool {
		isRepeated(stuckCount: stuckCount(name))
	}

	/// 最後一次卡這個概念是哪天 —— 總覽「該回頭看的」照這個排，越近越前面。
	/// topics 新到舊，所以第一個命中的就是最近的
	func lastStuckDate(_ name: String) -> Date? {
		problems.first { $0.situation == .stuck && $0.concepts.contains(name) }?.createdAt
	}

	/// 跟這個概念在同一題出現過的其他概念，常一起出現的排前面（同分照筆畫穩定排）。
	/// 只連使用者真的卡過的東西，不叫 AI 憑空列——這也是階段 3 graph 的邊
	func relatedConcepts(to name: String) -> [String] {
		var counts: [String: Int] = [:]
		for topic in topics(withConcept: name) {
			for other in topic.concepts where other != name {
				counts[other, default: 0] += 1
			}
		}
		return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
			.map(\.key)
	}

	/// 全部概念：真的卡住的排最上面，其次常出現的（同分照筆畫穩定排）—— 總覽頁用
	func allConcepts() -> [(name: String, appearances: Int, stuck: Int)] {
		let stats = conceptStats()
		return stats.appearances
			.map { (name: $0.key, appearances: $0.value, stuck: stats.stuck[$0.key] ?? 0) }
			.sorted {
				if $0.stuck != $1.stuck { return $0.stuck > $1.stuck }
				if $0.appearances != $1.appearances { return $0.appearances > $1.appearances }
				return $0.name < $1.name
			}
	}

	// MARK: - 題目截圖

	private func imageFileURL(_ topicID: UUID) -> URL {
		imagesDir.appendingPathComponent("\(topicID.uuidString).jpg")
	}

	/// 題目原始截圖。nil 代表這題是存圖功能上線前貼的，沒圖可看
	func image(for topicID: UUID) -> UIImage? {
		UIImage(contentsOfFile: imageFileURL(topicID).path)
	}

	/// 貼上 / 分享進來的完整流程：概念清單 → 診斷 → 組題目 → 存檔，回傳新題 id。
	/// 主 app 和分享浮層共用這一份，免得改流程時漏掉其中一邊。
	func analyze(image: UIImage) async throws -> UUID {
		// JPEG 只編碼一次，上傳和存檔共用同一份
		guard let imageData = AIClient.jpeg(from: image) else { throw AIError.badImage }
		let result = try await ai
			.diagnose(imageJPEG: imageData, knownConcepts: conceptNamesForPrompt(limit: 50))
		let topic = Card(
			title: result.title,
			body: result.status,
			kind: .topic,
			children: result.points.map { Card(title: $0.title, kind: $0.kind) },
			concepts: result.concepts,
			situation: result.parsedSituation,
			transcript: result.transcript,
			problem: result.problem.isEmpty ? nil : result.problem
		)
		insert(topic)
		// 原始截圖留檔 —— 病歷卡要能看到「題目長什麼樣」
		try? imageData.write(to: imageFileURL(topic.id), options: .atomic)
		return topic.id
	}
}
