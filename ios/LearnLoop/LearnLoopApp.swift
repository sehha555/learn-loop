import SwiftUI
import UniformTypeIdentifiers

/// 剪貼簿貼進來的圖。PasteButton 要求 Transferable，UIImage 沒有，包一層。
struct PastedImage: Transferable {
	let image: UIImage

	static var transferRepresentation: some TransferRepresentation {
		DataRepresentation(importedContentType: .image) { data in
			guard let image = UIImage(data: data) else { throw AIError.badImage }
			return PastedImage(image: image)
		}
	}
}

@main
struct LearnLoopApp: App {
	@StateObject private var store = CardStore()

	var body: some Scene {
		WindowGroup {
			// 題目和概念是兩個平等的視角，用 tab 一點就切 ——
			// 藏在 toolbar 按鈕裡要推頁面進出，概念那頁就不會有人去看
			TabView {
				TopicListView(store: store)
					.tabItem { Label("題目", systemImage: "list.bullet") }
				NavigationStack {
					ConceptListView(store: store)
						.conceptDestinations(store: store)
				}
				.tabItem { Label("概念", systemImage: "tag") }
			}
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
	@State private var analyzing = false
	@State private var path = NavigationPath()
	@State private var errorMessage: String?

	var body: some View {
		NavigationStack(path: $path) {
			Group {
				if store.topics.isEmpty {
					empty
				} else {
					List {
						ForEach(store.topics) { topic in
							NavigationLink(value: topic.id) {
								row(topic)
							}
						}
						.onDelete { indexes in
							for i in indexes { store.delete(topicID: store.topics[i].id) }
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
			.safeAreaInset(edge: .bottom) { pasteBar }
			// 清單點進去、貼上分析完自動跳轉、概念相關的頁全走這一份共用路由
			.conceptDestinations(store: store)
			.alert("沒辦法處理", isPresented: .constant(errorMessage != nil)) {
				Button("好") { errorMessage = nil }
			} message: {
				Text(errorMessage ?? "")
			}
		}
	}

	/// Slide Over 用法的入口：在 GoodNotes 截圖（或圈選複製）後，滑出來按這顆。
	/// 用系統的 PasteButton 才不會每次都跳「允許貼上？」的確認框。
	private var pasteBar: some View {
		Group {
			if analyzing {
				HStack(spacing: 8) {
					ProgressView()
					Text("看你寫了什麼…").foregroundStyle(.secondary)
				}
			} else {
				PasteButton(payloadType: PastedImage.self) { pasted in
					guard let first = pasted.first else { return }
					Task { @MainActor in await analyze(first.image) }
				}
				.buttonBorderShape(.capsule)
			}
		}
		.frame(maxWidth: .infinity)
		.padding(.vertical, 10)
		.background(.bar)
	}

	@MainActor
	private func analyze(_ image: UIImage) async {
		guard store.hasProvider else {
			showingSettings = true
			return
		}
		analyzing = true
		defer { analyzing = false }
		do {
			// 分析完直接跳進那棵樹，不用自己從清單找
			path.append(try await store.analyze(image: image))
		} catch {
			errorMessage = error.localizedDescription
		}
	}

	private func row(_ topic: Card) -> some View {
		VStack(alignment: .leading, spacing: 4) {
			Text(topic.title).font(.headline)
			if let body = topic.body {
				MathText(text: body, font: .caption, size: 12)
					.foregroundStyle(.secondary)
					.lineLimit(2)
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
			Text("在 GoodNotes 截圖或圈選複製，回到這裡按下面的「貼上」。")
		}
	}
}

struct SettingsView: View {
	@ObservedObject var store: CardStore
	@Environment(\.dismiss) private var dismiss
	@State private var key = ""
	@State private var relayAddress = ""
	@State private var style: TeachingStyle = .plain

	var body: some View {
		NavigationStack {
			Form {
				Section {
					SecureField("AIza... 或 sk-ant-...", text: $key)
						.textInputAutocapitalization(.never)
						.autocorrectionDisabled()
				} header: {
					Text("API key")
				} footer: {
					Text("Google AI Studio 的 key（AIza 開頭）有免費額度，貼上就會走 Gemini。貼 Anthropic 的 key（sk-ant 開頭）就走 Claude。")
				}
				Section {
					TextField("sehha555demacbook-pro.local", text: $relayAddress)
						.textInputAutocapitalization(.never)
						.autocorrectionDisabled()
						.keyboardType(.URL)
				} header: {
					Text("Mac 中繼站（選填）")
				} footer: {
					Text("Mac 上先跑 mac-relay/server.py，這裡填 Mac 的名字，就會優先用 Claude Code 訂閱、不吃 API。同一個 Wi-Fi 填「名字.local」；裝了 Tailscale 填它給的機器名，在外面也通。連不上會自動改用上面的 key。")
				}
				Section {
					Picker("口吻", selection: $style) {
						ForEach(TeachingStyle.allCases, id: \.self) { style in
							Text(style.label).tag(style)
						}
					}
					.pickerStyle(.inline)
					.labelsHidden()
				} header: {
					Text("點開步驟時的講法")
				} footer: {
					Text("零基礎白話：每個術語都解釋、步驟切最細。引導提問：不給完答案，每步留一個小問題推你想。精簡條列：直接講重點。")
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
						store.relayAddress = relayAddress
						store.teachingStyle = style
						dismiss()
					}
				}
			}
			.onAppear {
				key = store.apiKey
				relayAddress = store.relayAddress
				style = store.teachingStyle
			}
		}
	}
}
