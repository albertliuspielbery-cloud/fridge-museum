const L = require('./lib');
const [base, file, tag, w, h] = [process.argv[2], process.argv[3], process.argv[4], +(process.argv[5] || 375), +(process.argv[6] || 667)];
(async () => {
  const b = await L.launch(); const p = await L.newPage(b, { w, h, touch: true, mobile: true, dpr: 2 });
  await L.open(p, base + 'v9.html');
  await L.loadFile(p, file, 'craft'); await p.waitForTimeout(300);
  const click = sel => p.evaluate(s => document.querySelector(s).click(), sel);
  const state = () => p.evaluate(() => { const P = craftParts(); return { chip: !document.getElementById('pickBtn').hidden, pressed: document.getElementById('pickBtn').getAttribute('aria-pressed'), keepAll: !document.getElementById('keepAllBtn').hidden, nSig: P && P.nSig, drop: S.pickDrop ? [...S.pickDrop].join('') : null, tool: S.tool, toast: document.getElementById('toast').hidden ? '' : document.getElementById('statusText').textContent, hint: document.getElementById('hint').textContent, out: S.output.width + 'x' + S.output.height }; });
  // find a client point over part #k (by order of sig parts, k=0..)
  const ptFor = k => p.evaluate(k => {
    const P = craftParts(), sig = P.list.filter(q => q && q.sig), L_ = sig[k].id, v = document.getElementById('view'), r = v.getBoundingClientRect();
    let best = null, bc = 0;
    for (let y = 4; y < r.height; y += 6) for (let x = 4; x < r.width; x += 6) {
      const px = (x - fit.ox) / fit.s, py = (y - fit.oy) / fit.s; if (!S.pickView || px < 0 || py < 0 || px > S.pickView.canvas.width || py > S.pickView.canvas.height) continue;
      const [sx, sy] = S.pickView.toSrc(px, py); if (partAt(P, sx, sy, 0) === L_) { bc++; if (!best || Math.random() < 1 / bc) best = [r.left + x, r.top + y]; }
    }
    // choose a central one: re-scan for the median
    return best;
  }, k);
  const tapPart = async k => { const c = await ptFor(k); if (!c) return 'nopt'; await p.touchscreen.tap(c[0], c[1]); await p.waitForTimeout(500); return c.map(Math.round); };
  console.log(tag, 'initial', JSON.stringify(await state()));
  await p.screenshot({ path: `shots/pick_${tag}_0.png` });
  const chipBox = await p.locator('#pickBtn').boundingBox(); if (chipBox) await p.touchscreen.tap(chipBox.x + chipBox.width / 2, chipBox.y + chipBox.height / 2); else await click('#pickBtn');
  await p.waitForTimeout(400);
  console.log(tag, 'pick on', JSON.stringify(await state()));
  await p.screenshot({ path: `shots/pick_${tag}_1_on.png` });
  console.log(tag, 'tap part1', await tapPart(1), JSON.stringify(await state()));
  await p.screenshot({ path: `shots/pick_${tag}_2_drop1.png` });
  console.log(tag, 'tap part0 (last)', await tapPart(0), JSON.stringify(await state()));
  await p.screenshot({ path: `shots/pick_${tag}_3_last.png` });
  console.log(tag, 'tap part1 again', await tapPart(1), JSON.stringify(await state()));
  console.log(tag, 'tap part0', await tapPart(0), JSON.stringify(await state()));
  const ka = await p.locator('#keepAllBtn').boundingBox(); if (ka) { await p.touchscreen.tap(ka.x + ka.width / 2, ka.y + ka.height / 2); await p.waitForTimeout(400); }
  console.log(tag, 'keepAll', JSON.stringify(await state()));
  // drop part1 again, then exit pick, rotate / straighten / sens
  await tapPart(1); await click('#pickBtn'); await p.waitForTimeout(300);
  console.log(tag, 'drop1+exit', JSON.stringify(await state()));
  await click('#t_adjust'); await p.waitForTimeout(300);
  await p.screenshot({ path: `shots/pick_${tag}_4_adjust.png` });
  const turnVis = await p.evaluate(() => { const r = document.getElementById('tilt').getBoundingClientRect(), rr = document.getElementById('rotR').getBoundingClientRect(); return { tilt: [r.top | 0, r.bottom | 0], rot: [rr.top | 0, rr.bottom | 0], ih: innerHeight }; });
  console.log(tag, 'craft turn controls', JSON.stringify(turnVis));
  await click('#rotR'); await p.waitForTimeout(800); console.log(tag, 'rotR', JSON.stringify(await state()));
  await p.evaluate(() => { const t = document.getElementById('tilt'); t.value = 6; t.dispatchEvent(new Event('input')); }); await p.waitForTimeout(900);
  console.log(tag, 'tilt6', JSON.stringify(await state()));
  await p.evaluate(() => { const t = document.getElementById('sens'); t.value = 70; t.dispatchEvent(new Event('input')); }); await p.waitForTimeout(1500);
  console.log(tag, 'sens70', JSON.stringify(await state()));
  await p.evaluate(() => { const t = document.getElementById('sens'); t.value = 30; t.dispatchEvent(new Event('input')); }); await p.waitForTimeout(1500);
  console.log(tag, 'sens30', JSON.stringify(await state()));
  await p.screenshot({ path: `shots/pick_${tag}_5_turned.png` });
  // pick again on rotated view: tap part0 → keep-one toast expected, tap part1 → restore
  await click('#sheetDone'); await p.waitForTimeout(200); await click('#pickBtn'); await p.waitForTimeout(400);
  console.log(tag, 'rot pick tap1', await tapPart(1), JSON.stringify(await state()));
  await p.screenshot({ path: `shots/pick_${tag}_6_rotpick.png` });
  await click('#pickBtn');
  // brushes
  await click('#t_brush'); await p.waitForTimeout(300);
  const before = await p.evaluate(() => { const c = S.output, x = c.getContext('2d'); const d = x.getImageData(0, 0, c.width, c.height).data; let s = 0; for (let i = 0; i < d.length; i += 40) s += d[i]; return s; });
  const vb = await p.locator('#view').boundingBox();
  const cx = vb.x + vb.width / 2, cy = vb.y + vb.height / 2;
  await p.mouse.move(cx - 40, cy); await p.mouse.down(); for (let i = 0; i < 10; i++) await p.mouse.move(cx - 40 + i * 8, cy + i * 3); await p.mouse.up(); await p.waitForTimeout(700);
  const after = await p.evaluate(() => { const c = S.output, x = c.getContext('2d'); const d = x.getImageData(0, 0, c.width, c.height).data; let s = 0; for (let i = 0; i < d.length; i += 40) s += d[i]; return s; });
  console.log(tag, 'brush strokes', await p.evaluate(() => S.strokes.length), 'output changed', before !== after, 'chip hidden in brush', await p.evaluate(() => document.getElementById('pickBtn').hidden), 'tool', await p.evaluate(() => S.tool));
  await p.screenshot({ path: `shots/pick_${tag}_7_brush.png` });
  await click('#undo'); await p.waitForTimeout(500); console.log(tag, 'undo strokes', await p.evaluate(() => S.strokes.length));
  await click('#sheetDone'); await p.waitForTimeout(300); console.log(tag, 'after brush sheet closed', JSON.stringify(await state()));
  console.log(tag, 'errors', JSON.stringify(p._log.errors), JSON.stringify(p._log.console));
  await b.close();
})();
