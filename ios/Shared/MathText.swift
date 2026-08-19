import SwiftMath
import SwiftUI

/// 把 $...$ 之間的內容當 LaTeX 畫出來，其餘照一般文字排。
///
/// 數學式先渲染成 template 圖片，再用字串插值塞回 Text —— 換行、深色模式、
/// 前景色全部沿用 SwiftUI 自己的文字排版，不用另外算斷行（中文沒有空白，
/// 靠 FlowLayout 逐詞排會斷不開）。
/// 沒有 $ 的字串原樣輸出：使用者存過的舊題目是純文字，不能因為這層變樣。
struct MathText: View {
	let text: String
	let font: Font
	/// 數學式的字級。SwiftUI 的 Font 問不出 pt 數，呼叫端給的要跟 font 對得上
	let size: CGFloat

	var body: some View {
		content
			.font(font)
			.fixedSize(horizontal: false, vertical: true)
	}

	private var content: Text {
		Self.segments(of: text).reduce(Text(verbatim: "")) { acc, segment in
			switch segment {
			case let .plain(raw):
				return acc + Text(verbatim: raw)
			case let .math(latex):
				guard let image = Self.render(latex, size: size) else {
					// 式子有語法錯畫不出來時，把原文還回去，不要整段吃掉
					return acc + Text(verbatim: "$\(latex)$")
				}
				return acc + Text("\(Image(uiImage: image))")
			}
		}
	}

	// MARK: - 切段

	private enum Segment {
		case plain(String)
		case math(String)
	}

	/// 落單的 $（沒有結尾的那一個）連同後面的字一起當純文字，寧可少畫也不要吃掉內容
	private static func segments(of text: String) -> [Segment] {
		guard text.contains("$") else { return [.plain(text)] }
		var out: [Segment] = []
		var rest = Substring(text)
		while let open = rest.firstIndex(of: "$") {
			let afterOpen = rest.index(after: open)
			guard let close = rest[afterOpen...].firstIndex(of: "$"), afterOpen < close
			else { break }
			if open > rest.startIndex {
				out.append(.plain(String(rest[rest.startIndex..<open])))
			}
			out.append(.math(String(rest[afterOpen..<close])))
			rest = rest[rest.index(after: close)...]
		}
		if !rest.isEmpty { out.append(.plain(String(rest))) }
		return out
	}

	// MARK: - 渲染

	/// 一頁有幾十個式子，body 每次重算都重排版會頓，所以照 latex + 字級快取
	private static let cache = NSCache<NSString, UIImage>()

	/// 畫成黑色再標成 template：實際顏色交給呼叫端的 foregroundStyle，
	/// 深色模式才不用重畫一份
	private static func render(_ latex: String, size: CGFloat) -> UIImage? {
		let key = "\(size)|\(latex)" as NSString
		if let hit = cache.object(forKey: key) { return hit }
		var math = MathImage(
			latex: latex, fontSize: size, textColor: .black,
			labelMode: .text, textAlignment: .left
		)
		let (error, image, _) = math.asImage()
		guard error == nil, let image else { return nil }
		let template = image.withRenderingMode(.alwaysTemplate)
		cache.setObject(template, forKey: key)
		return template
	}
}
