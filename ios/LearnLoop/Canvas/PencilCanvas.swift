import PencilKit
import SwiftUI

/// 活的 PKCanvasView 的弱參考。圈選送出時讀 drawing／contentOffset／底圖用
final class CanvasHandle {
	weak var view: PaperCanvasView?
}

/// 底下墊一張講義的 PKCanvasView：底圖是 content 的一部分，跟筆跡一起捲；
/// 內容高度跟著底圖或筆跡長：講義比螢幕高、或寫到底了，都能往下捲著寫
final class PaperCanvasView: PKCanvasView {
	private let backgroundView = UIImageView()
	/// 筆開著：要當第一回應者，系統筆工具列才會出來。
	/// 推概念頁再返回時 SwiftUI 不一定重叫 updateUIView，回到畫面上自己接回來
	var wantsToolPicker = false {
		didSet { syncFirstResponder() }
	}

	override func didMoveToWindow() {
		super.didMoveToWindow()
		syncFirstResponder()
	}

	private func syncFirstResponder() {
		guard window != nil else { return }
		if wantsToolPicker, !isFirstResponder {
			DispatchQueue.main.async { self.becomeFirstResponder() }
		} else if !wantsToolPicker, isFirstResponder {
			resignFirstResponder()
		}
	}

	var background: UIImage? {
		didSet {
			backgroundView.image = background
			backgroundColor = background == nil ? .white : .clear
			isOpaque = background == nil
			setNeedsLayout()
		}
	}

	/// 底圖在 content 座標裡佔的框（圈選時要連底圖一起裁）
	var backgroundFrame: CGRect { backgroundView.frame }

	override init(frame: CGRect) {
		super.init(frame: frame)
		backgroundView.contentMode = .scaleAspectFit
		insertSubview(backgroundView, at: 0)
	}

	required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

	override func layoutSubviews() {
		super.layoutSubviews()
		guard bounds.width > 0 else { return }
		var height: CGFloat = 0
		if let background {
			height = bounds.width * background.size.height / max(background.size.width, 1)
			backgroundView.frame = CGRect(x: 0, y: 0, width: bounds.width, height: height)
		} else {
			backgroundView.frame = .zero
		}
		// 最後一筆底下永遠留一整個螢幕的空白：寫到被筆工具列蓋住的地方，往上捲就寫得到
		let ink = drawing.bounds.isNull ? 0 : drawing.bounds.maxY
		contentSize = CGSize(width: bounds.width, height: max(height, ink + bounds.height, bounds.height * 1.5))
	}
}

/// PKCanvasView 包成 SwiftUI。一頁一個 PKDrawing，換頁就換 drawing；停筆存檔交給 CanvasStore。
/// 圈選模式時整個 canvas 不收觸控（interactive = false），筆畫才不會跟拉框打架
struct PencilCanvas: UIViewRepresentable {
	let pageID: UUID
	@ObservedObject var store: CanvasStore
	var interactive: Bool
	/// 筆開著才畫得出線、才出筆工具列；關著時手指捲紙看內容
	var penOn: Bool
	var background: UIImage?
	/// 讓 SwiftUI 那邊拿得到活的 canvas（圈選時要當下的筆跡與捲動位置，不能等存檔）
	let handle: CanvasHandle
	/// 捲動時回報位置：紙上的編號標記要跟著筆跡一起動
	var onScroll: (CGPoint) -> Void = { _ in }

	func makeUIView(context: Context) -> PaperCanvasView {
		let view = PaperCanvasView()
		handle.view = view
		view.background = background
		// 真機只收 Pencil，手掌撐在紙上不會畫出線；模擬器沒 Pencil，手指要能畫
		#if targetEnvironment(simulator)
		view.drawingPolicy = .anyInput
		#else
		view.drawingPolicy = .pencilOnly
		#endif
		view.backgroundColor = .white
		view.delegate = context.coordinator
		view.drawing = store.drawing(for: pageID)
		context.coordinator.pageID = pageID
		// 系統的筆工具列：跟著 canvas 當第一回應者出現。出不出來只看筆開關（updateUIView）
		let picker = PKToolPicker()
		picker.addObserver(view)
		context.coordinator.picker = picker
		return view
	}

	func updateUIView(_ view: PaperCanvasView, context: Context) {
		if context.coordinator.pageID != pageID {
			context.coordinator.pageID = pageID
			view.drawing = store.drawing(for: pageID)
			view.contentOffset = .zero
		}
		if view.background !== background { view.background = background }
		view.isUserInteractionEnabled = interactive
		// 圈選中也收工具列：那時紙不收觸控
		let writing = interactive && penOn
		view.drawingGestureRecognizer.isEnabled = writing
		// 手指也能畫（模擬器）時 PencilKit 把捲動改成兩指；筆收起來就該一指捲
		view.panGestureRecognizer.minimumNumberOfTouches = writing && view.drawingPolicy == .anyInput ? 2 : 1
		context.coordinator.picker?.setVisible(writing, forFirstResponder: view)
		view.wantsToolPicker = writing
	}

	func makeCoordinator() -> Coordinator { Coordinator(store: store, onScroll: onScroll) }

	final class Coordinator: NSObject, PKCanvasViewDelegate {
		let store: CanvasStore
		var pageID: UUID?
		var picker: PKToolPicker?
		let onScroll: (CGPoint) -> Void

		init(store: CanvasStore, onScroll: @escaping (CGPoint) -> Void) {
			self.store = store
			self.onScroll = onScroll
		}

		func scrollViewDidScroll(_ scrollView: UIScrollView) {
			// 換頁時 updateUIView 裡歸零也會觸發，那時候不能直接改 SwiftUI 狀態
			let offset = scrollView.contentOffset
			DispatchQueue.main.async { self.onScroll(offset) }
		}

		func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
			// 寫到底了紙要跟著長
			canvasView.setNeedsLayout()
			guard let pageID else { return }
			store.saveDrawing(canvasView.drawing, for: pageID)
		}
	}
}
