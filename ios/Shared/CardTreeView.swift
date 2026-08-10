import SwiftUI

/// 一題的樹。主 app 和分享浮層用的是同一個畫面，差別只在外面包什麼。
struct CardTreeView: View {
	let topicID: UUID
	@ObservedObject var store: CardStore

	@State private var loading: Set<UUID> = []
	@State private var errorText: String?

	private var topic: Card? { store.topics.first { $0.id == topicID } }

	var body: some View {
		ScrollView {
			if let topic {
				VStack(alignment: .leading, spacing: 12) {
					header(topic)
					ForEach(topic.children.flatMap { $0.flattened() }, id: \.card.id) { item in
						node(item.card, depth: item.depth)
					}
					if topic.pendingCount > 0 {
						Text("還有 \(topic.pendingCount) 個沒展開")
							.font(.caption)
							.foregroundStyle(.secondary)
							.padding(.top, 4)
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

	// MARK: - 題目本身

	private func header(_ topic: Card) -> some View {
		VStack(alignment: .leading, spacing: 6) {
			Text(topic.title)
				.font(.title3.bold())
			if let body = topic.body {
				Text(body).font(.body)
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.padding()
		.background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
	}

	// MARK: - 一個節點（遞迴）

	private func node(_ card: Card, depth: Int) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			Button {
				if !card.isExpanded { Task { await expand(card) } }
			} label: {
				HStack(alignment: .top, spacing: 8) {
					// 空心圈 = 還沒展開，實心 = 展開過
					Image(systemName: card.isExpanded ? "circle.fill" : "circle")
						.font(.caption2)
						.foregroundStyle(card.isExpanded ? Color.accentColor : .secondary)
						.padding(.top, 5)
					Text(card.title)
						.font(.subheadline.weight(card.isExpanded ? .semibold : .regular))
						.multilineTextAlignment(.leading)
					Spacer(minLength: 0)
					if loading.contains(card.id) { ProgressView().controlSize(.small) }
				}
				.frame(maxWidth: .infinity, alignment: .leading)
				.padding(10)
				.background(
					card.isExpanded ? Color(.secondarySystemBackground) : Color(.tertiarySystemFill),
					in: RoundedRectangle(cornerRadius: 10)
				)
			}
			.buttonStyle(.plain)
			.disabled(card.isExpanded || loading.contains(card.id))

			if let body = card.body {
				Text(body)
					.font(.callout)
					.foregroundStyle(.primary)
					.padding(.horizontal, 10)
			}
		}
		.padding(.leading, CGFloat(depth) * 16)
	}

	// MARK: - 展開

	private func expand(_ card: Card) async {
		guard let topic, let (_, path) = store.context(for: card.id) else { return }
		loading.insert(card.id)
		defer { loading.remove(card.id) }
		do {
			let result = try await ClaudeClient(apiKey: store.apiKey).expand(
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
