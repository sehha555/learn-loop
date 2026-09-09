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

	// MARK: - 模型畫的圖

	/// 展開某個點時模型附的圖（中繼站畫的）。跟使用者附的圖分開存 —— 自己打的問題兩種都可能有
	func figureFileURL(_ cardID: UUID) -> URL {
		imagesDir.appendingPathComponent("\(cardID.uuidString)-figure.png")
	}

	func figure(for cardID: UUID) -> UIImage? {
		UIImage(contentsOfFile: figureFileURL(cardID).path)
	}

	func saveFigure(_ data: Data, for cardID: UUID) {
		try? data.write(to: figureFileURL(cardID), options: .atomic)
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
	/// - understanding: 問概念時他先寫的理解（可空）。有的話模型針對理解的破洞答、並記標籤
	/// - hintConcept: 在哪個概念頁問的，給模型當歸類提示
	/// - blockID: 畫布圈選送的才有——對到畫布上那一塊；是題目就存成 .canvas 樹
	func ingest(
		text: String, image: UIImage?, understanding: String? = nil, hintConcept: String? = nil,
		blockID: UUID? = nil
	) async throws -> UUID {
		var imageData: Data?
		if let image {
			guard let data = AIClient.jpeg(from: image) else { throw AIError.badImage }
			imageData = data
		}
		let result = try await ai.ingest(
			text: text, imageJPEG: imageData, understanding: understanding, hintConcept: hintConcept,
			knownConcepts: conceptNamesForPrompt(), knownChapters: knownChapters,
			knownSkills: allStuckSkills(), style: teachingStyle)
		var tree = Card(title: "", kind: .free)
		tree.blockID = blockID
		Self.apply(result, text: text, understanding: understanding, to: &tree)
		insert(tree)
		assignChapter(result.chapter, to: result.concepts)
		// 原始截圖留檔 —— 病歷卡要能看到「題目長什麼樣」；追問附圖也用同一套，key 是那張卡的 id
		if let imageData { saveImage(imageData, for: tree.id) }
		return tree.id
	}

	/// 根問題改了重送：整棵重生（種類、開場句、點、概念都可能換），id 與圖不變
	func reask(topicID: UUID, text: String) async throws {
		reasking.insert(topicID)
		defer { reasking.remove(topicID) }
		let imageData = try? Data(contentsOf: imageFileURL(topicID))
		let understanding = topics.first { $0.id == topicID }?.understanding
		let result = try await ai.ingest(
			text: text, imageJPEG: imageData, understanding: understanding, hintConcept: nil,
			knownConcepts: conceptNamesForPrompt(), knownChapters: knownChapters,
			knownSkills: allStuckSkills(), style: teachingStyle)
		guard let index = topics.firstIndex(where: { $0.id == topicID }) else { return }
		Self.apply(result, text: text, understanding: understanding, to: &topics[index])
		save()
		assignChapter(result.chapter, to: result.concepts)
	}

	/// 模型回覆寫進樹的根。ingest 新建與 reask 重生共用，兩邊的欄位對應不會走岔。
	/// 種類看兩件事：是不是題目、是不是畫布圈來的（tree.blockID 先設好）——重生時 blockID 還在，種類才不會掉回 .topic
	private static func apply(
		_ result: AIClient.Ingested, text: String, understanding: String?, to tree: inout Card
	) {
		tree.title = result.title
		tree.body = result.status
		tree.kind = result.isProblem ? (tree.blockID == nil ? .topic : .canvas) : .free
		tree.children = result.points.map(\.card)
		tree.concepts = result.concepts
		tree.situation = result.parsedSituation
		tree.transcript = result.transcript
		// 題目：清單預覽用的題目原文；提問：他打的那句（只貼圖沒打字就用模型取的名字）
		tree.problem = result.isProblem
			? (result.problem.isEmpty ? nil : Card.stripProblemNumber(result.problem))
			: (text.isEmpty ? result.title : text)
		tree.fallbackNote = result.fallbackNote
		tree.asked = text.isEmpty ? nil : text
		tree.stuckStep = result.isProblem ? result.stuckStep : nil
		let written = understanding?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		tree.understanding = written.isEmpty ? nil : written
		// 標籤只在有證據時記：題目要真的栽了（stuckStep ≥ 1，blank 題模型有時會硬給）；
		// 提問要他有寫理解（沒寫就沒有東西可診斷，硬給只會污染統計）
		let skill = result.stuckSkill?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		let evidenced = result.isProblem ? (result.stuckStep ?? 0) > 0 : !written.isEmpty
		tree.stuckSkill = (evidenced && !skill.isEmpty) ? skill : nil
	}
}
