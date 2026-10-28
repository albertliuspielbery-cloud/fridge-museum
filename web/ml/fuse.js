/* kidart: fuse the ML subject mask with the existing colour method (craft mode).
 * Runs in kidart.html's page scope: uses its helpers craftMask, maskCheck, components, morph, boxBlur, smooth, clamp,
 * ctx2d, makeCanvas, featArrays/bgDist/feat. Drop-in shapes:
 *   craftMaskML(src, sens, ml) -> same object as craftMask() (+ .ml, .mlInfo, .add)   [ml = mlSubjectMask() result]
 *   craftAlphaML(src, m)       -> Uint8Array(W*H) alpha, like craftAlpha()
 *
 * Fusion (on craftMask's ~256 px grid):
 *   P      = ML probability resampled to the grid (bilinear; the ML mask spans the whole photo, squashed).
 *   core   = P > 0.5, opened by 1 px, pieces < 15 % of the biggest dropped.
 *   trust  : 1 % <= area(core) <= 92 % of the photo and the ML map is decisive (mean |2P-1| >= 0.55). Otherwise the
 *            colour result is returned unchanged (fallback chain ML -> colour -> plainCraft stays intact).
 *   partial: if the colour cut-out is sane, contains >= 85 % of core and is >= 2.5x bigger, the ML only found a part
 *            of the object (seen at 320 px input: only the head of an edge-touching dino) -> colour result returned.
 *   add    = THIN colour parts touching the ML subject (only if the colour method passed its own sanity check):
 *            A = (colour soft mask > 0.15) \ core; a piece of A is added if it lies within 2 px of core, >= 30 % of it is
 *            more than 3 px away from core (not a halo/shadow rim) and <= 25 % of it survives a 5x5 erosion (a line/stick,
 *            not a blob). This recovers legs, sticks, pipe
 *            cleaners that u2netp at 224 px cannot see, but never glues a table pattern / second object (blobs) on.
 *   F      = blur1(fillSmallHoles(core)) (holes < 0.3 % of the photo filled; arches/rings kept), raised to
 *            min(1, 1.5 * colour mask) on add (dilated 1 px).
 * Full-resolution alpha:
 *   v = bilinear(F blurred by 1 grid px). v >= .98 -> 255, v <= .02 -> 0 (as before). In the band in between:
 *   pixels of colour-added pieces keep the existing colour-distance edge (crisp on a plain table);
 *   all others use a colour guided filter (r ≈ 0.6 % of the long edge, eps 1e-3) of the fused mask on a ≤768 px copy,
 *   upsampled and sharpened with smoothstep(0.3, 0.7). This snaps the 224 px ML outline to the real photo edges
 *   without asking the (unreliable on marble) table-colour model.
 */
(function () {
  "use strict";
  function sampleML(ml, w, h) {
    const P = new Float32Array(w * h), kx = ml.w / w, ky = ml.h / h, M = ml.mask;
    for (let y = 0; y < h; y++) {
      const fy = clamp((y + 0.5) * ky - 0.5, 0, ml.h - 1), y0 = fy | 0, y1 = Math.min(y0 + 1, ml.h - 1), wy = fy - y0;
      for (let x = 0; x < w; x++) {
        const fx = clamp((x + 0.5) * kx - 0.5, 0, ml.w - 1), x0 = fx | 0, x1 = Math.min(x0 + 1, ml.w - 1), wx = fx - x0;
        P[y * w + x] = (M[y0 * ml.w + x0] * (1 - wx) + M[y0 * ml.w + x1] * wx) * (1 - wy) + (M[y1 * ml.w + x0] * (1 - wx) + M[y1 * ml.w + x1] * wx) * wy;
      }
    }
    return P;
  }
  function bigPieces(bin, w, h, frac) {
    const cc = components(bin, w, h); let big = 0; for (let k = 1; k <= cc.n; k++) big = Math.max(big, cc.area[k]);
    const o = new Uint8Array(w * h); for (let i = 0; i < w * h; i++) { const l = cc.lab[i]; o[i] = l && cc.area[l] >= big * frac ? 1 : 0; }
    return o;
  }
  function fillSmallHoles(bin, w, h, maxA) {
    const inv = new Uint8Array(w * h); for (let i = 0; i < w * h; i++) inv[i] = bin[i] ? 0 : 1;
    const cc = components(inv, w, h), o = bin.slice(), touches = new Uint8Array(cc.n + 1);
    for (let k = 1; k <= cc.n; k++) touches[k] = cc.x0[k] === 0 || cc.y0[k] === 0 || cc.x1[k] === w - 1 || cc.y1[k] === h - 1 ? 1 : 0;
    for (let i = 0; i < w * h; i++) { const l = cc.lab[i]; if (l && !touches[l] && cc.area[l] <= maxA) o[i] = 1; }
    return o;
  }

  window.craftMaskML = function craftMaskML(src, sens, ml) {
    const c = craftMask(src, sens);
    if (!ml || !ml.mask) return c;
    const w = c.w, h = c.h, n = w * h, P = sampleML(ml, w, h);
    let core = new Uint8Array(n), dec = 0;
    for (let i = 0; i < n; i++) { core[i] = P[i] > 0.5 ? 1 : 0; dec += Math.abs(2 * P[i] - 1); }
    core = bigPieces(morph(morph(core, w, h, 1, false), w, h, 1, true), w, h, 0.15);
    const mi = maskCheck(core, w, h); mi.dec = +(dec / n).toFixed(2);
    mi.trust = mi.af >= 0.01 && mi.af <= 0.92 && mi.dec >= 0.55;
    if (!mi.trust) return Object.assign(c, { ml: false, mlInfo: mi });
    // ML found only a part of what a sane colour cut-out found (e.g. just the head of an animal running off the photo):
    // the colour cut-out contains the ML subject and is >= 2.5x bigger -> keep the colour result
    if (!c.fallback) {
      let cA = 0, both = 0, kA = 0;
      for (let i = 0; i < n; i++) { const C = c.mask[i] > 0.5; cA += C; kA += core[i]; both += C && core[i]; }
      mi.inColor = +(both / Math.max(1, kA)).toFixed(2); mi.colorRatio = +(cA / Math.max(1, kA)).toFixed(2);
      if (mi.inColor >= 0.85 && mi.colorRatio >= 2.5) { mi.partial = true; return Object.assign(c, { ml: false, mlInfo: mi }); }
    }
    // thin colour parts hanging off the ML subject (legs, sticks, pipe cleaners): u2netp at 224 px cannot see them
    const add = new Uint8Array(n); let added = 0, rejected = 0;
    if (!c.fallback) {
      const near = morph(core, w, h, 2, true), far = morph(core, w, h, 3, true), A = new Uint8Array(n);
      for (let i = 0; i < n; i++) A[i] = c.mask[i] > 0.15 && !core[i] ? 1 : 0;
      const er = morph(A, w, h, 2, false), cc = components(A, w, h), touch = new Uint8Array(cc.n + 1), fat = new Float64Array(cc.n + 1), out = new Float64Array(cc.n + 1);
      for (let i = 0; i < n; i++) { const l = cc.lab[i]; if (!l) continue; if (near[i]) touch[l] = 1; if (er[i]) fat[l]++; if (!far[i]) out[l]++; }
      // touching the subject, reaching > 3 px away from it (not just a halo/shadow rim) and thin (<= 25 % survives a 5x5 erosion)
      // ... and lying on the table: >= 60 % of a 3 px ring around it (outside the subject) must look like the table.
      // A strip that continues into some other thing (the edge of a folder, a pen behind the cup) is not rescued.
      const ok = new Uint8Array(cc.n + 1); for (let l = 1; l <= cc.n; l++) ok[l] = touch[l] && out[l] >= 0.3 * cc.area[l] && fat[l] <= 0.25 * cc.area[l] ? 1 : 0;
      if (ok.some(v => v)) {
        const sd = ctx2d(scaledCanvas(src, 256)).getImageData(0, 0, w, h).data, ring = new Float64Array(cc.n + 1), tab = new Float64Array(cc.n + 1);
        const pb = new Uint8Array(n); for (let i = 0; i < n; i++) if (ok[cc.lab[i]]) pb[i] = 1;
        const lab3 = cc.lab.slice(); for (let it = 0; it < 3; it++) { const prev = lab3.slice(); for (let i = 0; i < n; i++) if (!prev[i]) { const x = i % w, L = (x > 0 && prev[i - 1]) || (x < w - 1 && prev[i + 1]) || (i >= w && prev[i - w]) || (i + w < n && prev[i + w]); if (L) lab3[i] = L; } }
        for (let i = 0; i < n; i++) { const l = lab3[i]; if (!l || !ok[l] || cc.lab[i] || near[i]) continue; ring[l]++; if (bgDist(feat(sd[i * 4], sd[i * 4 + 1], sd[i * 4 + 2]), c.cs) < c.T) tab[l]++; }
        for (let l = 1; l <= cc.n; l++) if (ok[l] && ring[l] && tab[l] < 0.6 * ring[l]) { ok[l] = 0; rejected++; }
      }
      for (let i = 0; i < n; i++) { const l = cc.lab[i]; if (l && ok[l]) { add[i] = 1; added++; } }
    }
    const G = fillSmallHoles(core, w, h, n * 0.003), mf = new Float32Array(n);
    for (let i = 0; i < n; i++) mf[i] = G[i];
    const soft = boxBlur(mf, w, h, 1), addB = morph(add, w, h, 1, true);
    for (let i = 0; i < n; i++) if (addB[i] && c.mask[i] > soft[i]) soft[i] = Math.max(soft[i], Math.min(1, c.mask[i] * 1.5));
    const fin = new Uint8Array(n); for (let i = 0; i < n; i++) fin[i] = soft[i] > 0.5 || add[i] ? 1 : 0;
    const info = maskCheck(fin, w, h); info.ml = mi; info.added = +(added / n).toFixed(4); info.rejected = rejected;
    return { mask: soft, w, h, cs: c.cs, T: c.T, info, soft: false, fallback: false, edge: info.touch > 0, ml: true, mlInfo: mi, add: addB, core: G, color: c };
  };

  // colour guided filter (He et al.), guide = RGB in 0..1, input p; box radius r
  function guidedFilter(I, p, w, h, r, eps) {
    const n = w * h, B = (a) => boxBlur(a, w, h, r), R = I[0], G = I[1], Bl = I[2];
    const mul = (a, b) => { const o = new Float32Array(n); for (let i = 0; i < n; i++) o[i] = a[i] * b[i]; return o; };
    const mR = B(R), mG = B(G), mB = B(Bl), mp = B(p);
    const vRR = B(mul(R, R)), vRG = B(mul(R, G)), vRB = B(mul(R, Bl)), vGG = B(mul(G, G)), vGB = B(mul(G, Bl)), vBB = B(mul(Bl, Bl));
    const pR = B(mul(R, p)), pG = B(mul(G, p)), pB = B(mul(Bl, p));
    const aR = new Float32Array(n), aG = new Float32Array(n), aB = new Float32Array(n), b = new Float32Array(n);
    for (let i = 0; i < n; i++) {
      const rr = vRR[i] - mR[i] * mR[i] + eps, rg = vRG[i] - mR[i] * mG[i], rb = vRB[i] - mR[i] * mB[i];
      const gg = vGG[i] - mG[i] * mG[i] + eps, gb = vGB[i] - mG[i] * mB[i], bb = vBB[i] - mB[i] * mB[i] + eps;
      const cR = pR[i] - mR[i] * mp[i], cG = pG[i] - mG[i] * mp[i], cB = pB[i] - mB[i] * mp[i];
      // inverse of the symmetric 3x3 [[rr,rg,rb],[rg,gg,gb],[rb,gb,bb]]
      const i00 = gg * bb - gb * gb, i01 = rb * gb - rg * bb, i02 = rg * gb - rb * gg, i11 = rr * bb - rb * rb, i12 = rb * rg - rr * gb, i22 = rr * gg - rg * rg;
      const det = rr * i00 + rg * i01 + rb * i02, k = det > 1e-12 ? 1 / det : 0;
      aR[i] = (i00 * cR + i01 * cG + i02 * cB) * k; aG[i] = (i01 * cR + i11 * cG + i12 * cB) * k; aB[i] = (i02 * cR + i12 * cG + i22 * cB) * k;
      b[i] = mp[i] - aR[i] * mR[i] - aG[i] * mG[i] - aB[i] * mB[i];
    }
    const AR = B(aR), AG = B(aG), AB = B(aB), Bb = B(b), q = new Float32Array(n);
    for (let i = 0; i < n; i++) q[i] = AR[i] * R[i] + AG[i] * G[i] + AB[i] * Bl[i] + Bb[i];
    return q;
  }
  const bil = (M, mw, mh, fx, fy) => {
    fx = clamp(fx, 0, mw - 1); fy = clamp(fy, 0, mh - 1); const x0 = fx | 0, y0 = fy | 0, x1 = Math.min(x0 + 1, mw - 1), y1 = Math.min(y0 + 1, mh - 1), wx = fx - x0, wy = fy - y0;
    return (M[y0 * mw + x0] * (1 - wx) + M[y0 * mw + x1] * wx) * (1 - wy) + (M[y1 * mw + x0] * (1 - wx) + M[y1 * mw + x1] * wx) * wy;
  };

  window.craftAlphaML = function craftAlphaML(src, m) {
    if (!m.ml) return craftAlpha(src, m);
    const W = src.width, H = src.height, a = new Uint8Array(W * H);
    // guided filter on a <= 1024 px copy
    const gs = Math.min(1, (window.FUSE_GF_MAX || 768) / Math.max(W, H)), gw = Math.max(1, Math.round(W * gs)), gh = Math.max(1, Math.round(H * gs)), gn = gw * gh;
    const gc = makeCanvas(gw, gh), gx = ctx2d(gc); gx.imageSmoothingQuality = "high"; gx.drawImage(src, 0, 0, gw, gh);
    const gd = gx.getImageData(0, 0, gw, gh).data, I = [new Float32Array(gn), new Float32Array(gn), new Float32Array(gn)], p = new Float32Array(gn);
    for (let y = 0; y < gh; y++) for (let x = 0; x < gw; x++) {
      const i = y * gw + x; I[0][i] = gd[i * 4] / 255; I[1][i] = gd[i * 4 + 1] / 255; I[2][i] = gd[i * 4 + 2] / 255;
      p[i] = bil(m.mask, m.w, m.h, (x + 0.5) * m.w / gw - 0.5, (y + 0.5) * m.h / gh - 0.5);
    }
    const q = guidedFilter(I, p, gw, gh, Math.max(2, Math.round(Math.max(gw, gh) * 0.006)), 1e-3);
    // local two-colour model: mean colour of the confident subject (F) and of the confident background (B) nearby
    // (R2 ≈ 2 % of the long edge). In the edge band a pixel is also judged by where its colour lies on the F–B line
    // (only when F and B differ and the colour lies close to that line): this keeps a bright rim that the 224 px ML
    // outline only half covers, and drops a fringe of the background that the soft outline would otherwise keep.
    const R2 = Math.max(4, Math.round(Math.max(gw, gh) * 0.02)), fw = new Float32Array(gn), bw = new Float32Array(gn);
    for (let i = 0; i < gn; i++) { fw[i] = p[i] > 0.9 ? 1 : 0; bw[i] = p[i] < 0.1 ? 1 : 0; }
    const lm = (wt) => { const s = boxBlur(wt, gw, gh, R2), o = [0, 1, 2].map(k => { const t = new Float32Array(gn); for (let i = 0; i < gn; i++) t[i] = I[k][i] * wt[i]; return boxBlur(t, gw, gh, R2); }); for (let i = 0; i < gn; i++) { const z = s[i] > 1e-4 ? 1 / s[i] : 0; o[0][i] *= z; o[1][i] *= z; o[2][i] *= z; } return [o, s]; };
    const [mF, sF] = lm(fw), [mB, sB] = lm(bw);
    const av = new Float32Array(gn);
    for (let i = 0; i < gn; i++) {
      const band = p[i] > 0.02 && p[i] < 0.98; let v = band ? q[i] : p[i] >= 0.98 ? 1 : 0;
      if (band && sF[i] >= 0.04 && sB[i] >= 0.04) {
        const e0 = mF[0][i] - mB[0][i], e1 = mF[1][i] - mB[1][i], e2 = mF[2][i] - mB[2][i], den = e0 * e0 + e1 * e1 + e2 * e2, ln = Math.sqrt(den), cf = clamp((ln - 0.08) / 0.14, 0, 1);
        if (cf > 0) {
          const r0 = I[0][i] - mB[0][i], r1 = I[1][i] - mB[1][i], r2 = I[2][i] - mB[2][i], t = clamp((r0 * e0 + r1 * e1 + r2 * e2) / den, 0, 1);
          const res = Math.hypot(r0 - t * e0, r1 - t * e1, r2 - t * e2), wgt = 0.7 * cf * clamp(1 - res / (0.5 * ln), 0, 1);
          v = v * (1 - wgt) + t * wgt;
        }
      }
      av[i] = v;
    }
    // per-column / per-row bilinear taps for the mask grid (m) and the guided-filter grid
    const taps = (N, k, M) => { const i0 = new Int32Array(N), i1 = new Int32Array(N), f = new Float32Array(N); for (let t = 0; t < N; t++) { const v = clamp((t + 0.5) * k - 0.5, 0, M - 1); i0[t] = v | 0; i1[t] = Math.min(i0[t] + 1, M - 1); f[t] = v - i0[t]; } return [i0, i1, f]; };
    const [mx0, mx1, mwx] = taps(W, m.w / W, m.w), [my0, my1, mwy] = taps(H, m.h / H, m.h), [qx0, qx1, qwx] = taps(W, gw / W, gw), [qy0, qy1, qwy] = taps(H, gh / H, gh);
    const Mm = m.mask, mw = m.w; let d = null;
    for (let y = 0; y < H; y++) {
      const r0 = my0[y] * mw, r1 = my1[y] * mw, wy = mwy[y], s0 = qy0[y] * gw, s1 = qy1[y] * gw, vy = qwy[y], gy = Math.min(m.h - 1, ((y + 0.5) * m.h / H) | 0) * mw;
      for (let x = 0; x < W; x++) {
        const i = y * W + x, x0 = mx0[x], x1 = mx1[x], wx = mwx[x];
        const v = (Mm[r0 + x0] * (1 - wx) + Mm[r0 + x1] * wx) * (1 - wy) + (Mm[r1 + x0] * (1 - wx) + Mm[r1 + x1] * wx) * wy;
        if (v <= 0.02) { a[i] = 0; continue; }
        const u0 = qx0[x], u1 = qx1[x], ux = qwx[x], A = (av[s0 + u0] * (1 - ux) + av[s0 + u1] * ux) * (1 - vy) + (av[s1 + u0] * (1 - ux) + av[s1 + u1] * ux) * vy;
        if (v >= 0.98) { a[i] = A >= 0.98 ? 255 : smooth(0.3, 0.7, A) * 255; continue; }
        if (m.add[gy + Math.min(mw - 1, ((x + 0.5) * mw / W) | 0)]) {
          if (!d) d = ctx2d(src).getImageData(0, 0, W, H).data;
          const ad = smooth(m.T * 0.7, m.T * 1.25, bgDist(feat(d[i * 4], d[i * 4 + 1], d[i * 4 + 2]), m.cs)); a[i] = (ad * 0.65 + v * 0.35) * 255;
        } else a[i] = smooth(0.3, 0.7, A) * 255;
      }
    }
    return a;
  };
})();
