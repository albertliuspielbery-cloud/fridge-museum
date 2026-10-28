const L = require('./lib');
const R = '/tmp/claude-0/-home-user/bed2c260-5a9a-5d57-9a44-5819024f1478/scratchpad/real/';
const [w, h, loc, scheme] = [+process.argv[2] || 375, +process.argv[3] || 667, process.argv[4] || 'zh-TW', process.argv[5] || 'light'];
(async () => {
  const b = await L.launch(); const p = await L.newPage(b, { w, h, touch: true, mobile: w < 800, dpr: 2, locale: loc, scheme });
  const tag = `${w}_${loc}_${scheme}`;
  await L.open(p, L.BASE + 'v9.html');
  await L.loadFile(p, R + 'drawing_wood_orig.jpg', 'flat'); await p.waitForTimeout(300);
  const cdp = await p._ctx.newCDPSession(p);
  const touch = async (type, x, y) => cdp.send('Input.dispatchTouchEvent', { type, touchPoints: type === 'touchEnd' ? [] : [{ x, y, radiusX: 8, radiusY: 8, id: 1 }] });
  await p.evaluate(() => document.getElementById('t_crop').click()); await p.waitForTimeout(500);
  await p.screenshot({ path: `shots/crop_${tag}_open.png` });
  const g = await p.evaluate(() => { const r = id => { const x = document.getElementById(id).getBoundingClientRect(); return [x.top | 0, x.bottom | 0]; }; const sh = document.getElementById('sheet'); return { sheet: r('sheet'), sheetScroll: sh.scrollHeight + '/' + sh.clientHeight, tilt: r('tilt'), rotL: r('rotL'), redetect: r('redetect'), view: r('view'), ih: innerHeight, sw: document.documentElement.scrollWidth, quad: S.quad.map(q => q.map(Math.round)), fit, viewMode: S.view }; });
  console.log(tag, 'geom', JSON.stringify(g));
  // corner 0 client pos
  const c0 = await p.evaluate(() => { const r = document.getElementById('view').getBoundingClientRect(); return S.quad.map(q => [r.left + fit.ox + q[0] * fit.s, r.top + fit.oy + q[1] * fit.s]); });
  console.log(tag, 'corners(client)', JSON.stringify(c0.map(c => c.map(Math.round))));
  // drag the top-left corner inward by touch, starting 20px off the handle
  const [sx, sy] = [c0[0][0] + 18, c0[0][1] + 18];
  await touch('touchStart', sx, sy);
  for (let i = 1; i <= 8; i++) await touch('touchMove', sx + i * 5, sy + i * 5);
  await p.waitForTimeout(150);
  await p.screenshot({ path: `shots/crop_${tag}_dragging.png` });
  const dragging = await p.evaluate(() => drag && drag.kind);
  await touch('touchEnd'); await p.waitForTimeout(1200);
  const q2 = await p.evaluate(() => S.quad.map(q => q.map(Math.round)));
  console.log(tag, 'drag kind during move', dragging, 'quad after', JSON.stringify(q2), 'out', await p.evaluate(() => [S.output.width, S.output.height, (S.output.height / S.output.width).toFixed(3)]));
  // corners for all 4 reachable? test the bottom-right too
  const c1 = await p.evaluate(() => { const r = document.getElementById('view').getBoundingClientRect(); return S.quad.map(q => [r.left + fit.ox + q[0] * fit.s, r.top + fit.oy + q[1] * fit.s]); });
  const hits = await p.evaluate(cs => cs.map(([x, y]) => { const e = document.elementFromPoint(x, y); return e ? e.id || e.className : 'none'; }), c1);
  console.log(tag, 'what is at each corner', JSON.stringify(hits));
  await p.evaluate(() => document.getElementById('rotR').click()); await p.waitForTimeout(1200);
  console.log(tag, 'rotR out', await p.evaluate(() => [S.output.width, S.output.height, S.view, S.rot]));
  await p.screenshot({ path: `shots/crop_${tag}_rotR.png` });
  await p.evaluate(() => document.getElementById('rotL').click()); await p.waitForTimeout(1200);
  await p.evaluate(() => document.getElementById('rotL').click()); await p.waitForTimeout(1200);
  console.log(tag, 'rotL x2 out', await p.evaluate(() => [S.output.width, S.output.height, S.rot]));
  await p.evaluate(() => { const t = document.getElementById('tilt'); t.value = -4; t.dispatchEvent(new Event('input')); }); await p.waitForTimeout(1200);
  console.log(tag, 'tilt -4 out', await p.evaluate(() => [S.output.width, S.output.height, S.tilt]), 'tiltOut', await p.evaluate(() => document.getElementById('tiltOut').textContent));
  await p.screenshot({ path: `shots/crop_${tag}_tilt.png` });
  console.log(tag, 'errors', JSON.stringify(p._log.errors), JSON.stringify(p._log.console.filter(c => !/willRead/.test(c))));
  await b.close();
})();
