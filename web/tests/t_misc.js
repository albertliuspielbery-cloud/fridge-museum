const L = require('./lib');
(async () => {
  const b = await L.launch();
  // HEIC + bad file
  for (const loc of ['zh-TW', 'en-US']) {
    const p = await L.newPage(b, { w: 375, h: 667, locale: loc });
    await L.open(p, L.BASE + 'v9.html');
    for (const f of ['img/photo.HEIC', 'img/notes.jpg']) {
      await p.evaluate(() => { nextMode = 'flat'; });
      await p.setInputFiles('#fileIn', f); await p.waitForTimeout(1200);
      console.log(loc, f, JSON.stringify(await p.evaluate(() => ({ toast: document.getElementById('statusText').textContent, toastHidden: document.getElementById('toast').hidden, home: !document.getElementById('home').hidden, busy: !document.getElementById('busy').hidden }))));
      await p.screenshot({ path: `shots/heic_${loc}_${f.split('/')[1]}.png` });
    }
    // title toggle at runtime
    const t1 = await p.title(); await p.evaluate(() => document.getElementById('langChip').click()); const t2 = await p.title(); await p.evaluate(() => document.getElementById('langChip').click()); const t3 = await p.title();
    console.log(loc, 'titles', t1, '->', t2, '->', t3, 'html lang', await p.evaluate(() => document.documentElement.lang));
    await p._ctx.close();
  }
  // persisted language survives reload & overrides auto-detect
  { const p = await L.newPage(b, { w: 390, h: 844, locale: 'zh-TW' }); await L.open(p, L.BASE + 'v9.html'); await p.evaluate(() => document.getElementById('langChip').click()); await p.reload(); await p.waitForTimeout(800); console.log('persist after reload', await p.evaluate(() => LANG), await p.title()); await p._ctx.close(); }
  // other locales
  for (const loc of ['zh-HK', 'zh-CN', 'ja-JP', 'fr-FR']) { const p = await L.newPage(b, { w: 390, h: 844, locale: loc }); await p.goto(L.BASE + 'v9.html'); console.log('locale', loc, await p.evaluate(() => LANG)); await p._ctx.close(); }
  // success toast + Bibi overlap on home, English, 375 and 390
  for (const [w, h, loc, scheme] of [[375, 667, 'en-US', 'light'], [390, 844, 'zh-TW', 'dark'], [1280, 800, 'en-US', 'light']]) {
    const p = await L.newPage(b, { w, h, locale: loc, scheme, dpr: 2 }); await L.open(p, L.BASE + 'v9.html');
    await L.loadFile(p, '/tmp/claude-0/-home-user/bed2c260-5a9a-5d57-9a44-5819024f1478/scratchpad/real/drawing_marble_orig.jpg', 'flat');
    // edit stage: does hint-bibi overlap the drawn artwork?
    const ov = await p.evaluate(() => { const v = document.getElementById('view').getBoundingClientRect(); const art = { l: v.left + fit.ox, t: v.top + fit.oy, r: v.left + fit.ox + S.output.width * fit.s, b: v.top + fit.oy + S.output.height * fit.s };
      const res = {}; for (const sel of ['.hint-bibi', '.busy-bibi', '.toast', '#pickBtn', '#compareBtn', '#sampleTag']) { const e = document.querySelector(sel); if (!e) continue; const r = e.getBoundingClientRect(); if (!r.width || e.closest('[hidden]')) { res[sel] = 'hidden'; continue; } const ix = Math.max(0, Math.min(r.right, art.r) - Math.max(r.left, art.l)), iy = Math.max(0, Math.min(r.bottom, art.b) - Math.max(r.top, art.t)); res[sel] = Math.round(ix * iy); } return { art: Object.values(art).map(Math.round), res }; });
    console.log(w, loc, 'edit overlap(px²) with artwork', JSON.stringify(ov));
    await p.screenshot({ path: `shots/edit_${w}_${loc}_${scheme}.png` });
    await p.evaluate(() => document.getElementById('addBtn').click()); await p.waitForTimeout(700);
    await p.screenshot({ path: `shots/toast_home_${w}_${loc}_${scheme}.png` });
    const tv = await p.evaluate(() => { const t = document.getElementById('toast').getBoundingClientRect(); const th = document.querySelector('#thumbs .thumb'); const r = th.getBoundingClientRect(); const ix = Math.max(0, Math.min(t.right, r.right) - Math.max(t.left, r.left)), iy = Math.max(0, Math.min(t.bottom, r.bottom) - Math.max(t.top, r.top)); return { toast: [t.top | 0, t.bottom | 0], thumb: [r.top | 0, r.bottom | 0], overlap: Math.round(ix * iy), sw: document.documentElement.scrollWidth, iw: innerWidth }; });
    console.log(w, loc, 'toast vs new work', JSON.stringify(tv));
    await p._ctx.close();
  }
  // reduced motion
  for (const red of [false, true]) {
    const p = await L.newPage(b, { w: 390, h: 844, reduced: red }); await L.open(p, L.BASE + 'v9.html'); await p.waitForTimeout(500);
    const a = await p.evaluate(() => { const an = document.getAnimations().filter(x => x.playState === 'running'); return { running: an.length, names: [...new Set(an.map(x => x.animationName || x.constructor.name))].slice(0, 10), transitions: [...document.querySelectorAll('*')].filter(e => { const d = getComputedStyle(e).transitionDuration; return d && d.split(',').some(v => parseFloat(v) > 0.01); }).length }; });
    await L.loadFile(p, '/tmp/claude-0/-home-user/bed2c260-5a9a-5d57-9a44-5819024f1478/scratchpad/real/drawing_marble_orig.jpg', 'flat');
    await p.evaluate(() => document.getElementById('addBtn').click()); await p.waitForTimeout(100);
    const a2 = await p.evaluate(() => { const an = document.getAnimations().filter(x => x.playState === 'running'); return { running: an.length, names: [...new Set(an.map(x => x.animationName || x.constructor.name))].slice(0, 10) }; });
    console.log('reduced', red, JSON.stringify(a), 'after keep', JSON.stringify(a2));
    await p._ctx.close();
  }
  await b.close();
})();
