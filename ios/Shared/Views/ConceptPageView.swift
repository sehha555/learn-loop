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

/// 一個概念的病歷卡，以概念為主角：你對它問過什麼、它連到哪些概念、出現在哪些題。
///
/// 一題掛多個概念時，完整紀錄若每個概念頁都放一份，逛起來像同一題被複製三次 ——
/// 所以題目預設縮成一行索引，點了才原地展開當時的紀錄（截圖、診斷、追問）。
/// 整頁純 code、零 AI 呼叫：這些事實 app 本來就存著，秒開、永遠準。
struct ConceptPageView: View {
	let name: String
	@ObservedObject var store: CardStore
	/// 問完跳進新樹。nil（分享浮層）就不顯示問的那格
	var open: ((UUID) -> Void)?

	/// 整理頁進行中的請求。存 Task 是為了讓「取消」真的能中斷
	@State private var compiling: Task<Void, Never>?
	/// 整理裡收起來的區塊（說明／重點／…）。點標題切換；只記這一次開頁
	@State private var foldedBlocks: Set<String> = []
	@State private var errorText: String?

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 20) {
				header
				wikiSection
				problemsSection
				notesSection
				questionsSection
				relatedSection
			}
			.padding()
		}
		.errorAlert($errorText)
		.navigationTitle(name)
		.navigationBarTitleDisplayMode(.inline)
		// 第一次進來、有材料但還沒整理過：自動整理一次。之後有新材料才靠按鈕
		.task(id: name) {
			if store.wiki[name] == nil, store.wikiNewCount(for: name) > 0 { compile() }
		}
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

	// MARK: - 模型整理頁

	/// 概念頁的成品區：模型讀底下所有材料寫的三塊。按了才重寫，新材料進來只標「多了 N 筆」
	@ViewBuilder
	private var wikiSection: some View {
		let page = store.wiki[name]
		let newCount = store.wikiNewCount(for: name)
		VStack(alignment: .leading, spacing: 10) {
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
				} else if page == nil {
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
			if let page {
				wikiBlock("說明", lines: [page.what])
				if let keyPoints = page.keyPoints {
					wikiBlock("重點", lines: keyPoints.components(separatedBy: "\n"))
				}
				wikiBlock("你卡過的地方", lines: page.stuck.components(separatedBy: "\n"))
				wikiBlock("還沒補的", lines: page.gaps.components(separatedBy: "\n"))
				if let note = page.fallbackNote {
					Label(note, systemImage: "icloud.and.arrow.down")
						.font(.caption2)
						.foregroundStyle(.orange)
				}
				Text("整理於 \(page.compiledAt.formatted(date: .abbreviated, time: .shortened)) · 讀了 \(page.materialCount) 筆材料")
					.font(.caption2)
					.foregroundStyle(.tertiary)
			} else if compiling != nil {
				Text("正在讀這個概念下的材料，寫說明和重點…")
					.font(.caption)
					.foregroundStyle(.secondary)
			} else if newCount == 0 {
				Text("還沒有材料。貼一題或問一個問題，歸到這個概念後就能整理。")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
		}
		.padding(12)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
	}

	private func wikiBlock(_ title: String, lines: [String]) -> some View {
		let folded = foldedBlocks.contains(title)
		return VStack(alignment: .leading, spacing: 4) {
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
				ForEach(Array(lines.filter { !$0.isEmpty }.enumerated()), id: \.offset) { _, line in
					MathText(text: line, font: .callout, size: 15)
						.foregroundStyle(.primary.opacity(0.9))
				}
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
			if let open {
				AskBar(store: store, placeholder: "問這個概念…", hintConcept: name, open: open)
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

	/// 你在不同題裡對這個概念問過的問題，集結在最上面 ——
	/// 這頁的主角是概念，你的疑問就是它在你腦中的樣子
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

	@ViewBuilder
	private var relatedSection: some View {
		let related = store.relatedConcepts(to: name)
		if !related.isEmpty {
			VStack(alignment: .leading, spacing: 8) {
				Text("延伸（同一題一起出現過的）")
					.font(.caption2)
					.foregroundStyle(.tertiary)
				FlowLayout(spacing: 5) {
					ForEach(related, id: \.self) { other in
						NavigationLink(value: other) {
							ConceptChip(name: other, repeated: store.isRepeated(other))
						}
						.buttonStyle(.plain)
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
