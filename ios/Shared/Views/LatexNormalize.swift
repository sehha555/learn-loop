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
}
