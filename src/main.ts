import { Notice, Plugin, TFile } from "obsidian";

const PROBE_REPORT_PATH = "learn-loop-probe.md";

/**
 * Spike 階段的外掛：只做環境探測。
 *
 * 要回答的問題是「外掛能不能程式化拿到使用者手寫的內容、變成模型讀得懂的圖」。
 * Excalidraw 的 ExcalidrawAutomate 是未公開 API，簽名靠猜不可靠，
 * 所以這裡把實際存在的方法列出來、把幾種抓圖方式都試一遍，結果寫成報告。
 *
 * 報告寫成 vault 裡的 md 檔而不是 console.log：iPad 上沒有開發者工具。
 */
export default class LearnLoopPlugin extends Plugin {
	async onload() {
		this.addCommand({
			id: "probe",
			name: "探測環境（開發用）",
			callback: () => void this.probe(),
		});
	}

	private async probe() {
		const lines: string[] = ["# learn-loop 探測報告", ""];
		const anyApp = this.app as any;

		const view = anyApp.workspace.activeLeaf?.view;
		const viewType = view?.getViewType?.() ?? "(拿不到)";
		const file = this.app.workspace.getActiveFile();

		lines.push("## 當前分頁", "");
		lines.push(`- view type: \`${viewType}\``);
		lines.push(`- 檔案: \`${file?.path ?? "(無)"}\``);
		lines.push("");

		const exPlugin = anyApp.plugins?.plugins?.["obsidian-excalidraw-plugin"];
		const ea = (window as any).ExcalidrawAutomate;

		lines.push("## Excalidraw", "");
		lines.push(`- 外掛已載入: ${exPlugin ? "是" : "否"}`);
		if (exPlugin?.manifest?.version) {
			lines.push(`- 版本: ${exPlugin.manifest.version}`);
		}
		lines.push(`- ExcalidrawAutomate: ${ea ? "有" : "沒有"}`);
		lines.push("");

		if (ea) {
			lines.push(`### 可用方法`, "", "```", listMethods(ea).join("\n"), "```", "");
		}

		if (ea && file) {
			lines.push("## 抓圖嘗試", "");
			const attempts: Array<[string, () => unknown]> = [
				[`createPNG("${file.path}")`, () => ea.createPNG(file.path)],
				["createPNG()", () => ea.createPNG()],
				[`createSVG("${file.path}")`, () => ea.createSVG(file.path)],
				["getViewSelectedElements()", () => ea.getViewSelectedElements()],
			];
			for (const [name, run] of attempts) {
				lines.push(`- \`${name}\` → ${await tryDescribe(run)}`);
			}
			lines.push("");
		}

		if (view) {
			lines.push("## 當前 view 的方法", "", "```", listMethods(view).join("\n"), "```", "");
		}

		await this.writeReport(lines.join("\n"));
	}

	private async writeReport(content: string) {
		const existing = this.app.vault.getAbstractFileByPath(PROBE_REPORT_PATH);
		if (existing instanceof TFile) {
			await this.app.vault.modify(existing, content);
		} else {
			await this.app.vault.create(PROBE_REPORT_PATH, content);
		}
		new Notice(`探測完成 → ${PROBE_REPORT_PATH}`);
		await this.app.workspace.openLinkText(PROBE_REPORT_PATH, "", true);
	}
}

/** 列出物件自身與整條原型鏈上的方法名。未公開 API 的方法多半掛在原型上，只看 Object.keys 會漏掉。 */
function listMethods(obj: unknown): string[] {
	const names = new Set<string>();
	let cur: any = obj;
	while (cur && cur !== Object.prototype) {
		for (const k of Object.getOwnPropertyNames(cur)) names.add(k);
		cur = Object.getPrototypeOf(cur);
	}
	const fns: string[] = [];
	for (const k of names) {
		try {
			if (typeof (obj as any)[k] === "function") fns.push(k);
		} catch {
			// getter 可能拋錯，跳過
		}
	}
	return fns.sort();
}

async function tryDescribe(run: () => unknown): Promise<string> {
	try {
		return describe(await run());
	} catch (e) {
		return `失敗: ${(e as Error).message}`;
	}
}

function describe(value: unknown): string {
	if (value == null) return String(value);
	if (value instanceof Blob) return `Blob ${value.size} bytes (${value.type})`;
	if (value instanceof SVGElement) return `SVG ${value.outerHTML.length} 字元`;
	if (Array.isArray(value)) return `陣列，${value.length} 項`;
	if (typeof value === "object") return `物件 {${Object.keys(value).slice(0, 8).join(", ")}}`;
	return String(value);
}
