// usage: node run.js <kidart.html> <tag> [case filter]
const { chromium } = require('playwright'); const fs = require('fs'), path = require('path');
const [, , file, tag, filt] = process.argv; const D = __dirname, OUT = path.join(D, 'out-' + tag); fs.mkdirSync(OUT, { recursive: true });
const html = '<!doctype html><html><head><meta charset=utf8><meta name=viewport content="width=device-width,initial-scale=1"><style>[hidden]{display:none!important}</style></head><body>' + fs.readFileSync(file, 'utf8').replace(/<link[^>]+fonts[^>]+>/g, '') + '</body></html>';
const wrap = path.join(D, '_page_' + tag + '.html'); fs.writeFileSync(wrap, html);
(async () => {
  const b = await chromium.launch(); const p = await b.newPage({ viewport: { width: 390, height: 844 } }); const errs = [];
  p.on('pageerror', e => errs.push(e.message)); p.on('console', m => { if (m.type() === 'error') errs.push(m.text()); });
  await p.goto('file://' + wrap); await p.waitForTimeout(3000); await p.addScriptTag({ path: path.join(D, 'gen.js') });
  const names = await p.evaluate(() => [...Object.keys(HARD.FLAT).map(n => 'F:' + n), ...HARD.CRAFT.map(n => 'C:' + n)]);
  const res = [];
  const keep = r => { const { imIn, imOut, imProc, ...m } = r; if (imProc) fs.writeFileSync(path.join(OUT, r.name + '_proc.jpg'), Buffer.from(imProc.split(',')[1], 'base64')); fs.writeFileSync(path.join(OUT, r.name + '_in.jpg'), Buffer.from(imIn.split(',')[1], 'base64')); fs.writeFileSync(path.join(OUT, r.name + '_out.jpg'), Buffer.from(imOut.split(',')[1], 'base64')); res.push(m); console.log(JSON.stringify(m, (k, v) => typeof v === 'number' ? +v.toFixed(3) : v)); };
  if (!filt || filt === 'samples') for (const r of await p.evaluate(() => HARD.runSamples())) keep(r);
  for (const n of names) { if (filt && filt !== 'samples' && !n.includes(filt)) continue; if (filt === 'samples') break; const [k, nm] = n.split(':'); keep(await p.evaluate(([k, nm]) => k === 'F' ? HARD.runFlat(nm) : HARD.runCraft(nm), [k, nm])); }
  // timing: repeat typical cases after warm-up, report the median (end-to-end: detect + warp + flatten + whiten + specks / mask + alpha + compose)
  if (!filt) { const tm = await p.evaluate(async () => { const med = a => a.sort((x, y) => x - y)[a.length >> 1], o = {}; for (const [k, f] of [['flat normal', () => HARD.runFlat('normal')], ['flat phoneShadow', () => HARD.runFlat('phoneShadow')], ['craft thin', () => HARD.runCraft('thin')], ['craft whiteClay', () => HARD.runCraft('whiteClay')]]) { const t = []; for (let i = 0; i < 5; i++) t.push((await f()).tTotal); o[k] = +med(t).toFixed(0); } o.heapMB = performance.memory ? +(performance.memory.usedJSHeapSize / 1e6).toFixed(0) : null; return o; }); console.log('TIMING', JSON.stringify(tm)); fs.writeFileSync(path.join(OUT, 'timing.json'), JSON.stringify(tm)); }
  fs.writeFileSync(path.join(OUT, 'metrics.json'), JSON.stringify(res, null, 1));
  console.log('ERRORS', errs.length ? errs.join('\n') : 'none'); await b.close(); fs.unlinkSync(wrap);
})();
