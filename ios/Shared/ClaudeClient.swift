import Foundation
import UIKit

enum ClaudeError: LocalizedError {
	case noAPIKey
	case badImage
	case http(Int, String)
	case badResponse

	var errorDescription: String? {
		switch self {
		case .noAPIKey: "還沒設定 API key，到主 app 的設定貼上"
		case .badImage: "這張圖讀不出來"
		case let .http(code, message): "伺服器回 \(code)：\(message)"
		case .badResponse: "回應格式看不懂"
		}
	}
}

/// 打 Anthropic Messages API。
/// Swift 沒有官方 SDK，所以直接用 URLSession 打 REST。
struct ClaudeClient {
	let apiKey: String

	private let model = "claude-opus-5"
	private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

	// MARK: - 診斷一張截圖

	struct Diagnosis: Decodable {
		let title: String
		let diagnosis: String
		let points: [String]
	}

	private static let diagnosePrompt = """
	你是坐在旁邊的助教。使用者圈了一段自己手寫的內容給你看。

	規則（很重要）：
	1. diagnosis 只寫一句話，講他卡在哪或這段在做什麼。不要講解、不要列步驟、不要鼓勵。
	2. points 是「他可能不懂、但你這次刻意不講」的點，每個只寫標題，3 到 5 個。
	   標題要具體到看得出來裡面是什麼，例如「為什麼補的是 (b/2)²」，
	   不要寫「相關概念」「延伸思考」這種空的。
	3. 絕對不要把 points 的內容寫進 diagnosis。他點了才會展開。
	4. title 是這一題的名字，四到八個字，之後會用來歸類。
	5. 全部用繁體中文。
	"""

	func diagnose(image: UIImage) async throws -> Diagnosis {
		guard let data = Self.jpeg(from: image) else { throw ClaudeError.badImage }
		let content: [[String: Any]] = [
			[
				"type": "image",
				"source": [
					"type": "base64",
					"media_type": "image/jpeg",
					"data": data.base64EncodedString(),
				],
			],
			["type": "text", "text": Self.diagnosePrompt],
		]
		return try await call(
			messages: [["role": "user", "content": content]],
			tool: "record_diagnosis",
			schema: [
				"type": "object",
				"properties": [
					"title": ["type": "string"],
					"diagnosis": ["type": "string"],
					"points": ["type": "array", "items": ["type": "string"]],
				],
				"required": ["title", "diagnosis", "points"],
			]
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

	/// - Parameters:
	///   - path: 從題目到這個點的標題路徑，讓模型知道在回答哪一層
	func expand(topic: String, diagnosis: String, path: [String]) async throws -> Expansion {
		let prompt = """
		題目：\(topic)
		先前的診斷：\(diagnosis)
		他現在點開的路徑：\(path.joined(separator: " → "))

		回答路徑最後那一個點。

		規則：
		1. body 控制在三到五句，直接講重點，不要前言不要總結。
		2. follow_ups 是這段解釋之後「新冒出來、他可能會想追問」的點，
		   0 到 3 個，只寫標題。沒有就給空陣列，不要硬湊。
		3. 不要重複上層已經講過的東西。
		4. 全部用繁體中文。
		"""
		return try await call(
			messages: [["role": "user", "content": prompt]],
			tool: "record_expansion",
			schema: [
				"type": "object",
				"properties": [
					"body": ["type": "string"],
					"follow_ups": ["type": "array", "items": ["type": "string"]],
				],
				"required": ["body", "follow_ups"],
			]
		)
	}

	// MARK: - 共用

	/// 強制模型呼叫一個工具，這樣拿回來的一定是結構化資料，不用解析散文
	private func call<T: Decodable>(
		messages: [[String: Any]],
		tool name: String,
		schema: [String: Any]
	) async throws -> T {
		guard !apiKey.isEmpty else { throw ClaudeError.noAPIKey }

		var request = URLRequest(url: endpoint)
		request.httpMethod = "POST"
		request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
		request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
		request.setValue("application/json", forHTTPHeaderField: "content-type")
		request.httpBody = try JSONSerialization.data(withJSONObject: [
			"model": model,
			"max_tokens": 2048,
			"messages": messages,
			"tools": [["name": name, "input_schema": schema]],
			"tool_choice": ["type": "tool", "name": name],
		])

		let (data, response) = try await URLSession.shared.data(for: request)
		if let http = response as? HTTPURLResponse, http.statusCode != 200 {
			throw ClaudeError.http(
				http.statusCode, String(data: data, encoding: .utf8) ?? "")
		}

		// 回應長這樣：{"content":[{"type":"tool_use","input":{...}}]}
		guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
		      let blocks = root["content"] as? [[String: Any]],
		      let input = blocks.first(where: { $0["type"] as? String == "tool_use" })?["input"]
		else { throw ClaudeError.badResponse }

		let payload = try JSONSerialization.data(withJSONObject: input)
		return try JSONDecoder().decode(T.self, from: payload)
	}

	/// 長邊壓到 1568px —— 再大 Anthropic 也會自己縮，白花上傳時間和錢
	private static func jpeg(from image: UIImage) -> Data? {
		let maxSide: CGFloat = 1568
		let scale = min(1, maxSide / max(image.size.width, image.size.height))
		guard scale < 1 else { return image.jpegData(compressionQuality: 0.8) }

		let size = CGSize(
			width: image.size.width * scale, height: image.size.height * scale)
		let renderer = UIGraphicsImageRenderer(size: size)
		let resized = renderer.image { _ in
			image.draw(in: CGRect(origin: .zero, size: size))
		}
		return resized.jpegData(compressionQuality: 0.8)
	}
}
