import PencilKit
import SwiftUI

/// 讓 SwiftUI 那邊拿得到活的 UIKit 畫布：整疊頁（捲到某頁、圈選時找是哪一頁），
/// 以及最後寫過的那一頁（復原／重做送給它）
final class CanvasHandle {
	weak var stack: PageStackView?
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
	override class var layerClass: AnyClass { CAShapeLayer.self }
	private var lines: CAShapeLayer { layer as! CAShapeLayer }

	var showsLines = true {
		didSet { setNeedsLayout() }
	}
	/// 頁縮放多少倍，線距跟著縮放
	var scale: CGFloat = 1 {
		didSet { if scale != oldValue { setNeedsLayout() } }
	}

	override init(frame: CGRect) {
		super.init(frame: frame)
		// 線用向量畫：頁放大很多倍時，自己畫的點陣圖一頁就要幾百 MB
		isUserInteractionEnabled = false
		lines.fillColor = nil
		lines.lineWidth = 1
		lines.actions = ["path": NSNull()]
	}

	required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

	override func layoutSubviews() {
		super.layoutSubviews()
		lines.strokeColor = UIColor.systemGray5.cgColor
		guard showsLines else {
			lines.path = nil
			return
		}
		let path = CGMutablePath()
		let spacing = CanvasPage.lineSpacing * scale
		for y in stride(from: spacing, to: bounds.height, by: spacing) {
			path.move(to: CGPoint(x: 0, y: y))
			path.addLine(to: CGPoint(x: bounds.width, y: y))
		}
		lines.path = path
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

/// 固定大小的一頁：底下墊講義（或淡橫線）的 PKCanvasView。自己不捲，捲動交給外面整疊頁（PageStackView）；
/// 用 PencilKit 自己的 zoomScale 縮放到畫面寬度，筆跡座標永遠是頁內座標、放大也清楚
final class PaperCanvasView: PKCanvasView {
	private let backgroundView = UIImageView()
	private let linesView = RuledLinesView()

	let pageID: UUID
	let pageSize: CGSize
	/// 開始寫（筆或圖形）時通知外面：復原要送給最後寫過的那一頁
	var onUse: (() -> Void)?

	var background: UIImage? {
		didSet {
			backgroundView.image = background
			linesView.showsLines = background == nil && ruled
			setNeedsLayout()
		}
	}

	var ruled = true {
		didSet { linesView.showsLines = background == nil && ruled }
	}

	/// 頁顯示成幾倍大（頁寬 768pt，螢幕比較寬就放大）
	var scale: CGFloat = 1 {
		didSet {
			guard scale != oldValue else { return }
			minimumZoomScale = scale
			maximumZoomScale = scale
			zoomScale = scale
			contentSize = CGSize(width: pageSize.width * scale, height: pageSize.height * scale)
			setNeedsLayout()
		}
	}

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

	init(pageID: UUID, pageSize: CGSize) {
		self.pageID = pageID
		self.pageSize = pageSize
		super.init(frame: .zero)
		// scale 的 didSet 只在值變了才設 contentSize；剛好 1 倍時要先有
		contentSize = pageSize
		isScrollEnabled = false
		pinchGestureRecognizer?.isEnabled = false
		showsVerticalScrollIndicator = false
		showsHorizontalScrollIndicator = false
		contentInsetAdjustmentBehavior = .never
		// 頁一定跟原檔同比例，直接撐滿
		backgroundView.contentMode = .scaleToFill
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
	/// 手勢給的是放大後的座標，除回頁內座標
	@objc private func dragShape(_ gesture: TouchDownPan) {
		guard let shape, let touchDown = gesture.touchDown else { return }
		let start = CGPoint(x: touchDown.x / zoomScale, y: touchDown.y / zoomScale)
		let location = gesture.location(in: self)
		let point = CGPoint(x: location.x / zoomScale, y: location.y / zoomScale)
		switch gesture.state {
		case .began:
			onUse?()
			shapePreview.strokeColor = shape.color.cgColor
			shapePreview.lineWidth = max(shape.width, ShapeKind.minPointSize)
			shapePreview.setAffineTransform(CGAffineTransform(scaleX: zoomScale, y: zoomScale))
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
		// 擦除寬度是頁內大小，畫面上要乘上放大倍數
		let size = eraserWidth * zoomScale
		eraserRing.bounds.size = CGSize(width: size, height: size)
		eraserRing.layer.cornerRadius = size / 2
		eraserRing.center = gesture.location(in: self)
		eraserRing.isHidden = false
		bringSubviewToFront(eraserRing)
	}

	required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

	override func layoutSubviews() {
		super.layoutSubviews()
		let page = CGRect(x: 0, y: 0, width: pageSize.width * scale, height: pageSize.height * scale)
		if linesView.frame != page { linesView.frame = page }
		linesView.scale = scale
		backgroundView.frame = background.map { CanvasPage.backgroundRect(for: $0, pageWidth: pageSize.width * scale) } ?? .zero
	}

	/// 套用工具。writing = 筆拿著、不在圈選中
	func apply(tool: CanvasTool, settings: CanvasToolSettings, writing: Bool) {
		self.tool = tool.pkTool(settings)
		// 圖形工具時畫筆手勢讓給 shapePan
		if writing, case .shape(let kind, let color) = tool {
			drawingGestureRecognizer.isEnabled = false
			shape = (kind, CanvasTool.penColors[color], settings.penWidth)
		} else {
			drawingGestureRecognizer.isEnabled = writing
			shape = nil
		}
		eraserWidth = writing && tool == .eraser ? settings.eraserWidth : nil
	}
}
