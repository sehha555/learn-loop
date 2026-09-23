import PencilKit
import SwiftUI

/// 活的 PKCanvasView 的弱參考。圈選送出時讀 drawing／contentOffset／底圖用，復原／重做也從這拿
final class CanvasHandle {
	weak var view: PaperCanvasView?
}

/// 紙上的筆：三色原子筆、螢光筆、橡皮擦、套索。
/// 不用系統 PKToolPicker —— 它壓在紙底部一大塊、使用者收不掉；改在紙頂一條細工具列自己選
enum CanvasTool: Equatable {
	case pen(Int)
	case marker
	case eraser
	case lasso

	static let penColors: [UIColor] = [.black, .systemRed, .systemBlue]

	var pkTool: PKTool {
		switch self {
		case .pen(let index): PKInkingTool(.pen, color: Self.penColors[index], width: 3)
		case .marker: PKInkingTool(.marker, color: .systemYellow, width: 18)
		case .eraser: PKEraserTool(.vector)
		case .lasso: PKLassoTool()
		}
	}
}

/// 紙的白底＋淡橫線：跟內容一起捲，看得出寫到哪一行。墊講義的頁只留白底不畫線
private final class RuledLinesView: UIView {
	static let spacing: CGFloat = 36
	var showsLines = true {
		didSet { setNeedsDisplay() }
	}

	override init(frame: CGRect) {
		super.init(frame: frame)
		backgroundColor = .white
		contentMode = .redraw
		isUserInteractionEnabled = false
	}

	required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

	override func draw(_ rect: CGRect) {
		guard showsLines else { return }
		UIColor.systemGray5.setStroke()
		let path = UIBezierPath()
		var y = (rect.minY / Self.spacing).rounded(.down) * Self.spacing + Self.spacing
		while y <= rect.maxY {
			path.move(to: CGPoint(x: rect.minX, y: y))
			path.addLine(to: CGPoint(x: rect.maxX, y: y))
			y += Self.spacing
		}
		path.lineWidth = 1
		path.stroke()
	}
}

/// 底下墊一張講義（或淡橫線）的 PKCanvasView：底圖是 content 的一部分，跟筆跡一起捲；
/// 內容高度跟著底圖或筆跡長：講義比螢幕高、或寫到底了，都能往下捲著寫
final class PaperCanvasView: PKCanvasView {
	private let backgroundView = UIImageView()
	private let linesView = RuledLinesView()

	var background: UIImage? {
		didSet {
			backgroundView.image = background
			linesView.showsLines = background == nil
			setNeedsLayout()
		}
	}

	/// 底圖在 content 座標裡佔的框（圈選時要連底圖一起裁）
	var backgroundFrame: CGRect { backgroundView.frame }

	override init(frame: CGRect) {
		super.init(frame: frame)
		backgroundView.contentMode = .scaleAspectFit
		// PencilKit 不透明時會自己塗一層底色蓋住墊在下面的 view，所以畫布透明、白底交給 linesView
		backgroundColor = .clear
		isOpaque = false
		insertSubview(linesView, at: 0)
		insertSubview(backgroundView, at: 1)
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
		// 最後一筆底下永遠留一整個螢幕的空白：寫到底了往上捲就有地方繼續寫
		let ink = drawing.bounds.isNull ? 0 : drawing.bounds.maxY
		contentSize = CGSize(width: bounds.width, height: max(height, ink + bounds.height, bounds.height * 1.5))
		let lines = CGRect(origin: .zero, size: contentSize)
		if linesView.frame != lines { linesView.frame = lines }
	}
}

/// PKCanvasView 包成 SwiftUI。一頁一個 PKDrawing，換頁就換 drawing；停筆存檔交給 CanvasStore。
/// 圈選模式時整個 canvas 不收觸控（interactive = false），筆畫才不會跟拉框打架
struct PencilCanvas: UIViewRepresentable {
	let pageID: UUID
	@ObservedObject var store: CanvasStore
	var interactive: Bool
	/// 筆開著才畫得出線；關著時手指捲紙看內容
	var penOn: Bool
	var tool: CanvasTool
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
		view.delegate = context.coordinator
		view.drawing = store.drawing(for: pageID)
		view.tool = tool.pkTool
		context.coordinator.pageID = pageID
		context.coordinator.tool = tool
		return view
	}

	func updateUIView(_ view: PaperCanvasView, context: Context) {
		if context.coordinator.pageID != pageID {
			context.coordinator.pageID = pageID
			view.drawing = store.drawing(for: pageID)
			view.contentOffset = .zero
		}
		if view.background !== background { view.background = background }
		if context.coordinator.tool != tool {
			context.coordinator.tool = tool
			view.tool = tool.pkTool
		}
		view.isUserInteractionEnabled = interactive
		let writing = interactive && penOn
		view.drawingGestureRecognizer.isEnabled = writing
		// 手指也能畫（模擬器）時 PencilKit 把捲動改成兩指；筆收起來就該一指捲
		view.panGestureRecognizer.minimumNumberOfTouches = writing && view.drawingPolicy == .anyInput ? 2 : 1
	}

	func makeCoordinator() -> Coordinator { Coordinator(store: store, onScroll: onScroll) }

	final class Coordinator: NSObject, PKCanvasViewDelegate {
		let store: CanvasStore
		var pageID: UUID?
		var tool: CanvasTool?
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
