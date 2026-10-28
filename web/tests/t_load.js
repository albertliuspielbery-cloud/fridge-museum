const L = require('./lib');
const VPS = [[375, 667, 1], [390, 844, 2], [1280, 800, 1]];
const res = [];
const audit = () => {
  const broken = [...document.querySelectorAll('use')].map(u => u.getAttribute('href')).filter(h => h && h.startsWith('#') && !document.getElementById(h.slice(1)));
  const vis = el => { const r = el.getBoundingClientRect(); const cs = getComputedStyle(el); return r.width > 0 && r.height > 0 && cs.visibility !== 'hidden'; };
  const clipped = [];
  document.querySelectorAll('button, .chip, .quota, .placard, .placard *, .say, .toast, h1, h2, .modes button, .mode-tile *, .tools button span, .hint, .dock *').forEach(el => {
    if (!vis(el)) return; const cs = getComputedStyle(el);
    if ((el.scrollWidth > el.clientWidth + 1 && cs.overflowX !== 'visible') || (el.scrollHeight > el.clientHeight + 2 && cs.overflowY === 'hidden'))
      clipped.push((el.id || el.className.baseVal || el.className || el.tagName) + ':' + el.textContent.trim().slice(0, 30) + ` [${el.scrollWidth}/${el.clientWidth}x${el.scrollHeight}/${el.clientHeight}]`);
    const r = el.getBoundingClientRect(); if (r.right > innerWidth + 1 || r.left < -1) clipped.push('OFFSCREEN ' + (el.id || el.className) + ':' + el.textContent.trim().slice(0, 20) + ` [${Math.round(r.left)}..${Math.round(r.right)}]`);
  });
  const cjk = [];
  if (LANG === 'en') {
    const w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    let n; while ((n = w.nextNode())) { const p = n.parentElement; if (!p || p.closest('script,style,[lang="zh-Hant"]')) continue; if (/[㐀-鿿　-〿＀-￯]/.test(n.textContent)) cjk.push(p.id + '|' + p.className + ':' + n.textContent.trim().slice(0, 40)); }
    document.querySelectorAll('[aria-label],[title],[placeholder],[alt]').forEach(e => { for (const a of ['aria-label', 'title', 'placeholder', 'alt']) { const v = e.getAttribute(a); if (v && /[㐀-鿿]/.test(v) && !e.closest('[lang="zh-Hant"]')) cjk.push('@' + a + ' ' + (e.id || e.tagName) + ':' + v.slice(0, 30)); } });
  }
  return { title: document.title, htmlLang: document.documentElement.lang, lang: LANG, sw: document.documentElement.scrollWidth, iw: innerWidth, broken, clipped: [...new Set(clipped)].slice(0, 15), cjk: cjk.slice(0, 15) };
};
(async () => {
  const b = await L.launch();
  for (const [w, h, dpr] of VPS) for (const scheme of ['light', 'dark']) for (const locale of ['zh-TW', 'en-US']) {
    const p = await L.newPage(b, { w, h, dpr, scheme, locale });
    const t0 = Date.now();
    await p.goto(L.BASE + 'v9.html');
    await p.waitForTimeout(150);
    const tag = `${w}x${h}_${scheme}_${locale}`;
    await p.screenshot({ path: `shots/first_${tag}.png` });
    await p.waitForFunction(() => !document.getElementById('heroDone').hidden, null, { timeout: 30000 }).catch(() => {});
    await p.evaluate(() => document.fonts.ready); await p.waitForTimeout(400);
    const firstMs = Date.now() - t0;
    await p.screenshot({ path: `shots/home_${tag}.png` });
    const a = await p.evaluate(audit);
    // sample flat
    await L.tap(p, '#sampleFlat'); await L.waitDone(p); await p.waitForTimeout(500);
    await p.screenshot({ path: `shots/editflat_${tag}.png` });
    const ef = await p.evaluate(audit);
    const flatAsp = await p.evaluate(() => S.output.height / S.output.width);
    await L.tap(p, '#backBtn'); await L.tap(p, '#sampleCraft'); await L.waitDone(p);
    await p.waitForFunction(() => S.mlDebug.ms != null || S.mlDebug.path === 'none', null, { timeout: 60000 }).catch(() => {});
    await p.waitForTimeout(600);
    await p.screenshot({ path: `shots/editcraft_${tag}.png` });
    const ec = await p.evaluate(audit); const ml = await p.evaluate(() => S.mlDebug);
    // version + paywall sheets
    await L.tap(p, '#backBtn'); await L.tap(p, '#verBtn'); await p.waitForTimeout(400);
    await p.screenshot({ path: `shots/ver_${tag}.png` });
    const ev = await p.evaluate(audit);
    await p.keyboard.press('Escape');
    await p.evaluate(() => openPaywall(null)); await p.waitForTimeout(400);
    await p.screenshot({ path: `shots/pay_${tag}.png` });
    const ep = await p.evaluate(audit);
    const payGeom = await p.evaluate(() => { const r = q => document.querySelector(q).getBoundingClientRect(); return { note: r('.paytest').top, noteB: r('.paytest').bottom, unlock: r('#payUnlock').top, unlockB: r('#payUnlock').bottom, later: r('#payLater').bottom, ih: innerHeight }; });
    res.push({ tag, firstMs, home: a, editFlat: ef, editCraft: ec, ver: ev, pay: ep, payGeom, flatAsp, ml, log: p._log.errors.concat(p._log.console), failed: p._log.failed });
    await p._ctx.close();
  }
  require('fs').writeFileSync('out/load.json', JSON.stringify(res, null, 1));
  for (const r of res) console.log(r.tag, 'first', r.firstMs, 'asp', r.flatAsp.toFixed(3), 'ml', r.ml.path, r.ml.used, r.ml.ms, r.ml.why, '| titles', r.home.title, r.home.htmlLang, '| sw', [r.home, r.editFlat, r.editCraft, r.ver, r.pay].map(x => x.sw + '/' + x.iw).join(' '), '| broken', r.home.broken.length, '| errs', r.log.length, r.failed.length, '| pay', JSON.stringify(r.payGeom));
  for (const r of res) { const c = ['home', 'editFlat', 'editCraft', 'ver', 'pay'].map(k => [k, r[k].clipped, r[k].cjk]).filter(x => x[1].length || x[2].length); if (c.length || r.log.length) console.log(r.tag, JSON.stringify(c), JSON.stringify(r.log), JSON.stringify(r.failed)); }
  await b.close();
})();
