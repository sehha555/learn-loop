import SwiftUI

/// 畫布 tab：在 app 裡直接手寫（取代 GoodNotes 的第一步）。一頁一份筆跡，翻頁自己決定
struct CanvasTabView: View {
	@ObservedObject var store: CardStore
	@StateObject private var canvas: CanvasStore
	@State private var pageIndex = 0

	init(store: CardStore) {
		self.store = store
		_canvas = StateObject(wrappedValue: CanvasStore(dataDir: store.dataDir))
	}

	private var page: CanvasPage { canvas.pages[min(pageIndex, canvas.pages.count - 1)] }

	var body: some View {
		NavigationStack {
			PencilCanvas(pageID: page.id, store: canvas, interactive: true)
				.ignoresSafeArea(.keyboard)
				.navigationTitle("第 \(pageIndex + 1) 頁 / \(canvas.pages.count)")
				.navigationBarTitleDisplayMode(.inline)
				.toolbar {
					ToolbarItemGroup(placement: .primaryAction) {
						Button("上一頁", systemImage: "chevron.left") { pageIndex -= 1 }
							.disabled(pageIndex == 0)
						Button("下一頁", systemImage: "chevron.right") { pageIndex += 1 }
							.disabled(pageIndex >= canvas.pages.count - 1)
						Button("新增頁", systemImage: "plus.square") {
							pageIndex = canvas.addPage(after: pageIndex)
						}
					}
				}
		}
	}
}
