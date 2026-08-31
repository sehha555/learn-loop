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
		.sheet(item: $merging) { source in
			MergePickerView(store: store, source: source.name)
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
