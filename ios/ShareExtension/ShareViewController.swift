import SwiftUI
import UniformTypeIdentifiers

/// 分享浮層的進入點。從 GoodNotes 圈選後按分享，跳出來的就是這個。
@objc(ShareViewController)
final class ShareViewController: UIViewController {
	override func viewDidLoad() {
		super.viewDidLoad()

		let root = ShareRootView(
			loadImage: { [weak self] in await self?.loadSharedImage() },
			onDone: { [weak self] in
				self?.extensionContext?.completeRequest(returningItems: nil)
			}
		)
		let host = UIHostingController(rootView: root)
		addChild(host)
		host.view.frame = view.bounds
		host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
		view.addSubview(host.view)
		host.didMove(toParent: self)
	}

	/// 從分享進來的附件裡取出圖片
	private func loadSharedImage() async -> UIImage? {
		let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
			.flatMap { $0.attachments ?? [] }
		for provider in providers
		where provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
			let item = try? await provider.loadItem(
				forTypeIdentifier: UTType.image.identifier)
			switch item {
			case let image as UIImage: return image
			case let url as URL:
				if let data = try? Data(contentsOf: url) { return UIImage(data: data) }
			case let data as Data:
				return UIImage(data: data)
			default: continue
			}
		}
		return nil
	}
}

// MARK: - 浮層的內容

struct ShareRootView: View {
	let loadImage: () async -> UIImage?
	let onDone: () -> Void

	@StateObject private var store = CardStore()
	@State private var phase: Phase = .working

	private enum Phase {
		case working
		case ready(UUID)
		case failed(String)
	}

	var body: some View {
		NavigationStack {
			Group {
				switch phase {
				case .working:
					VStack(spacing: 12) {
						ProgressView()
						Text("看你寫了什麼…").foregroundStyle(.secondary)
					}
					.frame(maxWidth: .infinity, maxHeight: .infinity)

				case let .ready(topicID):
					CardTreeView(topicID: topicID, store: store)

				case let .failed(message):
					ContentUnavailableView {
						Label("沒辦法處理", systemImage: "exclamationmark.triangle")
					} description: {
						Text(message)
					}
				}
			}
			.toolbar {
				ToolbarItem(placement: .confirmationAction) {
					Button("完成", action: onDone)
				}
			}
		}
		.task { await run() }
	}

	private func run() async {
		guard let image = await loadImage() else {
			phase = .failed("分享進來的東西不是圖片")
			return
		}
		do {
			let result = try await ClaudeClient(apiKey: store.apiKey).diagnose(image: image)
			let topic = Card(
				title: result.title,
				body: result.diagnosis,
				children: result.points.map { Card(title: $0) }
			)
			store.insert(topic)
			phase = .ready(topic.id)
		} catch {
			phase = .failed(error.localizedDescription)
		}
	}
}
