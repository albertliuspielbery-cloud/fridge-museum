const L = require('./lib');
(async () => {
  const b = await L.launch(); const p = await L.newPage(b, { w: 375, h: 667 });
  await L.open(p, L.BASE + 'v9.html');
  await L.loadFile(p, '/tmp/claude-0/-home-user/bed2c260-5a9a-5d57-9a44-5819024f1478/scratchpad/real/drawing_wood_orig.jpg', 'flat');
  await p.evaluate(() => document.getElementById('saveBtn').click()); await p.waitForTimeout(1200);
  console.log('overlay', await p.evaluate(() => !document.getElementById('overlay').hidden), 'S.kept', await p.evaluate(() => S.kept), 'count', await p.evaluate(() => localStorage.getItem('kidart.quota.flat.' + today())));
  await p.evaluate(() => document.getElementById('overlayClose').click()); await p.evaluate(() => document.getElementById('backBtn').click()); await p.waitForTimeout(300);
  console.log('pending card hidden', await p.evaluate(() => document.getElementById('pending').hidden));
  // toast action button clickable
  await p.evaluate(() => setStatus('x', 'ok', { label: 'Next', fn: () => { window.__acted = 1; } })); await p.waitForTimeout(200);
  const bx = await p.locator('#statusAct').boundingBox(); await p.mouse.click(bx.x + bx.width / 2, bx.y + bx.height / 2); await p.waitForTimeout(200);
  console.log('toast action works', await p.evaluate(() => window.__acted === 1), 'pe', await p.evaluate(() => getComputedStyle(document.getElementById('statusAct')).pointerEvents));
  await p.evaluate(() => setStatus('hello', '')); await p.waitForTimeout(200);
  const t = await p.locator('#toast').boundingBox(); await p.mouse.click(t.x + t.width / 2, t.y + t.height / 2); await p.waitForTimeout(200);
  console.log('toast hidden after tap on it (old dismiss-on-tap)', await p.evaluate(() => document.getElementById('toast').hidden));
  console.log('errors', p._log.errors, p._log.console);
  await b.close();
})();
