import PencilKit
import SwiftUI
import UniformTypeIdentifiers

/// 一份材料的畫布：在 app 裡直接手寫（取代 GoodNotes 的第一步），從書架點進來。
/// 卡住時切「圈一題來問」拉一個框、按 [解釋][批改][打字問]，框裡的筆跡走既有的 ingest；
/// 回來的講解卡片浮在紙上（預設）或固定在側邊一欄，放慣用手的反邊。
/// 每個問過的塊在紙上留編號標記，點了打開那張卡片。側欄可以拖寬、可以換邊
struct MaterialView: View {
	@ObservedObject var store: CardStore
	@ObservedObject var canvas: CanvasStore
	let materialID: UUID
	@State private var pageIndex = 0
	@State private var penOn: Bool
	@State private var tool: CanvasTool = .pen(0)
	@State private var settings = CanvasToolSettings()
	/// 再點一次已選中的筆：開粗細選單（值是哪一色的筆，popover 要掛在那顆上）
	@State private var penMenu: Int?
	@State private var eraserMenu = false
	/// 圖形沿用上次選的筆色；形狀記住上次選的
	@State private var lastPen = 0
	@State private var shapeKind: ShapeKind = .line
	@State private var shapeMenu = false
	@State private var importing = false
	@State private var overview = false
	/// 放 @State：書架那層重畫時這個 struct 會重建，handle 不能跟著換新（換了就連不到活的畫布）
	@State private var handle = CanvasHandle()

	// 圈選
	@State private var selecting = false
	@State private var selection: CGRect?
	@State private var dragOrigin: CGPoint?
	/// 存 Task 是為了讓「取消」真的能中斷
	@State private var asking: Task<Void, Never>?
	@State private var errorText: String?
	/// 按了 [打字問]：方框旁的按鈕換成輸入框
	@State private var typing = false
	@State private var typedQuestion = ""
	@FocusState private var typingFocused: Bool

	// 講解卡片
	@State private var openTopicID: UUID?
	@State private var floating: Bool
	/// 浮動卡片左上角在紙上的位置。nil = 還沒拖過，放慣用手反邊靠上
	@State private var cardOrigin: CGPoint?
	@State private var dragBaseOrigin: CGPoint?
	@State private var panelOnLeft: Bool
	@State private var panelWidth: CGFloat
	@State private var dragBaseWidth: CGFloat?

	private static let defaultPanelWidth: CGFloat = 440
	private static let panelRange: ClosedRange<CGFloat> = 320...640
	private static let floatingSize = CGSize(width: 400, height: 560)

	init(store: CardStore, canvas: CanvasStore, materialID: UUID) {
		self.store = store
		self.canvas = canvas
		self.materialID = materialID
		// 上次停在這份材料的哪一頁，一打開就捲到那裡
		let lastPage = canvas.material(materialID)?.pages.firstIndex { $0.id.uuidString == store.canvasPageID }
		_pageIndex = State(initialValue: lastPage ?? 0)
		_penOn = State(initialValue: store.canvasPenOn)
		var tools = CanvasToolSettings()
		if store.canvasPenWidth > 0 { tools.penWidth = CGFloat(store.canvasPenWidth) }
		if store.canvasEraserWidth > 0 { tools.eraserWidth = CGFloat(store.canvasEraserWidth) }
		tools.eraseArea = store.canvasEraseArea
		_settings = State(initialValue: tools)
		_panelOnLeft = State(initialValue: store.canvasPanelOnLeft)
		_floating = State(initialValue: store.canvasCardFloating)
		let saved = store.canvasPanelWidth
		_panelWidth = State(initialValue: saved > 0 ? CGFloat(saved) : Self.defaultPanelWidth)
	}

	private var pages: [CanvasPage] { canvas.material(materialID)?.pages ?? [] }

	var body: some View {
		HStack(spacing: 0) {
			if openTopicID != nil, !floating, panelOnLeft {
				panel
				divider
			}
			paper
			if openTopicID != nil, !floating, !panelOnLeft {
				divider
				panel
			}
		}
		.navigationTitle(canvas.material(materialID)?.name ?? "")
		.navigationBarTitleDisplayMode(.inline)
		.toolbar {
			ToolbarItemGroup(placement: .primaryAction) { pageControls }
		}
		.errorAlert($errorText)
		.sheet(isPresented: $overview) {
			PageOverview(canvas: canvas, materialID: materialID) { index in
				pageIndex = index
				handle.stack?.scroll(toPage: index)
			}
		}
		// initial：一打開就記下，沒捲動也知道下次要開這份
		.onChange(of: pageIndex, initial: true) {
			if pages.indices.contains(pageIndex) { store.canvasPageID = pages[pageIndex].id.uuidString }
		}
		.onDisappear { canvas.flushSaves() }
		// 講義當底：PDF 每頁一張紙、圖片一張紙，插在目前頁後面
		.fileImporter(isPresented: $importing, allowedContentTypes: [.pdf, .image]) { result in
			do {
				pageIndex = try canvas.insertFile(from: try result.get(), into: materialID, after: pageIndex)
				handle.stack?.scroll(toPage: pageIndex)
			} catch {
				errorText = error.localizedDescription
			}
		}
	}

	// MARK: - 紙

	private var paper: some View {
		PageStack(
			pages: pages, store: canvas, interactive: !selecting, penOn: penOn, tool: tool, settings: settings,
			openCardID: openTopicID, handle: handle, initialPage: pageIndex,
			onCurrentPage: { pageIndex = $0 }, onOpenBlock: { openTopicID = $0 })
			.overlay { if selecting { selectionLayer } }
			// 紙頂一條細工具列：頂端那排跟 iPad 的分頁列同一排，放不下
			.overlay(alignment: .top) { penBar.padding(.top, 2).padding(.horizontal, 12) }
			.ignoresSafeArea(.keyboard)
			// 放在 ignoresSafeArea 外面：鍵盤跳出來時這層變矮，卡片跟著往上讓，輸入框不被蓋住
			.overlay { if floating, let openTopicID { floatingCard(openTopicID) } }
	}

	/// 頁碼、翻頁、加頁、總覽，收在工具列右邊
	@ViewBuilder
	private var pageControls: some View {
		Button("上一頁", systemImage: "chevron.left") { handle.stack?.scroll(toPage: pageIndex - 1) }
			.disabled(pageIndex == 0)
		// 工具列跟分頁列同一排，位子少，頁碼只寫「1 / 3」
		Text("\(pageIndex + 1) / \(pages.count)")
			.font(.caption.monospacedDigit())
			.foregroundStyle(.secondary)
		Button("下一頁", systemImage: "chevron.right") { handle.stack?.scroll(toPage: pageIndex + 1) }
			.disabled(pageIndex >= pages.count - 1)
		// 加在這頁後面（照 GoodNotes）
		Menu {
			Button("橫線頁", systemImage: "line.3.horizontal") { addPage(ruled: true) }
			Button("空白頁", systemImage: "square") { addPage(ruled: false) }
			Button("插入 PDF 講義", systemImage: "square.and.arrow.down") { importing = true }
		} label: {
			Label("加頁", systemImage: "plus")
		}
		Button("頁面總覽", systemImage: "square.grid.2x2") { overview = true }
	}

	private func addPage(ruled: Bool) {
		pageIndex = canvas.addPage(to: materialID, after: pageIndex, ruled: ruled)
		handle.stack?.scroll(toPage: pageIndex)
	}

	/// 紙頂的細工具列（照 Derive）：拿筆／收起筆、三色筆、螢光筆、橡皮擦、套索、復原重做、圈一題。
	/// 筆收起來只剩「拿筆」和「圈一題」；圈選中只剩「取消圈選」
	private var penBar: some View {
		// 放得下就置中；樹欄開著放不下時筆那段左右滑，「圈一題」固定在右邊不被擠出去
		ViewThatFits(in: .horizontal) {
			barCapsule {
				penTools
				if !selecting { barDivider }
				selectButton
			}
			HStack(spacing: 6) {
				if !selecting {
					ScrollView(.horizontal, showsIndicators: false) { barCapsule { penTools } }
				}
				barCapsule { selectButton }
			}
		}
	}

	private func barCapsule(@ViewBuilder _ content: () -> some View) -> some View {
		HStack(spacing: 2, content: content)
			.padding(.horizontal, 6)
			.padding(.vertical, 4)
			.background(.regularMaterial, in: Capsule())
			.overlay(Capsule().strokeBorder(Color(.separator).opacity(0.4)))
			.shadow(color: .black.opacity(0.06), radius: 6, y: 2)
			.padding(.vertical, 8)
	}

	/// 筆那段；圈選中整段收掉只留「取消圈選」
	@ViewBuilder
	private var penTools: some View {
		if !selecting {
			barButton(penOn ? "收起筆" : "拿筆", systemImage: penOn ? "pencil.slash" : "pencil", selected: false) {
				penOn.toggle()
				store.canvasPenOn = penOn
			}
			if penOn {
				barDivider
				ForEach(CanvasTool.penColors.indices, id: \.self) { index in
					// 點大小跟著粗細：下筆前就看得出多粗、什麼色。已選中再點一次開粗細選單
					barButton("筆", systemImage: "pencil.tip", selected: tool == .pen(index),
						dot: Color(CanvasTool.penColors[index]), dotSize: dotSize(settings.penWidth)) {
						if tool == .pen(index) { penMenu = index } else { tool = .pen(index); lastPen = index }
					}
					.popover(isPresented: Binding(
						get: { penMenu == index }, set: { if !$0 { penMenu = nil } })) {
						penWidthMenu(color: Color(CanvasTool.penColors[index]))
					}
				}
				barButton("螢光筆", systemImage: "highlighter", selected: tool == .marker, dot: .yellow) {
					tool = .marker
				}
				// 點大小跟著擦除寬度；已選中再點一次開模式與大小
				barButton("橡皮擦", systemImage: "eraser", selected: tool == .eraser,
					dot: .gray, dotSize: 3 + settings.eraserWidth / 8) {
					if tool == .eraser { eraserMenu = true } else { tool = .eraser }
				}
				.popover(isPresented: $eraserMenu) { eraserOptions }
				barButton("套索", systemImage: "lasso", selected: tool == .lasso) { tool = .lasso }
				// 已選中再點一次換形狀
				barButton("圖形", systemImage: shapeKind.systemImage, selected: tool.isShape) {
					if tool.isShape { shapeMenu = true } else { tool = .shape(shapeKind, lastPen) }
				}
				.popover(isPresented: $shapeMenu) { shapeOptions }
				barDivider
				barButton("復原", systemImage: "arrow.uturn.backward", selected: false) {
					handle.view?.undoManager?.undo()
				}
				barButton("重做", systemImage: "arrow.uturn.forward", selected: false) {
					handle.view?.undoManager?.redo()
				}
			}
		}
	}

	/// 粗細換成工具列上的點大小（1pt → 約 4、12pt → 約 10）
	private func dotSize(_ width: CGFloat) -> CGFloat {
		3.5 + width * 0.55
	}

	/// 筆的粗細：拖滑桿調 pt，上面一段線即時畫成現在的粗細與顏色
	private func penWidthMenu(color: Color) -> some View {
		VStack(spacing: 12) {
			Capsule().fill(color).frame(width: 150, height: settings.penWidth)
				.frame(height: CanvasToolSettings.penWidthRange.upperBound)
			HStack(spacing: 10) {
				Slider(value: $settings.penWidth, in: CanvasToolSettings.penWidthRange, step: 0.5) { editing in
					if !editing { store.canvasPenWidth = Double(settings.penWidth) }
				}
				Text(String(format: "%.1f pt", settings.penWidth))
					.font(.caption.monospacedDigit())
					.foregroundStyle(.secondary)
					.frame(width: 46, alignment: .trailing)
			}
		}
		.padding(16)
		.frame(width: 260)
		.presentationCompactAdaptation(.popover)
	}

	/// 橡皮擦：整筆擦／局部擦，加拖滑桿調大小（上面一個圈是實際大小）
	private var eraserOptions: some View {
		VStack(spacing: 12) {
			Picker("擦法", selection: $settings.eraseArea) {
				Text("整筆擦").tag(false)
				Text("局部擦").tag(true)
			}
			.pickerStyle(.segmented)
			.onChange(of: settings.eraseArea) { store.canvasEraseArea = settings.eraseArea }
			Text(settings.eraseArea ? "只擦掉圈到的那一塊" : "碰到的那一筆整條消失")
				.font(.caption)
				.foregroundStyle(.secondary)
			Circle()
				.strokeBorder(Color.gray, lineWidth: 1.5)
				.background(Circle().fill(Color.gray.opacity(0.12)))
				.frame(width: settings.eraserWidth, height: settings.eraserWidth)
				.frame(height: CanvasToolSettings.eraserWidthRange.upperBound)
			HStack(spacing: 10) {
				Slider(value: $settings.eraserWidth, in: CanvasToolSettings.eraserWidthRange, step: 1) { editing in
					if !editing { store.canvasEraserWidth = Double(settings.eraserWidth) }
				}
				Text(String(format: "%.0f pt", settings.eraserWidth))
					.font(.caption.monospacedDigit())
					.foregroundStyle(.secondary)
					.frame(width: 46, alignment: .trailing)
			}
		}
		.padding(16)
		.frame(width: 260)
		.presentationCompactAdaptation(.popover)
	}

	/// 圖形：直線、方框、圓，顏色粗細跟著筆
	private var shapeOptions: some View {
		HStack(spacing: 4) {
			ForEach(ShapeKind.allCases, id: \.self) { kind in
				Button {
					shapeKind = kind
					tool = .shape(kind, lastPen)
					shapeMenu = false
				} label: {
					VStack(spacing: 4) {
						Image(systemName: kind.systemImage).font(.system(size: 20))
						Text(kind.label).font(.caption2)
					}
					.frame(width: 56, height: 52)
					.background(kind == shapeKind ? Color(.systemGray5) : .clear, in: RoundedRectangle(cornerRadius: 8))
				}
				.buttonStyle(.plain)
			}
		}
		.padding(8)
		.presentationCompactAdaptation(.popover)
	}

	/// 工具列上一顆圖示鈕：選中的墊灰底，筆類底下一個顏色點（筆的點大小跟著粗細）
	private func barButton(
		_ title: String, systemImage: String, selected: Bool, dot: Color? = nil, dotSize: CGFloat = 6,
		action: @escaping () -> Void
	) -> some View {
		Button(action: action) {
			Image(systemName: systemImage)
				.font(.system(size: 16, weight: .medium))
				.frame(width: 34, height: 30)
				.overlay(alignment: .bottomTrailing) {
					if let dot {
						Circle().fill(dot).frame(width: dotSize, height: dotSize).offset(x: -5, y: -1)
					}
				}
				.background(selected ? Color(.systemGray5) : .clear, in: RoundedRectangle(cornerRadius: 8))
		}
		.buttonStyle(.plain)
		.foregroundStyle(.primary)
		.accessibilityLabel(title)
	}

	private var barDivider: some View {
		Divider().frame(height: 20).padding(.horizontal, 4)
	}

	/// 切「圈一題來問」模式
	private var selectButton: some View {
		Button {
			selecting.toggle()
			selection = nil
			typing = false
		} label: {
			Label(selecting ? "取消圈選" : "圈一題來問", systemImage: selecting ? "xmark" : "rectangle.dashed")
				.font(.subheadline.weight(.semibold))
				.padding(.horizontal, 10)
				.padding(.vertical, 5)
				.foregroundStyle(selecting ? Color.primary : Color.white)
				.background(selecting ? Color(.systemGray5) : Color.accentColor, in: Capsule())
		}
		.buttonStyle(.plain)
		.disabled(asking != nil)
	}

	// MARK: - 圈選

	/// 透明一層接拖曳畫框；框拉完在框下浮出 [解釋][批改][打字問]
	private var selectionLayer: some View {
		ZStack(alignment: .topLeading) {
			Color.black.opacity(0.001)
				.contentShape(Rectangle())
				.gesture(
					DragGesture(minimumDistance: 4, coordinateSpace: .local)
						.onChanged { value in
							guard asking == nil else { return }
							typing = false
							let origin = dragOrigin ?? value.startLocation
							dragOrigin = origin
							selection = CGRect(
								x: min(origin.x, value.location.x), y: min(origin.y, value.location.y),
								width: abs(value.location.x - origin.x), height: abs(value.location.y - origin.y))
						}
						.onEnded { _ in dragOrigin = nil }
				)
			if let selection {
				Rectangle()
					.fill(Color.accentColor.opacity(0.06))
					.overlay(
						RoundedRectangle(cornerRadius: 4)
							.strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
					.frame(width: selection.width, height: selection.height)
					.offset(x: selection.minX, y: selection.minY)
					.allowsHitTesting(false)
				if selection.width > 40, selection.height > 24 {
					askPill
						.offset(x: max(0, selection.maxX - 300), y: selection.maxY + 8)
				}
			}
		}
	}

	/// 不讓模型猜他要什麼：同一段手寫可能要批改、也可能要解釋概念，多點一下比猜錯多等一次好
	private var askPill: some View {
		HStack(spacing: 8) {
			if let asking {
				ProgressView().controlSize(.small)
				Button("取消") { asking.cancel() }
			} else if typing {
				TextField("想問這塊的什麼…", text: $typedQuestion)
					.frame(width: 220)
					.focused($typingFocused)
					.onAppear { typingFocused = true }
					.onSubmit(askTyped)
				Button("送出", action: askTyped)
					.disabled(typedQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
				Button("返回") { typing = false }
					.foregroundStyle(.secondary)
			} else {
				Button("解釋") { ask(.explain) }
				Divider().frame(height: 18)
				Button("批改") { ask(.grade) }
				Divider().frame(height: 18)
				Button("打字問") { typing = true }
			}
		}
		.font(.subheadline.weight(.semibold))
		.padding(.horizontal, 14)
		.padding(.vertical, 9)
		.background(.thinMaterial, in: Capsule())
		.overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.5)))
	}

	private func askTyped() {
		let text = typedQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !text.isEmpty else { return }
		ask(.question, text: text)
	}

	/// 框裡的筆跡鋪白底裁成圖，走統一入口。blockID 先產好，樹回來才對得上這一塊
	private func ask(_ mode: AIClient.AskMode, text: String = "") {
		guard let selection, asking == nil else { return }
		guard store.hasProvider else {
			errorText = AIError.noAPIKey.localizedDescription
			return
		}
		// 框換成「落在哪一頁、頁內哪一塊」：座標都是頁內的，跟縮放、捲到哪無關
		guard let hit = handle.stack?.hit(selection) else { return }
		let rect = hit.rect
		// PKDrawing 出來是透明背景，直接轉 JPEG 會變黑底；有講義底圖的話題目印在底圖上，
		// 他的過程寫在旁邊，兩個都要給模型看 —— 白底、底圖、筆跡三層疊起來再裁
		let image = canvas.render(hit.page, drawing: hit.drawing, rect: rect, scale: 1, background: hit.background)
		let blockID = UUID()
		let pageID = hit.page.id
		asking = Task { @MainActor in
			defer { asking = nil }
			do {
				let id = try await store.ingest(text: text, image: image, blockID: blockID, mode: mode)
				canvas.addBlock(CanvasBlock(id: blockID, rect: rect, cardID: id), to: pageID)
				selecting = false
				self.selection = nil
				typing = false
				typedQuestion = ""
				openTopicID = id
			} catch {
				guard !AIClient.isCancellation(error) else { return }
				errorText = error.localizedDescription
			}
		}
	}

	// MARK: - 講解卡片

	/// 標題列：第幾頁第幾塊、浮動／固定切換、收起。固定時多一顆換邊
	private var cardHeader: some View {
		HStack(spacing: 10) {
			if let openTopicID, let at = pages.firstIndex(where: { $0.blocks.contains { $0.cardID == openTopicID } }),
				let hit = pages[at].blocks.firstIndex(where: { $0.cardID == openTopicID }) {
				Text("第 \(at + 1) 頁 · 第 \(hit + 1) 塊")
			} else {
				Text("講解")
			}
			Spacer()
			if !floating {
				Button(panelOnLeft ? "換到右邊" : "換到左邊", systemImage: "arrow.left.arrow.right") {
					panelOnLeft.toggle()
				}
			}
			Button(floating ? "固定在側邊" : "浮動", systemImage: floating ? "sidebar.left" : "rectangle.on.rectangle") {
				floating.toggle()
				store.canvasCardFloating = floating
			}
			// 字跟其他鈕一樣大：只放 X 太小，看不出能收。收起後點紙上的編號再打開
			Button("收起", systemImage: "xmark") { openTopicID = nil }
		}
		.font(.caption)
		.foregroundStyle(.secondary)
		.padding(.horizontal, 12)
		.padding(.vertical, 8)
	}

	private var panel: some View {
		VStack(spacing: 0) {
			cardHeader
			Divider()
			if let openTopicID {
				// 概念 chip 的跳轉走外層的 NavigationStack
				ExplainCard(store: store, topicID: openTopicID).id(openTopicID)
			}
		}
		.frame(width: panelWidth)
		.background(Color(.systemBackground))
	}

	/// 浮在紙上的卡片：拖標題列移動。外面這層不吃觸控，筆照樣能在卡片外寫
	private func floatingCard(_ topicID: UUID) -> some View {
		GeometryReader { geo in
			let size = CGSize(
				width: min(Self.floatingSize.width, geo.size.width - 24),
				height: min(Self.floatingSize.height, geo.size.height - 24))
			let origin = clamped(cardOrigin ?? defaultCardOrigin(in: geo.size, card: size), in: geo.size, card: size)
			VStack(spacing: 0) {
				cardHeader
					.contentShape(Rectangle())
					.gesture(
						DragGesture()
							.onChanged { value in
								let base = dragBaseOrigin ?? origin
								dragBaseOrigin = base
								cardOrigin = clamped(
									CGPoint(x: base.x + value.translation.width, y: base.y + value.translation.height),
									in: geo.size, card: size)
							}
							.onEnded { _ in dragBaseOrigin = nil }
					)
				Divider()
				ExplainCard(store: store, topicID: topicID).id(topicID)
			}
			.frame(width: size.width, height: size.height)
			.background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 14))
			.clipShape(RoundedRectangle(cornerRadius: 14))
			.overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color(.separator).opacity(0.5)))
			.shadow(color: .black.opacity(0.15), radius: 14, y: 4)
			.offset(x: origin.x, y: origin.y)
		}
	}

	/// 慣用手的反邊、工具列底下
	private func defaultCardOrigin(in area: CGSize, card: CGSize) -> CGPoint {
		CGPoint(x: panelOnLeft ? 12 : area.width - card.width - 12, y: 56)
	}

	/// 整張卡留在紙的範圍內（鍵盤跳出來時範圍變矮，卡片往上讓）
	private func clamped(_ point: CGPoint, in area: CGSize, card: CGSize) -> CGPoint {
		CGPoint(
			x: min(max(point.x, 0), max(area.width - card.width, 0)),
			y: min(max(point.y, 0), max(area.height - card.height, 0)))
	}

	/// 紙和樹之間的把手：拖了改樹欄寬度，放手存起來
	private var divider: some View {
		Rectangle()
			.fill(Color(.systemGroupedBackground))
			.frame(width: 14)
			.overlay(
				Capsule()
					.fill(Color.secondary.opacity(0.5))
					.frame(width: 4, height: 44))
			.contentShape(Rectangle())
			.gesture(
				DragGesture()
					.onChanged { value in
						let base = dragBaseWidth ?? panelWidth
						dragBaseWidth = base
						let delta = panelOnLeft ? value.translation.width : -value.translation.width
						panelWidth = min(max(base + delta, Self.panelRange.lowerBound), Self.panelRange.upperBound)
					}
					.onEnded { _ in
						dragBaseWidth = nil
						store.canvasPanelWidth = Double(panelWidth)
					}
			)
	}
}
