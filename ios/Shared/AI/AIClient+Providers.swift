import Foundation
import UIKit

extension AIClient {
	// MARK: - Mac 中繼站

	/// prompt 和 schema 原樣丟給 Mac，Mac 那邊叫 claude -p 處理完回 JSON。
	/// 回應本身就是結果物件，不用再從 provider 的包裝裡挖。
	func callRelay<T: Decodable>(
		_ relay: URL, text: String, imageBase64: String?, schema: [String: Any]
	) async throws -> T {
		// 先敲 /health，2 秒沒回就當 Mac 不在，立刻換路 —— 不讓使用者乾等連線逾時
		var health = URLRequest(url: relay.appending(path: "health"))
		health.timeoutInterval = 2
		_ = try await URLSession.shared.data(for: health)

		var request = URLRequest(url: relay.appending(path: "call"))
		request.httpMethod = "POST"
		request.setValue("application/json", forHTTPHeaderField: "content-type")
		request.timeoutInterval = 180
		var body: [String: Any] = ["prompt": text, "schema": schema]
		if let imageBase64 { body["image_base64"] = imageBase64 }
		request.httpBody = try JSONSerialization.data(withJSONObject: body)

		let (data, response) = try await Self.transport.send(request)
		if let http = response as? HTTPURLResponse, http.statusCode != 200 {
			throw AIError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
		}
		return try JSONDecoder().decode(T.self, from: data)
	}

	// MARK: - Google Gemini

	func googleRequest(
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
				// 回應長度上限（含思考 token）—— 防止意外燒掉額度。
				// 不能設太低：Gemini 的思考也算在裡面，卡到會回不完整的 JSON
				"maxOutputTokens": 8192,
			],
		])
		return request
	}

	/// Gemini 的 schema 型別要大寫，而且不吃 additionalProperties 那類欄位
	static func googleSchema(_ node: [String: Any]) -> [String: Any] {
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
	static func extractGoogle(_ data: Data) throws -> Data {
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

	func anthropicRequest(
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
	static func extractAnthropic(_ data: Data) throws -> Data {
		guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
		      let blocks = root["content"] as? [[String: Any]],
		      let input = blocks.first(where: { $0["type"] as? String == "tool_use" })?["input"]
		else { throw AIError.badResponse }
		return try JSONSerialization.data(withJSONObject: input)
	}

	// MARK: - 圖片

	/// 使用者自己按「取消」中斷的不算出錯，不要跳 alert。
	/// URLSession 被中斷時丟的是 URLError.cancelled，不是 CancellationError
	static func isCancellation(_ error: Error) -> Bool {
		Task.isCancelled || error is CancellationError
			|| (error as? URLError)?.code == .cancelled
	}

	/// 長邊壓到 1568px —— 再大服務端也會自己縮，白花上傳時間和錢。
	/// CardStore 存題目截圖也用這個尺寸，夠看清題目。
	static func jpeg(from image: UIImage) -> Data? {
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
