import SwiftUI

/// 主 app 和分享浮層的 NavigationStack 都要認得這兩種頁：
/// UUID → 題目的樹、概念名（String）→ 病歷卡。
/// 收在一處，新增路由才不會漏掉浮層那邊。
/// 注意：導覽全由 path 驅動 —— 混用舊式 NavigationLink(destination:) 會讓
/// 新頁被插到它下面，看起來像「點了沒反應，要按返回才會出現」。
extension View {
	func conceptDestinations(store: CardStore) -> some View {
		navigationDestination(for: UUID.self) { id in
			CardTreeView(topicID: id, store: store)
				.navigationTitle(store.topics.first { $0.id == id }?.title ?? "")
				.navigationBarTitleDisplayMode(.inline)
		}
		.navigationDestination(for: String.self) { name in
			ConceptPageView(name: name, store: store)
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

	/// 截圖進頁時從磁碟讀一次放這，body 重算不再碰 I/O
	@State private var images: [UUID: UIImage] = [:]
	/// 點縮圖放大看的那一題
	@State private var zoomTopic: Card?
	/// 展開看紀錄的題目
	@State private var expanded: Set<UUID> = []
	@State private var noteQuestion = ""
	@State private var asking = false
	@State private var errorText: String?

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 20) {
				header
				notesSection
				questionsSection
				relatedSection
				recordsSection
			}
			.padding()
		}
		.alert("出錯了", isPresented: .constant(errorText != nil)) {
			Button("好") { errorText = nil }
		} message: {
			Text(errorText ?? "")
		}
		.navigationTitle(name)
		.navigationBarTitleDisplayMode(.inline)
		.task(id: name) {
			for topic in store.topics(withConcept: name) where images[topic.id] == nil {
				images[topic.id] = store.image(for: topic.id)
			}
		}
		.sheet(item: $zoomTopic) { topic in
			if let image = images[topic.id] {
				Image(uiImage: image)
					.resizable()
					.scaledToFit()
					.padding()
			}
		}
	}

	// MARK: - 各區塊

	/// 概念名已經在導覽列上，這裡只放次數。
	/// 卡過時兩個數字都給 ——「卡 3 次但出現 5 題」跟「卡 3 次只出現 3 題」是不同的事
	@ViewBuilder
	private var header: some View {
		let appearances = store.appearanceCount(name)
		let stuck = store.stuckCount(name)
		if store.isRepeated(stuckCount: stuck) {
			Text("卡過 \(stuck) 次 · 出現在 \(appearances) 題裡")
				.font(.footnote.weight(.semibold))
				.foregroundStyle(.red)
		} else {
			Text("出現在 \(appearances) 題裡")
				.font(.footnote)
				.foregroundStyle(.secondary)
		}
	}

	/// 知識點：不針對題目、直接問這個概念的問答。這裡問的記在這裡；
	/// 題目頁裡「不只關那題」的問題也能搬過來。追問走同一套樹頁
	@ViewBuilder
	private var notesSection: some View {
		let note = store.noteTopic(for: name)
		VStack(alignment: .leading, spacing: 10) {
			Text("知識點（不針對題目的問答）")
				.font(.caption2)
				.foregroundStyle(.tertiary)
			if let note {
				ForEach(note.children) { question in
					VStack(alignment: .leading, spacing: 6) {
						HStack(alignment: .firstTextBaseline, spacing: 6) {
							Text(Card.Kind.custom.mark)
								.font(.caption2.weight(.bold))
								.foregroundStyle(Card.Kind.custom.tint)
							MathText(text: question.title, font: .subheadline.weight(.semibold), size: 15)
						}
						if let body = question.body {
							ForEach(
								Array(body.split(separator: "\n").enumerated()), id: \.offset
							) { _, line in
								MathText(text: String(line), font: .callout, size: 15)
									.foregroundStyle(.primary.opacity(0.85))
							}
							.padding(.leading, 16)
						}
						if !question.children.isEmpty {
							Text("底下還有 \(question.children.count) 個追問")
								.font(.caption2)
								.foregroundStyle(.tertiary)
								.padding(.leading, 16)
						}
					}
					.padding(10)
					.frame(maxWidth: .infinity, alignment: .leading)
					.background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
				}
				NavigationLink(value: note.id) {
					Label("打開知識點樹（可以接著追問）", systemImage: "arrow.turn.down.right")
						.font(.caption.weight(.semibold))
				}
				.buttonStyle(.plain)
				.foregroundStyle(.tint)
			}
			HStack(spacing: 8) {
				Text(Card.Kind.custom.mark)
					.font(.caption2.weight(.bold))
					.foregroundStyle(Card.Kind.custom.tint)
					.frame(width: 14)
				TextField("問這個概念…", text: $noteQuestion)
					.font(.subheadline)
					.submitLabel(.go)
					.onSubmit { askNote() }
					.disabled(asking)
				if asking {
					ProgressView().controlSize(.small)
				} else if !noteQuestion.trimmingCharacters(in: .whitespaces).isEmpty {
					Button("問") { askNote() }
						.font(.subheadline.weight(.semibold))
						.buttonStyle(.borderless)
				}
			}
			.padding(.vertical, 7)
			.padding(.horizontal, 10)
			.background(Color.pink.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
		}
	}

	/// 在概念頁問：掛到這個概念的知識點樹根部，原地等答案。
	/// 追問的追問去樹頁做（那裡有接點、取消這些機制）
	private func askNote() {
		let text = noteQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !text.isEmpty, !asking else { return }
		let noteID = store.ensureNoteTopic(for: name)
		guard let id = store.addCustom(topicID: noteID, parentID: nil, title: text) else { return }
		noteQuestion = ""
		asking = true
		Task { @MainActor in
			defer { asking = false }
			do {
				let note = store.topics.first { $0.id == noteID }
				let result = try await store.ai.expand(
					topic: "概念「\(name)」的知識問題，不針對特定題目",
					diagnosis: "",
					transcript: nil,
					explained: note?.explainedLines() ?? [],
					path: [text],
					style: store.teachingStyle,
					wantFollowUps: false
				)
				store.expand(cardID: id, body: result.body, followUps: result.followUps)
			} catch {
				errorText = error.localizedDescription
			}
		}
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
						Text(Card.Kind.custom.mark)
							.font(.caption2.weight(.bold))
							.foregroundStyle(Card.Kind.custom.tint)
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

	private var recordsSection: some View {
		VStack(alignment: .leading, spacing: 14) {
			Text("題目（點了展開當時的紀錄）")
				.font(.caption2)
				.foregroundStyle(.tertiary)
			ForEach(store.topics(withConcept: name)) { topic in
				record(topic)
			}
		}
	}

	/// 一行索引：紅字＝當時卡住。點了原地展開，展開裡才有跳回樹的入口
	private func record(_ topic: Card) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			Button {
				if expanded.contains(topic.id) {
					expanded.remove(topic.id)
				} else {
					expanded.insert(topic.id)
				}
			} label: {
				HStack(alignment: .firstTextBaseline, spacing: 8) {
					Image(systemName: expanded.contains(topic.id) ? "chevron.down" : "chevron.right")
						.font(.caption2.weight(.semibold))
						.foregroundStyle(.tertiary)
						.frame(width: 14)
					Text(topic.title)
						.font(.subheadline.weight(.semibold))
						.foregroundStyle(topic.situation == .stuck ? .red : .primary)
						.multilineTextAlignment(.leading)
					Spacer(minLength: 8)
					Text(topic.createdAt.formatted(.dateTime.month().day()))
						.font(.caption2)
						.foregroundStyle(.tertiary)
				}
				.frame(maxWidth: .infinity, alignment: .leading)
			}
			.buttonStyle(.plain)

			if expanded.contains(topic.id) {
				// 左邊一條線，跟樹頁同一套視覺 —— 底下的內容都掛在這筆題目下
				HStack(alignment: .top, spacing: 0) {
					TreeLine()

					VStack(alignment: .leading, spacing: 8) {
						if let image = images[topic.id] {
							Button {
								zoomTopic = topic
							} label: {
								// scaledToFit 整張圖完整可見 —— fill 會為了填滿寬度
								// 把上下裁掉，題目截圖被裁就什麼都看不出來了
								Image(uiImage: image)
									.resizable()
									.scaledToFit()
									.frame(maxHeight: 180)
									.clipShape(RoundedRectangle(cornerRadius: 8))
							}
							.buttonStyle(.plain)
							.frame(maxWidth: .infinity, alignment: .leading)
						}
						if let body = topic.body {
							MathText(text: "診斷：\(body)", font: .callout, size: 16)
								.foregroundStyle(.primary.opacity(0.85))
						}
						ForEach(topic.children.filter { $0.kind == .custom }) { question in
							HStack(alignment: .firstTextBaseline, spacing: 6) {
								Text(Card.Kind.custom.mark)
									.font(.caption2.weight(.bold))
									.foregroundStyle(Card.Kind.custom.tint)
								Text("你問過：\(question.title)")
									.font(.callout)
									.foregroundStyle(.primary.opacity(0.85))
									.fixedSize(horizontal: false, vertical: true)
							}
						}
						if topic.expandedDescendants > 0 {
							Text("點開過 \(topic.expandedDescendants) 個步驟")
								.font(.caption)
								.foregroundStyle(.secondary)
						}
						NavigationLink(value: topic.id) {
							Label("打開這棵樹", systemImage: "arrow.turn.down.right")
								.font(.caption.weight(.semibold))
						}
						.buttonStyle(.plain)
						.foregroundStyle(.tint)
					}
				}
			}
		}
	}
}

/// 概念的小膠囊標籤。卡過的紅色，其他灰色。樹頁和病歷卡共用。
struct ConceptChip: View {
	let name: String
	let repeated: Bool
	/// 主概念（題目歸在哪一段）—— 清單上藍色，讓人看得出分段依據
	var primary: Bool = false

	private var color: Color {
		repeated ? .red : (primary ? .accentColor : .secondary)
	}

	var body: some View {
		Text(name)
			.font(.caption2)
			.foregroundStyle(color)
			.padding(.horizontal, 8)
			.padding(.vertical, 2)
			.background(primary ? color.opacity(0.08) : .clear, in: Capsule())
			.overlay(Capsule().strokeBorder(color.opacity(primary ? 0.6 : 0.4)))
	}
}

/// 全部概念的總覽。上段「該回頭看的」：卡過的照最後一次卡的日期排，越近越前面，
/// 每列帶「和誰一起出現」—— 概念是連在一起卡的，入口就要看得到連結。
/// 下段其他概念照出現次數收在後面。
struct ConceptListView: View {
	@ObservedObject var store: CardStore

	var body: some View {
		Group {
			let concepts = store.allConcepts()
			if concepts.isEmpty {
				ContentUnavailableView {
					Label("還沒有概念", systemImage: "tag")
				} description: {
					Text("貼幾題之後，用到的概念會累積在這裡。")
				}
			} else {
				let review = concepts
					.filter { store.isRepeated(stuckCount: $0.stuck) }
					.sorted {
						(store.lastStuckDate($0.name) ?? .distantPast)
							> (store.lastStuckDate($1.name) ?? .distantPast)
					}
				let rest = concepts.filter { !store.isRepeated(stuckCount: $0.stuck) }
				List {
					if !review.isEmpty {
						Section("該回頭看的") {
							ForEach(review, id: \.name) { item in
								reviewRow(item)
							}
						}
					}
					if !rest.isEmpty {
						Section(review.isEmpty ? "" : "其他") {
							ForEach(rest, id: \.name) { item in
								NavigationLink(value: item.name) {
									HStack {
										Text(item.name)
										Spacer()
										Text("\(item.appearances) 題")
											.font(.subheadline)
											.foregroundStyle(.secondary)
									}
								}
							}
						}
					}
				}
			}
		}
		.navigationTitle("概念")
	}

	/// 該回頭看的一列：紅概念名＋一起出現的夥伴，右邊次數＋最後一次卡的日期
	private func reviewRow(_ item: (name: String, appearances: Int, stuck: Int)) -> some View {
		NavigationLink(value: item.name) {
			HStack(alignment: .firstTextBaseline) {
				VStack(alignment: .leading, spacing: 2) {
					Text(item.name)
						.foregroundStyle(.red)
					let related = store.relatedConcepts(to: item.name).prefix(2)
					if !related.isEmpty {
						Text("和 \(related.joined(separator: "、")) 一起出現")
							.font(.caption)
							.foregroundStyle(.secondary)
					}
				}
				Spacer()
				VStack(alignment: .trailing, spacing: 2) {
					Text("卡 \(item.stuck) 次")
						.font(.subheadline)
						.foregroundStyle(.red)
					if let date = store.lastStuckDate(item.name) {
						Text("最後一次 \(date.formatted(.dateTime.month().day()))")
							.font(.caption2)
							.foregroundStyle(.tertiary)
					}
				}
			}
		}
	}
}
