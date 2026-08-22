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

	/// 先照 **…** 切粗體、再在每段裡切數學式 —— 反過來的話「**求 $f_x$**」會被 $ 切開，
	/// 兩邊各剩一個落單的 ** 就認不出粗體。成對的才加粗，落單的星號原樣保留
	private var content: Text {
		let parts = text.components(separatedBy: "**")
		guard parts.count >= 3 else { return inline(text, bold: false) }
		return parts.enumerated().reduce(Text(verbatim: "")) { acc, item in
			let (index, part) = item
			// 奇數段夾在兩個 ** 之間；最後一段若沒有收尾的 ** 就把星號還回去
			if index % 2 == 1 {
				return index == parts.count - 1
					? acc + inline("**" + part, bold: false)
					: acc + inline(part, bold: true)
			}
			return acc + inline(part, bold: false)
		}
	}

	private func inline(_ raw: String, bold: Bool) -> Text {
		Self.segments(of: raw).reduce(Text(verbatim: "")) { acc, segment in
			switch segment {
			case let .plain(piece):
				return acc + (bold ? Text(verbatim: piece).bold() : Text(verbatim: piece))
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
			} else if isTitle(line), !current.isEmpty {
				// 模型忘了空行、標題直接接在上一塊後面：標題行本身就是新的一塊的開頭
				blocks.append(current)
				current = [line]
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

	/// 模型有時把 $$ 放在自己一行、式子夾在中間（LaTeX 慣用寫法）—— 併成一行 $$…$$ 才走得進獨立式子那條。
	/// 逐行看、只有整行就是 $$ 的才當開關：用 regex 的話上一個式子的結尾 $$ 會被當成開頭，
	/// 一路吃到下一個式子，中間的標題全被吞掉（8/22 「交換積分順序」那則就這樣）。
	/// 另外式子跟句子擠在同一行（「$$…$$ 答案」）就拆開，讓每個獨立式子自己一行置中
	private static func joinDisplayMath(_ text: String) -> String {
		var out: [String] = []
		var pending: [String]?
		for raw in text.components(separatedBy: "\n") {
			let line = raw.trimmingCharacters(in: .whitespaces)
			if line == "$$" {
				if let body = pending {
					out.append("$$" + body.joined(separator: " ") + "$$")
					pending = nil
				} else {
					pending = []
				}
			} else if pending != nil {
				pending?.append(line)
			} else {
				out.append(raw)
			}
		}
		// 開了沒關：原樣還回去，不要吃掉內容
		if let body = pending { out.append("$$"); out += body }
		// 只在式子前後真的黏著字的時候才斷行，本來就自己一行的不動（多插空行會讓它裂成獨立的一塊）
		return out.joined(separator: "\n")
			.replacingOccurrences(of: #"(?<=\S)[ \t]*(\$\$[^$\n]+\$\$)"#, with: "\n$1", options: .regularExpression)
			.replacingOccurrences(of: #"(\$\$[^$\n]+\$\$)[ \t]*(?=\S)"#, with: "$1\n", options: .regularExpression)
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
			MathText(text: String(line.dropFirst(3)), font: .headline, size: 17)
				.padding(.top, 6)
		} else if line.hasPrefix("$$"), line.hasSuffix("$$"), line.count >= 4 {
			let latex = line.dropFirst(2).dropLast(2).trimmingCharacters(in: .whitespaces)
			// 獨立式子畫成一張圖、寬度不夠就整張等比縮小 —— 視窗窄的時候不會被切掉。
			// 只縮不放大：maxWidth／maxHeight 都鎖在原尺寸。高度一定要給，不然式子比欄寬長時
			// SwiftUI 拿不到高度提案，會把它縮成一小點（8/22 第三步那條）。畫不出來退回行內那套
			if let image = MathText.displayImage(latex, size: 22) {
				Image(uiImage: image)
					.resizable()
					.scaledToFit()
					.frame(maxWidth: image.size.width, maxHeight: image.size.height)
					.frame(maxWidth: .infinity, alignment: .center)
					.padding(.vertical, 4)
			} else {
				MathText(text: "$\(latex)$", font: .body, size: 22)
					.frame(maxWidth: .infinity, alignment: .center)
			}
		} else if line.hasPrefix("- ") {
			HStack(alignment: .firstTextBaseline, spacing: 8) {
				Text("•").foregroundStyle(.secondary)
				MathText(text: String(line.dropFirst(2)), font: .body, size: 17)
			}
			.padding(.leading, 4)
		} else if line.hasPrefix("關鍵是：") || line.hasPrefix("關鍵是:") {
			MathText(text: line, font: .body.weight(.semibold), size: 17)
				.padding(10)
				.frame(maxWidth: .infinity, alignment: .leading)
				.background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
				.padding(.top, 4)
		} else {
			// 粗體標題行也走這裡（MathText 自己認 **），字級跟內文一樣但粗
			MathText(text: line, font: .body, size: 17)
				.foregroundStyle(.primary.opacity(0.9))
		}
	}
}
