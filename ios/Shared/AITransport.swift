import Foundation

/// 送 HTTP 請求的管道。
///
/// 主 app 走 background session：使用者送出問題後切回 GoodNotes 寫字是常態，
/// 一般 session 在 app 進背景幾秒被暫停時連線就被收掉（Mac 那邊看到的是算完要回寫、
/// iPad 已斷線），答案白算、app 回來還靜默退回 Gemini。background session 由系統
/// 代跑，app 暫停、甚至被砍掉都會跑完，回前景再把結果交回來。
///
/// 分享浮層拿不到 background session（要 App Group 容器，免費簽章沒有），
/// 維持一般的前景 session。
final class AITransport: NSObject, URLSessionDataDelegate {
	static let foreground = AITransport(background: false)
	static let background = AITransport(background: true)

	private let isBackground: Bool
	private let lock = NSLock()
	private var buffers: [Int: Data] = [:]
	private var bodyFiles: [Int: URL] = [:]
	private var continuations: [Int: CheckedContinuation<(Data, URLResponse), Error>] = [:]
	/// app 被砍掉後系統為了交付結果把它喚醒時給的 handler，交付完要叫它
	var backgroundCompletion: (() -> Void)?

	private init(background: Bool) {
		isBackground = background
		super.init()
	}

	private lazy var session: URLSession = {
		let config = URLSessionConfiguration.background(
			withIdentifier: "com.sehha555.learnloop.ai")
		config.isDiscretionary = false
		config.sessionSendsLaunchEvents = true
		// 等模型的上限；resource 是整筆請求含系統重試的總時長
		config.timeoutIntervalForRequest = 180
		config.timeoutIntervalForResource = 600
		return URLSession(configuration: config, delegate: self, delegateQueue: nil)
	}()

	func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
		guard isBackground else { return try await URLSession.shared.data(for: request) }
		// background session 只接受「從檔案上傳」的請求，body 先落地
		let file = FileManager.default.temporaryDirectory
			.appendingPathComponent("ai-\(UUID().uuidString).json")
		try (request.httpBody ?? Data()).write(to: file)
		var upload = request
		upload.httpBody = nil
		let task = session.uploadTask(with: upload, fromFile: file)
		lock.withLock { bodyFiles[task.taskIdentifier] = file }
		return try await withTaskCancellationHandler {
			try await withCheckedThrowingContinuation { continuation in
				lock.withLock { continuations[task.taskIdentifier] = continuation }
				task.resume()
			}
		} onCancel: {
			task.cancel()
		}
	}

	// MARK: - URLSessionDataDelegate

	func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
		lock.withLock { buffers[dataTask.taskIdentifier, default: Data()].append(data) }
	}

	func urlSession(
		_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
	) {
		let id = task.taskIdentifier
		let (data, file, continuation) = lock.withLock {
			(buffers.removeValue(forKey: id), bodyFiles.removeValue(forKey: id),
			 continuations.removeValue(forKey: id))
		}
		if let file { try? FileManager.default.removeItem(at: file) }
		guard let continuation else {
			// app 被砍掉後才完成的請求：沒人在等了。結果只能丟掉 ——
			// 要接回去得把「哪張卡在等」存檔，目前沒做
			return
		}
		if let error {
			continuation.resume(throwing: error)
		} else {
			continuation.resume(returning: (data ?? Data(), task.response ?? URLResponse()))
		}
	}

	func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
		DispatchQueue.main.async {
			self.backgroundCompletion?()
			self.backgroundCompletion = nil
		}
	}
}
