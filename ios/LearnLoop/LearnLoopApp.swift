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
				AskTabView(store: store)
					.tabItem { Label("概念", systemImage: "tag") }
			}
			// 舊題補抄題目原文，背景跑、跑完清單自己更新
			.task { if store.hasProvider { await store.backfillProblems() } }
			// 從分享浮層回到主 app 時，樹可能已經被改過
			.onReceive(
				NotificationCenter.default.publisher(
					for: UIApplication.willEnterForegroundNotification)
			) { _ in store.load() }
		}
	}
}

/// 概念 tab：上面是概念總覽，底下一格「直接問」—— 唸書時沒題目也能問，
/// 答案長成跟題目一樣的樹、歸到模型判的概念下
struct AskTabView: View {
	@ObservedObject var store: CardStore
	@State private var path = NavigationPath()
	@State private var question = ""
	@State private var asking = false
	@State private var errorMessage: String?

	var body: some View {
		NavigationStack(path: $path) {
			ConceptListView(store: store)
				.conceptDestinations(store: store)
				.safeAreaInset(edge: .bottom) { askBar }
				.alert("沒辦法處理", isPresented: .constant(errorMessage != nil)) {
					Button("好") { errorMessage = nil }
				} message: {
					Text(errorMessage ?? "")
				}
		}
	}

	private var askBar: some View {
		HStack(spacing: 8) {
			if asking {
				ProgressView()
				Text("想一下…").foregroundStyle(.secondary)
			} else {
				TextField("直接問（不用貼題目）…", text: $question)
					.textFieldStyle(.roundedBorder)
					.submitLabel(.go)
					.onSubmit { ask() }
				if !question.trimmingCharacters(in: .whitespaces).isEmpty {
					Button("問") { ask() }
						.buttonStyle(.borderedProminent)
						.buttonBorderShape(.capsule)
				}
			}
		}
		.frame(maxWidth: .infinity)
		.padding(.horizontal)
		.padding(.vertical, 10)
		.background(.bar)
	}

	@MainActor
	private func ask() {
		let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !text.isEmpty, !asking, store.hasProvider else { return }
		asking = true
		Task { @MainActor in
			defer { asking = false }
			do {
				// 答完直接跳進那棵樹
				path.append(try await store.ask(question: text))
				question = ""
			} catch {
				errorMessage = error.localizedDescription
			}
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
	/// 收合寫在 UserDefaults，SwiftUI 不會察覺 —— 這個數字變了才重繪
	@State private var groupsVersion = 0

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

	/// 段落收合也要記得，跟樹頁的節點一樣
	private var collapsedGroups: Set<String> {
		get { Set(UserDefaults.standard.stringArray(forKey: "collapsedTopicGroups") ?? []) }
		nonmutating set {
			UserDefaults.standard.set(Array(newValue), forKey: "collapsedTopicGroups")
			groupsVersion += 1
		}
	}

	private func groupHeader(_ group: (name: String, topics: [Card])) -> some View {
		Button {
			var set = collapsedGroups
			if set.contains(group.name) { set.remove(group.name) } else { set.insert(group.name) }
			collapsedGroups = set
		} label: {
			HStack {
				Text(group.name)
				Spacer()
				Text("\(group.topics.count) 題")
				Image(systemName: collapsedGroups.contains(group.name) ? "chevron.right" : "chevron.down")
					.font(.caption2.weight(.semibold))
			}
			.contentShape(Rectangle())
			.padding(.vertical, 4)
		}
		.buttonStyle(.plain)
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
