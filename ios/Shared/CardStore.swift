import Foundation

/// 樹的儲存。主 app 和分享浮層要看到同一份資料，所以放在 App Group 的共享目錄。
///
/// 免費 Apple ID 簽章拿不到 App Group（那是付費開發者帳號的權限），
/// 這時會退回各自的沙盒 —— 浮層裡問的東西主 app 看不到。
/// 功能不會壞，只是樹不共用；付費之後自動接起來。
@MainActor
final class CardStore: ObservableObject {
	static let appGroupID = "group.com.sehha555.learnloop"

	@Published private(set) var topics: [Card] = []

	/// 是否真的拿到共享目錄。false 代表現在是免費簽章，主 app 與浮層各存各的。
	let isShared: Bool

	private let fileURL: URL
	private let defaults: UserDefaults

	init() {
		let shared = FileManager.default.containerURL(
			forSecurityApplicationGroupIdentifier: Self.appGroupID)
		isShared = shared != nil
		let dir = shared ?? FileManager.default.urls(
			for: .documentDirectory, in: .userDomainMask)[0]
		fileURL = dir.appendingPathComponent("topics.json")
		defaults = UserDefaults(suiteName: Self.appGroupID) ?? .standard
		load()
	}

	// MARK: - API key

	var apiKey: String {
		get { defaults.string(forKey: "anthropicAPIKey") ?? "" }
		set { defaults.set(newValue, forKey: "anthropicAPIKey") }
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

	/// 展開某個節點：填上內容，並把模型延伸出來的新問題掛成子節點
	func expand(cardID: UUID, body: String, followUps: [AIClient.Point]) {
		for index in topics.indices {
			let hit = topics[index].update(id: cardID) { card in
				card.body = body
				card.children.append(
					contentsOf: followUps.map { Card(title: $0.title, kind: $0.kind) })
			}
			if hit { break }
		}
		save()
	}

	/// 使用者自己加的點。AI 沒猜到的那些，正好告訴我們猜得準不準。
	/// 回傳新節點的 id，讓呼叫端接著展開它。
	func addCustom(topicID: UUID, title: String) -> UUID? {
		guard let index = topics.firstIndex(where: { $0.id == topicID }) else { return nil }
		let card = Card(title: title, kind: .custom)
		topics[index].children.append(card)
		save()
		return card.id
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
		save()
	}
}
