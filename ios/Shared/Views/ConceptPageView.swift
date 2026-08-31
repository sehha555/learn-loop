import SwiftUI

/// 主 app 和分享浮層的 NavigationStack 都要認得這兩種頁：
/// UUID → 題目的樹、概念名（String）→ 病歷卡。
/// 收在一處，新增路由才不會漏掉浮層那邊。
/// 注意：導覽全由 path 驅動 —— 混用舊式 NavigationLink(destination:) 會讓
/// 新頁被插到它下面，看起來像「點了沒反應，要按返回才會出現」。
extension View {
	/// open：概念頁裡問完要跳進新樹，交給擁有 NavigationPath 的那層；nil = 該頁不提供問
	func conceptDestinations(store: CardStore, open: ((UUID) -> Void)? = nil) -> some View {
		navigationDestination(for: UUID.self) { id in
			CardTreeView(topicID: id, store: store)
				.navigationTitle(store.topics.first { $0.id == id }?.title ?? "")
				.navigationBarTitleDisplayMode(.inline)
		}
		.navigationDestination(for: String.self) { name in
			ConceptPageView(name: name, store: store, open: open)
		}
	}
}

/// 一個概念的病歷卡，五塊：1 是什麼、2 相連的概念、3 哪裡用得上、4 會怎麼考、5 你卡過的。
/// 1–4 是模型整理的（按了才寫），5 是程式從判題紀錄即時統計的。
/// 原始材料（題目樹、問答樹）收在最下面的「原始材料」裡，永遠留著
struct ConceptPageView: View {
	let name: String
	@ObservedObject var store: CardStore
	/// 問完跳進新樹。nil（分享浮層）就不顯示問的那格
	var open: ((UUID) -> Void)?

	/// 整理頁進行中的請求。存 Task 是為了讓「取消」真的能中斷
	@State private var compiling: Task<Void, Never>?
	/// 收起來的區塊。點標題切換；只記這一次開頁
	@State private var foldedBlocks: Set<String> = []
	/// 原始材料（題目樹／問答）攤開了沒
	@State private var showRaw = false
	@State private var errorText: String?

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 20) {
				header
				wikiSection
				stuckSection
				practiceButton
				rawSection
				if let open {
					AskBar(store: store, placeholder: "問這個概念…", hintConcept: name, open: open)
				}
			}
			.padding()
		}
		.errorAlert($errorText)
		.navigationTitle(name)
		.navigationBarTitleDisplayMode(.inline)
	}

	// MARK: - 各區塊

	/// 概念名已經在導覽列上，這裡只放次數。
	/// 卡過時把證據攤開 ——「截圖看起來卡 2 次」跟「自己問了 2 次」可信度不同，不混成一個數字
	@ViewBuilder
	private var header: some View {
		let stats = store.conceptStats()
		let appearances = stats.appearances[name] ?? 0
		let stuck = stats.stuck[name] ?? 0
		let asked = stats.asked[name] ?? 0
		if store.isRepeated(trouble: stuck + asked) {
			Text("\(Self.troubleLabel(stuck: stuck, asked: asked)) · 出現在 \(appearances) 題裡")
				.font(.footnote.weight(.semibold))
				.foregroundStyle(.red)
		} else {
			Text("出現在 \(appearances) 題裡")
				.font(.footnote)
				.foregroundStyle(.secondary)
		}
	}

	/// 「卡過 2 次 · 問過 3 次」—— 哪邊是 0 就不寫
	static func troubleLabel(stuck: Int, asked: Int) -> String {
		var parts: [String] = []
		if stuck > 0 { parts.append("卡過 \(stuck) 次") }
		if asked > 0 { parts.append("問過 \(asked) 次") }
		return parts.joined(separator: " · ")
	}

	// MARK: - 模型整理頁（1–4 塊）

	/// 整理過沒 —— 考試「整理範圍」會先塞只有第 4 塊的頁，所以不能只看 nil
	private var compiledOnce: Bool {
		store.wiki[name]?.what.isEmpty == false
	}

	@ViewBuilder
	private var wikiSection: some View {
		let page = store.wiki[name]
		let newCount = store.wikiNewCount(for: name)
		VStack(alignment: .leading, spacing: 12) {
			HStack {
				Text("整理")
					.font(.caption2)
					.foregroundStyle(.tertiary)
				Spacer()
				if compiling != nil {
					ProgressView().controlSize(.small)
					Button("取消") { compiling?.cancel() }
						.font(.caption)
						.buttonStyle(.borderless)
				} else if !compiledOnce {
					Button("整理這個概念（\(newCount) 筆材料）", systemImage: "wand.and.stars") { compile() }
						.font(.caption.weight(.semibold))
						.buttonStyle(.borderless)
						.disabled(newCount == 0)
				} else if newCount > 0 {
					Button("重新整理（多了 \(newCount) 筆）", systemImage: "arrow.clockwise") { compile() }
						.font(.caption.weight(.semibold))
						.buttonStyle(.borderless)
				} else {
					Button("重新整理", systemImage: "arrow.clockwise") { compile() }
						.font(.caption)
						.buttonStyle(.borderless)
						.foregroundStyle(.secondary)
				}
			}
			block("1 · 是什麼") {
				if let page, compiledOnce {
					MathText(text: page.what, font: .callout, size: 15)
						.foregroundStyle(.primary.opacity(0.9))
					figureView(page.figure)
				} else if compiling != nil {
					caption("正在讀這個概念下的材料，寫說明…")
				} else if newCount == 0 && page == nil {
					caption("還沒有材料。貼一題或問一個問題，歸到這個概念後就能整理。")
				} else {
					caption("還沒整理。按右上的「整理」讓模型讀材料來寫。")
				}
			}
			block("2 · 相連的概念") {
				linksContent(page?.links ?? [])
			}
			block("3 · 哪裡用得上") {
				if let page, compiledOnce, !page.uses.isEmpty {
					MathText(text: page.uses, font: .callout, size: 15)
						.foregroundStyle(.primary.opacity(0.9))
				} else if compiledOnce {
					caption("材料裡還看不出來——之後貼了別科用到它的題目會補在這。")
				} else {
					caption("整理後會出現。")
				}
			}
			block("4 · 會怎麼考") {
				if let page, !page.examTopics.isEmpty {
					examContent(page.examTopics)
				} else {
					caption("整理考試範圍後會出現（考試分頁 → 附講義 → 整理範圍）。")
				}
			}
			if let note = page?.fallbackNote {
				Label(note, systemImage: "icloud.and.arrow.down")
					.font(.caption2)
					.foregroundStyle(.orange)
			}
			if let page, compiledOnce {
				Text("整理於 \(page.compiledAt.formatted(date: .abbreviated, time: .shortened)) · 讀了 \(page.materialCount) 筆材料")
					.font(.caption2)
					.foregroundStyle(.tertiary)
			}
		}
		.padding(12)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
	}

	private func caption(_ text: String) -> some View {
		Text(text)
			.font(.caption)
			.foregroundStyle(.secondary)
	}

	/// 可收合的區塊：標題一律照五塊編號。內容自由
	private func block<Content: View>(
		_ title: String, @ViewBuilder content: () -> Content
	) -> some View {
		let folded = foldedBlocks.contains(title)
		return VStack(alignment: .leading, spacing: 6) {
			Button {
				if folded { foldedBlocks.remove(title) } else { foldedBlocks.insert(title) }
			} label: {
				HStack(spacing: 4) {
					Image(systemName: folded ? "chevron.right" : "chevron.down")
						.font(.caption2.weight(.semibold))
					Text(title)
						.font(.caption.weight(.semibold))
				}
				.foregroundStyle(.secondary)
				.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			if !folded {
				content()
			}
		}
	}

	/// 第 1 塊的配圖：diff 走數學排版、plot 是中繼站畫好的 PNG、tree／table 用等寬字
	@ViewBuilder
	private func figureView(_ figure: WikiFigure?) -> some View {
		if let figure {
			switch figure.kind {
			case .diff:
				structuredBody(figure.content)
			case .plot:
				if let id = figure.pngID, let image = store.figure(for: id) {
					Image(uiImage: image)
						.resizable()
						.scaledToFit()
						.frame(maxWidth: min(image.size.width, 360), alignment: .leading)
						.clipShape(RoundedRectangle(cornerRadius: 6))
				}
			case .tree, .table:
				Text(figure.content)
					.font(.system(.footnote, design: .monospaced))
					.foregroundStyle(.primary.opacity(0.9))
			}
		}
	}

	/// 第 2 塊：整理過就列模型寫的連結（膠囊＋一句為什麼連）；
	/// 還沒整理先退回「同一題一起出現過的」共現統計，至少有東西可逛
	@ViewBuilder
	private func linksContent(_ links: [ConceptLink]) -> some View {
		if links.isEmpty {
			let related = store.relatedConcepts(to: name)
			if related.isEmpty {
				caption("整理後會列出相連的概念、為什麼連。")
			} else {
				caption("還沒整理——先列同一題一起出現過的：")
				FlowLayout(spacing: 5) {
					ForEach(related, id: \.self) { other in
						NavigationLink(value: other) {
							ConceptChip(name: other, repeated: store.isRepeated(other))
						}
						.buttonStyle(.plain)
					}
				}
			}
		} else {
			ForEach(links, id: \.concept) { link in
				HStack(alignment: .firstTextBaseline, spacing: 8) {
					NavigationLink(value: link.concept) {
						ConceptChip(name: link.concept, repeated: store.isRepeated(link.concept))
					}
					.buttonStyle(.plain)
					Text(link.why)
						.font(.caption)
						.foregroundStyle(.secondary)
						.fixedSize(horizontal: false, vertical: true)
				}
			}
		}
	}

	/// 第 4 塊：每個題型一小段 —— 型名、口訣、例題
	private func examContent(_ topics: [ExamTopic]) -> some View {
		VStack(alignment: .leading, spacing: 10) {
			ForEach(Array(topics.enumerated()), id: \.offset) { _, topic in
				VStack(alignment: .leading, spacing: 3) {
					Text(topic.name)
						.font(.subheadline.weight(.semibold))
					MathText(text: topic.howTo, font: .callout, size: 14)
						.foregroundStyle(.secondary)
					ForEach(
						Array(topic.examples.components(separatedBy: "\n").filter { !$0.isEmpty }.enumerated()),
						id: \.offset
					) { _, line in
						HStack(alignment: .firstTextBaseline, spacing: 5) {
							Text("•").font(.caption).foregroundStyle(.tertiary)
							MathText(text: line, font: .callout, size: 14)
						}
					}
				}
			}
		}
	}

	// MARK: - 第 5 塊：你卡過的（程式統計，不用整理）

	@ViewBuilder
	private var stuckSection: some View {
		let skills = store.stuckSkills(for: name)
		VStack(alignment: .leading, spacing: 8) {
			Text("5 · 你卡過的")
				.font(.caption.weight(.semibold))
				.foregroundStyle(.secondary)
			if skills.isEmpty {
				caption("還沒有紀錄——判題看出你在哪一步栽了，會按技巧記在這。")
			} else {
				ForEach(skills) { skill in
					DisclosureGroup {
						ForEach(skill.cards) { card in
							NavigationLink(value: card.id) {
								HStack(alignment: .firstTextBaseline, spacing: 6) {
									MathText(text: card.problem ?? card.title, font: .footnote, size: 13)
										.lineLimit(2)
										.multilineTextAlignment(.leading)
									Spacer(minLength: 6)
									Image(systemName: "chevron.right")
										.font(.caption2.weight(.semibold))
										.foregroundStyle(.tertiary)
								}
								.contentShape(Rectangle())
							}
							.buttonStyle(.plain)
							.padding(.top, 4)
						}
					} label: {
						HStack {
							Text(skill.skill)
								.font(.subheadline.weight(.semibold))
								.foregroundStyle(.red)
							Spacer()
							Text("×\(skill.count)")
								.font(.subheadline.weight(.bold))
								.foregroundStyle(.red)
						}
					}
					.tint(.secondary)
					.padding(10)
					.background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
				}
			}
		}
		.padding(12)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
	}

	// MARK: - 動作與原始材料

	/// 出題循環是下一輪的事，先把入口立在該在的位置
	private var practiceButton: some View {
		Button {
		} label: {
			Label("出一題練這個概念（快好了）", systemImage: "pencil.and.outline")
				.font(.subheadline.weight(.semibold))
				.frame(maxWidth: .infinity)
				.padding(.vertical, 10)
		}
		.buttonStyle(.bordered)
		.disabled(true)
	}

	/// 題目樹、問答樹 —— 思考鏈的原文，永遠留著；預設收起來，概念頁主角是上面五塊
	@ViewBuilder
	private var rawSection: some View {
		let problems = store.topics(withConcept: name)
		let questionCount = (store.noteTopic(for: name)?.children.count ?? 0)
			+ store.taggedNotes(for: name).count + store.freeQuestions(for: name).count
		VStack(alignment: .leading, spacing: 12) {
			Button {
				withAnimation { showRaw.toggle() }
			} label: {
				HStack(spacing: 4) {
					Image(systemName: showRaw ? "chevron.down" : "chevron.right")
						.font(.caption.weight(.semibold))
					Text("原始材料（\(problems.count) 題 · \(questionCount) 問）")
						.font(.subheadline.weight(.semibold))
				}
				.foregroundStyle(.secondary)
				.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			if showRaw {
				problemsSection
				notesSection
				questionsSection
			}
		}
	}

	private func compile() {
		guard compiling == nil else { return }
		guard store.hasProvider else {
			errorText = AIError.noAPIKey.localizedDescription
			return
		}
		compiling = Task { @MainActor in
			defer { compiling = nil }
			do {
				try await store.compileWiki(for: name)
			} catch {
				guard !AIClient.isCancellation(error) else { return }
				errorText = error.localizedDescription
			}
		}
	}

	/// 知識點：不針對題目、直接問這個概念的問答。這裡問的記在這裡；
	/// 題目頁裡「不只關那題」的問題也能搬過來。追問走同一套樹頁
	@ViewBuilder
	private var notesSection: some View {
		let note = store.noteTopic(for: name)
		let tagged = store.taggedNotes(for: name)
		VStack(alignment: .leading, spacing: 10) {
			Text("問過的（不只關某一題的問答）")
				.font(.caption2)
				.foregroundStyle(.tertiary)
			if let note {
				ForEach(note.children) { question in
					noteCard(question, source: nil)
				}
			}
			// 題目頁裡問的、模型判斷屬於這個概念的 —— 點來源可以跳回那棵樹
			ForEach(tagged, id: \.card.id) { item in
				noteCard(item.card, source: item.topic)
			}
			// 直接問的（沒貼題目），整棵樹就是一個知識點
			ForEach(store.freeQuestions(for: name)) { tree in
				NavigationLink(value: tree.id) {
					VStack(alignment: .leading, spacing: 4) {
						HStack(alignment: .firstTextBaseline, spacing: 6) {
							KindMark(kind: .free)
							MathText(text: tree.problem ?? tree.title, font: .subheadline.weight(.semibold), size: 15)
								.multilineTextAlignment(.leading)
						}
						if let body = tree.body {
							structuredBody(body)
								.padding(.leading, 16)
						}
						Text("問的 · \(tree.children.count) 個點")
							.font(.caption2)
							.foregroundStyle(.tertiary)
							.padding(.leading, 16)
					}
					.padding(10)
					.frame(maxWidth: .infinity, alignment: .leading)
					.background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
				}
				.buttonStyle(.plain)
			}
			if let note {
				NavigationLink(value: note.id) {
					Label("打開知識點樹（可以接著追問）", systemImage: "arrow.turn.down.right")
						.font(.caption.weight(.semibold))
				}
				.buttonStyle(.plain)
				.foregroundStyle(.tint)
			}
		}
	}

	/// 問過的內容跟樹頁同一套畫法：## 小標、$$ 獨立式子、粗體標題都認，不會整段變原始碼
	private func structuredBody(_ text: String) -> some View {
		VStack(alignment: .leading, spacing: 6) {
			ForEach(Array(StructuredBody.blocks(of: text).joined().enumerated()), id: \.offset) { _, line in
				StructuredLine(line)
			}
		}
	}

	private func noteCard(_ question: Card, source: Card?) -> some View {
		VStack(alignment: .leading, spacing: 6) {
			HStack(alignment: .firstTextBaseline, spacing: 6) {
				KindMark(kind: .custom)
				MathText(text: question.title, font: .subheadline.weight(.semibold), size: 15)
			}
			if let image = store.image(for: question.id) {
				Image(uiImage: image)
					.resizable()
					.scaledToFit()
					.frame(maxHeight: 140)
					.clipShape(RoundedRectangle(cornerRadius: 6))
					.padding(.leading, 16)
			}
			if let body = question.body {
				structuredBody(body)
					.padding(.leading, 16)
			}
			if !question.children.isEmpty {
				Text("底下還有 \(question.children.count) 個追問")
					.font(.caption2)
					.foregroundStyle(.tertiary)
					.padding(.leading, 16)
			}
			if let source {
				NavigationLink(value: source.id) {
					Text("來自題目：\(source.title)")
						.font(.caption2)
						.foregroundStyle(.tint)
				}
				.buttonStyle(.plain)
				.padding(.leading, 16)
			}
		}
		.padding(10)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
	}

	/// 你在不同題裡對這個概念問過的問題 —— 你的疑問就是它在你腦中的樣子
	@ViewBuilder
	private var questionsSection: some View {
		let questions = store.topics(withConcept: name)
			.flatMap { topic in topic.children.filter { $0.kind == .custom } }
		if !questions.isEmpty {
			VStack(alignment: .leading, spacing: 8) {
				Text("你在這個概念上問過的")
					.font(.caption2)
					.foregroundStyle(.tertiary)
				ForEach(questions) { question in
					HStack(alignment: .firstTextBaseline, spacing: 6) {
						KindMark(kind: .custom)
						Text(question.title)
							.font(.callout)
							.foregroundStyle(.primary.opacity(0.85))
							.fixedSize(horizontal: false, vertical: true)
					}
				}
			}
		}
	}

	/// 相關題目：一行一題，點了進樹。紅字＝當時卡住。截圖和紀錄都在樹頁，這裡只做索引
	@ViewBuilder
	private var problemsSection: some View {
		let problems = store.topics(withConcept: name)
		if !problems.isEmpty {
			VStack(alignment: .leading, spacing: 8) {
				Text("相關題目")
					.font(.caption2)
					.foregroundStyle(.tertiary)
				ForEach(problems) { topic in
					NavigationLink(value: topic.id) {
						HStack(alignment: .firstTextBaseline, spacing: 8) {
							KindMark(kind: .topic)
							MathText(text: topic.problem ?? topic.title, font: .subheadline, size: 15)
								.foregroundStyle(topic.situation == .stuck ? .red : .primary)
								.lineLimit(2)
								.multilineTextAlignment(.leading)
							Spacer(minLength: 8)
							Text(topic.createdAt.formatted(.dateTime.month().day()))
								.font(.caption2)
								.foregroundStyle(.tertiary)
							Image(systemName: "chevron.right")
								.font(.caption2.weight(.semibold))
								.foregroundStyle(.tertiary)
						}
						.padding(10)
						.frame(maxWidth: .infinity, alignment: .leading)
						.background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
					}
					.buttonStyle(.plain)
				}
			}
		}
	}
}
