import Foundation
import UIKit

enum AIError: LocalizedError {
	case noAPIKey
	case badImage
	case http(Int, String)
	case badResponse

	var errorDescription: String? {
		switch self {
		case .noAPIKey: "還沒設定 API key，到主 app 的設定貼上"
		case .badImage: "這張圖讀不出來"
		case let .http(code, message): "伺服器回 \(code)：\(message.prefix(300))"
		case .badResponse: "回應格式看不懂"
		}
	}
}

/// 打模型 API。
///
/// 支援 Google Gemini（有免費額度）和 Anthropic Claude，看 key 長什麼樣自動判斷 ——
/// 設定頁不用多一個選單，貼哪把就用哪家。
struct AIClient {
	let apiKey: String

	enum Provider {
		case google
		case anthropic
	}

	var provider: Provider {
		apiKey.hasPrefix("sk-ant-") ? .anthropic : .google
	}

	private var model: String {
		switch provider {
		case .google: "gemini-3.5-flash"
		case .anthropic: "claude-opus-5"
		}
	}

	// MARK: - 診斷一張截圖

	struct Point: Decodable {
		let kind: Card.Kind
		let title: String
	}

	struct Diagnosis: Decodable {
		let title: String
		/// stuck / done / blank —— 現在只用來除錯，UI 不顯示
		let situation: String
		let status: String
		let points: [Point]
	}

	/// 這段調過幾輪，兩個關鍵：
	/// 一是先分辨他「卡住 / 寫完 / 還沒動筆」—— 卡住的頻率遠高於寫錯，
	/// 只做批改的話會對著還沒寫完的算式講「你第三行錯了」。
	/// 二是 points 要有不同種類，全生成疑問句的話「想補充」「有雷」出不來。
	private static let diagnosePrompt = """
	你是坐在旁邊的助教，正在看使用者手寫的東西。

	第一步，先判斷他現在處在哪個狀態（situation）：
	- "stuck"：寫到一半停住了。有塗改、有問號、算式沒寫完、同一步重寫好幾次。
	- "done"：寫完了，有完整的答案或結論。
	- "blank"：只有題目、還沒開始算。

	第二步，依狀態寫 status 這一句話，直接對他說「你」：
	- stuck → 講他卡在哪一步，然後給下一步「該想什麼」的方向。
	  絕對不要直接給答案或算給他看，給了他就變成抄的。
	- done → 講他這段在幹嘛；如果哪一行開始歪掉就指出是哪一行，但不要說為什麼錯。
	- blank → 講這題在問什麼、可以從哪裡下手看。
	只寫一句。不要講解、不要列步驟、不要鼓勵、不要說「學生」。

	第三步，給 3 到 5 個 points。每個有 kind 和 title 兩個欄位。
	kind 只能是這四種，而且不要全部集中在同一種：
	- "question"：他心裡可能正在冒出來的疑問。用他會用的講法，
	  例如「25 為什麼不對」，不要寫成課本標題。
	- "supplement"：這題沒寫到、但接得上的東西。
	- "trap"：這個地方很多人會踩雷。
	- "extend"：更難或更一般的版本。
	title 是這個點的標題，一句話，不要超過 20 個字。
	不要在 title 裡回答它自己 —— 內容是他點下去才生的。

	title（最外層那個）是這一題的名字，四到八個字。

	全部繁體中文。數學符號用純文字寫（x²、√2、(x+3)²），
	絕對不要用 LaTeX、不要用 $ 符號、不要用 markdown。
	"""

	private static let pointSchema: [String: Any] = [
		"type": "object",
		"properties": [
			"kind": [
				"type": "string",
				"enum": ["question", "supplement", "trap", "extend"],
			],
			"title": ["type": "string"],
		],
		"required": ["kind", "title"],
	]

	private static let diagnoseSchema: [String: Any] = [
		"type": "object",
		"properties": [
			"title": ["type": "string"],
			"situation": ["type": "string", "enum": ["stuck", "done", "blank"]],
			"status": ["type": "string"],
			"points": ["type": "array", "items": pointSchema],
		],
		"required": ["title", "situation", "status", "points"],
	]

	func diagnose(image: UIImage) async throws -> Diagnosis {
		guard let data = Self.jpeg(from: image) else { throw AIError.badImage }
		return try await call(
			text: Self.diagnosePrompt,
			imageBase64: data.base64EncodedString(),
			toolName: "record_diagnosis",
			schema: Self.diagnoseSchema
		)
	}

	// MARK: - 展開一個點

	struct Expansion: Decodable {
		let body: String
		let followUps: [Point]

		enum CodingKeys: String, CodingKey {
			case body
			case followUps = "follow_ups"
		}
	}

	private static let expandSchema: [String: Any] = [
		"type": "object",
		"properties": [
			"body": ["type": "string"],
			"follow_ups": ["type": "array", "items": pointSchema],
		],
		"required": ["body", "follow_ups"],
	]

	/// - Parameter path: 從題目到這個點的標題路徑，讓模型知道在回答哪一層
	func expand(topic: String, diagnosis: String, path: [String]) async throws -> Expansion {
		let prompt = """
		題目：\(topic)
		先前的診斷：\(diagnosis)
		他現在點開的路徑：\(path.joined(separator: " → "))

		回答路徑最後那一個點。

		規則：
		1. body 控制在三到五句，直接對他說「你」，講重點，不要前言不要總結。
		2. follow_ups 是這段解釋之後新冒出來、他可能會想再點的點，0 到 3 個。
		   每個有 kind（question / supplement / trap / extend）和 title。
		   沒有就給空陣列，不要硬湊。
		3. 不要重複上層已經講過的東西。
		4. 全部繁體中文。數學符號用純文字寫（x²、√2、(x+3)²），
		   絕對不要用 LaTeX、不要用 $ 符號、不要用 markdown。
		"""
		return try await call(
			text: prompt,
			imageBase64: nil,
			toolName: "record_expansion",
			schema: Self.expandSchema
		)
	}

	// MARK: - 送出

	private func call<T: Decodable>(
		text: String,
		imageBase64: String?,
		toolName: String,
		schema: [String: Any]
	) async throws -> T {
		guard !apiKey.isEmpty else { throw AIError.noAPIKey }

		let (request, extract) = switch provider {
		case .google:
			(try googleRequest(text: text, imageBase64: imageBase64, schema: schema),
			 Self.extractGoogle)
		case .anthropic:
			(try anthropicRequest(
				text: text, imageBase64: imageBase64, toolName: toolName, schema: schema),
			 Self.extractAnthropic)
		}

		let (data, response) = try await URLSession.shared.data(for: request)
		if let http = response as? HTTPURLResponse, http.statusCode != 200 {
			throw AIError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
		}
		let payload = try extract(data)
		return try JSONDecoder().decode(T.self, from: payload)
	}

	// MARK: - Google Gemini

	private func googleRequest(
		text: String, imageBase64: String?, schema: [String: Any]
	) throws -> URLRequest {
		var parts: [[String: Any]] = []
		if let imageBase64 {
			parts.append([
				"inline_data": ["mime_type": "image/jpeg", "data": imageBase64]
			])
		}
		parts.append(["text": text])

		var request = URLRequest(
			url: URL(
				string:
					"https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"
			)!)
		request.httpMethod = "POST"
		request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
		request.setValue("application/json", forHTTPHeaderField: "content-type")
		request.httpBody = try JSONSerialization.data(withJSONObject: [
			"contents": [["role": "user", "parts": parts]],
			"generationConfig": [
				"responseMimeType": "application/json",
				"responseSchema": Self.googleSchema(schema),
			],
		])
		return request
	}

	/// Gemini 的 schema 型別要大寫，而且不吃 additionalProperties 那類欄位
	private static func googleSchema(_ node: [String: Any]) -> [String: Any] {
		var out: [String: Any] = [:]
		for (key, value) in node {
			switch (key, value) {
			case let ("type", raw as String):
				out["type"] = raw.uppercased()
			case let ("properties", raw as [String: Any]):
				out["properties"] = raw.mapValues { child in
					(child as? [String: Any]).map(googleSchema) ?? child
				}
			case let ("items", raw as [String: Any]):
				out["items"] = googleSchema(raw)
			default:
				out[key] = value
			}
		}
		return out
	}

	/// 回應：{"candidates":[{"content":{"parts":[{"text":"{...}"}]}}]}
	/// Gemini 3 會夾帶思考過程的 part，要跳過（thought: true）
	private static func extractGoogle(_ data: Data) throws -> Data {
		guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
		      let candidates = root["candidates"] as? [[String: Any]],
		      let content = candidates.first?["content"] as? [String: Any],
		      let parts = content["parts"] as? [[String: Any]],
		      let text = parts.first(where: { $0["thought"] as? Bool != true })?["text"]
		      	as? String,
		      let payload = text.data(using: .utf8)
		else { throw AIError.badResponse }
		return payload
	}

	// MARK: - Anthropic Claude

	private func anthropicRequest(
		text: String, imageBase64: String?, toolName: String, schema: [String: Any]
	) throws -> URLRequest {
		var content: [[String: Any]] = []
		if let imageBase64 {
			content.append([
				"type": "image",
				"source": [
					"type": "base64", "media_type": "image/jpeg", "data": imageBase64,
				],
			])
		}
		content.append(["type": "text", "text": text])

		var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
		request.httpMethod = "POST"
		request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
		request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
		request.setValue("application/json", forHTTPHeaderField: "content-type")
		request.httpBody = try JSONSerialization.data(withJSONObject: [
			"model": model,
			"max_tokens": 2048,
			"messages": [["role": "user", "content": content]],
			// 強制呼叫工具，這樣拿回來的一定是結構化資料，不用解析散文
			"tools": [["name": toolName, "input_schema": schema]],
			"tool_choice": ["type": "tool", "name": toolName],
		])
		return request
	}

	/// 回應：{"content":[{"type":"tool_use","input":{...}}]}
	private static func extractAnthropic(_ data: Data) throws -> Data {
		guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
		      let blocks = root["content"] as? [[String: Any]],
		      let input = blocks.first(where: { $0["type"] as? String == "tool_use" })?["input"]
		else { throw AIError.badResponse }
		return try JSONSerialization.data(withJSONObject: input)
	}

	// MARK: - 圖片

	/// 長邊壓到 1568px —— 再大服務端也會自己縮，白花上傳時間和錢
	private static func jpeg(from image: UIImage) -> Data? {
		let maxSide: CGFloat = 1568
		let scale = min(1, maxSide / max(image.size.width, image.size.height))
		guard scale < 1 else { return image.jpegData(compressionQuality: 0.8) }

		let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
		let renderer = UIGraphicsImageRenderer(size: size)
		let resized = renderer.image { _ in
			image.draw(in: CGRect(origin: .zero, size: size))
		}
		return resized.jpegData(compressionQuality: 0.8)
	}
}
