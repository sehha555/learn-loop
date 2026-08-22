import Foundation
import SwiftMath

// 用法：python3 tools/latexcheck/extract.py | swift run -c release --package-path tools/latexcheck
// 讀 stdin：一行一個 LaTeX，先過 app 同一份 LatexNormalize，再用 SwiftMath 解析；失敗的照錯誤分組印出來
var failures: [String: [String]] = [:]
var total = 0
while let line = readLine() {
	let latex = line.trimmingCharacters(in: .whitespaces)
	guard !latex.isEmpty else { continue }
	total += 1
	var error: NSError?
	_ = MTMathListBuilder.build(fromString: LatexNormalize.apply(latex), error: &error)
	if let error {
		failures[error.localizedDescription, default: []].append(latex)
	}
}
print("總共 \(total) 個式子，失敗 \(failures.values.map(\.count).reduce(0, +)) 個")
for (message, items) in failures.sorted(by: { $0.value.count > $1.value.count }) {
	print("\n[\(items.count)] \(message)")
	for item in items.prefix(3) { print("    \(item.prefix(90))") }
}
