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

	@Published internal(set) var topics: [Card] = []
	/// 概念 → 模型整理頁。存 wiki.json，跟 topics.json 分開 —— 它是衍生物，樹才是原始資料
	@Published internal(set) var wiki: [String: WikiPage] = [:]
	/// 概念 → 章。模型在 ingest 時順便判，第一次出現就定下來；概念總覽靠它分層
	@Published internal(set) var chapters: [String: String] = [:]
	/// 正在改問題重生的樹根。放 store 不放 view：樹頁離開再回來也要看得到轉圈圈
	@Published internal(set) var reasking: Set<UUID> = []
	/// 考試：日期、範圍、附檔、整理出的題型。照日期排
	@Published internal(set) var exams: [Exam] = []

	/// 真正的題目（不含概念知識點、直接問的那些樹）。清單、統計、病歷卡的題目紀錄都看這個
	var problems: [Card] { topics.filter { $0.kind != .note && $0.kind != .free } }

	/// 直接問的問題裡歸到這個概念的（新到舊）
	func freeQuestions(for concept: String) -> [Card] {
		topics.filter { $0.kind == .free && $0.concepts.contains(concept) }
	}

	/// 是否真的拿到共享目錄。false 代表現在是免費簽章，主 app 與浮層各存各的。
	let isShared: Bool

	private let fileURL: URL
	let wikiURL: URL
	let chaptersURL: URL
	let examsURL: URL
	let imagesDir: URL
	/// 考試附檔（講義／作業 PDF、圖）
	let materialsDir: URL
	private let defaults: UserDefaults

	init() {
		let shared = FileManager.default.containerURL(
			forSecurityApplicationGroupIdentifier: Self.appGroupID)
		isShared = shared != nil
		let dir = shared ?? FileManager.default.urls(
			for: .documentDirectory, in: .userDomainMask)[0]
		fileURL = dir.appendingPathComponent("topics.json")
		wikiURL = dir.appendingPathComponent("wiki.json")
		chaptersURL = dir.appendingPathComponent("chapters.json")
		examsURL = dir.appendingPathComponent("exams.json")
		imagesDir = dir.appendingPathComponent("images", isDirectory: true)
		materialsDir = dir.appendingPathComponent("materials", isDirectory: true)
		try? FileManager.default.createDirectory(
			at: imagesDir, withIntermediateDirectories: true)
		try? FileManager.default.createDirectory(
			at: materialsDir, withIntermediateDirectories: true)
		defaults = UserDefaults(suiteName: Self.appGroupID) ?? .standard
		load()
		loadWiki()
		loadChapters()
		loadExams()
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
			TeachingStyle.from(stored: defaults.string(forKey: "teachingStyle"))
		}
		set { defaults.set(newValue.rawValue, forKey: "teachingStyle") }
	}

	// MARK: - 讀寫

	func load() {
		guard let data = try? Data(contentsOf: fileURL),
		      let decoded = try? JSONDecoder().decode([Card].self, from: data)
		else { return }
		topics = decoded.map { topic in
			var topic = topic
			if let problem = topic.problem { topic.problem = Card.stripProblemNumber(problem) }
			return topic
		}
	}

	func save() {
		guard let data = try? JSONEncoder().encode(topics) else { return }
		try? data.write(to: fileURL, options: .atomic)
	}

	/// 新的一題插在最前面 —— 最近問的要在最上面，不用捲到底
	func insert(_ topic: Card) {
		topics.insert(topic, at: 0)
		save()
	}

	/// 展開某個節點：填上內容。
	/// noteConcept 是模型判斷「這問答屬於哪個概念的知識」，nil = 就是這題的事
	func expand(
		cardID: UUID, body: String, noteConcept: String? = nil, fallbackNote: String? = nil
	) {
		mutate(cardID) { card in
			card.body = body
			card.noteConcept = noteConcept
			card.fallbackNote = fallbackNote
		}
	}

	/// 找到任一棵樹裡的這個節點、就地改、存檔。四個「改一個節點」的入口共用
	private func mutate(_ cardID: UUID, _ change: (inout Card) -> Void) {
		for index in topics.indices {
			if topics[index].update(id: cardID, change) { break }
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
		mutate(cardID) { $0.collapsed.toggle() }
	}

	// MARK: - 概念知識點

	/// 某個概念的知識點樹（統一入口之前，概念頁問的都掛這裡）。現在只讀不寫、照常顯示舊資料
	func noteTopic(for concept: String) -> Card? {
		topics.first { $0.kind == .note && $0.concepts == [concept] }
	}

	/// 手動改模型的判斷：標成某概念的知識（nil = 取消）
	func setNoteConcept(cardID: UUID, concept: String?) {
		mutate(cardID) { $0.noteConcept = concept }
	}

	/// 被模型歸到這個概念的問答（不管是在題目、直接問、還是別的概念頁問的），附上來源樹。
	/// 這個概念自己的知識點樹不掃 —— 它的 children 本來就列在知識點區
	func taggedNotes(for concept: String) -> [(card: Card, topic: Card)] {
		topics
			.filter { !($0.kind == .note && $0.concepts == [concept]) }
			.flatMap { topic in topic.cards(taggedWith: concept).map { ($0, topic) } }
	}

	/// 改自己打的問題重送：清掉舊答案和它底下長出來的點，呼叫端接著重新展開
	func resetCustom(cardID: UUID, title: String) {
		mutate(cardID) { card in
			card.title = title
			card.body = nil
			card.children = []
			card.noteConcept = nil
			card.fallbackNote = nil
			card.collapsed = false
		}
	}

	/// 使用者改過的抄錄。模型抄錯根號、上下標時，改這裡一次，之後追問全用對的版本
	func updateTranscript(topicID: UUID, text: String) {
		guard let index = topics.firstIndex(where: { $0.id == topicID }) else { return }
		topics[index].transcript = text
		save()
	}

	func delete(topicID: UUID) {
		topics.removeAll { $0.id == topicID }
		try? FileManager.default.removeItem(at: imageFileURL(topicID))
		save()
	}

	/// backfillProblems／backfillChapters 的進行中旗標（stored property 不能放 extension）
	var backfilling = false
	var backfillingChapters = false
}
