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
			guard let data = try? Data(contentsOf: imageFileURL(topic.id)) else { continue }
			guard let text = try? await ai.extractProblem(imageJPEG: data),
				!text.isEmpty,
				let index = topics.firstIndex(where: { $0.id == topic.id })
			else { continue }
			topics[index].problem = Card.stripProblemNumber(text)
			save()
		}
	}

	/// 抄得不乾淨的那題，重新抄一次
	func reextractProblem(topicID: UUID) async {
		guard let data = try? Data(contentsOf: imageFileURL(topicID)),
			let text = try? await ai.extractProblem(imageJPEG: data), !text.isEmpty,
			let index = topics.firstIndex(where: { $0.id == topicID })
		else { return }
		topics[index].problem = Card.stripProblemNumber(text)
		save()
	}

	/// 直接問（沒貼題目）：問題自成一棵樹，歸到模型判的概念下，回傳新樹 id。
	/// 可以帶一張圖（課本的圖、筆記的一段）；圖會抄成文字存進樹，之後追問才有脈絡
	func ask(question: String, image: UIImage? = nil) async throws -> UUID {
		var imageData: Data?
		if let image {
			guard let data = AIClient.jpeg(from: image) else { throw AIError.badImage }
			imageData = data
		}
		let result = try await ai.ask(
			question: question, imageJPEG: imageData,
			knownConcepts: conceptNamesForPrompt(), style: teachingStyle)
		let tree = Card(
			title: result.title,
			body: result.status,
			kind: .free,
			children: result.points.map { Card(title: $0.title, kind: $0.kind) },
			concepts: result.concepts,
			transcript: result.transcript,
			problem: question.isEmpty ? result.title : question,
			fallbackNote: result.fallbackNote
		)
		insert(tree)
		if let imageData { saveImage(imageData, for: tree.id) }
		return tree.id
	}

	/// 貼上 / 分享進來的完整流程：概念清單 → 診斷 → 組題目 → 存檔，回傳新題 id。
	/// 主 app 和分享浮層共用這一份，免得改流程時漏掉其中一邊。
	func analyze(image: UIImage) async throws -> UUID {
		// JPEG 只編碼一次，上傳和存檔共用同一份
		guard let imageData = AIClient.jpeg(from: image) else { throw AIError.badImage }
		let result = try await ai
			.diagnose(imageJPEG: imageData, knownConcepts: conceptNamesForPrompt())
		let topic = Card(
			title: result.title,
			body: result.status,
			kind: .topic,
			children: result.points.map { Card(title: $0.title, kind: $0.kind) },
			concepts: result.concepts,
			situation: result.parsedSituation,
			transcript: result.transcript,
			problem: result.problem.isEmpty ? nil : Card.stripProblemNumber(result.problem),
			fallbackNote: result.fallbackNote
		)
		insert(topic)
		// 原始截圖留檔 —— 病歷卡要能看到「題目長什麼樣」
		try? imageData.write(to: imageFileURL(topic.id), options: .atomic)
		return topic.id
	}
}
