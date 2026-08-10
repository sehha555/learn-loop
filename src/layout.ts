/**
 * 版面計算：決定「AI 要讀哪一塊」與「生成的卡片放哪裡」。
 *
 * 這一層刻意不依賴 Obsidian 與 Excalidraw —— 只吃矩形、吐矩形。
 * 之後若把畫布換成自製的 iPad app，這個檔可以原封搬走。
 */

export interface Box {
	x: number;
	y: number;
	width: number;
	height: number;
}

/** 畫布元素只需要這幾個欄位就能算版面 */
export interface Positioned extends Box {
	id?: string;
}

const right = (b: Box) => b.x + b.width;
const bottom = (b: Box) => b.y + b.height;

/** 兩個矩形是否重疊（gap = 至少要留的間距） */
export function overlaps(a: Box, b: Box, gap = 0): boolean {
	return !(
		right(a) + gap <= b.x ||
		right(b) + gap <= a.x ||
		bottom(a) + gap <= b.y ||
		bottom(b) + gap <= a.y
	);
}

/** 把一組元素包起來的最小矩形 */
export function boundsOf(items: Box[]): Box | null {
	if (items.length === 0) return null;
	let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
	for (const it of items) {
		minX = Math.min(minX, it.x);
		minY = Math.min(minY, it.y);
		maxX = Math.max(maxX, right(it));
		maxY = Math.max(maxY, bottom(it));
	}
	return { x: minX, y: minY, width: maxX - minX, height: maxY - minY };
}

/** a 是否完全落在 container 內 */
export function contains(container: Box, a: Box): boolean {
	return (
		a.x >= container.x &&
		a.y >= container.y &&
		right(a) <= right(container) &&
		bottom(a) <= bottom(container)
	);
}

/**
 * 目前螢幕看得到的畫布範圍（場景座標）。
 * Excalidraw 的 appState 給的是 scrollX/scrollY/zoom，需要換算。
 */
export function viewportBounds(
	appState: { scrollX: number; scrollY: number; zoom: { value: number } },
	containerWidth: number,
	containerHeight: number,
): Box {
	const z = appState.zoom.value;
	return {
		// || 0 是為了把 -0 正規化成 0 —— 這個值會被序列化寫進畫布檔
		x: -appState.scrollX || 0,
		y: -appState.scrollY || 0,
		width: containerWidth / z,
		height: containerHeight / z,
	};
}

/**
 * 挑出 AI 該讀的元素。
 * 有圈選 → 用圈選的；沒圈選 → 用螢幕可見範圍。
 * 可見範圍只要「碰到」就整個算進去 —— 被螢幕邊切一半的題目要完整送出，
 * 讀到半題比多讀一點糟得多。
 */
export function pickTargets<T extends Positioned>(
	all: T[],
	selected: T[],
	viewport: Box,
): T[] {
	if (selected.length > 0) return selected;
	return all.filter((el) => overlaps(el, viewport));
}

export interface SpotOptions {
	/** 錨點：AI 正在回答的那一塊，卡片要長在它旁邊 */
	anchor: Box;
	/** 卡片尺寸 */
	size: { width: number; height: number };
	/** 畫布上已被佔用的矩形 */
	occupied: Box[];
	/** 目前可見範圍；卡片優先放在這裡面，不然按完按鈕會跑到畫面外 */
	viewport: Box;
	/** 元素之間至少留的間距 */
	gap?: number;
}

/**
 * 在錨點附近找一塊放得下卡片的空白。
 *
 * 候選位置取自「障礙物的外緣」而不是固定步長掃描 —— 固定步長會漏掉
 * 剛好落在兩個大障礙物之間的縫隙，也可能永遠掃不到很遠的那塊空地。
 *
 * 方向優先序：右 → 下 → 上 → 左。先右邊是因為橫向書寫時右側通常是留白，
 * 而且「答案在題目右邊」符合批改的直覺。同方向內離錨點越近越優先。
 *
 * occupied 請傳「合併過的區塊」而不是每一筆手寫筆跡 —— 候選數量是
 * occupied 的平方，傳幾百個 freedraw 進來會慢。
 *
 * 找不到時回傳 null，由呼叫端決定要往可見範圍外擴還是縮小卡片。
 */
export function findEmptySpot(opts: SpotOptions): Box | null {
	const { anchor, size, occupied, viewport } = opts;
	const gap = opts.gap ?? 24;

	// 候選座標：錨點自身的邊、可見範圍的邊、每個障礙物的左右／上下外緣
	const xs = new Set<number>([anchor.x, right(anchor) + gap, viewport.x]);
	const ys = new Set<number>([anchor.y, bottom(anchor) + gap, viewport.y]);
	for (const o of occupied) {
		xs.add(right(o) + gap);
		xs.add(o.x - gap - size.width);
		ys.add(bottom(o) + gap);
		ys.add(o.y - gap - size.height);
	}

	const candidates: Box[] = [];
	for (const x of xs) {
		for (const y of ys) {
			candidates.push({ x, y, width: size.width, height: size.height });
		}
	}

	const cost = (c: Box): number => {
		// 方向懲罰遠大於距離，確保「右邊很遠」仍勝過「左邊很近」
		let penalty: number;
		if (c.x >= right(anchor)) penalty = 0;
		else if (c.y >= bottom(anchor)) penalty = 1e6;
		else if (bottom(c) <= anchor.y) penalty = 2e6;
		else penalty = 3e6;
		return penalty + Math.hypot(c.x - anchor.x, c.y - anchor.y);
	};
	candidates.sort((a, b) => cost(a) - cost(b));

	for (const c of candidates) {
		if (!contains(viewport, c)) continue;
		if (occupied.some((o) => overlaps(c, o, gap))) continue;
		return c;
	}
	return null;
}

/**
 * 找空位，可見範圍內塞不下就往右邊擴出去。
 * 擴出去的位置一定放得下（畫布是無限的），所以永遠有結果。
 */
export function findSpotOrExtend(opts: SpotOptions): Box {
	const inView = findEmptySpot(opts);
	if (inView) return inView;

	const gap = opts.gap ?? 24;
	const all = boundsOf([...opts.occupied, opts.viewport])!;
	return {
		x: right(all) + gap,
		y: opts.anchor.y,
		width: opts.size.width,
		height: opts.size.height,
	};
}
