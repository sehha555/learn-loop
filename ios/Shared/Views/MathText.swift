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
				return acc + Self.boldAware(raw)
			case let .math(latex):
				guard let rendered = Self.render(latex, size: size) else {
					// 式子有語法錯畫不出來時，把原文還回去，不要整段吃掉
					return acc + Text(verbatim: "$\(latex)$")
				}
				// 圖片預設底邊貼基線，但分數、下標本來就該沉到基線以下 ——
				// 用 descent 把它壓回去，數學式才會跟前後文字對齊
				return acc + Text("\(Image(uiImage: rendered.image))")
					.baselineOffset(-rendered.descent)
			}
		}
	}

	/// 「完整解法」口吻會用 **…** 強調。成對的才加粗，落單的星號原樣保留
	private static func boldAware(_ raw: String) -> Text {
		let parts = raw.components(separatedBy: "**")
		guard parts.count >= 3 else { return Text(verbatim: raw) }
		return parts.enumerated().reduce(Text(verbatim: "")) { acc, item in
			let (index, part) = item
			// 奇數段夾在兩個 ** 之間；最後一段若沒有收尾的 ** 就把星號還回去
			if index % 2 == 1 {
				return index == parts.count - 1
					? acc + Text(verbatim: "**" + part)
					: acc + Text(verbatim: part).bold()
			}
			return acc + Text(verbatim: part)
		}
	}

	// MARK: - 切段

	private enum Segment {
		case plain(String)
		case math(String)
	}

	/// 落單的 $（沒有結尾的那一個）連同後面的字一起當純文字，寧可少畫也不要吃掉內容。
	/// $$…$$ 也認（模型混在句子裡寫的獨立式子）—— 以前把 $$ 看成空式子就放棄，整段變原始碼
	private static func segments(of text: String) -> [Segment] {
		guard text.contains("$") else { return [.plain(text)] }
		var out: [Segment] = []
		var rest = Substring(text)
		while let open = rest.firstIndex(of: "$") {
			let double = rest[rest.index(after: open)...].hasPrefix("$")
			let delimiter = double ? "$$" : "$"
			let afterOpen = rest.index(open, offsetBy: delimiter.count)
			guard let closeRange = rest[afterOpen...].range(of: delimiter), afterOpen < closeRange.lowerBound
			else { break }
			if open > rest.startIndex {
				out.append(.plain(String(rest[rest.startIndex..<open])))
			}
			out.append(.math(String(rest[afterOpen..<closeRange.lowerBound])))
			rest = rest[closeRange.upperBound...]
		}
		if !rest.isEmpty { out.append(.plain(String(rest))) }
		return out
	}

	// MARK: - 渲染

	/// 獨立式子（$$）用：整式一張 template 圖，呼叫端自己決定怎麼縮放擺放
	static func displayImage(_ latex: String, size: CGFloat) -> UIImage? {
		render(latex, size: size)?.image
	}

	/// 圖片加上它該沉到基線以下多深。NSCache 只收 class，所以是 NSObject
	private final class Rendered: NSObject {
		let image: UIImage
		let descent: CGFloat
		init(image: UIImage, descent: CGFloat) {
			self.image = image
			self.descent = descent
		}
	}

	/// 一頁有幾十個式子，body 每次重算都重排版會頓，所以照 latex + 字級快取
	private static let cache = NSCache<NSString, Rendered>()

	/// 畫成黑色再標成 template：實際顏色交給呼叫端的 foregroundStyle，
	/// 深色模式才不用重畫一份
	private static func render(_ latex: String, size: CGFloat) -> Rendered? {
		let key = "\(size)|\(latex)" as NSString
		if let hit = cache.object(forKey: key) { return hit }
		// SwiftMath 不認得 \dfrac 這類排版變體，會整式畫不出來 ——
		// prompt 有叮嚀只用基本款，但模型還是會吐，這裡兜底降級
		let normalized = latex
			.replacingOccurrences(of: "\\dfrac", with: "\\frac")
			.replacingOccurrences(of: "\\tfrac", with: "\\frac")
			// \boxed 去框留內容；\Big[ 這類大括號變體去掉前綴留括號本身
			.replacingOccurrences(of: "\\boxed{", with: "{")
			.replacingOccurrences(of: "\\\\[Bb]igg?", with: "", options: .regularExpression)
		var math = MathImage(
			latex: normalized, fontSize: size, textColor: .black,
			labelMode: .text, textAlignment: .left
		)
		let (error, image, layout) = math.asImage()
		guard error == nil, let image else { return nil }
		let rendered = Rendered(
			image: image.withRenderingMode(.alwaysTemplate),
			descent: layout?.descent ?? 0
		)
		cache.setObject(rendered, forKey: key)
		return rendered
	}
}

/// 把模型回的 body 切成區塊、每塊幾行。切法跟版面記號的認法集中在這，畫的人不用各自猜
enum StructuredBody {
	/// 空行隔開的是一塊。沒有空行、也沒有版面記號的舊資料（一步一行那版）退回一行一塊。
	/// 模型常在粗體標題後多空一行、或把 $$ 式子單獨隔開 —— 那樣一塊會裂成兩三個編號，
	/// 所以「只有標題的塊」往下併、「只有式子的塊」往上併，一個標題帶它底下的內容才算一塊
	static func blocks(of text: String) -> [[String]] {
		var blocks: [[String]] = []
		var current: [String] = []
		for raw in joinDisplayMath(text).components(separatedBy: "\n") {
			let line = raw.trimmingCharacters(in: .whitespaces)
			if line.isEmpty {
				if !current.isEmpty { blocks.append(current); current = [] }
			} else {
				current.append(line)
			}
		}
		if !current.isEmpty { blocks.append(current) }
		blocks = blocks.reduce(into: []) { merged, block in
			let hasTitle = block.first.map(isTitle) ?? false
			let mathOnly = block.allSatisfy { $0.hasPrefix("$$") }
			let lastIsTitleOnly = merged.last.map { $0.count == 1 && isTitle($0[0]) } ?? false
			if !merged.isEmpty, !hasTitle, mathOnly || lastIsTitleOnly {
				merged[merged.count - 1] += block
			} else {
				merged.append(block)
			}
		}
		let structured = blocks.contains { block in
			block.contains { $0.hasPrefix("**") || $0.hasPrefix("$$") || $0.hasPrefix("## ") || $0.hasPrefix("- ") }
		}
		if blocks.count == 1, !structured, blocks[0].count > 1 {
			return blocks[0].map { [$0] }
		}
		return blocks
	}

	/// 模型有時把 $$ 放在自己一行、式子夾在中間（LaTeX 慣用寫法）—— 併成一行 $$…$$ 才走得進獨立式子那條
	private static func joinDisplayMath(_ text: String) -> String {
		text.replacingOccurrences(
			of: #"\$\$[ \t]*\n([\s\S]*?)\n[ \t]*\$\$"#, with: "\\$\\$$1\\$\\$", options: .regularExpression)
			.replacingOccurrences(of: #"(\$\$[^\n$]*)\n([^\n$]*\$\$)"#, with: "$1 $2", options: .regularExpression)
	}

	static func isTitle(_ line: String) -> Bool {
		line.hasPrefix("## ") || (line.hasPrefix("**") && line.hasSuffix("**") && line.count > 4)
	}

	/// 針對某一塊發問時帶給模型的那句：拿標題行，去掉粗體／小標記號
	static func headline(of block: [String]) -> String {
		let first = block.first ?? ""
		var text = first.hasPrefix("## ") ? String(first.dropFirst(3)) : first
		text = text.replacingOccurrences(of: "**", with: "")
		return text.trimmingCharacters(in: .whitespaces)
	}

}

/// 講義體的一行：## 小標、$$ 獨立式子、- 條列、關鍵是：結尾，其餘是一般句子。
/// 樹頁展開內容和概念頁「問過的」共用 —— 模型給哪種版面記號，兩邊都要畫得出來
struct StructuredLine: View {
	let line: String
	init(_ line: String) { self.line = line }

	@ViewBuilder
	var body: some View {
		if line.hasPrefix("## ") {
			MathText(text: String(line.dropFirst(3)), font: .subheadline.weight(.semibold), size: 15)
				.padding(.top, 6)
		} else if line.hasPrefix("$$"), line.hasSuffix("$$"), line.count >= 4 {
			let latex = line.dropFirst(2).dropLast(2).trimmingCharacters(in: .whitespaces)
			// 獨立式子畫成一張圖、寬度不夠就整張等比縮小 —— 視窗窄的時候不會被切掉。
			// 只縮不放大（maxWidth 鎖在原尺寸），畫不出來退回行內那套原樣顯示
			if let image = MathText.displayImage(latex, size: 18) {
				Image(uiImage: image)
					.resizable()
					.scaledToFit()
					.frame(maxWidth: image.size.width)
					.frame(maxWidth: .infinity, alignment: .center)
					.padding(.vertical, 2)
			} else {
				MathText(text: "$\(latex)$", font: .callout, size: 18)
					.frame(maxWidth: .infinity, alignment: .center)
			}
		} else if line.hasPrefix("- ") {
			HStack(alignment: .firstTextBaseline, spacing: 8) {
				Text("•").foregroundStyle(.secondary)
				MathText(text: String(line.dropFirst(2)), font: .callout, size: 16)
			}
			.padding(.leading, 4)
		} else if line.hasPrefix("關鍵是：") || line.hasPrefix("關鍵是:") {
			MathText(text: line, font: .callout.weight(.semibold), size: 16)
				.padding(10)
				.frame(maxWidth: .infinity, alignment: .leading)
				.background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
				.padding(.top, 4)
		} else {
			MathText(text: line, font: .callout, size: 16)
				.foregroundStyle(.primary.opacity(0.85))
		}
	}
}
