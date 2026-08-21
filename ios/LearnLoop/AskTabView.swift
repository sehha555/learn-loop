import SwiftUI

/// 概念 tab：上面是概念總覽，底下一格「直接問」—— 唸書時沒題目也能問，
/// 答案長成跟題目一樣的樹、歸到模型判的概念下
struct AskTabView: View {
	@ObservedObject var store: CardStore
	@State private var path = NavigationPath()
	@State private var question = ""
	/// 貼進來的圖（課本的圖、筆記的一段），跟問題一起給模型
	@State private var image: UIImage?
	/// 進行中的請求。存 Task 是為了讓「取消」真的能中斷
	@State private var asking: Task<Void, Never>?
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

	private var canAsk: Bool {
		!question.trimmingCharacters(in: .whitespaces).isEmpty || image != nil
	}

	private var askBar: some View {
		VStack(spacing: 8) {
			if let image, asking == nil {
				HStack(spacing: 8) {
					Image(uiImage: image)
						.resizable()
						.scaledToFit()
						.frame(height: 56)
						.clipShape(RoundedRectangle(cornerRadius: 6))
					Button("移除圖片", systemImage: "xmark.circle.fill") { self.image = nil }
						.labelStyle(.iconOnly)
						.foregroundStyle(.secondary)
					Spacer()
				}
			}
			HStack(spacing: 8) {
				if asking != nil {
					ProgressView()
					Text("想一下…").foregroundStyle(.secondary)
					Spacer()
					Button("取消") { asking?.cancel() }
						.buttonStyle(.bordered)
						.buttonBorderShape(.capsule)
				} else {
					// 跟題目頁一樣用系統 PasteButton，不會每次跳「允許貼上？」
					PasteButton(payloadType: PastedImage.self) { pasted in
						if let first = pasted.first { image = first.image }
					}
					.labelStyle(.iconOnly)
					.buttonBorderShape(.capsule)
					TextField(
						image == nil ? "直接問（不用貼題目）…" : "這張圖想問什麼？（可留空）",
						text: $question
					)
					.textFieldStyle(.roundedBorder)
					.submitLabel(.go)
					.onSubmit { ask() }
					if canAsk {
						Button("問") { ask() }
							.buttonStyle(.borderedProminent)
							.buttonBorderShape(.capsule)
					}
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
		guard canAsk, asking == nil, store.hasProvider else { return }
		asking = Task { @MainActor in
			defer { asking = nil }
			do {
				// 答完直接跳進那棵樹
				path.append(try await store.ask(question: text, image: image))
				question = ""
				image = nil
			} catch {
				guard !AIClient.isCancellation(error) else { return }
				errorMessage = error.localizedDescription
			}
		}
	}
}
