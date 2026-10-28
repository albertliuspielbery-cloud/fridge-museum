// usage: node realrun.js <kidart.html> <tag>   -> real/out-<tag>/
const { chromium } = require('playwright'); const fs = require('fs'), path = require('path');
const [, , file, tag] = process.argv; const D = __dirname, RD = path.join(D, '../real'), OUT = path.join(RD, 'out-' + tag); fs.mkdirSync(OUT, { recursive: true });
const html = '<!doctype html><html><head><meta charset=utf8><style>[hidden]{display:none!important}</style></head><body>' + fs.readFileSync(file, 'utf8').replace(/<link[^>]+fonts[^>]+>/g, '') + '</body></html>';
const wrap = path.join(D, '_real_' + tag + '.html'); fs.writeFileSync(wrap, html);
const cases = [['drawing_wood', 'drawing_wood_orig.jpg', 'flat', null], ['drawing_marble', 'drawing_marble_orig.jpg', 'flat', [[466, 607], [1494, 572], [1775, 2141], [295, 2152]]], ['marble_shot', 'marble_crop.jpg', 'flat', [[330, 425], [960, 398], [1145, 1350], [135, 1328]]], ['flag_marble', 'flag_marble_orig.jpg', 'craft', null]];
(async () => {
  const b = await chromium.launch(); const p = await b.newPage(); const errs = []; p.on('pageerror', e => errs.push(e.message));
  await p.goto('file://' + wrap); await p.waitForTimeout(2000);
  for (const [name, f, mode, gt] of cases) {
    const url = 'data:image/jpeg;base64,' + fs.readFileSync(path.join(RD, f)).toString('base64');
    const r = await p.evaluate(async ([url, mode, gt]) => {
      const im = new Image(); await new Promise(r => { im.onload = r; im.src = url; });
      const c = makeCanvas(im.naturalWidth, im.naturalHeight); c.getContext('2d').drawImage(im, 0, 0);
      setModeUI(mode); S.strokes = []; S.paperDebug = null; S.rodDebug = null; const t0 = performance.now(); S.src = scaledCanvas(c, MAX_SRC);
      if (mode === 'flat') { S.quad = detectPaper(S.src); buildFlat(); } else buildCraft(); render(); const t = performance.now() - t0;
      const th = (cv, w) => { const s = w / cv.width, o = makeCanvas(w, Math.round(cv.height * s)), x = o.getContext('2d'); x.drawImage(cv, 0, 0, o.width, o.height); return [o, x, s]; };
      const [ov, ox, s] = th(S.src, 600);
      if (mode === 'flat') { const k = s * S.src.width / c.width; const poly = (q, col, sc) => { ox.strokeStyle = col; ox.lineWidth = 3; ox.beginPath(); q.forEach((p, i) => i ? ox.lineTo(p[0] * sc, p[1] * sc) : ox.moveTo(p[0] * sc, p[1] * sc)); ox.closePath(); ox.stroke(); }; if (gt) poly(gt, '#00e05a', k); poly(S.quad, '#ff2a2a', s); }
      else { const a = S.craft.alphaBase, W = S.src.width, id = ox.getImageData(0, 0, ov.width, ov.height); for (let y = 0; y < ov.height; y++) for (let x = 0; x < ov.width; x++) { const v = a[Math.floor(y / s) * W + Math.floor(x / s)], j = (y * ov.width + x) * 4; if (v < 128) { id.data[j] = id.data[j] * 0.4; id.data[j + 1] = id.data[j + 1] * 0.4; id.data[j + 2] = id.data[j + 2] * 0.4 + 80; } } ox.putImageData(id, 0, 0); }
      return { rod: S.rodDebug, pb: S.paperBorder, t, fill: S.flat && S.flat.fill && S.flat.fill.area, mode: S.flat && S.flat.mode, hint: $('hint').textContent, dbg: S.paperDebug, info: S.craft && S.craft.info, quad: S.quad, ov: ov.toDataURL('image/jpeg', 0.85), out: th(S.output, 600)[0].toDataURL('image/jpeg', 0.88) };
    }, [url, mode, gt]);
    fs.writeFileSync(path.join(OUT, name + '_in.jpg'), Buffer.from(r.ov.split(',')[1], 'base64')); fs.writeFileSync(path.join(OUT, name + '_out.jpg'), Buffer.from(r.out.split(',')[1], 'base64'));
    delete r.ov; delete r.out; console.log(name, JSON.stringify(r));
  }
  console.log('ERR', errs); await b.close(); fs.unlinkSync(wrap);
})();
