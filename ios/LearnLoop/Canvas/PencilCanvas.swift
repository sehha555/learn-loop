import PencilKit
import SwiftUI

/// 活的 PKCanvasView 的弱參考。圈選送出時讀 drawing／contentOffset 用
final class CanvasHandle {
	weak var view: PKCanvasView?
}

/// PKCanvasView 包成 SwiftUI。一頁一個 PKDrawing，換頁就換 drawing；停筆存檔交給 CanvasStore。
/// 圈選模式時整個 canvas 不收觸控（interactive = false），筆畫才不會跟拉框打架
struct PencilCanvas: UIViewRepresentable {
	let pageID: UUID
	@ObservedObject var store: CanvasStore
	var interactive: Bool
	/// 讓 SwiftUI 那邊拿得到活的 canvas（圈選時要當下的筆跡與捲動位置，不能等存檔）
	let handle: CanvasHandle

	func makeUIView(context: Context) -> PKCanvasView {
		let view = PKCanvasView()
		handle.view = view
		// 模擬器沒 Pencil、手指也要能畫；真機上 Pencil 照常，手指用來捲動的話之後再改 pencilOnly
		view.drawingPolicy = .anyInput
		view.backgroundColor = .white
		view.delegate = context.coordinator
		view.drawing = store.drawing(for: pageID)
		context.coordinator.pageID = pageID
		// 系統的筆工具列：跟著 canvas 當第一回應者出現，離開這頁自動收
		let picker = PKToolPicker()
		picker.addObserver(view)
		picker.setVisible(true, forFirstResponder: view)
		context.coordinator.picker = picker
		DispatchQueue.main.async { view.becomeFirstResponder() }
		return view
	}

	func updateUIView(_ view: PKCanvasView, context: Context) {
		if context.coordinator.pageID != pageID {
			context.coordinator.pageID = pageID
			view.drawing = store.drawing(for: pageID)
		}
		view.isUserInteractionEnabled = interactive
		if interactive, !view.isFirstResponder { view.becomeFirstResponder() }
	}

	func makeCoordinator() -> Coordinator { Coordinator(store: store) }

	final class Coordinator: NSObject, PKCanvasViewDelegate {
		let store: CanvasStore
		var pageID: UUID?
		var picker: PKToolPicker?

		init(store: CanvasStore) { self.store = store }

		func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
			guard let pageID else { return }
			store.saveDrawing(canvasView.drawing, for: pageID)
		}
	}
}
