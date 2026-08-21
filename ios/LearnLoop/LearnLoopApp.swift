import SwiftUI

/// 只為了接 background URLSession 的喚醒：app 被砍掉後系統把結果送回來時會走這裡
final class AppDelegate: NSObject, UIApplicationDelegate {
	func application(
		_ application: UIApplication,
		handleEventsForBackgroundURLSession identifier: String,
		completionHandler: @escaping () -> Void
	) {
		AITransport.background.backgroundCompletion = completionHandler
	}
}

@main
struct LearnLoopApp: App {
	@UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
	@StateObject private var store = CardStore()

	init() {
		// 主 app 的模型請求交給系統背景跑 —— 送出後切回 GoodNotes 也不會斷
		AIClient.transport = .background
	}

	var body: some Scene {
		WindowGroup {
			// 題目和概念是兩個平等的視角，用 tab 一點就切 ——
			// 藏在 toolbar 按鈕裡要推頁面進出，概念那頁就不會有人去看
			TabView {
				TopicListView(store: store)
					.tabItem { Label("題目", systemImage: "list.bullet") }
				AskTabView(store: store)
					.tabItem { Label("概念", systemImage: "tag") }
			}
			// 舊題補抄題目原文，背景跑、跑完清單自己更新
			.task { if store.hasProvider { await store.backfillProblems() } }
			// 從分享浮層回到主 app 時，樹可能已經被改過
			.onReceive(
				NotificationCenter.default.publisher(
					for: UIApplication.willEnterForegroundNotification)
			) { _ in store.load() }
		}
	}
}
