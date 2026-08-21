import SwiftUI

/// 所有題目的清單。最近問的在最上面，不用捲到底。
struct TopicListView: View {
	@ObservedObject var store: CardStore
	@State private var showingSettings = false
	@State private var path = NavigationPath()
	/// 段落收合。改 @State 畫面才會重畫；UserDefaults 只負責記住
	@State private var collapsedGroups = Set(
		UserDefaults.standard.stringArray(forKey: "collapsedTopicGroups") ?? [])

	var body: some View {
		NavigationStack(path: $path) {
			Group {
				if store.topics.isEmpty {
					empty
				} else {
					List {
						ForEach(groups, id: \.name) { group in
							Section {
								if !collapsedGroups.contains(group.name) {
									ForEach(group.topics) { topic in
										NavigationLink(value: topic.id) {
											row(topic)
										}
										.contextMenu {
											Button("重新抄題目", systemImage: "arrow.clockwise") {
												Task { await store.reextractProblem(topicID: topic.id) }
											}
										}
									}
									.onDelete { indexes in
										for i in indexes { store.delete(topicID: group.topics[i].id) }
									}
								}
							} header: {
								groupHeader(group)
							}
						}
					}
				}
			}
			.navigationTitle("題目")
			.toolbar {
				Button("設定", systemImage: "gearshape") { showingSettings = true }
			}
			.sheet(isPresented: $showingSettings) {
				SettingsView(store: store)
			}
			.safeAreaInset(edge: .bottom) {
				// 貼題目截圖或直接打問題都從這裡進，答完直接跳進那棵樹
				AskBar(store: store, placeholder: "貼題目截圖，或直接問…") { path.append($0) }
					.padding(.horizontal)
					.padding(.vertical, 8)
					.background(.bar)
			}
			// 清單點進去、貼上分析完自動跳轉、概念相關的頁全走這一份共用路由
			.conceptDestinations(store: store) { path.append($0) }
		}
	}

	/// 照「主概念」（模型列的第一個）分段，一題只出現一次；段落順序＝最新那題的順序。
	/// 其他概念靠列上的 tag 看到
	private var groups: [(name: String, topics: [Card])] {
		var order: [String] = []
		var byName: [String: [Card]] = [:]
		for topic in store.problems {
			let name = topic.concepts.first ?? "未分類"
			if byName[name] == nil { order.append(name) }
			byName[name, default: []].append(topic)
		}
		return order.map { ($0, byName[$0]!) }
	}

	private func groupHeader(_ group: (name: String, topics: [Card])) -> some View {
		GroupHeader(
			title: group.name, detail: "\(group.topics.count) 題",
			collapsed: collapsedGroups.contains(group.name)
		) {
			if collapsedGroups.contains(group.name) {
				collapsedGroups.remove(group.name)
			} else {
				collapsedGroups.insert(group.name)
			}
			// 跟樹頁的節點一樣，收合要記得
			UserDefaults.standard.set(Array(collapsedGroups), forKey: "collapsedTopicGroups")
		}
	}

	/// 預覽放題目原文（舊題沒抄就退回診斷句），底下一排概念 tag，主概念藍色
	private func row(_ topic: Card) -> some View {
		VStack(alignment: .leading, spacing: 5) {
			// 大標就是題目本身，四到八個字的名字退成小字；舊題沒抄題目就還是名字當大標
			if let problem = topic.problem {
				Text(topic.title).font(.caption).foregroundStyle(.secondary)
				MathText(text: problem, font: .subheadline.weight(.semibold), size: 15)
					.lineLimit(4)
			} else {
				Text(topic.title).font(.headline)
				if let body = topic.body {
					MathText(text: body, font: .caption, size: 12)
						.foregroundStyle(.secondary)
						.lineLimit(2)
				}
			}
			if !topic.concepts.isEmpty {
				FlowLayout(spacing: 5) {
					ForEach(Array(topic.concepts.enumerated()), id: \.offset) { index, name in
						ConceptChip(name: name, repeated: store.isRepeated(name), primary: index == 0)
					}
				}
			}
			if topic.pendingCount > 0 {
				Text("\(topic.pendingCount) 個沒展開")
					.font(.caption2)
					.foregroundStyle(.tertiary)
			}
		}
		.padding(.vertical, 2)
	}

	private var empty: some View {
		ContentUnavailableView {
			Label("還沒有東西", systemImage: "tray")
		} description: {
			Text("在 GoodNotes 截圖或圈選複製，回到這裡貼到下面那格；沒題目也可以直接打問題。")
		}
	}
}
