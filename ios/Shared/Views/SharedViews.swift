import CoreTransferable
import SwiftUI

/// 概念 chips 用的極簡換行排版 —— 放不下就折到下一行
struct FlowLayout: Layout {
	var spacing: CGFloat = 6

	func sizeThatFits(
		proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
	) -> CGSize {
		let width = proposal.width ?? .infinity
		var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
		for view in subviews {
			let size = view.sizeThatFits(.unspecified)
			if x + size.width > width, x > 0 {
				x = 0
				y += rowHeight + spacing
				rowHeight = 0
			}
			x += size.width + spacing
			rowHeight = max(rowHeight, size.height)
		}
		return CGSize(width: proposal.width ?? x, height: y + rowHeight)
	}

	func placeSubviews(
		in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
	) {
		var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
		for view in subviews {
			let size = view.sizeThatFits(.unspecified)
			if x + size.width > bounds.maxX, x > bounds.minX {
				x = bounds.minX
				y += rowHeight + spacing
				rowHeight = 0
			}
			view.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
			x += size.width + spacing
			rowHeight = max(rowHeight, size.height)
		}
	}
}

/// 樹的層級直線。樹頁的縮排線和病歷卡的內容邊線共用這一條，改視覺一處生效。
struct TreeLine: View {
	var body: some View {
		Rectangle()
			.fill(Color.secondary.opacity(0.25))
			.frame(width: 1)
			.padding(.leading, 9)
			.padding(.trailing, 12)
	}
}

/// 每種點的記號與顏色 —— 樹頁和病歷卡共用同一份對照，
/// 一眼看得出這是「疑問」還是「有雷」還是「我自己加的」
extension Card.Kind {
	var mark: String {
		switch self {
		case .step: "▸"
		case .question: "？"
		case .supplement: "＋"
		case .trap: "！"
		case .extend: "↗"
		case .custom: "✎"
		case .topic: "◆"
		case .note: "◇"
		case .free: "◇"
		}
	}

	var tint: Color {
		switch self {
		case .step: .blue
		case .question: .accentColor
		case .supplement: .teal
		case .trap: .orange
		case .extend: .purple
		case .custom: .pink
		case .topic: .accentColor
		case .note: .accentColor
		case .free: .accentColor
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

/// 問問題的輸入列：貼圖、打字、送出，進行中可取消。
/// 題目 tab、概念 tab、概念頁、樹頁追問四處共用 —— 之前各寫一份，
/// 結果「追問不能貼圖」「這邊有取消那邊沒有」這種不對稱一直冒出來
struct AskField: View {
	@Binding var text: String
	@Binding var image: UIImage?
	var placeholder: String
	var running: Bool
	var onCancel: () -> Void
	var onSubmit: () -> Void

	private var canSubmit: Bool {
		image != nil || !text.trimmingCharacters(in: .whitespaces).isEmpty
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			if let image, !running {
				HStack(spacing: 8) {
					Image(uiImage: image)
						.resizable()
						.scaledToFit()
						.frame(height: 56)
						.clipShape(RoundedRectangle(cornerRadius: 6))
					Button("移除圖片", systemImage: "xmark.circle.fill") { self.image = nil }
						.labelStyle(.iconOnly)
						.buttonStyle(.borderless)
						.foregroundStyle(.secondary)
				}
			}
			HStack(spacing: 8) {
				Text(Card.Kind.custom.mark)
					.font(.caption2.weight(.bold))
					.foregroundStyle(Card.Kind.custom.tint)
					.frame(width: 14)
				if !running {
					// 用系統 PasteButton 才不會每次跳「允許貼上？」
					PasteButton(payloadType: PastedImage.self) { pasted in
						if let first = pasted.first { image = first.image }
					}
					.labelStyle(.iconOnly)
					.controlSize(.small)
					.buttonBorderShape(.capsule)
				}
				TextField(image == nil ? placeholder : "這張圖想問什麼？（可留空）", text: $text)
					.font(.subheadline)
					.submitLabel(.go)
					.onSubmit(onSubmit)
					.disabled(running)
				if running {
					ProgressView().controlSize(.small)
					Button("取消", action: onCancel)
						.font(.subheadline)
						.buttonStyle(.borderless)
				} else if canSubmit {
					Button("問", action: onSubmit)
						.font(.subheadline.weight(.semibold))
						.buttonStyle(.borderless)
				}
			}
		}
		.padding(.vertical, 7)
		.padding(.horizontal, 10)
		.background(Color.pink.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
	}
}

/// 統一入口的「問」列：題目截圖、直接問、在概念頁問，全部從這裡走 CardStore.ingest，
/// 模型自己判斷是題目還是提問。答完把新樹的 id 交給 open，呼叫端負責跳進去
struct AskBar: View {
	@ObservedObject var store: CardStore
	var placeholder: String
	/// 在哪個概念頁問的，給模型當歸類提示
	var hintConcept: String? = nil
	var open: (UUID) -> Void

	@State private var text = ""
	@State private var image: UIImage?
	/// 存 Task 是為了讓「取消」真的能中斷
	@State private var asking: Task<Void, Never>?
	@State private var errorMessage: String?

	var body: some View {
		AskField(
			text: $text, image: $image, placeholder: placeholder, running: asking != nil,
			onCancel: { asking?.cancel() }, onSubmit: submit
		)
		.alert("沒辦法處理", isPresented: .constant(errorMessage != nil)) {
			Button("好") { errorMessage = nil }
		} message: {
			Text(errorMessage ?? "")
		}
	}

	private func submit() {
		let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !typed.isEmpty || image != nil, asking == nil else { return }
		guard store.hasProvider else {
			errorMessage = AIError.noAPIKey.localizedDescription
			return
		}
		let image = image
		asking = Task { @MainActor in
			defer { asking = nil }
			do {
				let id = try await store.ingest(text: typed, image: image, hintConcept: hintConcept)
				text = ""
				self.image = nil
				open(id)
			} catch {
				guard !AIClient.isCancellation(error) else { return }
				errorMessage = error.localizedDescription
			}
		}
	}
}
