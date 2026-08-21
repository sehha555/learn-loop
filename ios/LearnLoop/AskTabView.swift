import SwiftUI

/// 概念 tab：上面是概念總覽，底下一格可以問 —— 唸書時沒題目也能問，
/// 答案長成樹、歸到模型判的概念下
struct AskTabView: View {
	@ObservedObject var store: CardStore
	@State private var path = NavigationPath()

	var body: some View {
		NavigationStack(path: $path) {
			ConceptListView(store: store)
				.conceptDestinations(store: store) { path.append($0) }
				.safeAreaInset(edge: .bottom) {
					AskBar(store: store, placeholder: "貼題目截圖，或直接問…") { path.append($0) }
						.padding(.horizontal)
						.padding(.vertical, 8)
						.background(.bar)
				}
		}
	}
}
