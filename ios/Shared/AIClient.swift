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

	struct Diagnosis: Decodable {
		let title: String
		let diagnosis: String
		let points: [String]
	}

	/// 這段調過三輪。關鍵是 points 要寫成「他心裡那句話」而不是課本標題 ——
	/// 模型的預設會吐出「一次項係數與常數項的關聯性」這種一看就不想點的東西。
	private static let diagnosePrompt = """
	你是坐在旁邊的助教，正在看使用者手寫的東西。

	diagnosis：一句話，直接對他說「你」。講他卡在哪、或這段在幹嘛。
	不要講解、不要列步驟、不要鼓勵、不要說「學生」。

	points：他心裡可能正在冒出來、但你這次刻意不回答的疑問。3 到 5 個。
	用他會用的講法，像是他自己在心裡問的那句話 —— 例如「為什麼是除以 2 再平方」、
	「25 為什麼不對」。
	不要寫成課本標題，例如「一次項係數與常數項的關聯性」「分配律的驗算」這種一看
	就不想點的東西。

	title：這一題的名字，四到八個字。

	全部繁體中文。數學符號用純文字寫（x²、√2、(x+3)²），
	絕對不要用 LaTeX、不要用 $ 符號、不要用 markdown。
	"""

	private static let diagnoseSchema: [String: Any] = [
		"type": "object",
		"properties": [
			"title": ["type": "string"],
			"diagnosis": ["type": "string"],
			"points": ["type": "array", "items": ["type": "string"]],
		],
		"required": ["title", "diagnosis", "points"],
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
		let followUps: [String]

		enum CodingKeys: String, CodingKey {
			case body
			case followUps = "follow_ups"
		}
	}

	private static let expandSchema: [String: Any] = [
		"type": "object",
		"properties": [
			"body": ["type": "string"],
			"follow_ups": ["type": "array", "items": ["type": "string"]],
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
		2. follow_ups 是這段解釋之後「新冒出來、他可能會想追問」的點，
		   0 到 3 個，寫成他心裡會問的那句話。沒有就給空陣列，不要硬湊。
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
