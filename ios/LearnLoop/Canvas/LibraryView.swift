import SwiftUI
import UniformTypeIdentifiers

/// 打開哪一份材料（全螢幕蓋上去）
struct MaterialRoute: Identifiable, Hashable {
	let id: UUID
}

/// 書架（照設計畫布的 B 版骨架）：左邊資料夾樹一層層展開，右邊是選中資料夾裡的子資料夾與材料封面。
/// 右邊之後（第 4 塊）上半會換成知識地圖，材料縮成下方一排
struct LibraryView: View {
	@ObservedObject var store: CardStore
	@StateObject private var canvas: CanvasStore
	/// 選中的資料夾；書架最上層用 shelfID 代表
	@State private var selection: UUID? = LibraryView.shelfID
	@State private var opened: MaterialRoute?
	/// 畫布裡的導覽：概念 chip、題目樹推在這上面
	@State private var materialPath = NavigationPath()
	@State private var importing = false
	@State private var naming: Naming?
	@State private var deleting: Deleting?
	@State private var errorText: String?
	/// 上次開著的材料只在第一次出現時打開
	@State private var restored = false
	@Environment(\.scenePhase) private var scenePhase

	static let shelfID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

	init(store: CardStore) {
		self.store = store
		_canvas = StateObject(wrappedValue: CanvasStore(dataDir: store.dataDir))
	}

	/// 目前資料夾：nil = 書架最上層
	private var folderID: UUID? { selection == Self.shelfID ? nil : selection }
	private var library: Library { canvas.library }

	var body: some View {
		NavigationSplitView {
			sidebar
		} detail: {
			NavigationStack { folderContent }
		}
		// 材料全螢幕打開（照 GoodNotes）：紙要整個畫面，左上「書架」回來
		.fullScreenCover(item: $opened, onDismiss: { materialPath = NavigationPath() }) { route in
			NavigationStack(path: $materialPath) {
				MaterialView(store: store, canvas: canvas, materialID: route.id, path: $materialPath)
					.toolbar {
						ToolbarItem(placement: .topBarLeading) {
							Button("書架", systemImage: "chevron.left") {
								canvas.flushSaves()
								opened = nil
							}
							.labelStyle(.titleAndIcon)
						}
					}
					.conceptDestinations(store: store) { materialPath.append($0) }
			}
		}
		.onAppear(perform: restore)
		// 慣用手問卷還開著時不能再蓋一層，答完才打開上次那份
		.onChange(of: store.handedness) { restore() }
		.onChange(of: scenePhase) { _, phase in
			if phase != .active { canvas.flushSaves() }
		}
		.fileImporter(isPresented: $importing, allowedContentTypes: [.pdf, .image]) { result in
			do {
				let material = try canvas.importMaterial(from: try result.get(), in: folderID)
				opened = MaterialRoute(id: material.id)
			} catch {
				errorText = error.localizedDescription
			}
		}
		.alert(naming?.title ?? "", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
			TextField("名稱", text: Binding(get: { naming?.text ?? "" }, set: { naming?.text = $0 }))
			Button("取消", role: .cancel) {}
			Button("好") { commitNaming() }
		}
		.confirmationDialog(
			deleting?.title ?? "", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
			titleVisibility: .visible
		) {
			Button("刪除", role: .destructive) { commitDelete() }
		} message: {
			Text("刪了就找不回來，裡面的筆跡也會一起刪")
		}
		.errorAlert($errorText)
	}

	/// 上次停在哪一頁（canvasPageID）→ 那份材料在哪個資料夾，打開它
	private func restore() {
		guard !restored, store.handedness != nil else { return }
		restored = true
		guard let pageID = UUID(uuidString: store.canvasPageID), let material = canvas.material(containing: pageID) else { return }
		selection = material.folderID ?? Self.shelfID
		opened = MaterialRoute(id: material.id)
	}

	// MARK: - 左：資料夾樹

	private struct FolderNode: Identifiable, Hashable {
		let id: UUID
		let name: String
		let children: [FolderNode]?
	}

	private func nodes(under parentID: UUID?) -> [FolderNode] {
		library.subfolders(of: parentID).map { folder in
			let children = nodes(under: folder.id)
			return FolderNode(id: folder.id, name: folder.name, children: children.isEmpty ? nil : children)
		}
	}

	private var sidebar: some View {
		List(selection: $selection) {
			Label("書架", systemImage: "books.vertical").tag(Self.shelfID)
			OutlineGroup(nodes(under: nil), children: \.children) { node in
				Label(node.name, systemImage: "folder").tag(node.id)
			}
		}
		.navigationTitle("書架")
	}

	// MARK: - 右：資料夾內容

	private var folderContent: some View {
		let folders = library.subfolders(of: folderID)
		let materials = library.materials(in: folderID)
		return ScrollView {
			if folders.isEmpty, materials.isEmpty {
				ContentUnavailableView("這裡還是空的", systemImage: "tray", description: Text("右上角「＋」可以新增資料夾、筆記本，或匯入 PDF 講義"))
					.padding(.top, 80)
			}
			LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 24)], spacing: 28) {
				ForEach(folders) { folder in
					Button { selection = folder.id } label: {
						tile(name: folder.name) {
							RoundedRectangle(cornerRadius: 10)
								.fill(Color.accentColor.opacity(0.12))
								.overlay(Image(systemName: "folder.fill").font(.system(size: 44)).foregroundStyle(Color.accentColor))
						}
					}
					.buttonStyle(.plain)
					.contextMenu { itemMenu(name: folder.name, rename: .folder(folder.id), delete: .folder(folder.id)) }
				}
				ForEach(materials) { material in
					Button { opened = MaterialRoute(id: material.id) } label: {
						tile(name: material.name) { cover(material) }
					}
					.buttonStyle(.plain)
					.contextMenu { itemMenu(name: material.name, rename: .material(material.id), delete: .material(material.id)) }
				}
			}
			.padding(28)
		}
		.background(Color(.systemGroupedBackground))
		.navigationTitle(folderID.flatMap { id in library.folders.first { $0.id == id }?.name } ?? "書架")
		.toolbar {
			Menu {
				Button("新資料夾", systemImage: "folder.badge.plus") { naming = Naming(kind: .newFolder, text: "新資料夾") }
				Button("新筆記本", systemImage: "book.closed") { naming = Naming(kind: .newNotebook, text: "筆記本") }
				Button("匯入 PDF", systemImage: "square.and.arrow.down") { importing = true }
			} label: {
				Label("新增", systemImage: "plus")
			}
		}
	}

	/// 封面格子：上面圖、下面名字，材料封面是第一頁縮圖
	private func tile(name: String, @ViewBuilder art: () -> some View) -> some View {
		VStack(spacing: 8) {
			art()
				.frame(height: 200)
				.frame(maxWidth: .infinity)
			Text(name)
				.font(.subheadline)
				.lineLimit(2)
				.multilineTextAlignment(.center)
		}
		.contentShape(Rectangle())
	}

	private func cover(_ material: Material) -> some View {
		Group {
			if let first = material.pages.first {
				Image(uiImage: canvas.thumbnail(for: first, width: 150))
					.resizable()
					.scaledToFit()
			} else {
				Color.white
			}
		}
		.clipShape(RoundedRectangle(cornerRadius: 6))
		.shadow(color: .black.opacity(0.15), radius: 3, y: 1)
	}

	@ViewBuilder
	private func itemMenu(name: String, rename: Item, delete: Item) -> some View {
		Button("改名", systemImage: "pencil") { naming = Naming(kind: .rename(rename), text: name) }
		Button("刪除", systemImage: "trash", role: .destructive) { deleting = Deleting(item: delete, name: name) }
	}

	// MARK: - 新增、改名、刪除

	private enum Item: Equatable {
		case folder(UUID)
		case material(UUID)
	}

	private struct Naming {
		enum Kind: Equatable {
			case newFolder, newNotebook
			case rename(Item)
		}
		let kind: Kind
		var text: String

		var title: String {
			switch kind {
			case .newFolder: "新資料夾"
			case .newNotebook: "新筆記本"
			case .rename: "改名"
			}
		}
	}

	private struct Deleting {
		let item: Item
		let name: String
		var title: String { "刪除「\(name)」？" }
	}

	private func commitNaming() {
		guard let naming else { return }
		let name = naming.text.trimmingCharacters(in: .whitespaces)
		guard !name.isEmpty else { return }
		switch naming.kind {
		case .newFolder:
			canvas.createFolder(named: name, in: folderID)
		case .newNotebook:
			let material = canvas.createNotebook(named: name, in: folderID)
			opened = MaterialRoute(id: material.id)
		case .rename(.folder(let id)):
			canvas.renameFolder(id, to: name)
		case .rename(.material(let id)):
			canvas.renameMaterial(id, to: name)
		}
	}

	private func commitDelete() {
		guard let deleting else { return }
		switch deleting.item {
		case .folder(let id):
			// 正在看的資料夾被刪了（或在它底下）就回書架
			if let selection, library.folderTree(id).contains(selection) { self.selection = Self.shelfID }
			canvas.deleteFolder(id)
		case .material(let id):
			canvas.deleteMaterial(id)
		}
	}
}
