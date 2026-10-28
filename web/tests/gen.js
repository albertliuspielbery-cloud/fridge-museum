// Synthetic hard-case generator + metrics. Runs inside the kidart page (uses its globals).
(function () {
const PW = 2400, PH = 1800;
const mk = (w, h) => { const c = document.createElement("canvas"); c.width = w; c.height = h; return c; };
const cx2 = c => c.getContext("2d", { willReadFrequently: true });
function R0(seed) { let s = seed; return () => (s = (s * 16807) % 2147483647) / 2147483647; }

// ---------- tables ----------
function table(kind, R) {
  const c = mk(PW, PH), x = cx2(c);
  if (kind === "wood" || kind === "woodstrong") {
    const g = x.createLinearGradient(0, 0, PW, PH); g.addColorStop(0, "#9a6a45"); g.addColorStop(1, "#74492d"); x.fillStyle = g; x.fillRect(0, 0, PW, PH);
    const n = kind === "woodstrong" ? 420 : 160;
    for (let i = 0; i < n; i++) { const dk = R() < 0.5; x.strokeStyle = dk ? `rgba(${40 + R() * 30},${20 + R() * 15},8,${0.1 + R() * (kind === "woodstrong" ? 0.35 : 0.12)})` : `rgba(210,160,110,${0.05 + R() * (kind === "woodstrong" ? 0.25 : 0.06)})`; x.lineWidth = 1 + R() * (kind === "woodstrong" ? 9 : 4); x.beginPath(); const y = R() * PH; x.moveTo(0, y); x.bezierCurveTo(PW * 0.3, y + R() * 80 - 40, PW * 0.6, y + R() * 80 - 40, PW, y + R() * 60 - 30); x.stroke(); }
  } else if (kind === "white") {
    x.fillStyle = "#e7e5e1"; x.fillRect(0, 0, PW, PH);
    for (let i = 0; i < 900; i++) { x.fillStyle = `rgba(${R() < 0.5 ? "120,115,110" : "255,255,255"},${0.03 + R() * 0.05})`; x.beginPath(); x.ellipse(R() * PW, R() * PH, 10 + R() * 90, 4 + R() * 30, R() * 3, 0, 7); x.fill(); }
  } else if (kind === "gingham") {
    x.fillStyle = "#f4f1ec"; x.fillRect(0, 0, PW, PH); const s = 70;
    x.fillStyle = "rgba(200,40,45,.55)"; for (let i = 0; i < PW / s; i += 2) x.fillRect(i * s, 0, s, PH); for (let j = 0; j < PH / s; j += 2) x.fillRect(0, j * s, PW, s);
    for (let i = 0; i < 4000; i++) { x.fillStyle = `rgba(0,0,0,${R() * 0.05})`; x.fillRect(R() * PW, R() * PH, 1 + R() * 6, 1); }
  } else if (kind === "floral") {
    x.fillStyle = "#3a5b8c"; x.fillRect(0, 0, PW, PH); const cols = ["#f5f0e6", "#f2c94c", "#e86f8a", "#ffffff", "#8fd0a0"];
    for (let i = 0; i < 700; i++) { x.fillStyle = cols[(R() * cols.length) | 0]; const px = R() * PW, py = R() * PH, r = 12 + R() * 40; for (let k = 0; k < 5; k++) { x.beginPath(); x.arc(px + Math.cos(k * 1.26) * r, py + Math.sin(k * 1.26) * r, r * 0.6, 0, 7); x.fill(); } }
  } else if (kind === "gray") { x.fillStyle = "#8d8f93"; x.fillRect(0, 0, PW, PH); }
  else if (kind === "same") { x.fillStyle = "rgb(246,243,236)"; x.fillRect(0, 0, PW, PH); }
  return c;
}

// ---------- sheets (ground-truth flat drawings, true paper color) ----------
const SW = 1000, SH = 750;
function sheet(kind, R) {
  const c = mk(SW, SH), x = cx2(c);
  const paper = kind === "colored" ? [150, 196, 232] : kind === "black" ? [34, 34, 38] : kind === "kraft" ? [196, 160, 112] : [246, 243, 236];
  x.fillStyle = `rgb(${paper})`; x.fillRect(0, 0, SW, SH);
  const crayon = (col, pts, w, n, al = 0.6) => { x.strokeStyle = col; x.lineCap = "round"; x.lineJoin = "round"; for (let k = 0; k < n; k++) { x.lineWidth = w * (0.6 + R() * 0.6); x.globalAlpha = al + R() * 0.3; x.beginPath(); pts.forEach((p, i) => { const px = p[0] + (R() - 0.5) * w, py = p[1] + (R() - 0.5) * w; i ? x.lineTo(px, py) : x.moveTo(px, py); }); x.stroke(); } x.globalAlpha = 1; };
  const meta = { dots: [], specks: [], paper };
  const house = () => { for (let yy = 330; yy < 560; yy += 12) crayon("#d8473b", [[380, yy], [640, yy + 4]], 12, 1); crayon("#9b2f27", [[380, 330], [640, 330], [640, 560], [380, 560], [380, 330]], 6, 2); for (let k = 0; k < 11; k++) crayon("#3c5bd8", [[360 + k * 3, 330], [510, 210 + k * 6], [660 - k * 3, 330]], 9, 1); };
  if (kind === "normal" || kind === "colored" || kind === "kraft") {
    house(); crayon("#4caf50", Array.from({ length: 40 }, (_, i) => [40 + i * 24, 640 + (i % 2 ? -26 : 8)]), 10, 3);
    crayon(kind === "colored" ? "#fff6a0" : "#f6df6e", Array.from({ length: 30 }, (_, i) => [160 + Math.cos(i / 29 * 7) * 50, 150 + Math.sin(i / 29 * 7) * 50]), 14, 2);
    crayon("#555", [[790, 400], [790, 520]], 3, 2); crayon("#555", [[740, 450], [840, 450]], 3, 2); crayon("#555", Array.from({ length: 20 }, (_, i) => [790 + Math.cos(i / 19 * 7) * 30, 368 + Math.sin(i / 19 * 7) * 30]), 3, 2);
    if (kind === "normal") { x.fillStyle = "#38342e"; for (const [px, py, r] of [[300, 90, 2.5], [880, 260, 3], [120, 470, 2.5], [930, 700, 3], [600, 700, 2]]) { x.beginPath(); x.arc(px, py, r, 0, 7); x.fill(); meta.specks.push([px, py]); } }
  } else if (kind === "black") {
    crayon("#f4f4f0", Array.from({ length: 30 }, (_, i) => [500 + Math.cos(i / 29 * 7) * 150, 360 + Math.sin(i / 29 * 7) * 150]), 10, 2, 0.7);
    crayon("#ffe066", [[150, 150], [300, 260], [180, 400]], 12, 2, 0.7); crayon("#ff7aa8", [[700, 600], [900, 520]], 14, 2, 0.7); crayon("#7ad0ff", [[120, 650], [450, 600]], 14, 2, 0.7);
  } else if (kind === "paint") {
    // full-coverage poster paint: sky, ground, sun; ~2% bare paper at a ragged margin
    x.fillStyle = "#4f8fd8"; x.fillRect(14, 12, SW - 30, SH * 0.62); x.fillStyle = "#3f9f4a"; x.fillRect(12, SH * 0.6, SW - 26, SH * 0.4 - 14);
    for (let i = 0; i < 400; i++) { x.fillStyle = R() < 0.5 ? "rgba(255,255,255,.06)" : "rgba(0,0,40,.06)"; x.beginPath(); x.ellipse(R() * SW, R() * SH * 0.6, 30 + R() * 60, 8 + R() * 14, 0, 0, 7); x.fill(); }
    x.fillStyle = "#f7d64a"; x.beginPath(); x.arc(780, 140, 80, 0, 7); x.fill(); x.fillStyle = "#f2f0ea"; for (let k = 0; k < 5; k++) { x.beginPath(); x.ellipse(280 + k * 45, 160, 70, 40, 0, 0, 7); x.fill(); }
    x.fillStyle = "#c0392b"; x.fillRect(420, 360, 220, 160); x.fillStyle = "#6d3b1a"; x.fillRect(500, 430, 50, 90);
  } else if (kind === "light") {
    crayon("#fbf3b8", Array.from({ length: 30 }, (_, i) => [250 + Math.cos(i / 29 * 7) * 120, 260 + Math.sin(i / 29 * 7) * 120]), 22, 3, 0.75); // very light yellow
    for (let yy = 200; yy < 330; yy += 14) crayon("#f8f6f2", [[560, yy], [880, yy + 6]], 16, 1, 0.9); // white crayon (nearly invisible)
    crayon("#f9d2dc", [[120, 560], [480, 520], [880, 600]], 18, 3, 0.7); // pale pink
    crayon("#cfe3f6", [[560, 420], [900, 380]], 16, 3, 0.7); // pale blue pencil
    crayon("#b8b4ac", [[100, 690], [900, 690]], 2, 2, 0.6); // light graphite line
  } else if (kind === "dots") {
    house();
    for (let j = 0; j < 7; j++) for (let i = 0; i < 12; i++) { const px = 60 + i * 80 + (j % 2) * 40, py = 60 + j * 34; if (py > 200 && px > 300 && px < 700) continue; const r = 3 + R() * 1.5; x.fillStyle = "#2b2b2b"; x.beginPath(); x.arc(px, py, r, 0, 7); x.fill(); meta.dots.push([px, py]); }
  }
  return { c, meta };
}

// ---------- compose a photo ----------
function inv(h, x, y) { const d = h[6] * x + h[7] * y + 1; return [(h[0] * x + h[1] * y + h[2]) / d, (h[3] * x + h[4] * y + h[5]) / d]; }
function illum(opt) {
  const tint = opt.tint || [1, 0.97, 0.9];
  return (x, y) => {
    let l = (opt.base || 0.95) - (opt.grad || 0.12) * (x / PW) - 0.05 * (y / PH);
    const vx = x / PW - 0.5, vy = y / PH - 0.5; l *= 1 - 0.25 * (vx * vx + vy * vy);
    if (opt.phone) { const [px, py, rx, ry, s] = opt.phone; const dd = Math.hypot((x - px) / rx, (y - py) / ry); l *= 1 - s * (1 - smooth(0.75, 1.25, dd)); }
    return [l * tint[0], l * tint[1], l * tint[2]];
  };
}
async function jpeg(c, q) { const url = c.toDataURL("image/jpeg", q); const im = new Image(); await new Promise(r => { im.onload = r; im.src = url; }); const o = mk(c.width, c.height); o.getContext("2d").drawImage(im, 0, 0); return o; }
async function photo(tbl, sheets, opt, R) {
  const c = mk(PW, PH), x = cx2(c); x.drawImage(tbl, 0, 0);
  if (!opt.noShadow) for (const s of sheets) { x.save(); x.beginPath(); s.q.forEach((p, i) => i ? x.lineTo(p[0], p[1]) : x.moveTo(p[0], p[1])); x.closePath(); x.shadowColor = "rgba(0,0,0,.35)"; x.shadowBlur = 24; x.shadowOffsetY = 8; x.fillStyle = "rgba(0,0,0,.3)"; x.fill(); x.restore(); }
  const id = x.getImageData(0, 0, PW, PH), d = id.data, L = illum(opt);
  for (const s of sheets) {
    const sd = cx2(s.c).getImageData(0, 0, SW, SH).data, h = homography(s.q, [[0, 0], [SW, 0], [SW, SH], [0, SH]]);
    const px = s.q.map(p => p[0]), py = s.q.map(p => p[1]);
    const xa = Math.max(0, Math.floor(Math.min(...px)) - 2), xb = Math.min(PW - 1, Math.ceil(Math.max(...px)) + 2), ya = Math.max(0, Math.floor(Math.min(...py)) - 2), yb = Math.min(PH - 1, Math.ceil(Math.max(...py)) + 2);
    const sc = Math.max(PW, PH) / 1000 * 0.4;
    for (let y = ya; y <= yb; y++) for (let X = xa; X <= xb; X++) {
      const [u, v] = inv(h, X + 0.5, y + 0.5); const cov = clamp(Math.min(u, SW - u, v, SH - v) / sc + 0.5, 0, 1); if (cov <= 0) continue;
      const uu = clamp(u - 0.5, 0, SW - 1.001), vv = clamp(v - 0.5, 0, SH - 1.001), x0 = uu | 0, y0 = vv | 0, fx = uu - x0, fy = vv - y0, i0 = (y0 * SW + x0) * 4, i1 = i0 + SW * 4, j = (y * PW + X) * 4;
      const fib = 1 + (R() - 0.5) * 0.025;
      for (let k = 0; k < 3; k++) { const a = sd[i0 + k] + (sd[i0 + 4 + k] - sd[i0 + k]) * fx, b = sd[i1 + k] + (sd[i1 + 4 + k] - sd[i1 + k]) * fx; d[j + k] = d[j + k] * (1 - cov) + (a + (b - a) * fy) * fib * cov; }
    }
  }
  const sh = opt.objects || [];
  for (let y = 0; y < PH; y++) for (let X = 0; X < PW; X++) { const l = L(X, y), j = (y * PW + X) * 4, n = (R() - 0.5) * (opt.noise || 8); for (let k = 0; k < 3; k++) d[j + k] = d[j + k] * l[k] + n; }
  x.putImageData(id, 0, 0);
  return jpeg(c, 0.86);
}
// ---------- flat cases ----------
const rot = (cx, cy, w, h, a) => [[-w / 2, -h / 2], [w / 2, -h / 2], [w / 2, h / 2], [-w / 2, h / 2]].map(([u, v]) => [cx + u * Math.cos(a) - v * Math.sin(a), cy + u * Math.sin(a) + v * Math.cos(a)]);
const persp = (q, k) => q.map(([x, y], i) => [x + (i < 2 ? (i ? -k : k) : 0), y]);
const FLAT = {
  normal: { tbl: "wood", sheet: "normal", q: [[420, 260], [2020, 220], [2080, 1560], [360, 1510]], opt: {} },
  whiteTable: { tbl: "white", sheet: "normal", q: [[420, 260], [2020, 220], [2080, 1560], [360, 1510]], opt: { grad: 0.08 } },
  fillsFrame: { tbl: "wood", sheet: "normal", q: [[-30, 20], [2440, -40], [2420, 1790], [10, 1840]], opt: {} },
  cutOff: { tbl: "wood", sheet: "normal", q: [[700, 300], [2700, 250], [2760, 1700], [650, 1660]], opt: {} },
  rot30: { tbl: "wood", sheet: "normal", q: rot(1200, 900, 1500, 1125, 0.52), opt: {} },
  rot45: { tbl: "wood", sheet: "normal", q: persp(rot(1200, 900, 1350, 1010, 0.785), 0), opt: {} },
  gingham: { tbl: "gingham", sheet: "normal", q: [[420, 260], [2020, 220], [2080, 1560], [360, 1510]], opt: {} },
  floral: { tbl: "floral", sheet: "normal", q: [[420, 260], [2020, 220], [2080, 1560], [360, 1510]], opt: {} },
  twoSheets: { tbl: "wood", sheet: "normal", q: [[300, 300], [1700, 260], [1740, 1480], [260, 1440]], extra: [[1820, 500], [2600, 520], [2580, 1250], [1800, 1230]], opt: {} },
  paint: { tbl: "wood", sheet: "paint", q: [[420, 260], [2020, 220], [2080, 1560], [360, 1510]], opt: {} },
  colored: { tbl: "wood", sheet: "colored", q: [[420, 260], [2020, 220], [2080, 1560], [360, 1510]], opt: {} },
  black: { tbl: "wood", sheet: "black", q: [[420, 260], [2020, 220], [2080, 1560], [360, 1510]], opt: {} },
  kraft: { tbl: "gray", sheet: "kraft", q: [[420, 260], [2020, 220], [2080, 1560], [360, 1510]], opt: {} },
  lightCrayon: { tbl: "wood", sheet: "light", q: [[420, 260], [2020, 220], [2080, 1560], [360, 1510]], opt: {} },
  phoneShadow: { tbl: "wood", sheet: "normal", q: [[420, 260], [2020, 220], [2080, 1560], [360, 1510]], opt: { phone: [1700, 1350, 700, 520, 0.55], grad: 0.25 } },
  dots: { tbl: "wood", sheet: "dots", q: [[420, 260], [2020, 220], [2080, 1560], [360, 1510]], opt: {} },
  noEdge: { tbl: "same", sheet: "normal", q: [[420, 260], [2020, 220], [2080, 1560], [360, 1510]], opt: { noShadow: true } },
};
// ---------- craft cases ----------
function craftPhoto(kind, R) {
  const tk = kind === "whiteClay" ? "white" : kind === "texture" ? "woodstrong" : kind === "busy" ? "floral" : "wood";
  const c = table(tk, R), x = cx2(c), m = mk(PW, PH), mx = cx2(m), thin = mk(PW, PH), tx = cx2(thin);
  if (kind === "texture") { x.fillStyle = "rgba(240,235,225,.9)"; for (let j = 0; j < 10; j++) for (let i = 0; i < 14; i++) if ((i + j) % 2) x.fillRect(1300 + i * 70, 900 + j * 70, 70, 70); }
  const both = (fn) => { fn(x, false); fn(mx, true); };
  const ball = (cx, cy, r, c1, c2) => both((g, isM) => { if (isM) g.fillStyle = "#fff"; else { const bg = g.createRadialGradient(cx - r * 0.35, cy - r * 0.4, r * 0.1, cx, cy, r); bg.addColorStop(0, c1); bg.addColorStop(1, c2); g.fillStyle = bg; } g.beginPath(); g.arc(cx, cy, r, 0, 7); g.fill(); });
  const shadow = (cx, cy, rx, a) => { const sh = x.createRadialGradient(cx, cy, 10, cx, cy, rx); sh.addColorStop(0, `rgba(30,22,12,${a})`); sh.addColorStop(1, "rgba(30,22,12,0)"); x.fillStyle = sh; x.save(); x.translate(cx, cy); x.scale(1, 0.25); x.translate(-cx, -cy); x.beginPath(); x.arc(cx, cy, rx, 0, 7); x.restore(); x.fill(); };
  if (kind === "touchEdge") {
    shadow(900, 1700, 900, 0.4);
    both((g, isM) => { g.fillStyle = isM ? "#fff" : "#4fa35a"; g.beginPath(); g.ellipse(700, 1500, 1000, 520, -0.1, 0, 7); g.fill(); g.beginPath(); g.ellipse(1500, 800, 260, 220, 0, 0, 7); g.fill(); g.fillRect(1250, 850, 300, 600); });
    both((g, isM) => { g.fillStyle = isM ? "#fff" : "#f4c542"; for (let k = 0; k < 6; k++) { g.beginPath(); g.arc(300 + k * 200, 1050 - k * 10, 60, 0, 7); g.fill(); } });
    x.fillStyle = "#111"; x.beginPath(); x.arc(1560, 760, 22, 0, 7); x.fill();
  } else if (kind === "whiteClay") {
    shadow(1200, 1430, 420, 0.28);
    ball(1200, 1200, 300, "#fdfcf9", "#cfcac0"); ball(1200, 760, 210, "#fefdfb", "#d3cec5");
    both((g, isM) => { g.fillStyle = isM ? "#fff" : "#e9e5de"; g.beginPath(); g.ellipse(1110, 520, 50, 130, -0.15, 0, 7); g.fill(); g.beginPath(); g.ellipse(1290, 520, 50, 130, 0.15, 0, 7); g.fill(); });
    x.fillStyle = "#222"; x.beginPath(); x.arc(1130, 740, 14, 0, 7); x.arc(1270, 740, 14, 0, 7); x.fill(); x.fillStyle = "#f29bb0"; x.beginPath(); x.arc(1200, 800, 16, 0, 7); x.fill();
  } else if (kind === "texture") {
    shadow(1200, 1400, 500, 0.35);
    ball(1200, 1150, 320, "#ff9f6e", "#c4502a"); ball(1200, 720, 200, "#9fd4ff", "#3a7fc2");
    x.fillStyle = "#111"; x.beginPath(); x.arc(1140, 700, 16, 0, 7); x.arc(1260, 700, 16, 0, 7); x.fill();
  } else if (kind === "busy") {
    shadow(1200, 1300, 450, 0.35); ball(1200, 1000, 330, "#ffe6f0", "#e86f8a");
  } else if (kind === "thin") {
    shadow(1200, 1250, 520, 0.3);
    const legs = (g, isM, w) => { g.strokeStyle = isM ? "#fff" : "#7a2fbf"; g.lineWidth = w; g.lineCap = "round"; g.beginPath(); for (let k = 0; k < 4; k++) { const yy = 1000 + k * 60; g.moveTo(1150, yy); g.quadraticCurveTo(800, yy - 220, 560 - k * 40, yy + 150); g.moveTo(1250, yy); g.quadraticCurveTo(1600, yy - 220, 1840 + k * 40, yy + 150); } g.moveTo(1170, 820); g.quadraticCurveTo(1100, 560, 980, 480); g.moveTo(1230, 820); g.quadraticCurveTo(1300, 560, 1420, 480); g.stroke(); };
    legs(x, false, 10); legs(mx, true, 10); legs(tx, true, 10);
    ball(1200, 1060, 220, "#c7a0ff", "#6a33b0"); ball(1200, 860, 120, "#c7a0ff", "#6a33b0");
    const cl = (g) => { g.globalCompositeOperation = "destination-out"; g.beginPath(); g.arc(1200, 1060, 220, 0, 7); g.arc(1200, 860, 120, 0, 7); g.fill(); g.globalCompositeOperation = "source-over"; }; cl(tx);
  }
  return { c, m, thin };
}
async function craftCase(kind, R) {
  const { c, m, thin } = craftPhoto(kind, R);
  const id = cx2(c).getImageData(0, 0, PW, PH), d = id.data, L = illum({ grad: 0.1 });
  for (let y = 0; y < PH; y++) for (let X = 0; X < PW; X++) { const l = L(X, y), j = (y * PW + X) * 4, n = (R() - 0.5) * 8; for (let k = 0; k < 3; k++) d[j + k] = d[j + k] * l[k] + n; }
  cx2(c).putImageData(id, 0, 0);
  const md = cx2(m).getImageData(0, 0, PW, PH).data, gt = new Uint8Array(PW * PH); for (let i = 0; i < PW * PH; i++) gt[i] = md[i * 4 + 3] > 128 ? 1 : 0;
  const td = cx2(thin).getImageData(0, 0, PW, PH).data, gtt = new Uint8Array(PW * PH); for (let i = 0; i < PW * PH; i++) gtt[i] = td[i * 4 + 3] > 128 ? 1 : 0;
  return { src: await jpeg(c, 0.86), gt, gtt };
}

// ---------- metrics ----------
function polyMask(q, w, h, s) { const c = mk(w, h), x = cx2(c); x.fillStyle = "#fff"; x.beginPath(); q.forEach((p, i) => i ? x.lineTo(p[0] * s, p[1] * s) : x.moveTo(p[0] * s, p[1] * s)); x.closePath(); x.fill(); const d = x.getImageData(0, 0, w, h).data, o = new Uint8Array(w * h); for (let i = 0; i < w * h; i++) o[i] = d[i * 4 + 3] > 128; return o; }
function quadIoU(a, b) { const s = 0.2, w = PW * s, h = PH * s, A = polyMask(a, w, h, s), B = polyMask(b, w, h, s); let I = 0, U = 0; for (let i = 0; i < w * h; i++) { I += A[i] && B[i]; U += A[i] || B[i]; } return I / U; }
function cornerErr(det, gt) { if (gt.some(([x, y]) => x < 0 || y < 0 || x > PW || y > PH)) return null; let e = 0; for (let i = 0; i < 4; i++) { let m = 1e9; for (let j = 0; j < 4; j++) m = Math.min(m, dist(det[j], gt[i])); e += m; } return e / 4; }
function procMetrics(out, sh, kind, q) {
  // out: ImageData (result for GT quad), sh: GT sheet canvas
  const W = out.width, H = out.height, g = mk(W, H), gx = cx2(g); gx.drawImage(sh.c, 0, 0, W, H); const gd = gx.getImageData(0, 0, W, H).data, o = out.data, P = sh.meta.paper;
  const white = (P[0] + P[1] + P[2]) / 3 > 200;
  const tgt = white ? [255, 255, 255] : P; // ideal paper in the output
  let se = 0, sn = 0, pe = 0, pn = 0, lc = 0, lg = 0, pl = [], pr = 0, pg = 0, pb = 0;
  const m = Math.round(Math.min(W, H) * 0.04), hq = homography([[0, 0], [W, 0], [W, H], [0, H]], q);
  for (let y = m; y < H - m; y++) for (let x = m; x < W - m; x++) {
    if (x % 8 === 0) { const [px, py] = inv(hq, x, y); if (px < 6 || py < 6 || px > PW - 6 || py > PH - 6) { x += 7; continue; } }
    const i = (y * W + x) * 4, dP = Math.abs(gd[i] - P[0]) + Math.abs(gd[i + 1] - P[1]) + Math.abs(gd[i + 2] - P[2]);
    const ideal = [0, 1, 2].map(k => clamp(gd[i + k] / P[k] * tgt[k], 0, 255));
    const e = (Math.abs(o[i] - ideal[0]) + Math.abs(o[i + 1] - ideal[1]) + Math.abs(o[i + 2] - ideal[2])) / 3;
    if (dP < 6) { pe += e; pn++; if ((x + y) % 7 === 0) pl.push(0.299 * o[i] + 0.587 * o[i + 1] + 0.114 * o[i + 2]); pr += o[i]; pg += o[i + 1]; pb += o[i + 2]; }
    else if (dP > 40) {
      se += e; sn++;
      const gy = 0.299 * ideal[0] + 0.587 * ideal[1] + 0.114 * ideal[2];
      if (white && gy > 200) { lc += Math.max(o[i], o[i + 1], o[i + 2]) - Math.min(o[i], o[i + 1], o[i + 2]); lg += Math.max(...ideal) - Math.min(...ideal); }
    }
  }
  const mean = pl.reduce((a, b) => a + b, 0) / (pl.length || 1), std = Math.sqrt(pl.reduce((a, b) => a + (b - mean) ** 2, 0) / (pl.length || 1));
  const r = { strokeErr: se / (sn || 1), paperErr: pe / (pn || 1), paperStd: std, paperRGB: [pr / pn, pg / pn, pb / pn].map(Math.round) };
  if (lg) r.lightChroma = lc / lg;
  const sx = W / SW, sy = H / SH, dark = p => { const i = (Math.round(p[1] * sy) * W + Math.round(p[0] * sx)) * 4; return 0.299 * o[i] + 0.587 * o[i + 1] + 0.114 * o[i + 2] < 150; };
  if (sh.meta.dots.length) r.dotsKept = sh.meta.dots.filter(dark).length + "/" + sh.meta.dots.length;
  if (sh.meta.specks.length) r.specksLeft = sh.meta.specks.filter(dark).length + "/" + sh.meta.specks.length;
  return r;
}
const thumb = (c, w) => { const s = w / c.width, t = mk(w, Math.round(c.height * s)); const x = t.getContext("2d"); x.imageSmoothingQuality = "high"; x.drawImage(c, 0, 0, t.width, t.height); return t; };
function overlay(src, gtq, det) { const t = thumb(src, 480), x = t.getContext("2d"), s = 480 / src.width; const poly = (q, col, w) => { x.strokeStyle = col; x.lineWidth = w; x.beginPath(); q.forEach((p, i) => i ? x.lineTo(p[0] * s, p[1] * s) : x.moveTo(p[0] * s, p[1] * s)); x.closePath(); x.stroke(); }; if (gtq) poly(gtq, "#00e05a", 4); if (det) poly(det, "#ff2a2a", 2); return t.toDataURL("image/jpeg", 0.85); }
const clipQ = q => q.map(([x, y]) => [clamp(x, 0, PW), clamp(y, 0, PH)]);

async function runFlat(name) {
  const cs = FLAT[name], R = R0(1000 + name.length * 37), sh = sheet(cs.sheet, R), sheets = [{ c: sh.c, q: cs.q }];
  if (cs.extra) sheets.push({ c: sheet("normal", R0(5)).c, q: cs.extra });
  const src = await photo(table(cs.tbl, R), sheets, cs.opt, R);
  setModeUI("flat"); S.strokes = []; S.params.speck = true;
  const t0 = performance.now(); S.src = scaledCanvas(src, MAX_SRC); S.quad = detectPaper(S.src); const t1 = performance.now(); buildFlat(); render(); const t2 = performance.now();
  const det = S.quad.map(p => p.slice()), e2e = S.output, hint = $("hint").textContent, info = JSON.stringify({ dbg: S.paperDebug, guess: S.paperGuess, mode: S.flat && S.flat.mode, note: S.note });
  // processing metrics with the ground-truth quad (clipped to frame)
  S.quad = cs.q.map(p => p.slice()); buildFlat(); const img = whiten(S.flat, S.params); const specks = S.flat.mode !== "keep" ? removeSpecks(img) : 0;
  const pm = procMetrics(img, sh, cs.sheet, cs.q); const pc = mk(img.width, img.height); pc.getContext("2d").putImageData(img, 0, 0);
  return { name, kind: "flat", iou: quadIoU(det, clipQ(cs.q)), cornerErr: cornerErr(det, cs.q), ...pm, specks, tDetect: t1 - t0, tTotal: t2 - t0, hint, info,
    imIn: overlay(src, cs.q, det), imOut: thumb(e2e, 480).toDataURL("image/jpeg", 0.85), imProc: thumb(pc, 480).toDataURL("image/jpeg", 0.85) };
}
async function runCraft(name) {
  const R = R0(77 + name.length * 13); const { src, gt, gtt } = await craftCase(name, R);
  setModeUI("craft"); S.strokes = [];
  const t0 = performance.now(); S.src = scaledCanvas(src, MAX_SRC); buildCraft(); render(); const t1 = performance.now();
  const a = S.craft.alphaBase; let I = 0, U = 0, tt = 0, tn = 0;
  for (let i = 0; i < a.length; i++) { const p = a[i] > 128; I += p && gt[i]; U += p || gt[i]; if (gtt[i]) { tn++; tt += p; } }
  return { name, kind: "craft", iou: I / U, thinRecall: tn ? tt / tn : null, tTotal: t1 - t0, hint: $("hint").textContent, info: JSON.stringify({ ...S.craft.info, fb: S.craft.fallback, soft: S.craft.m.soft, edge: S.craft.edge }),
    imIn: thumb(src, 480).toDataURL("image/jpeg", 0.85), imOut: thumb(S.output, 480).toDataURL("image/jpeg", 0.85) };
}
async function runSamples() {
  const res = [];
  // built-in flat sample
  setModeUI("flat"); S.strokes = []; const a = sampleArtwork(); let t0 = performance.now(); S.src = scaledCanvas(a, MAX_SRC); S.quad = detectPaper(S.src); buildFlat(); render(); let t1 = performance.now();
  const gq = [[250, 150], [1380, 120], [1420, 1080], [205, 1050]], o = S.output, od = cx2(o).getImageData(0, 0, o.width, o.height).data;
  // probe sheet coords (1000x750) -> output pixel via GT quad mapping approximated by detected output frame
  const chroma = p => Math.max(...p) - Math.min(...p), lum = p => 0.299 * p[0] + 0.587 * p[1] + 0.114 * p[2];
  const probe = (u, v, f) => { let best = null, bv = -1e9; for (let dy = -5; dy <= 5; dy++) for (let dx = -5; dx <= 5; dx++) { const i = ((Math.round(v / 750 * o.height) + dy) * o.width + Math.round(u / 1000 * o.width) + dx) * 4, p = [od[i], od[i + 1], od[i + 2]], s = f(p); if (s > bv) { bv = s; best = p; } } return best; };
  res.push({ name: "sampleFlat", kind: "flat", cornerErr: (() => { let e = 0; for (let i = 0; i < 4; i++) e += dist(S.quad[i], gq[i]); return e / 4; })(), specks: S.specks,
    sunChroma: chroma(probe(160 + 33, 150, chroma)), cloudChroma: chroma(probe(700, 140, chroma)), armLum: Math.round(lum(probe(770, 450, p => -lum(p)))), tTotal: t1 - t0, hint: $("hint").textContent,
    imIn: overlay(a, gq, S.quad), imOut: thumb(o, 480).toDataURL("image/jpeg", 0.85) });
  setModeUI("craft"); S.strokes = []; const cc = sampleCraft(); t0 = performance.now(); S.src = scaledCanvas(cc, MAX_SRC); buildCraft(); render(); t1 = performance.now();
  let area = 0; for (const v of S.craft.alphaBase) area += v > 128; res.push({ name: "sampleCraft", kind: "craft", areaFrac: area / S.craft.alphaBase.length, tTotal: t1 - t0, hint: $("hint").textContent,
    imIn: thumb(cc, 480).toDataURL("image/jpeg", 0.85), imOut: thumb(S.output, 480).toDataURL("image/jpeg", 0.85) });
  window.__sampleAlpha = S.craft.alphaBase;
  return res;
}
window.HARD = { FLAT, CRAFT: ["touchEdge", "whiteClay", "texture", "thin", "busy"], runFlat, runCraft, runSamples };
})();
