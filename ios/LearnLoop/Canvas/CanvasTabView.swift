import PencilKit
import SwiftUI
import UniformTypeIdentifiers

/// 畫布 tab：在 app 裡直接手寫（取代 GoodNotes 的第一步）。
/// 卡住時切「圈一題來問」拉一個框、按「問這一題」，框裡的筆跡走既有的 ingest；
/// 送出後紙留一邊、樹開另一邊，手不用離開紙。每個問過的塊在紙上留編號標記，點了切到那棵樹。
/// 樹欄可以拖寬、可以換邊（左撇子）
struct CanvasTabView: View {
	@ObservedObject var store: CardStore
	@StateObject private var canvas: CanvasStore
	@State private var pageIndex = 0
	@State private var importing = false
	private let handle = CanvasHandle()

	// 圈選
	@State private var selecting = false
	@State private var selection: CGRect?
	@State private var dragOrigin: CGPoint?
	/// 存 Task 是為了讓「取消」真的能中斷
	@State private var asking: Task<Void, Never>?
	@State private var errorText: String?

	// 樹欄
	@State private var openTopicID: UUID?
	@State private var path = NavigationPath()
	@State private var panelOnLeft: Bool
	@State private var panelWidth: CGFloat
	@State private var dragBaseWidth: CGFloat?

	private static let defaultPanelWidth: CGFloat = 440
	private static let panelRange: ClosedRange<CGFloat> = 320...640

	init(store: CardStore) {
		self.store = store
		_canvas = StateObject(wrappedValue: CanvasStore(dataDir: store.dataDir))
		_panelOnLeft = State(initialValue: store.canvasPanelOnLeft)
		let saved = store.canvasPanelWidth
		_panelWidth = State(initialValue: saved > 0 ? CGFloat(saved) : Self.defaultPanelWidth)
	}

	private var page: CanvasPage { canvas.pages[min(pageIndex, canvas.pages.count - 1)] }

	var body: some View {
		// 外層一個 NavigationStack：撐住頂端安全區（分頁列底下），概念 chip 的跳轉也走它（整頁推入，跟別的分頁一樣）
		NavigationStack(path: $path) {
			HStack(spacing: 0) {
				if openTopicID != nil, panelOnLeft {
					panel
					divider
				}
				paper
				if openTopicID != nil, !panelOnLeft {
					divider
					panel
				}
			}
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItemGroup(placement: .primaryAction) { pageControls }
			}
			.conceptDestinations(store: store) { path.append($0) }
		}
		.errorAlert($errorText)
		// 講義當底：PDF 每頁一張紙、圖片一張紙，插在目前頁後面
		.fileImporter(isPresented: $importing, allowedContentTypes: [.pdf, .image]) { result in
			do {
				pageIndex = try canvas.importFile(from: try result.get(), after: pageIndex)
			} catch {
				errorText = error.localizedDescription
			}
		}
	}

	// MARK: - 紙

	private var paper: some View {
		PencilCanvas(
			pageID: page.id, store: canvas, interactive: !selecting,
			background: canvas.backgroundImage(for: page), handle: handle)
			.overlay { blockMarks }
			.overlay { if selecting { selectionLayer } }
			// 左上角：工具列跟 iPad 的分頁列同一排，放進去會被壓成圖示；底部又有系統筆工具列
			.overlay(alignment: .topLeading) { selectButton.padding(12) }
			.ignoresSafeArea(.keyboard)
	}

	/// 頁碼、翻頁、匯入，收在工具列右邊
	@ViewBuilder
	private var pageControls: some View {
		Button("上一頁", systemImage: "chevron.left") { pageIndex -= 1 }
			.disabled(pageIndex == 0)
		// 工具列跟分頁列同一排，位子少，頁碼只寫「1 / 3」
		Text("\(pageIndex + 1) / \(canvas.pages.count)")
			.font(.caption.monospacedDigit())
			.foregroundStyle(.secondary)
		Button("下一頁", systemImage: "chevron.right") { pageIndex += 1 }
			.disabled(pageIndex >= canvas.pages.count - 1)
		Button("新增頁", systemImage: "plus") { pageIndex = canvas.addPage(after: pageIndex) }
		Button("匯入講義", systemImage: "square.and.arrow.down") { importing = true }
	}

	/// 切「圈一題來問」模式
	private var selectButton: some View {
		Button {
			selecting.toggle()
			selection = nil
		} label: {
			Label(selecting ? "取消圈選" : "圈一題來問", systemImage: selecting ? "xmark" : "rectangle.dashed")
				.font(.subheadline.weight(.semibold))
				.padding(.horizontal, 6)
				.padding(.vertical, 4)
		}
		.buttonStyle(.borderedProminent)
		.buttonBorderShape(.capsule)
		.tint(selecting ? .secondary : .accentColor)
		.disabled(asking != nil)
	}

	// MARK: - 圈選

	/// 透明一層接拖曳畫框；框拉完在框下浮出「問這一題」
	private var selectionLayer: some View {
		ZStack(alignment: .topLeading) {
			Color.black.opacity(0.001)
				.contentShape(Rectangle())
				.gesture(
					DragGesture(minimumDistance: 4, coordinateSpace: .local)
						.onChanged { value in
							guard asking == nil else { return }
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
						.offset(x: max(0, selection.maxX - 140), y: selection.maxY + 8)
				}
			}
		}
	}

	private var askPill: some View {
		HStack(spacing: 8) {
			if let asking {
				ProgressView().controlSize(.small)
				Button("取消") { asking.cancel() }
					.font(.subheadline.weight(.semibold))
			} else {
				Button {
					ask()
				} label: {
					Label("問這一題", systemImage: "pencil.and.outline")
						.font(.subheadline.weight(.semibold))
				}
			}
		}
		.padding(.horizontal, 14)
		.padding(.vertical, 9)
		.background(.thinMaterial, in: Capsule())
		.overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.5)))
	}

	/// 框裡的筆跡鋪白底裁成圖，走統一入口。blockID 先產好，樹回來才對得上這一塊
	private func ask() {
		guard let selection, asking == nil else { return }
		guard store.hasProvider else {
			errorText = AIError.noAPIKey.localizedDescription
			return
		}
		let offset = handle.view?.contentOffset ?? .zero
		let rect = selection.offsetBy(dx: offset.x, dy: offset.y)
		let drawing = handle.view?.drawing ?? canvas.drawing(for: page.id)
		// PKDrawing 出來是透明背景，直接轉 JPEG 會變黑底；有講義底圖的話題目印在底圖上，
		// 他的過程寫在旁邊，兩個都要給模型看 —— 白底、底圖、筆跡三層疊起來再裁
		let ink = drawing.image(from: rect, scale: 2)
		let backgroundImage = handle.view?.background
		let backgroundFrame = handle.view?.backgroundFrame ?? .zero
		let image = UIGraphicsImageRenderer(size: rect.size).image { context in
			UIColor.white.setFill()
			context.fill(CGRect(origin: .zero, size: rect.size))
			backgroundImage?.draw(in: backgroundFrame.offsetBy(dx: -rect.minX, dy: -rect.minY))
			ink.draw(in: CGRect(origin: .zero, size: rect.size))
		}
		let blockID = UUID()
		let pageID = page.id
		asking = Task { @MainActor in
			defer { asking = nil }
			do {
				let id = try await store.ingest(text: "", image: image, blockID: blockID)
				canvas.addBlock(CanvasBlock(id: blockID, rect: rect, cardID: id), to: pageID)
				selecting = false
				self.selection = nil
				open(id)
			} catch {
				guard !AIClient.isCancellation(error) else { return }
				errorText = error.localizedDescription
			}
		}
	}

	// MARK: - 標記

	/// 每個問過的塊：淡色框＋左上編號。這一題藍、其他紅；點編號切到那棵樹。
	/// 框本身不吃觸控，筆照畫
	private var blockMarks: some View {
		let offset = handle.view?.contentOffset ?? .zero
		return ZStack(alignment: .topLeading) {
			ForEach(Array(page.blocks.enumerated()), id: \.element.id) { index, block in
				let rect = block.rect.offsetBy(dx: -offset.x, dy: -offset.y)
				let current = block.cardID == openTopicID
				let color: Color = current ? .accentColor : .red
				RoundedRectangle(cornerRadius: 6)
					.fill(color.opacity(0.06))
					.overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(color.opacity(current ? 0.6 : 0.3)))
					.frame(width: rect.width, height: rect.height)
					.offset(x: rect.minX, y: rect.minY)
					.allowsHitTesting(false)
				Button {
					open(block.cardID)
				} label: {
					Text("\(index + 1)")
						.font(.caption2.weight(.bold))
						.foregroundStyle(.white)
						.frame(width: 22, height: 22)
						.background(color, in: Circle())
						.shadow(radius: 2, y: 1)
				}
				.buttonStyle(.plain)
				.offset(x: rect.minX - 11, y: rect.minY - 11)
			}
		}
		// 撐滿紙、靠左上：overlay 預設置中，ZStack 只有內容那麼大的話整組會被推到中間
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
	}

	private func open(_ id: UUID) {
		openTopicID = id
	}

	// MARK: - 樹欄

	private var panel: some View {
		VStack(spacing: 0) {
			HStack(spacing: 10) {
				if let openTopicID, let hit = page.blocks.firstIndex(where: { $0.cardID == openTopicID }) {
					Text("第 \(pageIndex + 1) 頁 · 第 \(hit + 1) 塊")
				} else {
					Text("樹")
				}
				Spacer()
				Button(panelOnLeft ? "換到右邊" : "換到左邊", systemImage: "arrow.left.arrow.right") {
					panelOnLeft.toggle()
					store.canvasPanelOnLeft = panelOnLeft
				}
				Button("收起", systemImage: "xmark") { openTopicID = nil }
					.labelStyle(.iconOnly)
			}
			.font(.caption)
			.foregroundStyle(.secondary)
			.padding(.horizontal, 12)
			.padding(.vertical, 8)
			Divider()
			if let openTopicID {
				// 直接放樹；概念 chip 的跳轉走外層的 NavigationStack
				CardTreeView(topicID: openTopicID, store: store)
			}
		}
		.frame(width: panelWidth)
		.background(Color(.systemBackground))
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
