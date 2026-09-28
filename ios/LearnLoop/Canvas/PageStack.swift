import PencilKit
import SwiftUI

/// 一份材料的所有頁上下排成一疊（照 GoodNotes 連續捲）。外層只負責上下捲，兩指捏合改放大倍數；
/// 每頁是固定大小的 PaperCanvasView，只有畫面附近的頁真的建出畫布，頁多也不卡
final class PageStackView: UIScrollView, UIScrollViewDelegate, PKCanvasViewDelegate {
	private let store: CanvasStore
	private(set) var pages: [CanvasPage] = []
	private var slots: [UUID: PageSlot] = [:]
	/// 放大倍數：1 = 頁寬貼齊畫面（左右留邊），兩指捏合最多放到 3 倍
	private var zoom: CGFloat = 1
	private var pinchBase: CGFloat = 1
	private var laidOutWidth: CGFloat = 0
	private var pendingScrollIndex: Int?

	private var tool: CanvasTool = .pen(0)
	private var settings = CanvasToolSettings()
	private var writing = true
	private var openCardID: UUID?

	var onCurrentPage: (Int) -> Void = { _ in }
	var onOpenBlock: (UUID) -> Void = { _ in }
	/// 開始在某頁寫字：復原要送給它
	var onUse: (PaperCanvasView) -> Void = { _ in }

	private static let margin: CGFloat = 24
	private static let gap: CGFloat = 20

	init(store: CanvasStore) {
		self.store = store
		super.init(frame: .zero)
		delegate = self
		backgroundColor = .systemGroupedBackground
		alwaysBounceVertical = true
		contentInsetAdjustmentBehavior = .never
		addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:))))
	}

	required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

	// MARK: - 外面給的狀態

	func setPages(_ new: [CanvasPage]) {
		guard new != pages else { return }
		let keep = Set(new.map(\.id))
		for (id, slot) in slots where !keep.contains(id) {
			slot.removeFromSuperview()
			slots[id] = nil
		}
		pages = new
		for page in pages {
			if let slot = slots[page.id] {
				slot.page = page
			} else {
				let slot = PageSlot(page: page)
				slot.onOpenBlock = { [weak self] in self?.onOpenBlock($0) }
				slots[page.id] = slot
				addSubview(slot)
			}
		}
		relayout()
	}

	func setTool(_ tool: CanvasTool, settings: CanvasToolSettings, writing: Bool) {
		guard tool != self.tool || settings != self.settings || writing != self.writing else { return }
		self.tool = tool
		self.settings = settings
		self.writing = writing
		for slot in slots.values { slot.canvas?.apply(tool: tool, settings: settings, writing: writing) }
		// 手指也能畫（模擬器）時筆拿著就改兩指捲；真機只收 Pencil，手指一直都能捲
		#if targetEnvironment(simulator)
		panGestureRecognizer.minimumNumberOfTouches = writing ? 2 : 1
		#endif
	}

	func setOpenCard(_ id: UUID?) {
		guard id != openCardID else { return }
		openCardID = id
		for slot in slots.values { slot.openCardID = id }
	}

	/// 捲到第幾頁（還沒排版就等排好再捲）
	func scroll(toPage index: Int) {
		guard pages.indices.contains(index), let slot = slots[pages[index].id], laidOutWidth > 0 else {
			pendingScrollIndex = index
			return
		}
		let maxY = max(0, contentSize.height - bounds.height)
		contentOffset.y = min(max(0, slot.frame.minY - Self.gap), maxY)
	}

	/// 圈選框（畫面座標）落在哪一頁、換成頁內座標；橫跨兩頁時算重疊比較多的那頁
	func hit(_ rect: CGRect) -> (page: CanvasPage, rect: CGRect, drawing: PKDrawing, background: UIImage?)? {
		let content = rect.offsetBy(dx: contentOffset.x, dy: contentOffset.y)
		let best = pages.compactMap { page -> (CanvasPage, PageSlot, CGFloat)? in
			guard let slot = slots[page.id] else { return nil }
			let overlap = slot.frame.intersection(content)
			return overlap.isNull ? nil : (page, slot, overlap.width * overlap.height)
		}.max { $0.2 < $1.2 }
		guard let (page, slot, _) = best else { return nil }
		let scale = slot.scale
		let local = slot.frame.intersection(content).offsetBy(dx: -slot.frame.minX, dy: -slot.frame.minY)
		let pageRect = CGRect(x: local.minX / scale, y: local.minY / scale, width: local.width / scale, height: local.height / scale)
		return (page, pageRect, slot.canvas?.drawing ?? store.drawing(for: page.id), store.backgroundImage(for: page))
	}

	// MARK: - 排版

	private var fitScale: CGFloat {
		let widest = pages.map(\.size.width).max() ?? CanvasPage.blankSize.width
		return max(0.1, (bounds.width - Self.margin * 2) / widest)
	}

	private func relayout() {
		guard bounds.width > 0 else { return }
		laidOutWidth = bounds.width
		let scale = fitScale * zoom
		var y = Self.gap
		var widest: CGFloat = 0
		for (index, page) in pages.enumerated() {
			guard let slot = slots[page.id] else { continue }
			slot.setNumber("\(index + 1) / \(pages.count)")
			let size = CGSize(width: page.size.width * scale, height: page.size.height * scale)
			widest = max(widest, size.width)
			slot.frame = CGRect(x: max(Self.margin, (bounds.width - size.width) / 2), y: y, width: size.width, height: size.height)
			slot.scale = scale
			y += size.height + Self.gap
		}
		contentSize = CGSize(width: max(bounds.width, widest + Self.margin * 2), height: y)
		updateLiveCanvases()
		if let index = pendingScrollIndex {
			pendingScrollIndex = nil
			scroll(toPage: index)
		}
	}

	override func layoutSubviews() {
		super.layoutSubviews()
		if bounds.width != laidOutWidth { relayout() }
	}

	/// 畫面上下各多一個螢幕高的頁建畫布，其他頁收掉（筆跡早就存了）
	private func updateLiveCanvases() {
		let live = bounds.insetBy(dx: 0, dy: -bounds.height)
		for page in pages {
			guard let slot = slots[page.id] else { continue }
			if slot.frame.intersects(live) {
				guard slot.canvas == nil else { continue }
				let canvas = PaperCanvasView(pageID: page.id, pageSize: page.size)
				#if targetEnvironment(simulator)
				canvas.drawingPolicy = .anyInput
				#else
				// 真機只收 Pencil，手掌撐在紙上不會畫出線
				canvas.drawingPolicy = .pencilOnly
				#endif
				canvas.ruled = page.ruled
				canvas.background = store.backgroundImage(for: page)
				canvas.drawing = store.drawing(for: page.id)
				canvas.delegate = self
				canvas.onUse = { [weak self, weak canvas] in
					guard let self, let canvas else { return }
					self.onUse(canvas)
				}
				canvas.apply(tool: tool, settings: settings, writing: writing)
				slot.canvas = canvas
			} else if slot.canvas != nil {
				slot.canvas = nil
			}
		}
	}

	private func reportCurrentPage() {
		let probe = contentOffset.y + bounds.height * 0.3
		guard let index = pages.firstIndex(where: { slots[$0.id].map { $0.frame.maxY + Self.gap > probe } ?? false }) else { return }
		onCurrentPage(index)
	}

	// MARK: - 捲動與縮放

	func scrollViewDidScroll(_ scrollView: UIScrollView) {
		updateLiveCanvases()
		reportCurrentPage()
	}

	/// 捏合時以兩指中間那點為準：放大後同一個內容點還在手指底下
	@objc private func pinch(_ gesture: UIPinchGestureRecognizer) {
		switch gesture.state {
		case .began:
			pinchBase = zoom
		case .changed:
			let focus = gesture.location(in: self)
			let onScreen = CGPoint(x: focus.x - contentOffset.x, y: focus.y - contentOffset.y)
			let old = zoom
			zoom = min(max(pinchBase * gesture.scale, 1), 3)
			guard zoom != old else { return }
			let ratio = zoom / old
			relayout()
			let maxX = max(0, contentSize.width - bounds.width)
			let maxY = max(0, contentSize.height - bounds.height)
			contentOffset = CGPoint(
				x: min(max(0, focus.x * ratio - onScreen.x), maxX),
				y: min(max(0, focus.y * ratio - onScreen.y), maxY))
		default:
			break
		}
	}

	// MARK: - 筆跡

	func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
		guard let canvas = canvasView as? PaperCanvasView else { return }
		store.saveDrawing(canvas.drawing, for: canvas.pageID)
	}

	func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
		guard let canvas = canvasView as? PaperCanvasView else { return }
		onUse(canvas)
	}
}

/// 一頁的位置：頁的陰影、頁碼、圈過的塊的記號；畫布在畫面附近才放進來
private final class PageSlot: UIView {
	var page: CanvasPage {
		didSet { if page.blocks != oldValue.blocks { rebuildMarks() } }
	}
	var scale: CGFloat = 1 {
		didSet {
			guard scale != oldValue else { return }
			canvas?.scale = scale
			rebuildMarks()
			setNeedsLayout()
		}
	}
	var openCardID: UUID? {
		didSet { if openCardID != oldValue { rebuildMarks() } }
	}
	var onOpenBlock: (UUID) -> Void = { _ in }

	var canvas: PaperCanvasView? {
		didSet {
			oldValue?.removeFromSuperview()
			guard let canvas else { return }
			canvas.scale = scale
			insertSubview(canvas, at: 0)
			setNeedsLayout()
		}
	}

	private var marks: [UIView] = []
	private let number = UILabel()

	init(page: CanvasPage) {
		self.page = page
		super.init(frame: .zero)
		backgroundColor = .white
		layer.shadowColor = UIColor.black.cgColor
		layer.shadowOpacity = 0.12
		layer.shadowRadius = 3
		layer.shadowOffset = CGSize(width: 0, height: 1)
		number.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
		number.textColor = .tertiaryLabel
		addSubview(number)
		rebuildMarks()
	}

	required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

	func setNumber(_ text: String) {
		number.text = text
		setNeedsLayout()
	}

	override func layoutSubviews() {
		super.layoutSubviews()
		canvas?.frame = bounds
		number.sizeToFit()
		number.frame.origin = CGPoint(x: bounds.width - number.frame.width - 10, y: bounds.height - number.frame.height - 8)
		bringSubviewToFront(number)
	}

	/// 每個問過的塊：淡色框＋左上編號。這一題藍、其他紅；點編號打開那棵樹。框本身不吃觸控，筆照畫
	private func rebuildMarks() {
		marks.forEach { $0.removeFromSuperview() }
		marks = []
		for (index, block) in page.blocks.enumerated() {
			let rect = CGRect(x: block.x * scale, y: block.y * scale, width: block.width * scale, height: block.height * scale)
			let color: UIColor = block.cardID == openCardID ? .tintColor : .systemRed
			let frame = UIView(frame: rect)
			frame.isUserInteractionEnabled = false
			frame.backgroundColor = color.withAlphaComponent(0.06)
			frame.layer.borderColor = color.withAlphaComponent(block.cardID == openCardID ? 0.6 : 0.3).cgColor
			frame.layer.borderWidth = 1
			frame.layer.cornerRadius = 6
			let button = UIButton(type: .system)
			button.frame = CGRect(x: rect.minX - 11, y: rect.minY - 11, width: 22, height: 22)
			button.backgroundColor = color
			button.layer.cornerRadius = 11
			button.setTitle("\(index + 1)", for: .normal)
			button.setTitleColor(.white, for: .normal)
			button.titleLabel?.font = .systemFont(ofSize: 11, weight: .bold)
			let cardID = block.cardID
			button.addAction(UIAction { [weak self] _ in self?.onOpenBlock(cardID) }, for: .touchUpInside)
			addSubview(frame)
			addSubview(button)
			marks += [frame, button]
		}
	}
}

/// PageStackView 包成 SwiftUI
struct PageStack: UIViewRepresentable {
	let pages: [CanvasPage]
	@ObservedObject var store: CanvasStore
	/// 圈選中整疊不收觸控，筆畫才不會跟拉框打架
	var interactive: Bool
	var penOn: Bool
	var tool: CanvasTool
	var settings: CanvasToolSettings
	var openCardID: UUID?
	let handle: CanvasHandle
	var onCurrentPage: (Int) -> Void
	var onOpenBlock: (UUID) -> Void

	func makeUIView(context: Context) -> PageStackView {
		let view = PageStackView(store: store)
		handle.stack = view
		view.onUse = { [handle] in handle.view = $0 }
		return view
	}

	func updateUIView(_ view: PageStackView, context: Context) {
		// 回報頁碼是捲動時觸發的，那時候不能直接改 SwiftUI 狀態
		view.onCurrentPage = { index in DispatchQueue.main.async { onCurrentPage(index) } }
		view.onOpenBlock = onOpenBlock
		view.setPages(pages)
		view.isUserInteractionEnabled = interactive
		view.setTool(tool, settings: settings, writing: interactive && penOn)
		view.setOpenCard(openCardID)
	}
}
