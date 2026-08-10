import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
	overlaps,
	boundsOf,
	contains,
	viewportBounds,
	pickTargets,
	findEmptySpot,
	findSpotOrExtend,
	type Box,
} from './layout.ts';

const box = (x: number, y: number, width: number, height: number): Box => ({ x, y, width, height });

test('overlaps：相鄰不算重疊，gap 會把相鄰變成重疊', () => {
	assert.equal(overlaps(box(0, 0, 100, 100), box(100, 0, 100, 100)), false);
	assert.equal(overlaps(box(0, 0, 100, 100), box(100, 0, 100, 100), 10), true);
	assert.equal(overlaps(box(0, 0, 100, 100), box(50, 50, 100, 100)), true);
});

test('boundsOf：包住所有元素', () => {
	assert.deepEqual(
		boundsOf([box(10, 20, 30, 40), box(100, 0, 50, 50)]),
		box(10, 0, 140, 60),
	);
	assert.equal(boundsOf([]), null);
});

test('viewportBounds：zoom 縮小時可見範圍變大', () => {
	const at1 = viewportBounds({ scrollX: 0, scrollY: 0, zoom: { value: 1 } }, 1000, 800);
	assert.deepEqual(at1, box(0, 0, 1000, 800));

	const at05 = viewportBounds({ scrollX: -200, scrollY: -100, zoom: { value: 0.5 } }, 1000, 800);
	assert.deepEqual(at05, box(200, 100, 2000, 1600));
});

test('pickTargets：有圈選就只讀圈選的', () => {
	const all = [{ id: 'a', ...box(0, 0, 10, 10) }, { id: 'b', ...box(5000, 0, 10, 10) }];
	const picked = pickTargets(all, [all[1]], box(0, 0, 100, 100));
	assert.deepEqual(picked.map((e) => e.id), ['b']);
});

test('pickTargets：沒圈選時讀可見範圍，被邊界切一半的整塊算進去', () => {
	const all = [
		{ id: '畫面內', ...box(10, 10, 50, 50) },
		{ id: '切一半', ...box(950, 10, 200, 50) },
		{ id: '畫面外', ...box(3000, 10, 50, 50) },
	];
	const picked = pickTargets(all, [], box(0, 0, 1000, 800));
	assert.deepEqual(picked.map((e) => e.id), ['畫面內', '切一半']);
});

test('findEmptySpot：空畫布時放在錨點右側', () => {
	const anchor = box(100, 100, 200, 150);
	const spot = findEmptySpot({
		anchor,
		size: { width: 300, height: 120 },
		occupied: [anchor],
		viewport: box(0, 0, 1400, 900),
	});
	assert.ok(spot);
	assert.equal(spot.x, 324); // anchor 右緣 300 + gap 24
	assert.equal(spot.y, 100);
});

test('findEmptySpot：右側被佔用時往下避開，且不與任何元素重疊', () => {
	const anchor = box(100, 100, 200, 150);
	const blocker = box(324, 0, 400, 600); // 整條右側都擋住
	const occupied = [anchor, blocker];
	const spot = findEmptySpot({
		anchor,
		size: { width: 300, height: 120 },
		occupied,
		viewport: box(0, 0, 1400, 900),
	});
	assert.ok(spot);
	for (const o of occupied) {
		assert.equal(overlaps(spot, o, 24), false, `不該和 ${JSON.stringify(o)} 重疊`);
	}
});

test('findEmptySpot：可見範圍塞不下就回 null', () => {
	const anchor = box(0, 0, 100, 100);
	const spot = findEmptySpot({
		anchor,
		size: { width: 300, height: 120 },
		occupied: [anchor],
		viewport: box(0, 0, 200, 200), // 螢幕比卡片還小
	});
	assert.equal(spot, null);
});

test('findSpotOrExtend：塞不下時擴到所有元素右邊，永遠有結果', () => {
	const anchor = box(0, 0, 100, 100);
	const spot = findSpotOrExtend({
		anchor,
		size: { width: 300, height: 120 },
		occupied: [anchor],
		viewport: box(0, 0, 200, 200),
	});
	assert.ok(spot.x >= 200);
});

test('findEmptySpot：卡片一定完全落在可見範圍內', () => {
	const anchor = box(600, 400, 200, 150);
	const spot = findEmptySpot({
		anchor,
		size: { width: 300, height: 120 },
		occupied: [anchor],
		viewport: box(0, 0, 1000, 700),
	});
	assert.ok(spot);
	assert.equal(contains(box(0, 0, 1000, 700), spot), true);
});
