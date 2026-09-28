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
	/// 拉直線、方框、圓；第二個值是用哪一色的筆（沿用上次選的筆）
	case shape(ShapeKind, Int)

	static let penColors: [UIColor] = [.black, .systemRed, .systemBlue]

	var isShape: Bool {
		if case .shape = self { true } else { false }
	}

	func pkTool(_ settings: CanvasToolSettings) -> PKTool {
		switch self {
		// 圖形不走 PencilKit 畫筆手勢（見 PaperCanvasView.shapePan），給筆只是佔位
		case .pen(let index), .shape(_, let index):
			PKInkingTool(.pen, color: Self.penColors[index], width: settings.penWidth)
		case .marker: PKInkingTool(.marker, color: .systemYellow, width: 18)
		case .eraser: PKEraserTool(settings.eraseArea ? .bitmap : .vector, width: settings.eraserWidth)
		case .lasso: PKLassoTool()
		}
	}
}

/// 工具的粗細等設定，三色筆共用一個粗細。存偏好，換工具不會重設
struct CanvasToolSettings: Equatable {
	static let penWidthRange: ClosedRange<CGFloat> = 1...12
	static let eraserWidthRange: ClosedRange<CGFloat> = 4...60

	var penWidth: CGFloat = 3.5
	/// 橡皮擦：false＝碰到整筆消失，true＝只擦掉圈到的那一塊
	var eraseArea = false
	var eraserWidth: CGFloat = 20
}

/// 圖形工具畫的形狀。拉的起點到終點當對角線（直線就是兩端點）
enum ShapeKind: CaseIterable {
	case line, rect, ellipse

	var systemImage: String {
		switch self {
		case .line: "line.diagonal"
		case .rect: "rectangle"
		case .ellipse: "circle"
		}
	}

	var label: String {
		switch self {
		case .line: "直線"
		case .rect: "方框"
		case .ellipse: "圓"
		}
	}

	/// 畫布即時渲染會把點大小 2pt 以下的筆畫整條略過（drawing.image() 卻畫得出來），
	/// 手寫筆最輕的筆壓也記成約 3pt，所以細筆的圖形墊到 3
	static let minPointSize: CGFloat = 3

	/// 拖的當下的預覽：直接畫幾何形狀，不用每一步都做出筆畫
	func previewPath(from start: CGPoint, to end: CGPoint) -> CGPath {
		switch self {
		case .line:
			let path = CGMutablePath()
			path.move(to: start)
			path.addLine(to: end)
			return path
		case .rect: return CGPath(rect: Self.box(start, end), transform: nil)
		case .ellipse: return CGPath(ellipseIn: Self.box(start, end), transform: nil)
		}
	}

	/// 拉完放手時轉成筆畫，之後跟手寫的一樣能擦、能圈、能存。
	/// PKStrokePath 是 B-spline，會把轉角磨圓，所以方框拆成四條直線
	func strokes(from start: CGPoint, to end: CGPoint, color: UIColor, width: CGFloat) -> [PKStroke] {
		let box = Self.box(start, end)
		switch self {
		case .line:
			return [Self.stroke([start, end], color: color, width: width)]
		case .rect:
			let corners = [
				CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
				CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY),
			]
			return corners.indices.map { Self.stroke([corners[$0], corners[($0 + 1) % 4]], color: color, width: width) }
		case .ellipse:
			let points = (0...64).map { step -> CGPoint in
				let angle = CGFloat(step) / 64 * 2 * .pi
				return CGPoint(x: box.midX + box.width / 2 * cos(angle), y: box.midY + box.height / 2 * sin(angle))
			}
			return [Self.stroke(points, color: color, width: width)]
		}
	}

	/// 起點到終點當對角線的框
	private static func box(_ start: CGPoint, _ end: CGPoint) -> CGRect {
		CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
	}

	/// 直線段中間補點：只有兩個控制點的 B-spline 畫不出東西
	private static func stroke(_ points: [CGPoint], color: UIColor, width: CGFloat) -> PKStroke {
		var path = points
		if points.count == 2 {
			path = (0...16).map { i in
				let t = CGFloat(i) / 16
				return CGPoint(x: points[0].x + (points[1].x - points[0].x) * t, y: points[0].y + (points[1].y - points[0].y) * t)
			}
		}
		let size = max(width, minPointSize)
		let controlPoints = path.enumerated().map { index, location in
			PKStrokePoint(
				location: location, timeOffset: TimeInterval(index) * 0.01, size: CGSize(width: size, height: size),
				opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
		}
		return PKStroke(ink: PKInkingTool(.pen, color: color, width: width).ink, path: PKStrokePath(controlPoints: controlPoints, creationDate: Date()))
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

/// pan 要拖過一段距離（有時還慢半拍）才認得出來，那時筆已經離起點一段；直接記下筆尖碰到紙的位置當起點
private final class TouchDownPan: UIPanGestureRecognizer {
	private(set) var touchDown: CGPoint?

	override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
		super.touchesBegan(touches, with: event)
		touchDown = touches.first?.location(in: view)
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

	/// 拿著橡皮擦時的擦除寬度，其他工具是 nil。擦的當下在筆尖畫一個這麼大的圈：
	/// iPad Air 的 Pencil 不支援懸停，下筆前看不到範圍，至少擦的時候看得到
	var eraserWidth: CGFloat?
	private let eraserRing = UIView()

	/// 拿著圖形工具時要畫的形狀、顏色、粗細，其他工具是 nil（這時 shapePan 關掉）
	var shape: (kind: ShapeKind, color: UIColor, width: CGFloat)? {
		didSet { shapePan.isEnabled = shape != nil }
	}
	private let shapePan = TouchDownPan()
	private let shapePreview = CAShapeLayer()

	override init(frame: CGRect) {
		super.init(frame: frame)
		backgroundView.contentMode = .scaleAspectFit
		// PencilKit 不透明時會自己塗一層底色蓋住墊在下面的 view，所以畫布透明、白底交給 linesView
		backgroundColor = .clear
		isOpaque = false
		insertSubview(linesView, at: 0)
		insertSubview(backgroundView, at: 1)
		eraserRing.isUserInteractionEnabled = false
		eraserRing.isHidden = true
		eraserRing.backgroundColor = UIColor.systemGray.withAlphaComponent(0.12)
		eraserRing.layer.borderColor = UIColor.systemGray.cgColor
		eraserRing.layer.borderWidth = 1.5
		addSubview(eraserRing)
		drawingGestureRecognizer.addTarget(self, action: #selector(trackEraser(_:)))
		shapePreview.fillColor = nil
		shapePreview.lineCap = .round
		// 獨立的 layer 改 path 會自帶 0.25 秒動畫，預覽要跟手
		shapePreview.actions = ["path": NSNull()]
		layer.addSublayer(shapePreview)
		shapePan.addTarget(self, action: #selector(dragShape(_:)))
		shapePan.maximumNumberOfTouches = 1
		shapePan.isEnabled = false
		#if !targetEnvironment(simulator)
		// 真機跟畫筆一樣只收 Pencil，手指照樣捲紙
		shapePan.allowedTouchTypes = [UITouch.TouchType.pencil.rawValue as NSNumber]
		#endif
		addGestureRecognizer(shapePan)
	}

	/// 拉圖形：拖的時候畫預覽，放手轉成筆畫加進 drawing
	@objc private func dragShape(_ gesture: TouchDownPan) {
		guard let shape, let start = gesture.touchDown else { return }
		let point = gesture.location(in: self)
		switch gesture.state {
		case .began:
			shapePreview.strokeColor = shape.color.cgColor
			shapePreview.lineWidth = max(shape.width, ShapeKind.minPointSize)
		case .changed:
			shapePreview.path = shape.kind.previewPath(from: start, to: point)
		default:
			if gesture.state == .ended, hypot(point.x - start.x, point.y - start.y) > 4 {
				var drawing = self.drawing
				drawing.strokes += shape.kind.strokes(from: start, to: point, color: shape.color, width: shape.width)
				replaceDrawing(with: drawing)
			}
			shapePreview.path = nil
		}
	}

	/// 自己改 drawing 不會進 PencilKit 的復原堆疊，這裡補註冊：復原換回舊的，重做再換回來
	private func replaceDrawing(with new: PKDrawing) {
		let old = drawing
		undoManager?.registerUndo(withTarget: self) { $0.replaceDrawing(with: old) }
		drawing = new
	}

	@objc private func trackEraser(_ gesture: UIGestureRecognizer) {
		guard let eraserWidth, gesture.state == .began || gesture.state == .changed else {
			eraserRing.isHidden = true
			return
		}
		// 自己是 scroll view，location(in: self) 就是 content 座標，圈跟著內容捲
		eraserRing.bounds.size = CGSize(width: eraserWidth, height: eraserWidth)
		eraserRing.layer.cornerRadius = eraserWidth / 2
		eraserRing.center = gesture.location(in: self)
		eraserRing.isHidden = false
		bringSubviewToFront(eraserRing)
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
	var settings: CanvasToolSettings
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
		view.tool = tool.pkTool(settings)
		context.coordinator.pageID = pageID
		context.coordinator.tool = tool
		context.coordinator.settings = settings
		return view
	}

	func updateUIView(_ view: PaperCanvasView, context: Context) {
		if context.coordinator.pageID != pageID {
			context.coordinator.pageID = pageID
			view.drawing = store.drawing(for: pageID)
			view.contentOffset = .zero
		}
		if view.background !== background { view.background = background }
		if context.coordinator.tool != tool || context.coordinator.settings != settings {
			context.coordinator.tool = tool
			context.coordinator.settings = settings
			view.tool = tool.pkTool(settings)
		}
		view.isUserInteractionEnabled = interactive
		let writing = interactive && penOn
		// 圖形工具時畫筆手勢讓給 shapePan
		if writing, case .shape(let kind, let color) = tool {
			view.drawingGestureRecognizer.isEnabled = false
			view.shape = (kind, CanvasTool.penColors[color], settings.penWidth)
		} else {
			view.drawingGestureRecognizer.isEnabled = writing
			view.shape = nil
		}
		view.eraserWidth = writing && tool == .eraser ? settings.eraserWidth : nil
		// 手指也能畫（模擬器）時 PencilKit 把捲動改成兩指；筆收起來就該一指捲
		view.panGestureRecognizer.minimumNumberOfTouches = writing && view.drawingPolicy == .anyInput ? 2 : 1
	}

	func makeCoordinator() -> Coordinator { Coordinator(store: store, onScroll: onScroll) }

	final class Coordinator: NSObject, PKCanvasViewDelegate {
		let store: CanvasStore
		var pageID: UUID?
		var tool: CanvasTool?
		var settings: CanvasToolSettings?
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
