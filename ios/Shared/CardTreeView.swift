import SwiftUI

/// 概念 chips 用的極簡換行排版 —— 放不下就折到下一行
struct FlowLayout: Layout {
	var spacing: CGFloat = 6

	func sizeThatFits(
		proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
	) -> CGSize {
		let width = proposal.width ?? .infinity
		var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
		for view in subviews {
			let size = view.sizeThatFits(.unspecified)
			if x + size.width > width, x > 0 {
				x = 0
				y += rowHeight + spacing
				rowHeight = 0
			}
			x += size.width + spacing
			rowHeight = max(rowHeight, size.height)
		}
		return CGSize(width: proposal.width ?? x, height: y + rowHeight)
	}

	func placeSubviews(
		in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
	) {
		var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
		for view in subviews {
			let size = view.sizeThatFits(.unspecified)
			if x + size.width > bounds.maxX, x > bounds.minX {
				x = bounds.minX
				y += rowHeight + spacing
				rowHeight = 0
			}
			view.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
			x += size.width + spacing
			rowHeight = max(rowHeight, size.height)
		}
	}
}

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
	@State private var ownQuestion = ""
	@State private var errorText: String?

	private var topic: Card? { store.topics.first { $0.id == topicID } }

	var body: some View {
		ScrollView {
			if let topic {
				VStack(alignment: .leading, spacing: 0) {
					header(topic)
						.padding(.bottom, 14)

					if topic.children.contains(where: { $0.kind == .step }) {
						Text("解題步驟")
							.font(.caption2)
							.foregroundStyle(.tertiary)
							.padding(.leading, 4)
							.padding(.bottom, 4)
					}

					ForEach(visibleNodes(of: topic), id: \.card.id) { item in
						node(item.card, depth: item.depth)
					}

					askOwn(topic)
						.padding(.top, 8)

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

	/// 層級刻意反過來：診斷那一句話才是主角（最大字），標題退成小字只做識別。
	private func header(_ topic: Card) -> some View {
		// 每個概念的次數算一次，紅字和 chips 共用同一份
		let counts = topic.concepts.reduce(into: [String: Int]()) {
			$0[$1] = store.conceptCount($1)
		}
		return VStack(alignment: .leading, spacing: 6) {
			Text(topic.title)
				.font(.caption)
				.foregroundStyle(.secondary)
			if let body = topic.body {
				Text(body)
					.font(.headline)
					.fixedSize(horizontal: false, vertical: true)
			}
			if let recall = recallText(topic.concepts, counts: counts) {
				Text(recall)
					.font(.footnote.weight(.semibold))
					.foregroundStyle(.red)
					.padding(.top, 2)
			}
			if !topic.concepts.isEmpty {
				FlowLayout(spacing: 5) {
					ForEach(topic.concepts, id: \.self) { name in
						chip(name, repeated: counts[name, default: 0] >= 2)
					}
				}
				.padding(.top, 4)
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.padding(14)
		.background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
	}

	/// 「你之前也卡過」那行紅字。次數是 app 數出來的，模型只負責給概念名。
	private func recallText(_ concepts: [String], counts: [String: Int]) -> String? {
		let repeated = concepts.compactMap { name -> String? in
			let count = counts[name, default: 0]
			return count >= 2 ? "「\(name)」第 \(count) 次卡了" : nil
		}
		guard !repeated.isEmpty else { return nil }
		return repeated.joined(separator: "、")
	}

	private func chip(_ name: String, repeated: Bool) -> some View {
		Text(name)
			.font(.caption2)
			.foregroundStyle(repeated ? Color.red : Color.secondary)
			.padding(.horizontal, 8)
			.padding(.vertical, 2)
			.overlay(
				Capsule().strokeBorder(
					repeated ? Color.red.opacity(0.5) : Color.secondary.opacity(0.35))
			)
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
					stepBody(body)
						.padding(.leading, 22)
						.padding(.trailing, 4)
				}
			}
		}
		.padding(.vertical, 3)
	}

	/// 把 body 用換行切開，一行變一個帶編號的步驟 —— 讀起來像思緒一步步展開，
	/// 不是塞成一整段。
	private func stepBody(_ text: String) -> some View {
		let lines =
			text
			.split(separator: "\n", omittingEmptySubsequences: true)
			.map { $0.trimmingCharacters(in: .whitespaces) }
			.filter { !$0.isEmpty }
		return VStack(alignment: .leading, spacing: 8) {
			ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
				HStack(alignment: .firstTextBaseline, spacing: 8) {
					Text("\(index + 1)")
						.font(.caption2.weight(.bold))
						.foregroundStyle(.secondary)
						.frame(width: 16, height: 16)
						.background(Color(.tertiarySystemFill), in: Circle())
					Text(line)
						.font(.callout)
						.foregroundStyle(.primary.opacity(0.85))
						.fixedSize(horizontal: false, vertical: true)
				}
			}
		}
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
				.foregroundStyle(Self.tint(card.kind))
				.frame(width: 14)
		} else {
			Text(Self.mark(card.kind))
				.font(.caption2.weight(.bold))
				.foregroundStyle(Self.tint(card.kind))
				.frame(width: 14)
		}
	}

	/// 四種點各有記號，一眼看得出這是「疑問」還是「有雷」還是「我自己加的」
	private static func mark(_ kind: Card.Kind) -> String {
		switch kind {
		case .step: "▸"
		case .question: "？"
		case .supplement: "＋"
		case .trap: "！"
		case .extend: "↗"
		case .custom: "✎"
		case .topic: "◆"
		}
	}

	private static func tint(_ kind: Card.Kind) -> Color {
		switch kind {
		case .step: .blue
		case .question: .accentColor
		case .supplement: .teal
		case .trap: .orange
		case .extend: .purple
		case .custom: .pink
		case .topic: .accentColor
		}
	}

	// MARK: - 自己加一個點

	private func askOwn(_ topic: Card) -> some View {
		HStack(spacing: 8) {
			Text("✎").font(.caption2.weight(.bold)).foregroundStyle(.pink).frame(width: 14)
			TextField("我想問別的…", text: $ownQuestion)
				.font(.subheadline)
				.submitLabel(.go)
				.onSubmit { Task { await askOwn(in: topic.id) } }
			if !ownQuestion.trimmingCharacters(in: .whitespaces).isEmpty {
				Button("問") { Task { await askOwn(in: topic.id) } }
					.font(.subheadline.weight(.semibold))
					.buttonStyle(.borderless)
			}
		}
		.padding(.vertical, 7)
		.padding(.horizontal, 10)
		.background(Color.pink.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
	}

	private func askOwn(in topicID: UUID) async {
		let text = ownQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !text.isEmpty, let id = store.addCustom(topicID: topicID, title: text) else {
			return
		}
		ownQuestion = ""
		guard let card = store.topics.first(where: { $0.id == topicID })?
			.children.first(where: { $0.id == id })
		else { return }
		await expand(card)
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
				path: Array(path.dropFirst()), // 第一個是題目本身，模型已經知道
				style: store.teachingStyle
			)
			store.expand(cardID: card.id, body: result.body, followUps: result.followUps)
		} catch {
			errorText = error.localizedDescription
		}
	}
}
