import { test } from "node:test";
import assert from "node:assert/strict";
import { groupStrokes, groupBounds, anchorGroup } from "./grouping.ts";
import { findEmptySpot } from "./layout.ts";

/** 造一筆手寫：x, y, 寬, 高 */
const s = (x: number, y: number, width = 100, height = 10) => ({
	x, y, width, height,
});

test("同一題的上下行合成一群", () => {
	const strokes = [s(0, 0), s(0, 34), s(0, 68)];
	assert.equal(groupStrokes(strokes).length, 1);
});

test("隔很遠的兩題分開", () => {
	const strokes = [s(0, 0), s(0, 34), s(0, 600), s(0, 634)];
	const groups = groupStrokes(strokes);
	assert.equal(groups.length, 2);
	assert.equal(groups[0].length, 2);
	assert.equal(groups[1].length, 2);
});

test("連鎖：一行字靠接龍連起來，頭尾很遠也算同一群", () => {
	// 每個字寬 20、間隔 10，整行長 900 —— 遠超過 gapX
	const strokes = Array.from({ length: 30 }, (_, i) => s(i * 30, 0, 20, 10));
	assert.equal(groupStrokes(strokes).length, 1);
});

test("直向門檻比橫向嚴：同樣距離，橫向算同群、直向算兩群", () => {
	const gap = 60; // 介於 DEFAULT_GAP_Y(45) 和 DEFAULT_GAP_X(80) 之間
	assert.equal(groupStrokes([s(0, 0, 10, 10), s(10 + gap, 0, 10, 10)]).length, 1);
	assert.equal(groupStrokes([s(0, 0, 10, 10), s(0, 10 + gap, 10, 10)]).length, 2);
});

test("群按左上到右下排序", () => {
	const groups = groupBounds([s(1000, 500), s(0, 0), s(0, 300)]);
	assert.deepEqual(groups.map((g) => g.y), [0, 300, 500]);
});

test("空輸入不會爆", () => {
	assert.deepEqual(groupStrokes([]), []);
	assert.deepEqual(groupBounds([]), []);
	assert.equal(anchorGroup([]), null);
});

test("錨點取最下面那一群", () => {
	const groups = groupBounds([s(0, 0), s(0, 300), s(0, 600)]);
	assert.equal(anchorGroup(groups)!.y, 600);
});

test("同高時錨點取最右邊", () => {
	const groups = groupBounds([s(0, 0), s(900, 0)]);
	assert.equal(anchorGroup(groups)!.x, 900);
});

test("分群後的外框餵給 findEmptySpot，卡片不會壓到任何一筆手寫", () => {
	// 三題散在各處，每題三行
	const strokes = [
		s(0, 0, 260), s(0, 34, 300), s(0, 68, 220),
		s(180, 620, 320), s(180, 654, 280), s(180, 688, 240),
		s(1150, 260, 240), s(1150, 294, 300), s(1150, 328, 260),
	];
	const occupied = groupBounds(strokes);
	assert.equal(occupied.length, 3);

	const spot = findEmptySpot({
		anchor: occupied[0],
		size: { width: 320, height: 110 },
		occupied,
		viewport: { x: -100, y: -100, width: 2000, height: 1500 },
	});
	assert.ok(spot, "應該找得到空位");

	for (const st of strokes) {
		const noOverlap =
			spot!.x + spot!.width <= st.x ||
			st.x + st.width <= spot!.x ||
			spot!.y + spot!.height <= st.y ||
			st.y + st.height <= spot!.y;
		assert.ok(noOverlap, `卡片壓到 (${st.x}, ${st.y}) 的手寫`);
	}
});

test("一百筆手寫也能在合理時間內分群", () => {
	const strokes = Array.from({ length: 100 }, (_, i) =>
		s((i % 10) * 300, Math.floor(i / 10) * 300),
	);
	const groups = groupStrokes(strokes);
	assert.equal(groups.length, 100); // 每筆都隔很遠，各自成群
});
