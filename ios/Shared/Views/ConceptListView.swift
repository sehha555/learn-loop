import SwiftUI

/// 全部概念的總覽。上段「該回頭看的」：卡過的照最後一次卡的日期排，越近越前面，
/// 每列帶「和誰一起出現」—— 概念是連在一起卡的，入口就要看得到連結。
/// 下段其他概念照出現次數收在後面。
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
				let review = concepts
					.filter { store.isRepeated(stuckCount: $0.stuck) }
					.sorted {
						(store.lastStuckDate($0.name) ?? .distantPast)
							> (store.lastStuckDate($1.name) ?? .distantPast)
					}
				let rest = concepts.filter { !store.isRepeated(stuckCount: $0.stuck) }
				List {
					if !review.isEmpty {
						Section("該回頭看的") {
							ForEach(review, id: \.name) { item in
								reviewRow(item)
							}
						}
					}
					if !rest.isEmpty {
						Section(review.isEmpty ? "" : "其他") {
							ForEach(rest, id: \.name) { item in
								NavigationLink(value: item.name) {
									HStack {
										Text(item.name)
										Spacer()
										Text(countLabel(item))
											.font(.subheadline)
											.foregroundStyle(.secondary)
									}
								}
							}
						}
					}
				}
			}
		}
		.navigationTitle("概念")
	}

	/// 「3 題 · 2 點」—— 題目與知識點分開數，哪邊是 0 就不寫
	private func countLabel(_ item: (name: String, appearances: Int, stuck: Int, notes: Int))
		-> String
	{
		var parts: [String] = []
		if item.appearances > 0 { parts.append("\(item.appearances) 題") }
		if item.notes > 0 { parts.append("\(item.notes) 點") }
		return parts.joined(separator: " · ")
	}

	/// 該回頭看的一列：紅概念名＋一起出現的夥伴，右邊次數＋最後一次卡的日期
	private func reviewRow(_ item: (name: String, appearances: Int, stuck: Int, notes: Int))
		-> some View
	{
		NavigationLink(value: item.name) {
			HStack(alignment: .firstTextBaseline) {
				VStack(alignment: .leading, spacing: 2) {
					Text(item.name)
						.foregroundStyle(.red)
					let related = store.relatedConcepts(to: item.name).prefix(2)
					if !related.isEmpty {
						Text("和 \(related.joined(separator: "、")) 一起出現")
							.font(.caption)
							.foregroundStyle(.secondary)
					}
				}
				Spacer()
				VStack(alignment: .trailing, spacing: 2) {
					Text("卡 \(item.stuck) 次")
						.font(.subheadline)
						.foregroundStyle(.red)
					if let date = store.lastStuckDate(item.name) {
						Text("最後一次 \(date.formatted(.dateTime.month().day()))")
							.font(.caption2)
							.foregroundStyle(.tertiary)
					}
				}
			}
		}
	}
}
