import SwiftUI

@main
struct LearnLoopApp: App {
	@StateObject private var store = CardStore()

	var body: some Scene {
		WindowGroup {
			TopicListView(store: store)
				// 從分享浮層回到主 app 時，樹可能已經被改過
				.onReceive(
					NotificationCenter.default.publisher(
						for: UIApplication.willEnterForegroundNotification)
				) { _ in store.load() }
		}
	}
}

/// 所有題目的清單。最近問的在最上面，不用捲到底。
struct TopicListView: View {
	@ObservedObject var store: CardStore
	@State private var showingSettings = false

	var body: some View {
		NavigationStack {
			Group {
				if store.topics.isEmpty {
					empty
				} else {
					List {
						ForEach(store.topics) { topic in
							NavigationLink {
								CardTreeView(topicID: topic.id, store: store)
									.navigationTitle(topic.title)
									.navigationBarTitleDisplayMode(.inline)
							} label: {
								row(topic)
							}
						}
						.onDelete { indexes in
							for i in indexes { store.delete(topicID: store.topics[i].id) }
						}
					}
				}
			}
			.navigationTitle("知識點")
			.toolbar {
				Button("設定", systemImage: "gearshape") { showingSettings = true }
			}
			.sheet(isPresented: $showingSettings) {
				SettingsView(store: store)
			}
		}
	}

	private func row(_ topic: Card) -> some View {
		VStack(alignment: .leading, spacing: 4) {
			Text(topic.title).font(.headline)
			if let body = topic.body {
				Text(body).font(.caption).foregroundStyle(.secondary).lineLimit(2)
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
			Text("在 GoodNotes 圈一段寫過的內容，按分享，選 LearnLoop。")
		}
	}
}

struct SettingsView: View {
	@ObservedObject var store: CardStore
	@Environment(\.dismiss) private var dismiss
	@State private var key = ""

	var body: some View {
		NavigationStack {
			Form {
				Section("Anthropic API key") {
					SecureField("sk-ant-...", text: $key)
						.textInputAutocapitalization(.never)
						.autocorrectionDisabled()
				}
				if !store.isShared {
					Section {
						Text("目前是免費簽章，分享浮層和這裡各存各的樹。改用付費開發者帳號之後會自動合併。")
							.font(.footnote)
							.foregroundStyle(.secondary)
					}
				}
			}
			.navigationTitle("設定")
			.toolbar {
				ToolbarItem(placement: .confirmationAction) {
					Button("完成") {
						store.apiKey = key
						dismiss()
					}
				}
			}
			.onAppear { key = store.apiKey }
		}
	}
}
