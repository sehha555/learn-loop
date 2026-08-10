/**
 * 手寫分群：把散落的筆畫合併成「一題」。
 *
 * 為什麼需要：版面計算的 occupied 不能傳每一筆 freedraw。
 * 候選位置數量是障礙物數量的平方，一頁手寫幾百筆就會卡；
 * 而且「避開每一筆」和「避開這一題」在視覺上是同一件事。
 *
 * 跟 layout.ts 一樣不依賴 Obsidian 與 Excalidraw，只吃矩形吐矩形。
 */

import { boundsOf, type Box, type Positioned } from "./layout.ts";

export interface GroupOptions {
	/** 橫向要隔多遠才算不同題（字與字之間會比這近很多） */
	gapX?: number;
	/** 直向要隔多遠才算不同題（同一題的行距要小於這個值） */
	gapY?: number;
}

/**
 * 直向門檻比橫向小。
 * 同一題的上下行貼得很近（行距），左右卻常常拉很開（一整行算式）；
 * 反過來說，兩題之間通常是「空一行」，直向留白反而是最可靠的分界。
 */
const DEFAULT_GAP_X = 80;
const DEFAULT_GAP_Y = 45;

/** 兩個矩形的間距是否小於門檻（各軸分開看） */
function near(a: Box, b: Box, gapX: number, gapY: number): boolean {
	const dx = Math.max(a.x - (b.x + b.width), b.x - (a.x + a.width), 0);
	const dy = Math.max(a.y - (b.y + b.height), b.y - (a.y + a.height), 0);
	return dx <= gapX && dy <= gapY;
}

/**
 * 把靠得夠近的筆畫分成一群。
 *
 * 用的是「連鎖」規則：A 靠近 B、B 靠近 C，三個就同一群，即使 A 和 C 很遠。
 * 這正是手寫要的行為 —— 一行字是一顆顆字元接龍連起來的，
 * 不能要求整題的頭尾互相靠近。
 *
 * 回傳的每一群保持原本的元素順序，群本身按左上到右下排。
 */
export function groupStrokes<T extends Positioned>(
	items: T[],
	opts: GroupOptions = {},
): T[][] {
	const gapX = opts.gapX ?? DEFAULT_GAP_X;
	const gapY = opts.gapY ?? DEFAULT_GAP_Y;

	// union-find：parent[i] 指向同群的代表元素
	const parent = items.map((_, i) => i);
	const find = (i: number): number => {
		while (parent[i] !== i) {
			parent[i] = parent[parent[i]];
			i = parent[i];
		}
		return i;
	};
	const union = (a: number, b: number) => {
		const ra = find(a), rb = find(b);
		if (ra !== rb) parent[rb] = ra;
	};

	for (let i = 0; i < items.length; i++) {
		for (let j = i + 1; j < items.length; j++) {
			if (near(items[i], items[j], gapX, gapY)) union(i, j);
		}
	}

	const buckets = new Map<number, T[]>();
	for (let i = 0; i < items.length; i++) {
		const root = find(i);
		const bucket = buckets.get(root);
		if (bucket) bucket.push(items[i]);
		else buckets.set(root, [items[i]]);
	}

	const groups = [...buckets.values()];
	groups.sort((a, b) => {
		const ba = boundsOf(a)!, bb = boundsOf(b)!;
		return ba.y - bb.y || ba.x - bb.x;
	});
	return groups;
}

/** 分群後只要每一群的外框 —— 這就是丟給 findEmptySpot 的 occupied */
export function groupBounds<T extends Positioned>(
	items: T[],
	opts: GroupOptions = {},
): Box[] {
	return groupStrokes(items, opts).map((g) => boundsOf(g)!);
}

/**
 * 找出使用者最後寫的那一群，當作卡片的錨點。
 *
 * 「最後」用畫面位置判斷（最下面、同高取最右），不是寫入時間 ——
 * 回頭補寫上一題時，卡片應該長在那一題旁邊，而不是跳到畫布最底下。
 */
export function anchorGroup(groups: Box[]): Box | null {
	if (groups.length === 0) return null;
	return groups.reduce((best, g) =>
		g.y + g.height > best.y + best.height ||
		(g.y + g.height === best.y + best.height && g.x > best.x)
			? g
			: best,
	);
}
