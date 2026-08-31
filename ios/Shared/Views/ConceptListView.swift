import SwiftUI

/// 全部概念的總覽。上段「該回頭看的」：卡過的照「次數 × 放了幾天」排，久沒碰的舊弱點浮上來，
/// 每列帶「和誰一起出現」—— 概念是連在一起卡的，入口就要看得到連結。
/// 下段其他概念照出現次數收在後面。
struct ConceptListView: View {
	@ObservedObject var store: CardStore
	/// 收起來的章。改 @State 畫面才會重畫；UserDefaults 只負責記住
	@State private var collapsed = Set(
		UserDefaults.standard.stringArray(forKey: "collapsedChapters") ?? [])
	/// 長按「併入…」選了哪個概念要被併走
	@State private var merging: MergeSource?
	/// 「整理概念清單」進行中的請求。存 Task 讓「取消」真的能中斷
	@State private var linting: Task<Void, Never>?
	/// 模型建議的合併，等使用者勾選確認
	@State private var lintResult: [AIClient.ConceptMerge]?
	@State private var lintError: String?

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
				let now = Date()
				let review = concepts
					.filter { store.isRepeated(trouble: $0.trouble) }
					.sorted { $0.reviewScore(now: now) > $1.reviewScore(now: now) }
				let rest = concepts.filter { !store.isRepeated(trouble: $0.trouble) }
				List {
					if !review.isEmpty {
						Section("該回頭看的") {
							ForEach(review, id: \.name) { item in
								reviewRow(item)
									.contextMenu { mergeButton(item.name) }
							}
						}
					}
					// 其他概念照章分段 —— 攤平排 40 列沒人看；章的順序照出現題數
					ForEach(chapterGroups(rest), id: \.chapter) { group in
						Section {
							if !collapsed.contains(group.chapter) {
								ForEach(group.items, id: \.name) { item in
									NavigationLink(value: item.name) {
										HStack {
											Text(item.name)
											Spacer()
											Text(countLabel(item))
												.font(.subheadline)
												.foregroundStyle(.secondary)
										}
									}
									.contextMenu { mergeButton(item.name) }
								}
							}
						} header: {
							GroupHeader(
								title: group.chapter, detail: "\(group.items.count) 個概念",
								collapsed: collapsed.contains(group.chapter)
							) {
								if collapsed.contains(group.chapter) {
									collapsed.remove(group.chapter)
								} else {
									collapsed.insert(group.chapter)
								}
								UserDefaults.standard.set(Array(collapsed), forKey: "collapsedChapters")
							}
						}
					}
				}
			}
		}
		.navigationTitle("概念")
		.toolbar {
			ToolbarItem(placement: .primaryAction) {
				if linting != nil {
					HStack(spacing: 8) {
						ProgressView().controlSize(.small)
						Button("取消") { linting?.cancel() }.font(.caption)
					}
				} else {
					// 模型看整份清單找同義／太細的，回提案讓你勾——按了才跑，不自動
					Button("整理概念清單", systemImage: "wand.and.stars") { lint() }
						.disabled(store.allConcepts().isEmpty)
				}
			}
		}
		.sheet(item: $merging) { source in
			MergePickerView(store: store, source: source.name)
		}
		.sheet(
			isPresented: Binding(get: { lintResult != nil }, set: { if !$0 { lintResult = nil } })
		) {
			if let lintResult {
				LintConfirmView(store: store, merges: lintResult)
			}
		}
		.errorAlert($lintError)
	}

	private func lint() {
		guard linting == nil else { return }
		guard store.hasProvider else {
			lintError = AIError.noAPIKey.localizedDescription
			return
		}
		linting = Task { @MainActor in
			defer { linting = nil }
			do {
				let merges = try await store.lintConcepts()
				if merges.isEmpty {
					lintError = "模型看完整份清單：沒有該合併的。"
				} else {
					lintResult = merges
				}
			} catch {
				guard !AIClient.isCancellation(error) else { return }
				lintError = error.localizedDescription
			}
		}
	}

	/// 長按選單：把這個概念併進別的（同義詞、模型手滑取的新名都靠這裡收）
	private func mergeButton(_ name: String) -> some View {
		Button("併入其他概念…", systemImage: "arrow.triangle.merge") {
			merging = MergeSource(name: name)
		}
	}

	private typealias Item = CardStore.ConceptItem

	/// 依章分組。還沒分章的（模型還沒補到）收在最後一段「還沒分章」
	private func chapterGroups(_ items: [Item]) -> [(chapter: String, items: [Item])] {
		var order: [String] = []
		var byChapter: [String: [Item]] = [:]
		for item in items {
			let chapter = store.chapters[item.name] ?? CardStore.unassigned
			if byChapter[chapter] == nil { order.append(chapter) }
			byChapter[chapter, default: []].append(item)
		}
		return order
			.sorted { a, b in
				if a == CardStore.unassigned { return false }
				if b == CardStore.unassigned { return true }
				let ta = byChapter[a]!.reduce(0) { $0 + $1.appearances }
				let tb = byChapter[b]!.reduce(0) { $0 + $1.appearances }
				return ta == tb ? a < b : ta > tb
			}
			.map { ($0, byChapter[$0]!) }
	}

	/// 「3 題 · 2 點」—— 題目與知識點分開數，哪邊是 0 就不寫
	private func countLabel(_ item: Item) -> String {
		var parts: [String] = []
		if item.appearances > 0 { parts.append("\(item.appearances) 題") }
		if item.notes > 0 { parts.append("\(item.notes) 點") }
		return parts.joined(separator: " · ")
	}

	private struct MergeSource: Identifiable {
		let name: String
		var id: String { name }
	}

	/// 該回頭看的一列：紅概念名＋一起出現的夥伴，右邊兩種證據的次數＋最後一次卡的日期
	private func reviewRow(_ item: Item) -> some View {
		NavigationLink(value: item.name) {
			HStack(alignment: .firstTextBaseline) {
				VStack(alignment: .leading, spacing: 2) {
					Text(item.name)
						.foregroundStyle(.red)
					let related = item.related.prefix(2)
					if !related.isEmpty {
						Text("和 \(related.joined(separator: "、")) 一起出現")
							.font(.caption)
							.foregroundStyle(.secondary)
					}
				}
				Spacer()
				VStack(alignment: .trailing, spacing: 2) {
					Text(ConceptPageView.troubleLabel(stuck: item.stuck, asked: item.asked))
						.font(.subheadline)
						.foregroundStyle(.red)
					if let date = item.lastTrouble {
						Text("最後一次 \(date.formatted(.dateTime.month().day()))")
							.font(.caption2)
							.foregroundStyle(.tertiary)
					}
				}
			}
		}
	}
}

/// 「A 併入 B」的選單：列出全部概念（排除 A），點一個、確認、合併。
/// 合併＝A 的題目標籤、章、考試涵蓋全改成 B，整理頁併進 B 的
private struct MergePickerView: View {
	@ObservedObject var store: CardStore
	/// 要被併走的概念
	let source: String
	@Environment(\.dismiss) private var dismiss
	@State private var query = ""
	/// 點了哪個當合併目標（等確認）
	@State private var target: String?

	var body: some View {
		NavigationStack {
			List(candidates, id: \.self) { name in
				Button {
					target = name
				} label: {
					HStack {
						Text(name)
						Spacer()
						Text(store.chapters[name] ?? "")
							.font(.caption)
							.foregroundStyle(.secondary)
					}
				}
				.foregroundStyle(.primary)
			}
			.searchable(text: $query, prompt: "找要併入的概念")
			.navigationTitle("「\(source)」併入…")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
			}
			.confirmationDialog(
				"把「\(source)」併入「\(target ?? "")」？",
				isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } }),
				titleVisibility: .visible
			) {
				Button("合併", role: .destructive) {
					if let target { store.mergeConcept(keep: target, drop: source) }
					dismiss()
				}
			} message: {
				Text("「\(source)」的題目、章、考試範圍會全部改標「\(target ?? "")」，整理頁也併進去。這動作沒有復原。")
			}
		}
	}

	private var candidates: [String] {
		store.knownConceptNames().filter {
			$0 != source && (query.isEmpty || $0.localizedStandardContains(query))
		}
	}
}

/// 「整理概念清單」跑完的確認頁：每筆一個 Toggle，勾了才套。
/// keep 不在清單裡的（模型自創名）標灰不能勾——合併需要目標真的存在
private struct LintConfirmView: View {
	@ObservedObject var store: CardStore
	let merges: [AIClient.ConceptMerge]
	@Environment(\.dismiss) private var dismiss
	@State private var enabled: Set<Int> = []

	/// 攤平成一筆一對（drop → keep），勾選按這個算
	private var pairs: [(keep: String, drop: String)] {
		merges.flatMap { merge in merge.drop.map { (merge.keep, $0) } }
	}

	var body: some View {
		NavigationStack {
			List {
				Section {
					ForEach(Array(pairs.enumerated()), id: \.offset) { index, pair in
						let valid = isValid(pair)
						Toggle(isOn: binding(index)) {
							VStack(alignment: .leading, spacing: 2) {
								Text("\(pair.drop) → \(pair.keep)")
									.foregroundStyle(valid ? .primary : .tertiary)
								if !valid {
									Text("「\(pair.keep)」不在清單裡，不能當合併目標")
										.font(.caption2)
										.foregroundStyle(.tertiary)
								}
							}
						}
						.disabled(!valid)
					}
				} footer: {
					Text("勾選的會把左邊併進右邊：題目、章、考試範圍全部改名，整理頁併進去。沒把握的取消勾選就好。")
				}
			}
			.navigationTitle("模型建議的合併")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
				ToolbarItem(placement: .confirmationAction) {
					Button("套用 \(enabled.count) 筆") { apply() }
						.disabled(enabled.isEmpty)
				}
			}
		}
		.onAppear {
			enabled = Set(pairs.indices.filter { isValid(pairs[$0]) })
		}
	}

	private func isValid(_ pair: (keep: String, drop: String)) -> Bool {
		pair.keep != pair.drop && store.knownConceptNames().contains(pair.keep)
	}

	private func binding(_ index: Int) -> Binding<Bool> {
		Binding(
			get: { enabled.contains(index) },
			set: { if $0 { enabled.insert(index) } else { enabled.remove(index) } })
	}

	private func apply() {
		for index in pairs.indices where enabled.contains(index) {
			let pair = pairs[index]
			// 前一筆可能剛把這筆的 keep 併走了，套之前再驗一次
			guard store.knownConceptNames().contains(pair.keep) else { continue }
			store.mergeConcept(keep: pair.keep, drop: pair.drop)
		}
		dismiss()
	}
}
