import Foundation

/// 模型寫的 LaTeX 在畫之前先過這一關：SwiftMath 不認的指令換成它認的等價寫法。
/// prompt 有叮嚀只用基本款，但模型還是會吐，這裡是保底。
/// 只用 Foundation，讓 tools/latexcheck 在 Mac 上直接拿同一份邏輯檢查呼叫紀錄裡的式子
enum LatexNormalize {
	static func apply(_ latex: String) -> String {
		latex
			.replacingOccurrences(of: "\\dfrac", with: "\\frac")
			.replacingOccurrences(of: "\\tfrac", with: "\\frac")
			// \boxed 去框留內容；\Big[ 這類大括號變體去掉前綴留括號本身
			.replacingOccurrences(of: "\\boxed{", with: "{")
			.replacingOccurrences(of: "\\\\[Bb]igg?", with: "", options: .regularExpression)
			// 多重積分號沒有，拆成連續的 \int
			.replacingOccurrences(of: "\\iiint", with: "\\int\\!\\!\\!\\int\\!\\!\\!\\int")
			.replacingOccurrences(of: "\\iint", with: "\\int\\!\\!\\!\\int")
			// \le、\ge、\ne 補成 \leq、\geq、\neq（後面接字母的不動）
			.replacingOccurrences(of: "\\\\(le|ge|ne)(?![A-Za-z])", with: "\\\\$1q", options: .regularExpression)
	}

	/// 模型偶爾把題目寫成「∫∫_Ω 1/(1+x+y)^2 dA，Ω: 0≤x≤2」這種 unicode 假數學、不包 $ ——
	/// MathText 當純文字顯示就是一串符號。這裡把非中文的段落裡有數學記號的，
	/// 換成 LaTeX 指令再包 $；中文字和中文標點照舊。已經有 $ 的原樣不動
	static func latexifyPlainMath(_ text: String) -> String {
		guard !text.contains("$") else { return text }
		// 切成「中文／中文標點」與「其他」交替的段落
		let pattern = #"[\p{Han}，。、：；！？（）「」【】]+|[^\p{Han}，。、：；！？（）「」【】]+"#
		guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
		let whole = NSRange(text.startIndex..., in: text)
		var out = ""
		for match in regex.matches(in: text, range: whole) {
			guard let range = Range(match.range, in: text) else { continue }
			let segment = String(text[range])
			if segment.rangeOfCharacter(from: mathMarkers) != nil,
			   segment.range(of: #"\p{Han}"#, options: .regularExpression) == nil {
				let leading = segment.prefix { $0.isWhitespace }
				let trailing = segment.reversed().prefix { $0.isWhitespace }
				let core = segment.trimmingCharacters(in: .whitespaces)
				out += leading + "$" + unicodeToLatex(core) + "$" + String(trailing.reversed())
			} else {
				out += segment
			}
		}
		return out
	}

	/// 看到這些就當這段是數學
	private static let mathMarkers = CharacterSet(charactersIn: "∫∬∭∑∏√≤≥≠≈∞π θΩαβγδλμσφωΔ^_\\×·→")
		.subtracting(.whitespaces)

	private static let unicodeMap: [(String, String)] = [
		("∭", "\\iiint"), ("∬", "\\iint"), ("∫∫∫", "\\iiint"), ("∫∫", "\\iint"), ("∫", "\\int"),
		("∑", "\\sum"), ("∏", "\\prod"), ("√", "\\sqrt"), ("≤", "\\leq"), ("≥", "\\geq"),
		("≠", "\\neq"), ("≈", "\\approx"), ("∞", "\\infty"), ("π", "\\pi"), ("θ", "\\theta"),
		("Ω", "\\Omega"), ("α", "\\alpha"), ("β", "\\beta"), ("γ", "\\gamma"), ("δ", "\\delta"),
		("λ", "\\lambda"), ("μ", "\\mu"), ("σ", "\\sigma"), ("φ", "\\phi"), ("ω", "\\omega"),
		("Δ", "\\Delta"), ("×", "\\times"), ("·", "\\cdot"), ("→", "\\to"),
	]

	private static func unicodeToLatex(_ text: String) -> String {
		var out = text
		for (symbol, latex) in unicodeMap {
			// 指令後面接字母會黏成別的指令（\Omega1 沒事，\int dA 要空格），一律補空格
			out = out.replacingOccurrences(of: symbol, with: latex + " ")
		}
		return out.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
	}
}
