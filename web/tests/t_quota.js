const L = require('./lib');
const R = '/tmp/claude-0/-home-user/bed2c260-5a9a-5d57-9a44-5819024f1478/scratchpad/real/';
const IMG = __dirname + '/img/';
(async () => {
  const b = await L.launch();
  const p = await L.newPage(b, { w: 375, h: 667, locale: 'en-US' });
  await L.open(p, L.BASE + 'v9.html');
  const st = () => p.evaluate(() => ({ quota: document.getElementById('quotaText').textContent, pay: !document.getElementById('payModal').hidden, sess: session.length, flatKey: localStorage.getItem('kidart.quota.flat.' + today()), craft: localStorage.getItem('kidart.quota.craft'), unlocked: localStorage.getItem('kidart.unlocked'), overlay: !document.getElementById('overlay').hidden, toast: document.getElementById('toast').hidden ? '' : document.getElementById('statusText').textContent }));
  const click = sel => p.evaluate(s => document.querySelector(s).click(), sel);
  // samples don't count
  await click('#sampleFlat'); await L.waitDone(p); await click('#addBtn'); await p.waitForTimeout(600);
  console.log('after sample keep', await st());
  for (let i = 1; i <= 3; i++) {
    await L.loadFile(p, R + (i % 2 ? 'drawing_wood_orig.jpg' : 'drawing_marble_orig.jpg'), 'flat');
    if (i === 2) { // double tap add
      await p.evaluate(() => { document.getElementById('addBtn').click(); document.getElementById('addBtn').click(); });
    } else if (i === 3) { // keep via save → overlay
      await click('#saveBtn');
    } else await click('#addBtn');
    await p.waitForTimeout(900);
    console.log('flat', i, await st());
    if (i === 3) { await p.screenshot({ path: 'shots/overlay_save.png' }); await click('#overlayClose'); }
  }
  // 4th → paywall
  await L.loadFile(p, R + 'drawing_wood_orig.jpg', 'flat');
  await click('#addBtn'); await p.waitForTimeout(500);
  console.log('flat 4 add', await st());
  await p.screenshot({ path: 'shots/pay_flat_375_en.png' });
  const geom = await p.evaluate(() => { const r = q => document.querySelector(q).getBoundingClientRect(); return { note: [r('.paytest').top|0, r('.paytest').bottom|0], unlock: [r('#payUnlock').top|0, r('#payUnlock').bottom|0], later: [r('#payLater').top|0,r('#payLater').bottom|0], ih: innerHeight, sheetScroll: document.querySelector('#payModal .msheet').scrollHeight + '/' + document.querySelector('#payModal .msheet').clientHeight, focus: document.activeElement.id }; });
  console.log('paygeom flat en', geom);
  // Tab cycle
  const seq = [];
  for (let i = 0; i < 9; i++) { await p.keyboard.press('Tab'); seq.push(await p.evaluate(() => { const a = document.activeElement; const cs = getComputedStyle(a); return (a.id || a.className) + (cs.outlineStyle !== 'none' && cs.outlineWidth !== '0px' ? '' : (cs.boxShadow !== 'none' ? '' : '[noring]')); })); }
  console.log('pay tab', seq.join(' > '));
  const seq2 = []; for (let i = 0; i < 6; i++) { await p.keyboard.press('Shift+Tab'); seq2.push(await p.evaluate(() => document.activeElement.id || document.activeElement.className)); }
  console.log('pay shift-tab', seq2.join(' > '));
  // Maybe tomorrow
  await click('#payLater'); await p.waitForTimeout(300);
  console.log('after later', await st());
  // unlock completes pending
  await click('#addBtn'); await p.waitForTimeout(300); await click('#payUnlock'); await p.waitForTimeout(1200);
  console.log('after unlock', await st());
  // restore while unlocked
  await p.evaluate(() => openPaywall(null)); await click('#payRestore'); await p.waitForTimeout(300); console.log('restore unlocked', await st());
  // reset in version sheet
  await click('#verBtn'); await p.waitForTimeout(300);
  const vseq = []; for (let i = 0; i < 8; i++) { await p.keyboard.press('Tab'); vseq.push(await p.evaluate(() => document.activeElement.id || document.activeElement.dataset.lang || document.activeElement.className)); }
  console.log('ver tab', vseq.join(' > '));
  await click('#resetQuota'); await p.waitForTimeout(300); console.log('after reset', await st());
  await p.keyboard.press('Escape');
  // restore when not unlocked
  await p.evaluate(() => openPaywall(null)); await click('#payRestore'); await p.waitForTimeout(300); console.log('restore not unlocked', await st()); await click('#payLater');
  // craft trial
  for (let i = 1; i <= 4; i++) {
    await L.loadFile(p, R + (i % 2 ? 'cup_orig.jpg' : 'flag_marble_orig.jpg'), 'craft');
    await click('#addBtn'); await p.waitForTimeout(900);
    console.log('craft', i, await st());
  }
  await p.screenshot({ path: 'shots/pay_craft_375_en.png' });
  console.log('errors', p._log.errors, p._log.console);
  await b.close();
})();
