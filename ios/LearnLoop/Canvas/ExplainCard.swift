import SwiftUI

/// 畫布的講解卡片：圈選後按 [解釋][批改][打字問] 回來的內容。
/// 講解一句一行、解題步驟先藏著按「下一步」一步步打開（不用再等模型）、底部接著問。
/// 只畫內容；浮動或固定在側邊的外框、標題列由 MaterialView 給
struct ExplainCard: View {
	@ObservedObject var store: CardStore
	let topicID: UUID

	/// 打開了幾步。用 .id(topicID) 換卡時重來
	@State private var shownSteps: Int?
	/// 正在答的追問；存 Task 是為了讓「取消」真的能中斷
	@State private var answering: [UUID: Task<Void, Never>] = [:]
	@State private var errorText: String?

	private var topic: Card? { store.topics.first { $0.id == topicID } }

	var body: some View {
		VStack(spacing: 0) {
			ScrollView {
				if let topic {
					VStack(alignment: .leading, spacing: 14) {
						Text(topic.title).font(.title3.weight(.semibold))
						explanation(topic)
						let steps = topic.children.filter { $0.kind == .step }
						if !steps.isEmpty { stepsSection(steps, stuckStep: topic.stuckStep) }
						followUps(topic)
					}
					.padding(16)
					.frame(maxWidth: .infinity, alignment: .leading)
				}
			}
			Divider()
			FollowUpBar(running: !answering.isEmpty, onCancel: { answering.values.forEach { $0.cancel() } }, onSubmit: ask)
				.padding(10)
		}
		.errorAlert($errorText)
	}

	// MARK: - 講解

	private func explanation(_ topic: Card) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			StructuredText(text: ConceptMarkup.plain(topic.body ?? ""))
			if let note = topic.fallbackNote { FallbackNote(note: note) }
		}
	}

	// MARK: - 解題步驟

	/// 一打開先亮幾步：他已經做對的（卡住那步之前）直接給看；全對（0）就全部攤開
	static func initiallyShown(stuckStep: Int?, count: Int) -> Int {
		guard let stuck = stuckStep else { return 0 }
		return stuck == 0 ? count : min(max(stuck - 1, 0), count)
	}

	private func stepsSection(_ steps: [Card], stuckStep: Int?) -> some View {
		let shown = shownSteps ?? Self.initiallyShown(stuckStep: stuckStep, count: steps.count)
		return VStack(alignment: .leading, spacing: 10) {
			Text("解題步驟（先自己想，再按下一步）")
				.font(.subheadline.weight(.semibold))
				.foregroundStyle(.secondary)
			ForEach(Array(steps.prefix(shown).enumerated()), id: \.element.id) { index, step in
				HStack(alignment: .firstTextBaseline, spacing: 8) {
					Text("\(index + 1)")
						.font(.caption.weight(.bold))
						.foregroundStyle(.white)
						.frame(width: 22, height: 22)
						.background(Color.accentColor, in: Circle())
					VStack(alignment: .leading, spacing: 4) {
						MathText(text: ConceptMarkup.plain(step.title), font: .body, size: 17)
						// 舊的畫布卡：步驟標題底下可能有之前點開的內容
						if let body = step.body { StructuredText(text: body) }
					}
				}
			}
			HStack(spacing: 10) {
				if shown < steps.count {
					Button(shown == 0 ? "看第一步" : "下一步") { shownSteps = shown + 1 }
						.buttonStyle(.borderedProminent)
				}
				if shown > 0 {
					Button("重新來一次") { shownSteps = 0 }
						.buttonStyle(.bordered)
				}
			}
			.controlSize(.small)
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.padding(12)
		.background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
	}

	// MARK: - 追問

	/// 底部打字問的，接在卡片最下面
	private func followUps(_ topic: Card) -> some View {
		ForEach(topic.children.filter { $0.kind == .custom }) { card in
			VStack(alignment: .leading, spacing: 6) {
				Label {
					MathText(text: card.title, font: .subheadline.weight(.semibold), size: 15)
				} icon: {
					Image(systemName: "questionmark.bubble")
				}
				if let body = card.body {
					StructuredText(text: body)
				} else if answering[card.id] != nil {
					// 取消在底部輸入列
					ProgressView().controlSize(.small)
				} else {
					Button("沒答到，再問一次") { answer(card.id) }.font(.caption)
				}
			}
			.padding(.top, 6)
		}
	}

	/// 打的字和貼的圖都掛在新的追問上，跟題目樹的追問同一套
	private func ask(_ text: String, image: UIImage?) {
		let imageData = image.flatMap(AIClient.jpeg(from:))
		let title = text.isEmpty ? "這張圖在講什麼？" : text
		guard let id = store.addCustom(topicID: topicID, parentID: nil, title: title) else { return }
		if let imageData { store.saveImage(imageData, for: id) }
		answer(id, imageJPEG: imageData)
	}

	private func answer(_ cardID: UUID, imageJPEG: Data? = nil) {
		answering[cardID] = Task { @MainActor in
			defer { answering[cardID] = nil }
			do {
				try await store.answer(cardID: cardID, in: topicID, imageJPEG: imageJPEG)
			} catch {
				guard !AIClient.isCancellation(error) else { return }
				errorText = error.localizedDescription
			}
		}
	}
}

/// 卡片底部的追問輸入。自己管打的字：打字時只重畫這一列，不重排整張卡片
private struct FollowUpBar: View {
	var running: Bool
	var onCancel: () -> Void
	var onSubmit: (String, UIImage?) -> Void

	@State private var text = ""
	@State private var image: UIImage?

	var body: some View {
		AskField(
			text: $text, image: $image, placeholder: "接著問…", running: running, onCancel: onCancel
		) {
			onSubmit(text.trimmingCharacters(in: .whitespacesAndNewlines), image)
			text = ""
			image = nil
		}
	}
}

/// 模型在講解裡用 [名詞] 標概念名。現在先去掉括號顯示；之後變成點了跳概念頁的連結。
/// $…$ 裡的不碰（\sqrt[3]{x}），含逗號的也不算（區間 [0, 1]）
enum ConceptMarkup {
	static func plain(_ line: String) -> String {
		segments(line).map(\.text).joined()
	}

	static func segments(_ line: String) -> [(text: String, isConcept: Bool)] {
		var result: [(text: String, isConcept: Bool)] = []
		// 用 $ 切：偶數段是一般文字、奇數段是數學式
		for (index, part) in line.components(separatedBy: "$").enumerated() {
			let prefix = index == 0 ? "" : "$"
			guard index % 2 == 0 else {
				result.append((prefix + part, false))
				continue
			}
			var rest = Substring(part)
			var pending = prefix
			while let open = rest.firstIndex(of: "["),
				let close = rest[open...].firstIndex(of: "]") {
				let name = rest[rest.index(after: open)..<close]
				if name.isEmpty || name.count > 12 || name.contains(where: { ",，[".contains($0) }) {
					pending += rest[...open]
					rest = rest[rest.index(after: open)...]
					continue
				}
				pending += rest[..<open]
				if !pending.isEmpty { result.append((pending, false)) }
				result.append((String(name), true))
				pending = ""
				rest = rest[rest.index(after: close)...]
			}
			pending += rest
			if !pending.isEmpty { result.append((pending, false)) }
		}
		return result
	}
}
