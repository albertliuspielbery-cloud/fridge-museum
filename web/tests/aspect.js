// Regression: true-perspective A4 shots (camera pitch 30-45 deg) + real photos must come out at A4 ratio; circle must stay round.
const { chromium } = require('playwright'); const fs = require('fs'), path = require('path');
const file = process.argv[2], D = __dirname;
const html = '<!doctype html><html><head><meta charset=utf8></head><body>' + fs.readFileSync(file, 'utf8').replace(/<link[^>]+fonts[^>]+>/g, '') + '</body></html>';
const wrap = path.join(D, '_asp.html'); fs.writeFileSync(wrap, html);
(async () => {
  const b = await chromium.launch(); const p = await b.newPage(); await p.goto('file://' + wrap); await p.waitForTimeout(1500); await p.addScriptTag({ path: path.join(D, 'gen.js') });
  const res = await p.evaluate(async () => {
    const PW = 1800, PH = 2400, out = [];
    // A4 sheet with a big circle and a square
    const sh = makeCanvas(1000, 1414), x = sh.getContext('2d'); x.fillStyle = '#f6f3ec'; x.fillRect(0, 0, 1000, 1414);
    x.strokeStyle = '#111'; x.lineWidth = 14; x.beginPath(); x.arc(500, 520, 330, 0, 7); x.stroke(); x.fillStyle = '#d33'; x.fillRect(350, 1000, 300, 300);
    const measure = img => { // bbox of dark pixels (circle) in the upper 60% and of red square
      const W = img.width, H = img.height, d = img.data; let a = [W, H, -1, -1], s = [W, H, -1, -1];
      for (let y = 0; y < H; y++) for (let X = 0; X < W; X++) { const i = (y * W + X) * 4, r = d[i], g = d[i + 1], bb = d[i + 2];
        if (y < H * 0.62 && r < 90 && g < 90 && bb < 90) { a[0] = Math.min(a[0], X); a[1] = Math.min(a[1], y); a[2] = Math.max(a[2], X); a[3] = Math.max(a[3], y); }
        if (y > H * 0.62 && r > 150 && g < 110 && bb < 110) { s[0] = Math.min(s[0], X); s[1] = Math.min(s[1], y); s[2] = Math.max(s[2], X); s[3] = Math.max(s[3], y); } }
      return { circle: +((a[2] - a[0]) / (a[3] - a[1])).toFixed(3), square: +((s[2] - s[0]) / (s[3] - s[1])).toFixed(3) };
    };
    const run = async (src, label, gtq) => {
      setModeUI('flat'); S.strokes = []; S.rot = S.tilt = 0; S.src = scaledCanvas(src, MAX_SRC); S.quad = gtq || detectPaper(S.src); buildFlat(); render();
      const o = S.output, img = o.getContext('2d').getImageData(0, 0, o.width, o.height);
      return { label, HoverW: +(o.height / o.width).toFixed(3), ...measure(img) };
    };
    for (const [pitch, yaw, fmul] of [[30, 0, 0.75], [40, 0, 0.75], [45, 0, 0.75], [35, 20, 0.75], [45, -25, 0.75], [40, 15, 0.68], [40, 0, 0.82], [40, 0, 1.0]]) {
      const f = fmul * PH, th = pitch * Math.PI / 180, ya = yaw * Math.PI / 180, Dd = 400;
      const C = [0, -Math.sin(th) * Dd, Math.cos(th) * Dd]; // camera looks at origin
      const zc = C.map(v => -v / Dd), xc = [1, 0, 0], yc = [zc[1] * xc[2] - zc[2] * xc[1], zc[2] * xc[0] - zc[0] * xc[2], zc[0] * xc[1] - zc[1] * xc[0]];
      const proj = ([X, Y]) => { const P = [X * Math.cos(ya) - Y * Math.sin(ya), X * Math.sin(ya) + Y * Math.cos(ya), 0].map((v, i) => v - C[i]); const cx = P[0] * xc[0] + P[1] * xc[1] + P[2] * xc[2], cy = P[0] * yc[0] + P[1] * yc[1] + P[2] * yc[2], cz = P[0] * zc[0] + P[1] * zc[1] + P[2] * zc[2]; return [PW / 2 + f * cx / cz, PH / 2 - f * cy / cz]; };
      const q = [[-105, -148.5], [105, -148.5], [105, 148.5], [-105, 148.5]].map(proj); const Dd2 = 0;
      const ph = await (async () => { const c = makeCanvas(PW, PH), g = c.getContext('2d', { willReadFrequently: true }); g.drawImage((() => { const t = makeCanvas(PW, PH), tx = t.getContext('2d'); const gr = tx.createLinearGradient(0, 0, PW, PH); gr.addColorStop(0, '#9a6a45'); gr.addColorStop(1, '#74492d'); tx.fillStyle = gr; tx.fillRect(0, 0, PW, PH); return t; })(), 0, 0);
        const id = g.getImageData(0, 0, PW, PH), dd = id.data, sd = sh.getContext('2d').getImageData(0, 0, 1000, 1414).data, hm = homography(q, [[0, 0], [1000, 0], [1000, 1414], [0, 1414]]);
        for (let y = 0; y < PH; y++) for (let X = 0; X < PW; X++) { const den = hm[6] * X + hm[7] * y + 1, u = (hm[0] * X + hm[1] * y + hm[2]) / den, v = (hm[3] * X + hm[4] * y + hm[5]) / den; if (u < 0 || v < 0 || u >= 1000 || v >= 1414) continue; const si = ((v | 0) * 1000 + (u | 0)) * 4, j = (y * PW + X) * 4; dd[j] = sd[si] * 0.95; dd[j + 1] = sd[si + 1] * 0.94; dd[j + 2] = sd[si + 2] * 0.9; }
        g.putImageData(id, 0, 0); return c; })();
      const r = await run(ph, `pitch${pitch} yaw${yaw} f${fmul}L`); r.img = scaledCanvas(ph, 300).toDataURL('image/jpeg'); r.out = scaledCanvas(S.output, 300).toDataURL('image/jpeg'); r.q = q.map(p => p.map(Math.round)); r.quadErr = +(S.quad.reduce((a, p, i) => a + dist(p, q[i]), 0) / 4).toFixed(1); out.push(r);
    }
    return out;
  });
  for (const [label, f, gt] of [['real wood', 'drawing_wood_orig.jpg'], ['real marble', 'drawing_marble_orig.jpg']]) {
    const url = 'data:image/jpeg;base64,' + fs.readFileSync(path.join(D, '../real', f)).toString('base64');
    res.push(await p.evaluate(async ([url, label]) => { const im = new Image(); await new Promise(r => { im.onload = r; im.src = url; }); const c = makeCanvas(im.naturalWidth, im.naturalHeight); c.getContext('2d').drawImage(im, 0, 0);
      setModeUI('flat'); S.strokes = []; S.rot = S.tilt = 0; S.src = scaledCanvas(c, MAX_SRC); S.quad = detectPaper(S.src); buildFlat(); render();
      const o = S.output, d = o.getContext('2d').getImageData(0, 0, o.width, o.height).data, W = o.width, H = o.height;
      // the big face circle: dark pixels in the top-left 60%x35% region, bbox
      let a = [W, H, -1, -1]; for (let y = Math.round(H * 0.06); y < H * 0.36; y++) for (let X = 0; X < W * 0.62; X++) { const i = (y * W + X) * 4; if (d[i] < 70 && d[i + 1] < 70 && d[i + 2] < 70) { a[0] = Math.min(a[0], X); a[1] = Math.min(a[1], y); a[2] = Math.max(a[2], X); a[3] = Math.max(a[3], y); } }
      return { label, HoverW: +(H / W).toFixed(3), faceBox: [a[2] - a[0], a[3] - a[1]], face: +((a[2] - a[0]) / (a[3] - a[1])).toFixed(3) }; }, [url, label]));
  }
  res.forEach((r, i) => { if (r.img) { fs.writeFileSync(path.join(D, 'asp' + i + '_in.jpg'), Buffer.from(r.img.split(',')[1], 'base64')); fs.writeFileSync(path.join(D, 'asp' + i + '_out.jpg'), Buffer.from(r.out.split(',')[1], 'base64')); delete r.img; delete r.out; } console.log(JSON.stringify(r)); }); await b.close(); fs.unlinkSync(wrap);
})();
