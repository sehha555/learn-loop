import Foundation
import UIKit

// MARK: - 截圖、問答流程
extension CardStore {
	// MARK: - 題目截圖

	func imageFileURL(_ topicID: UUID) -> URL {
		imagesDir.appendingPathComponent("\(topicID.uuidString).jpg")
	}

	/// 題目原始截圖。nil 代表這題是存圖功能上線前貼的，沒圖可看。
	/// 知識點問題附的圖也用同一套，key 是那張卡的 id
	func image(for topicID: UUID) -> UIImage? {
		UIImage(contentsOfFile: imageFileURL(topicID).path)
	}

	func saveImage(_ data: Data, for cardID: UUID) {
		try? data.write(to: imageFileURL(cardID), options: .atomic)
	}

	/// 「題目原文」欄上線前拍的舊題，拿存著的截圖補抄一次。一次只跑一題（不要同時開
	/// 好幾個 claude），失敗就跳過、下次啟動再試；沒圖的舊題沒得補，維持名字當大標
	func backfillProblems() async {
		guard !backfilling else { return }
		backfilling = true
		defer { backfilling = false }
		for topic in problems where topic.problem == nil {
			await reextractProblem(topicID: topic.id)
		}
	}

	/// 拿存著的截圖抄一次題目原文。沒圖、抄不出來就不動
	func reextractProblem(topicID: UUID) async {
		guard let data = try? Data(contentsOf: imageFileURL(topicID)),
			let text = try? await ai.extractProblem(imageJPEG: data), !text.isEmpty,
			let index = topics.firstIndex(where: { $0.id == topicID })
		else { return }
		topics[index].problem = Card.stripProblemNumber(text)
		save()
	}

	/// 統一入口：題目截圖、直接問、概念頁問、分享進來的圖全走這一條。
	/// 模型判斷是題目還是提問，題目存成題目樹（kind topic）、提問存成問答樹（kind free），
	/// 都掛在模型判的概念下。回傳新樹的 id 讓畫面跳進去。
	/// - hintConcept: 在哪個概念頁問的，給模型當歸類提示
	func ingest(text: String, image: UIImage?, hintConcept: String? = nil) async throws -> UUID {
		var imageData: Data?
		if let image {
			guard let data = AIClient.jpeg(from: image) else { throw AIError.badImage }
			imageData = data
		}
		let result = try await ai.ingest(
			text: text, imageJPEG: imageData, hintConcept: hintConcept,
			knownConcepts: conceptNamesForPrompt(), style: teachingStyle)
		var tree = Card(title: "", kind: .free)
		Self.apply(result, text: text, to: &tree)
		insert(tree)
		// 原始截圖留檔 —— 病歷卡要能看到「題目長什麼樣」；追問附圖也用同一套，key 是那張卡的 id
		if let imageData { saveImage(imageData, for: tree.id) }
		return tree.id
	}

	/// 根問題改了重送：整棵重生（種類、開場句、點、概念都可能換），id 與圖不變
	func reask(topicID: UUID, text: String) async throws {
		let imageData = try? Data(contentsOf: imageFileURL(topicID))
		let result = try await ai.ingest(
			text: text, imageJPEG: imageData, hintConcept: nil,
			knownConcepts: conceptNamesForPrompt(), style: teachingStyle)
		guard let index = topics.firstIndex(where: { $0.id == topicID }) else { return }
		Self.apply(result, text: text, to: &topics[index])
		save()
	}

	/// 模型回覆寫進樹的根。ingest 新建與 reask 重生共用，兩邊的欄位對應不會走岔
	private static func apply(_ result: AIClient.Ingested, text: String, to tree: inout Card) {
		tree.title = result.title
		tree.body = result.status
		tree.kind = result.isProblem ? .topic : .free
		tree.children = result.points.map(\.card)
		tree.concepts = result.concepts
		tree.situation = result.parsedSituation
		tree.transcript = result.transcript
		// 題目：清單預覽用的題目原文；提問：他打的那句（只貼圖沒打字就用模型取的名字）
		tree.problem = result.isProblem
			? (result.problem.isEmpty ? nil : Card.stripProblemNumber(result.problem))
			: (text.isEmpty ? result.title : text)
		tree.fallbackNote = result.fallbackNote
	}
}
