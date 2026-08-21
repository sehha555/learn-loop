import SwiftUI

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
	/// 追問接點：自己打的問題掛在哪個節點下。nil = 題目根部（另起一條線）。
	/// 每次展開完自動指到剛展開的節點，連問就串成一條線
	@State private var attachID: UUID?
	@State private var ownQuestion = ""
	/// 追問附的圖。跟概念頁一樣：只在這一問送模型、存在這張卡的 id 下
	@State private var ownImage: UIImage?
	@State private var errorText: String?
	@State private var showingTranscript = false
	/// 口吻的本地鏡像 —— store 的 teachingStyle 直接寫 UserDefaults、不會觸發重繪
	@State private var style: TeachingStyle = .plain
	@State private var transcriptDraft = ""
	/// 正在改的問題：自己打的節點、或直接問的根（root = true）
	@State private var editing: (cardID: UUID, root: Bool)?
	@State private var editDraft = ""

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
		.sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
			editSheet
		}
		.errorAlert($errorText)
	}

	// MARK: - 哪些節點看得到

	/// 攤平成一維清單，收起來的節點不往下展開。
	/// SwiftUI 的 View 不能遞迴，層級改用左邊的線和縮排表達。
	private func visibleNodes(of topic: Card) -> [(card: Card, depth: Int)] {
		var out: [(card: Card, depth: Int)] = []
		func walk(_ cards: [Card], _ depth: Int) {
			for card in cards {
				out.append((card, depth))
				if !card.collapsed { walk(card.children, depth + 1) }
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
			if let note = topic.fallbackNote {
				fallbackLabel(note)
			}
			if let transcript = topic.transcript {
				transcriptBlock(transcript, topicID: topic.id)
			}
			// 你打字送進來的樹（題目或提問）都能改那句重生；舊的直接問樹只存在 problem 欄
			if let question = topic.asked ?? (topic.kind == .free ? topic.problem : nil) {
				HStack(spacing: 8) {
					Text("你問：\(question)")
						.font(.caption)
						.foregroundStyle(.secondary)
					if running[topic.id] != nil {
						ProgressView().controlSize(.mini)
						Button("取消") { running[topic.id]?.cancel() }
							.font(.caption)
							.buttonStyle(.borderless)
					} else {
						Button("改問題", systemImage: "pencil") {
							editDraft = question
							editing = (topic.id, true)
						}
						.font(.caption)
						.labelStyle(.iconOnly)
						.buttonStyle(.borderless)
					}
				}
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
				if card.kind == .custom, let image = store.image(for: card.id) {
					Image(uiImage: image)
						.resizable()
						.scaledToFit()
						.frame(maxHeight: 120)
						.clipShape(RoundedRectangle(cornerRadius: 6))
						.padding(.leading, 22)
				}
				if let body = card.body, !card.collapsed {
					stepBody(body)
						.padding(.leading, 22)
						.padding(.trailing, 4)
					if let note = card.fallbackNote {
						fallbackLabel(note)
							.padding(.leading, 22)
					}
					if card.kind == .custom, let topic {
						moveToNoteMenu(card, concepts: conceptChoices(for: topic))
							.padding(.leading, 22)
					}
				}
			}
		}
		.padding(.vertical, 3)
	}

	/// 中繼站失敗退回雲端的提示 —— 不再靜默，答案風格不同或沒看到圖時知道是為什麼
	private func fallbackLabel(_ note: String) -> some View {
		Label(note, systemImage: "icloud.and.arrow.down")
			.font(.caption2)
			.foregroundStyle(.orange)
	}

	/// 模型答題時順便判斷這問答是不是概念層的知識；這裡顯示判斷結果，判錯可以改。
	/// 節點不搬，只是概念的知識點頁會同時列出它
	private func moveToNoteMenu(_ card: Card, concepts: [String]) -> some View {
		Menu {
			ForEach(concepts, id: \.self) { name in
				Button("收進「\(name)」知識點") {
					store.setNoteConcept(cardID: card.id, concept: name)
				}
			}
			if card.noteConcept != nil {
				Button("這只關這題，移出知識點", role: .destructive) {
					store.setNoteConcept(cardID: card.id, concept: nil)
				}
			}
		} label: {
			if let concept = card.noteConcept {
				Label("已收進「\(concept)」知識點", systemImage: "book.closed")
					.font(.caption)
			} else {
				Label("只關這題 · 改收進知識點", systemImage: "book.closed")
					.font(.caption)
					.foregroundStyle(.tertiary)
			}
		}
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
				// 展開過的：點一下收起來，再點打開（落地存檔，離開再回來還記得）
				store.toggleCollapsed(cardID: card.id)
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
					// 再點一下就是取消 —— 寫出來，不然沒人知道可以按
					Text("取消")
						.font(.caption)
						.foregroundStyle(.secondary)
					ProgressView().controlSize(.small)
				} else if card.isExpanded {
					// 換接點：下一個問題接在這個節點下，岔出另一條線
					Button {
						attachID = attachID == card.id ? nil : card.id
					} label: {
						Image(systemName: "arrow.turn.down.right")
							.font(.caption.weight(.semibold))
							.foregroundStyle(attachID == card.id ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
							.padding(4)
					}
					.buttonStyle(.plain)
				}
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			.padding(.vertical, 7)
			.padding(.horizontal, 10)
			.contextMenu {
				if card.kind == .custom, running[card.id] == nil {
					Button("改問題重送", systemImage: "pencil") {
						editDraft = card.title
						editing = (card.id, false)
					}
				}
			}
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
			Image(systemName: card.collapsed ? "chevron.right" : "chevron.down")
				.font(.caption2.weight(.bold))
				.foregroundStyle(card.kind.tint)
				.frame(width: 14)
		} else {
			KindMark(kind: card.kind, wide: true)
		}
	}

	// MARK: - 自己加一個點

	private func askOwn(_ topic: Card) -> some View {
		VStack(alignment: .leading, spacing: 6) {
			if let attachID, let target = topic.find(attachID) {
				HStack(spacing: 6) {
					Text("接在：")
						.font(.caption2)
						.foregroundStyle(.secondary)
					Button {
						self.attachID = nil
					} label: {
						HStack(spacing: 4) {
							Text(target.title).lineLimit(1)
							Image(systemName: "xmark")
						}
						.font(.caption2)
						.padding(.horizontal, 8)
						.padding(.vertical, 3)
						.background(Color(.tertiarySystemFill), in: Capsule())
					}
					.buttonStyle(.plain)
				}
			}
			askField(topic)
		}
	}

	private func askField(_ topic: Card) -> some View {
		AskField(
			text: $ownQuestion, image: $ownImage,
			placeholder: topic.kind == .note
				? "問這個概念…" : (attachID == nil ? "我想問別的…" : "接著問…"),
			running: false, onCancel: {}
		) { askOwn(in: topic.id) }
	}

	private func askOwn(in topicID: UUID) {
		let typed = ownQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
		guard ownImage != nil || !typed.isEmpty else { return }
		let imageData = ownImage.flatMap(AIClient.jpeg(from:))
		// 只貼圖沒打字，標題就寫明是在問圖
		let text = typed.isEmpty ? "這張圖在講什麼？" : typed
		guard let id = store.addCustom(topicID: topicID, parentID: attachID, title: text) else { return }
		if let imageData { store.saveImage(imageData, for: id) }
		ownQuestion = ""
		ownImage = nil
		guard let card = store.topics.first(where: { $0.id == topicID })?.find(id) else { return }
		start(expanding: card, imageJPEG: imageData)
	}

	// MARK: - 展開

	private func start(expanding card: Card, imageJPEG: Data? = nil) {
		running[card.id] = Task { await expand(card, imageJPEG: imageJPEG) }
	}

	private func conceptChoices(for topic: Card) -> [String] {
		var names = topic.concepts
		for name in store.conceptNamesForPrompt() where !names.contains(name) {
			names.append(name)
		}
		return names
	}

	// MARK: - 改問題重送

	/// 自己打的問題下得不好可以改再送：自訂節點清掉舊答案重展開；直接問的根整棵重生
	private var editSheet: some View {
		NavigationStack {
			TextEditor(text: $editDraft)
				.font(.body)
				.padding()
				.navigationTitle("改問題")
				.navigationBarTitleDisplayMode(.inline)
				.toolbar {
					ToolbarItem(placement: .cancellationAction) {
						Button("取消") { editing = nil }
					}
					ToolbarItem(placement: .confirmationAction) {
						Button("重送") { resend() }
							.disabled(editDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
					}
				}
		}
		.presentationDetents([.medium])
	}

	private func resend() {
		guard let editing else { return }
		let text = editDraft.trimmingCharacters(in: .whitespacesAndNewlines)
		self.editing = nil
		if editing.root {
			running[editing.cardID] = Task { @MainActor in
				defer { running[editing.cardID] = nil }
				do { try await store.reask(topicID: editing.cardID, text: text) } catch {
					guard !AIClient.isCancellation(error) else { return }
					errorText = error.localizedDescription
				}
			}
		} else {
			store.resetCustom(cardID: editing.cardID, title: text)
			guard let card = topic?.find(editing.cardID) else { return }
			start(expanding: card)
		}
	}

	/// 送給模型的「題目」欄：知識點樹與直接問的樹沒有題目，講清楚它是什麼
	private func topicContext(_ topic: Card) -> String {
		switch topic.kind {
		case .note: "概念「\(topic.title)」的知識問題，不針對特定題目"
		case .free: "他直接問的問題（沒有特定題目）：\(topic.problem ?? topic.title)"
		default: topic.asked.map { "\(topic.title)（他貼題目時說：\($0)）" } ?? topic.title
		}
	}

	/// 標 MainActor 是為了讓 Task 的第一步一定是切回主執行緒 ——
	/// 這個 suspension 保證 start 那行把 Task 存進 running 之後，defer 才有機會清掉它
	@MainActor
	private func expand(_ card: Card, imageJPEG: Data? = nil) async {
		guard let topic, let path = topic.path(to: card.id) else { return }
		defer { running[card.id] = nil }
		do {
			let result = try await store.ai.expand(
				topic: topicContext(topic),
				diagnosis: topic.body ?? "",
				transcript: topic.transcript,
				explained: topic.explainedLines(),
				path: Array(path.dropFirst()), // 第一個是題目本身，模型已經知道
				style: store.teachingStyle,
				wantFollowUps: card.kind != .custom,
				// 自己打的問題才判斷屬於哪個概念；清單是全部既有概念，這題的放前面
				conceptChoices: card.kind == .custom ? conceptChoices(for: topic) : [],
				imageJPEG: imageJPEG
			)
			// 知識點樹裡問的，判回同一個概念就不用再標
			let concept = (topic.kind == .note && result.concept == topic.title) ? nil : result.concept
			store.expand(
				cardID: card.id, body: result.body, followUps: result.followUps,
				noteConcept: concept, fallbackNote: result.fallbackNote)
			// 剛講完的東西就是下一個問題最可能接的地方
			attachID = card.id
		} catch {
			guard !AIClient.isCancellation(error) else { return }
			errorText = error.localizedDescription
		}
	}
}
