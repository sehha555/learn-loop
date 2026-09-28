import SwiftUI

/// 頁面總覽（照 GoodNotes）：所有頁的縮圖格子。拖一頁放到另一頁上＝搬到那個位置；
/// 長按複製、刪除；點縮圖回到畫布捲到那頁
struct PageOverview: View {
	@ObservedObject var canvas: CanvasStore
	let materialID: UUID
	var onPick: (Int) -> Void
	@Environment(\.dismiss) private var dismiss

	private var pages: [CanvasPage] { canvas.material(materialID)?.pages ?? [] }

	var body: some View {
		NavigationStack {
			ScrollView {
				LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 180), spacing: 20)], spacing: 24) {
					ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
						cell(page, index: index)
					}
				}
				.padding(24)
			}
			.background(Color(.systemGroupedBackground))
			.navigationTitle("頁面")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
			}
		}
	}

	private func cell(_ page: CanvasPage, index: Int) -> some View {
		Button {
			onPick(index)
			dismiss()
		} label: {
			VStack(spacing: 6) {
				Image(uiImage: canvas.thumbnail(for: page, width: 150))
					.resizable()
					.scaledToFit()
					.frame(height: 190)
					.shadow(color: .black.opacity(0.15), radius: 3, y: 1)
				Text("\(index + 1)")
					.font(.caption.monospacedDigit())
					.foregroundStyle(.secondary)
			}
		}
		.buttonStyle(.plain)
		.contextMenu {
			Button("複製這頁", systemImage: "plus.square.on.square") { canvas.duplicatePage(page.id, in: materialID) }
			Button("刪除這頁", systemImage: "trash", role: .destructive) { canvas.deletePage(page.id, from: materialID) }
				.disabled(pages.count <= 1)
		}
		.draggable(page.id.uuidString)
		.dropDestination(for: String.self) { items, _ in
			guard let id = items.first, let from = pages.firstIndex(where: { $0.id.uuidString == id }), from != index else { return false }
			// 往後拖放在目標之後、往前拖放在目標之前：放下的那頁就佔目標原本的位置
			canvas.movePages(in: materialID, from: [from], to: from < index ? index + 1 : index)
			return true
		}
	}
}
