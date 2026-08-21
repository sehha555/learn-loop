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
