import SwiftUI

/// 概念總覽頁的路由值。主 app 的導覽由 path 驅動，
/// 所有跳頁都必須走 path —— 混用舊式 NavigationLink(destination:) 會讓
/// 新頁被插到它下面，看起來像「點了沒反應，要按返回才會出現」。
struct ConceptListRoute: Hashable {}

/// 主 app 和分享浮層的 NavigationStack 都要認得這三種頁：
/// UUID → 題目的樹、概念名（String）→ 病歷卡、ConceptListRoute → 概念總覽。
/// 收在一處，新增路由才不會漏掉浮層那邊。
extension View {
	func conceptDestinations(store: CardStore) -> some View {
		navigationDestination(for: UUID.self) { id in
			CardTreeView(topicID: id, store: store)
				.navigationTitle(store.topics.first { $0.id == id }?.title ?? "")
				.navigationBarTitleDisplayMode(.inline)
		}
		.navigationDestination(for: String.self) { name in
			ConceptPageView(name: name, store: store)
		}
		.navigationDestination(for: ConceptListRoute.self) { _ in
			ConceptListView(store: store)
		}
	}
}

/// 一個概念的病歷卡：卡了幾次、每次是哪題、當時的診斷、你當時問了什麼。
///
/// 整頁純 code、零 AI 呼叫 —— 這一頁的價值在「你卡的紀錄」，
/// 這些事實 app 本來就存著，秒開、永遠準。概念的教學解釋留給之後的 wiki 連結。
struct ConceptPageView: View {
	let name: String
	@ObservedObject var store: CardStore

	/// 截圖進頁時從磁碟讀一次放這，body 重算不再碰 I/O
	@State private var images: [UUID: UIImage] = [:]
	/// 點縮圖放大看的那一題
	@State private var zoomTopic: Card?

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 20) {
				header
				recordsSection
				relatedSection
			}
			.padding()
		}
		.navigationTitle(name)
		.navigationBarTitleDisplayMode(.inline)
		.task(id: name) {
			for topic in store.topics(withConcept: name) where images[topic.id] == nil {
				images[topic.id] = store.image(for: topic.id)
			}
		}
		.sheet(item: $zoomTopic) { topic in
			if let image = images[topic.id] {
				Image(uiImage: image)
					.resizable()
					.scaledToFit()
					.padding()
			}
		}
	}

	// MARK: - 各區塊

	/// 概念名已經在導覽列上，這裡只放次數。
	/// 卡過時兩個數字都給 ——「卡 3 次但出現 5 題」跟「卡 3 次只出現 3 題」是不同的事
	@ViewBuilder
	private var header: some View {
		let appearances = store.appearanceCount(name)
		let stuck = store.stuckCount(name)
		if store.isRepeated(stuckCount: stuck) {
			Text("卡過 \(stuck) 次 · 出現在 \(appearances) 題裡")
				.font(.footnote.weight(.semibold))
				.foregroundStyle(.red)
		} else {
			Text("出現在 \(appearances) 題裡")
				.font(.footnote)
				.foregroundStyle(.secondary)
		}
	}

	private var recordsSection: some View {
		VStack(alignment: .leading, spacing: 14) {
			Text("卡的紀錄（新到舊）")
				.font(.caption2)
				.foregroundStyle(.tertiary)
			ForEach(store.topics(withConcept: name)) { topic in
				record(topic)
			}
		}
	}

	/// 一筆病歷：題目名點了跳回那棵樹，縮圖點了放大，其餘是當時的事實
	private func record(_ topic: Card) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			NavigationLink(value: topic.id) {
				HStack(alignment: .firstTextBaseline, spacing: 8) {
					Text(Card.Kind.topic.mark)
						.font(.caption2.weight(.bold))
						.foregroundStyle(Card.Kind.topic.tint)
						.frame(width: 14)
					Text(topic.title)
						.font(.subheadline.weight(.semibold))
						.foregroundStyle(.primary)
						.multilineTextAlignment(.leading)
					Spacer(minLength: 8)
					Text(topic.createdAt.formatted(.dateTime.month().day()))
						.font(.caption2)
						.foregroundStyle(.tertiary)
				}
				.frame(maxWidth: .infinity, alignment: .leading)
			}
			.buttonStyle(.plain)

			// 左邊一條線，跟樹頁同一套視覺 —— 底下的內容都掛在這筆題目下
			HStack(alignment: .top, spacing: 0) {
				TreeLine()

				VStack(alignment: .leading, spacing: 8) {
					if let image = images[topic.id] {
						Button {
							zoomTopic = topic
						} label: {
							// scaledToFit 整張圖完整可見 —— fill 會為了填滿寬度
							// 把上下裁掉，題目截圖被裁就什麼都看不出來了
							Image(uiImage: image)
								.resizable()
								.scaledToFit()
								.frame(maxHeight: 180)
								.clipShape(RoundedRectangle(cornerRadius: 8))
						}
						.buttonStyle(.plain)
						.frame(maxWidth: .infinity, alignment: .leading)
					}
					if let body = topic.body {
						MathText(text: "診斷：\(body)", font: .callout, size: 16)
							.foregroundStyle(.primary.opacity(0.85))
					}
					ForEach(topic.children.filter { $0.kind == .custom }) { question in
						HStack(alignment: .firstTextBaseline, spacing: 6) {
							Text(Card.Kind.custom.mark)
								.font(.caption2.weight(.bold))
								.foregroundStyle(Card.Kind.custom.tint)
							Text("你問過：\(question.title)")
								.font(.callout)
								.foregroundStyle(.primary.opacity(0.85))
								.fixedSize(horizontal: false, vertical: true)
						}
					}
					if topic.expandedDescendants > 0 {
						Text("點開過 \(topic.expandedDescendants) 個步驟")
							.font(.caption)
							.foregroundStyle(.secondary)
					}
				}
			}
		}
	}

	@ViewBuilder
	private var relatedSection: some View {
		let related = store.relatedConcepts(to: name)
		if !related.isEmpty {
			VStack(alignment: .leading, spacing: 8) {
				Text("相關概念（同一題一起出現過的）")
					.font(.caption2)
					.foregroundStyle(.tertiary)
				FlowLayout(spacing: 5) {
					ForEach(related, id: \.self) { other in
						NavigationLink(value: other) {
							ConceptChip(name: other, repeated: store.isRepeated(other))
						}
						.buttonStyle(.plain)
					}
				}
			}
		}
	}
}

/// 概念的小膠囊標籤。卡過的紅色，其他灰色。樹頁和病歷卡共用。
struct ConceptChip: View {
	let name: String
	let repeated: Bool

	var body: some View {
		Text(name)
			.font(.caption2)
			.foregroundStyle(repeated ? Color.red : Color.secondary)
			.padding(.horizontal, 8)
			.padding(.vertical, 2)
			.overlay(
				Capsule().strokeBorder(
					repeated ? Color.red.opacity(0.5) : Color.secondary.opacity(0.35))
			)
	}
}

/// 全部概念的總覽：常卡的在最上面，點進去是病歷卡。
struct ConceptListView: View {
	@ObservedObject var store: CardStore

	var body: some View {
		Group {
			let concepts = store.allConcepts()
			if concepts.isEmpty {
				ContentUnavailableView {
					Label("還沒有概念", systemImage: "tag")
				} description: {
					Text("貼幾題之後，用到的概念會累積在這裡。")
				}
			} else {
				List(concepts, id: \.name) { item in
					NavigationLink(value: item.name) {
						HStack {
							Text(item.name)
							Spacer()
							if store.isRepeated(stuckCount: item.stuck) {
								Text("卡過 \(item.stuck) 次")
									.font(.subheadline)
									.foregroundStyle(.red)
							} else {
								Text("\(item.appearances) 題")
									.font(.subheadline)
									.foregroundStyle(.secondary)
							}
						}
					}
				}
			}
		}
		.navigationTitle("概念")
	}
}
