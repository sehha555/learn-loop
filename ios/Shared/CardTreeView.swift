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

/// 樹的層級直線。樹頁的縮排線和病歷卡的內容邊線共用這一條，改視覺一處生效。
struct TreeLine: View {
	var body: some View {
		Rectangle()
			.fill(Color.secondary.opacity(0.25))
			.frame(width: 1)
			.padding(.leading, 9)
			.padding(.trailing, 12)
	}
}

/// 每種點的記號與顏色 —— 樹頁和病歷卡共用同一份對照，
/// 一眼看得出這是「疑問」還是「有雷」還是「我自己加的」
extension Card.Kind {
	var mark: String {
		switch self {
		case .step: "▸"
		case .question: "？"
		case .supplement: "＋"
		case .trap: "！"
		case .extend: "↗"
		case .custom: "✎"
		case .topic: "◆"
		}
	}

	var tint: Color {
		switch self {
		case .step: .blue
		case .question: .accentColor
		case .supplement: .teal
		case .trap: .orange
		case .extend: .purple
		case .custom: .pink
		case .topic: .accentColor
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

	/// 進行中的展開請求。存 Task 而不是單純的 id，是為了讓使用者再點一下就取消
	@State private var running: [UUID: Task<Void, Never>] = [:]
	@State private var collapsed: Set<UUID> = []
	@State private var ownQuestion = ""
	@State private var errorText: String?
	@State private var showingTranscript = false
	/// 口吻的本地鏡像 —— store 的 teachingStyle 直接寫 UserDefaults、不會觸發重繪
	@State private var style: TeachingStyle = .plain
	@State private var transcriptDraft = ""

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
		.onAppear { style = store.teachingStyle }
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
		VStack(alignment: .leading, spacing: 6) {
			HStack {
				Text(topic.title)
					.font(.caption)
					.foregroundStyle(.secondary)
				Spacer()
				stylePicker
			}
			if let body = topic.body {
				MathText(text: body, font: .headline, size: 17)
			}
			if let transcript = topic.transcript {
				transcriptBlock(transcript, topicID: topic.id)
			}
			if let recall = recallText(topic.concepts) {
				Text(recall)
					.font(.footnote.weight(.semibold))
					.foregroundStyle(.red)
					.padding(.top, 2)
			}
			if !topic.concepts.isEmpty {
				FlowLayout(spacing: 5) {
					ForEach(topic.concepts, id: \.self) { name in
						// 點概念進病歷卡 —— 值是概念名字串，
						// 外層的 NavigationStack 要掛 conceptDestinations
						NavigationLink(value: name) {
							ConceptChip(name: name, repeated: store.isRepeated(name))
						}
						.buttonStyle(.plain)
					}
				}
				.padding(.top, 4)
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.padding(14)
		.background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
	}

	/// 在問答頁直接換口吻，不用跑去設定頁。只影響之後展開的點，已經生好的不重生
	private var stylePicker: some View {
		Menu {
			Picker("口吻", selection: $style) {
				ForEach(TeachingStyle.allCases, id: \.self) { Text($0.label).tag($0) }
			}
		} label: {
			Label(style.label, systemImage: "text.bubble")
				.font(.caption)
				.labelStyle(.titleAndIcon)
		}
		.onChange(of: style) { _, new in store.teachingStyle = new }
	}

	/// 模型抄下來的圖片內容。預設收著（頁面已經夠長），展開看它抄對沒、錯了就改 ——
	/// 追問全靠這份，抄錯會一路錯
	private func transcriptBlock(_ transcript: String, topicID: UUID) -> some View {
		DisclosureGroup {
			VStack(alignment: .leading, spacing: 4) {
				ForEach(Array(transcript.split(separator: "\n").enumerated()), id: \.offset) {
					_, line in
					MathText(text: String(line), font: .callout, size: 15)
				}
				Button("抄錯了，我改") {
					transcriptDraft = transcript
					showingTranscript = true
				}
				.font(.caption)
				.padding(.top, 4)
			}
			.padding(.top, 6)
		} label: {
			Text("圖片抄錄（追問時模型看的是這份）")
				.font(.caption)
				.foregroundStyle(.secondary)
		}
		.sheet(isPresented: $showingTranscript) {
			NavigationStack {
				TextEditor(text: $transcriptDraft)
					.font(.system(.body, design: .monospaced))
					.padding()
					.navigationTitle("改抄錄")
					.navigationBarTitleDisplayMode(.inline)
					.toolbar {
						ToolbarItem(placement: .cancellationAction) {
							Button("取消") { showingTranscript = false }
						}
						ToolbarItem(placement: .confirmationAction) {
							Button("存") {
								store.updateTranscript(topicID: topicID, text: transcriptDraft)
								showingTranscript = false
							}
						}
					}
			}
		}
	}

	/// 「你之前也卡過」那行紅字。數的是真的卡住的次數（app 算的，模型只給概念名），
	/// 「算不算卡過」的門檻問 store，這裡不自己比大小。
	private func recallText(_ concepts: [String]) -> String? {
		let repeated = concepts.compactMap { name -> String? in
			let count = store.stuckCount(name)
			return store.isRepeated(stuckCount: count) ? "「\(name)」第 \(count) 次卡了" : nil
		}
		guard !repeated.isEmpty else { return nil }
		return repeated.joined(separator: "、")
	}

	// MARK: - 一個節點

	private func node(_ card: Card, depth: Int) -> some View {
		HStack(alignment: .top, spacing: 0) {
			// 每一層一條垂直線，讓子節點看起來是掛在上一層底下的
			ForEach(0..<depth, id: \.self) { _ in
				TreeLine()
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
		// 「完整解法」口吻帶小標／獨立式子／條列記號，那就是講義體，不套步驟編號
		let structured = lines.contains {
			$0.hasPrefix("## ") || $0.hasPrefix("$$") || $0.hasPrefix("- ")
		}
		return VStack(alignment: .leading, spacing: 8) {
			ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
				if structured {
					structuredLine(line)
				} else {
					HStack(alignment: .firstTextBaseline, spacing: 8) {
						Text("\(index + 1)")
							.font(.caption2.weight(.bold))
							.foregroundStyle(.secondary)
							.frame(width: 16, height: 16)
							.background(Color(.tertiarySystemFill), in: Circle())
						MathText(text: line, font: .callout, size: 16)
							.foregroundStyle(.primary.opacity(0.85))
					}
				}
			}
		}
	}

	/// 講義體的一行：## 小標、$$ 獨立式子、- 條列、關鍵是：結尾，其餘是一般句子
	@ViewBuilder
	private func structuredLine(_ line: String) -> some View {
		if line.hasPrefix("## ") {
			MathText(text: String(line.dropFirst(3)), font: .subheadline.weight(.semibold), size: 15)
				.padding(.top, 6)
		} else if line.hasPrefix("$$"), line.hasSuffix("$$"), line.count >= 4 {
			MathText(
				text: "$" + line.dropFirst(2).dropLast(2).trimmingCharacters(in: .whitespaces) + "$",
				font: .callout, size: 18
			)
			.frame(maxWidth: .infinity, alignment: .center)
			.padding(.vertical, 2)
		} else if line.hasPrefix("- ") {
			HStack(alignment: .firstTextBaseline, spacing: 8) {
				Text("•").foregroundStyle(.secondary)
				MathText(text: String(line.dropFirst(2)), font: .callout, size: 16)
			}
			.padding(.leading, 4)
		} else if line.hasPrefix("關鍵是：") || line.hasPrefix("關鍵是:") {
			MathText(text: line, font: .callout.weight(.semibold), size: 16)
				.padding(10)
				.frame(maxWidth: .infinity, alignment: .leading)
				.background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
				.padding(.top, 4)
		} else {
			MathText(text: line, font: .callout, size: 16)
				.foregroundStyle(.primary.opacity(0.85))
		}
	}

	private func title(_ card: Card) -> some View {
		Button {
			if let task = running[card.id] {
				// 轉圈圈時再點一次就是反悔。留著 running 讓 expand 的 defer 自己清，
				// 這裡先清掉的話下一次點會跟還沒結束的舊 Task 搶同一格
				task.cancel()
			} else if card.isExpanded {
				// 展開過的：點一下收起來，再點打開
				if collapsed.contains(card.id) { collapsed.remove(card.id) }
				else { collapsed.insert(card.id) }
			} else {
				start(expanding: card)
			}
		} label: {
			HStack(alignment: .firstTextBaseline, spacing: 8) {
				marker(card)
				MathText(
					text: card.title,
					font: .subheadline.weight(card.isExpanded ? .semibold : .regular),
					size: 15
				)
				.foregroundStyle(card.isExpanded ? .primary : .secondary)
				.multilineTextAlignment(.leading)
				Spacer(minLength: 0)
				if running[card.id] != nil {
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
	}

	@ViewBuilder
	private func marker(_ card: Card) -> some View {
		if card.isExpanded {
			Image(systemName: collapsed.contains(card.id) ? "chevron.right" : "chevron.down")
				.font(.caption2.weight(.bold))
				.foregroundStyle(card.kind.tint)
				.frame(width: 14)
		} else {
			Text(card.kind.mark)
				.font(.caption2.weight(.bold))
				.foregroundStyle(card.kind.tint)
				.frame(width: 14)
		}
	}

	// MARK: - 自己加一個點

	private func askOwn(_ topic: Card) -> some View {
		HStack(spacing: 8) {
			Text(Card.Kind.custom.mark)
				.font(.caption2.weight(.bold))
				.foregroundStyle(Card.Kind.custom.tint)
				.frame(width: 14)
			TextField("我想問別的…", text: $ownQuestion)
				.font(.subheadline)
				.submitLabel(.go)
				.onSubmit { askOwn(in: topic.id) }
			if !ownQuestion.trimmingCharacters(in: .whitespaces).isEmpty {
				Button("問") { askOwn(in: topic.id) }
					.font(.subheadline.weight(.semibold))
					.buttonStyle(.borderless)
			}
		}
		.padding(.vertical, 7)
		.padding(.horizontal, 10)
		.background(Color.pink.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
	}

	private func askOwn(in topicID: UUID) {
		let text = ownQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !text.isEmpty, let id = store.addCustom(topicID: topicID, title: text) else {
			return
		}
		ownQuestion = ""
		guard let card = store.topics.first(where: { $0.id == topicID })?
			.children.first(where: { $0.id == id })
		else { return }
		start(expanding: card)
	}

	// MARK: - 展開

	private func start(expanding card: Card) {
		running[card.id] = Task { await expand(card) }
	}

	/// 標 MainActor 是為了讓 Task 的第一步一定是切回主執行緒 ——
	/// 這個 suspension 保證 start 那行把 Task 存進 running 之後，defer 才有機會清掉它
	@MainActor
	private func expand(_ card: Card) async {
		guard let topic, let (_, path) = store.context(for: card.id) else { return }
		defer { running[card.id] = nil }
		do {
			let result = try await store.ai.expand(
				topic: topic.title,
				diagnosis: topic.body ?? "",
				transcript: topic.transcript,
				explained: topic.explainedLines(),
				path: Array(path.dropFirst()), // 第一個是題目本身，模型已經知道
				style: store.teachingStyle,
				wantFollowUps: card.kind != .custom
			)
			store.expand(cardID: card.id, body: result.body, followUps: result.followUps)
		} catch {
			// 使用者自己按掉的不是出錯，不要跳 alert。
			// URLSession 被中斷時丟的是 URLError.cancelled，不是 CancellationError
			guard !Task.isCancelled, !(error is CancellationError),
				(error as? URLError)?.code != .cancelled
			else { return }
			errorText = error.localizedDescription
		}
	}
}
