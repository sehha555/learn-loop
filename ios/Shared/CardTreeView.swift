import SwiftUI

/// 一題的樹。主 app 和分享浮層用的是同一個畫面，差別只在外面包什麼。
///
/// 視覺上要一眼看出是「樹」而不是「一串對話」，靠三件事：
/// 左邊的層級線、可以收合的箭頭、展開與未展開的強烈對比。
/// 收起來之後整題剩幾行，這才是「回頭看知識點」成立的前提。
struct CardTreeView: View {
	let topicID: UUID
	@ObservedObject var store: CardStore

	@State private var loading: Set<UUID> = []
	@State private var collapsed: Set<UUID> = []
	@State private var errorText: String?

	private var topic: Card? { store.topics.first { $0.id == topicID } }

	var body: some View {
		ScrollView {
			if let topic {
				VStack(alignment: .leading, spacing: 0) {
					header(topic)
						.padding(.bottom, 14)

					ForEach(visibleNodes(of: topic), id: \.card.id) { item in
						node(item.card, depth: item.depth)
					}

					if topic.pendingCount > 0 {
						Text("還有 \(topic.pendingCount) 個沒展開")
							.font(.caption)
							.foregroundStyle(.secondary)
							.padding(.top, 12)
							.padding(.leading, 4)
					}
				}
				.padding()
			}
		}
		.alert("出錯了", isPresented: .constant(errorText != nil)) {
			Button("好") { errorText = nil }
		} message: {
			Text(errorText ?? "")
		}
	}

	// MARK: - 哪些節點看得到

	/// 攤平成一維清單，收起來的節點不往下展開。
	/// SwiftUI 的 View 不能遞迴，層級改用左邊的線和縮排表達。
	private func visibleNodes(of topic: Card) -> [(card: Card, depth: Int)] {
		var out: [(card: Card, depth: Int)] = []
		func walk(_ cards: [Card], _ depth: Int) {
			for card in cards {
				out.append((card, depth))
				if !collapsed.contains(card.id) { walk(card.children, depth + 1) }
			}
		}
		walk(topic.children, 0)
		return out
	}

	// MARK: - 題目本身

	private func header(_ topic: Card) -> some View {
		VStack(alignment: .leading, spacing: 6) {
			Text(topic.title)
				.font(.title3.bold())
			if let body = topic.body {
				Text(body)
					.font(.subheadline)
					.foregroundStyle(.secondary)
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.padding(14)
		.background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
	}

	// MARK: - 一個節點

	private func node(_ card: Card, depth: Int) -> some View {
		HStack(alignment: .top, spacing: 0) {
			// 每一層一條垂直線，讓子節點看起來是掛在上一層底下的
			ForEach(0..<depth, id: \.self) { _ in
				Rectangle()
					.fill(Color.secondary.opacity(0.25))
					.frame(width: 1)
					.padding(.leading, 9)
					.padding(.trailing, 12)
			}

			VStack(alignment: .leading, spacing: 6) {
				title(card)
				if let body = card.body, !collapsed.contains(card.id) {
					Text(body)
						.font(.callout)
						.foregroundStyle(.primary.opacity(0.85))
						.fixedSize(horizontal: false, vertical: true)
						.padding(.leading, 22)
						.padding(.trailing, 4)
				}
			}
		}
		.padding(.vertical, 3)
	}

	private func title(_ card: Card) -> some View {
		Button {
			if card.isExpanded {
				// 展開過的：點一下收起來，再點打開
				if collapsed.contains(card.id) { collapsed.remove(card.id) }
				else { collapsed.insert(card.id) }
			} else {
				Task { await expand(card) }
			}
		} label: {
			HStack(alignment: .firstTextBaseline, spacing: 8) {
				marker(card)
				Text(card.title)
					.font(.subheadline.weight(card.isExpanded ? .semibold : .regular))
					.foregroundStyle(card.isExpanded ? .primary : .secondary)
					.multilineTextAlignment(.leading)
					.fixedSize(horizontal: false, vertical: true)
				Spacer(minLength: 0)
				if loading.contains(card.id) {
					ProgressView().controlSize(.small)
				}
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			.padding(.vertical, 7)
			.padding(.horizontal, 10)
			.background(
				// 沒展開的長得像一顆等著被點的方塊，展開過的退成背景
				card.isExpanded
					? Color.clear
					: Color(.tertiarySystemFill),
				in: RoundedRectangle(cornerRadius: 8)
			)
		}
		.buttonStyle(.plain)
		.disabled(loading.contains(card.id))
	}

	@ViewBuilder
	private func marker(_ card: Card) -> some View {
		if card.isExpanded {
			Image(systemName: collapsed.contains(card.id) ? "chevron.right" : "chevron.down")
				.font(.caption2.weight(.bold))
				.foregroundStyle(Color.accentColor)
				.frame(width: 12)
		} else {
			Image(systemName: "plus")
				.font(.caption2.weight(.bold))
				.foregroundStyle(.secondary)
				.frame(width: 12)
		}
	}

	// MARK: - 展開

	private func expand(_ card: Card) async {
		guard let topic, let (_, path) = store.context(for: card.id) else { return }
		loading.insert(card.id)
		defer { loading.remove(card.id) }
		do {
			let result = try await AIClient(apiKey: store.apiKey).expand(
				topic: topic.title,
				diagnosis: topic.body ?? "",
				path: Array(path.dropFirst()) // 第一個是題目本身，模型已經知道
			)
			store.expand(cardID: card.id, body: result.body, followUps: result.followUps)
		} catch {
			errorText = error.localizedDescription
		}
	}
}
