const L = require('./lib');
const R = '/tmp/claude-0/-home-user/bed2c260-5a9a-5d57-9a44-5819024f1478/scratchpad/real/';
(async () => {
  const b = await L.launch();
  for (const [cpu, cdn] of [[1, 'ok'], [4, 'ok'], [1, 'blocked'], [4, 'blocked']]) for (const f of ['flag_marble_orig.jpg']) {
    const p = await L.newPage(b, { w: 390, h: 844, cpu: cpu > 1 ? cpu : undefined, cdn });
    await L.open(p, L.BASE + 'v9.html');
    const t0 = Date.now(); await p.evaluate(() => { nextMode = 'craft'; }); await p.setInputFiles('#fileIn', R + f);
    await p.waitForFunction(() => S.src && S.output && document.getElementById('busy').hidden, null, { timeout: 90000 }); const tFirst = Date.now() - t0;
    await p.waitForFunction(() => S.mlDebug.used || S.mlDebug.path === 'none', null, { timeout: 90000 }).catch(() => {}); const tML = Date.now() - t0;
    console.log(`cold craft cpu${cpu} cdn=${cdn}`, f, 'first result', tFirst, 'ms; ML result', tML, 'ms', JSON.stringify(await p.evaluate(() => S.mlDebug)));
    await p._ctx.close();
  }
  // forced themes
  for (const [scheme, theme] of [['light', 'dark'], ['dark', 'light']]) {
    const p = await L.newPage(b, { w: 390, h: 844, scheme, locale: 'en-US' }); await p.goto(L.BASE + 'v9.html'); await p.evaluate(t => document.documentElement.dataset.theme = t, theme); await p.waitForTimeout(1500);
    await p.screenshot({ path: `shots/theme_${scheme}_forced_${theme}.png` }); console.log('forced', scheme, theme, await p.evaluate(() => getComputedStyle(document.body).backgroundColor));
    await p._ctx.close();
  }
  // English pick chips + Keep All by touch, 375
  const p = await L.newPage(b, { w: 375, h: 667, locale: 'en-US', touch: true, mobile: true, dpr: 2 }); await L.open(p, L.BASE + 'v9.html');
  await L.loadFile(p, __dirname + '/img/two_parts.jpg', 'craft');
  const tapSel = async s => { const bx = await p.locator(s).boundingBox(); await p.touchscreen.tap(bx.x + bx.width / 2, bx.y + bx.height / 2); await p.waitForTimeout(400); };
  await tapSel('#pickBtn');
  await p.evaluate(() => { const P = craftParts(); const L2 = P.list.filter(q => q && q.sig)[1]; S.pick.drops.push({ x: L2.seed[0], y: L2.seed[1], area: L2.areaPx }); S.pick.touched = true; render(); });
  await p.waitForTimeout(500);
  await p.screenshot({ path: 'shots/pick_en_375.png' });
  console.log('en chips', JSON.stringify(await p.evaluate(() => ['pickBtn', 'keepAllBtn', 'compareBtn'].map(id => { const e = document.getElementById(id), r = e.getBoundingClientRect(); return [id, e.hidden, Math.round(r.left), Math.round(r.right), e.scrollWidth <= e.clientWidth]; }))));
  await tapSel('#keepAllBtn');
  console.log('after keepAll touch', await p.evaluate(() => [...S.pickDrop].join(''), ), await p.evaluate(() => document.getElementById('keepAllBtn').hidden));
  await b.close();
})();
