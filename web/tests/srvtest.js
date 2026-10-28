const { chromium } = require('playwright'); const fs = require('fs');
const html = '<!doctype html><html><head><meta charset=utf8><meta name=viewport content="width=device-width,initial-scale=1,viewport-fit=cover"><style>[hidden]{display:none!important}</style></head><body>' + fs.readFileSync('/home/user/kidart/kidart.html', 'utf8') + '</body></html>';
fs.writeFileSync(__dirname + '/srv/index.html', html);
(async () => {
  const b = await chromium.launch(); const errs = [];
  const p = await b.newPage({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2 }); p.on('pageerror', e => errs.push('PAGEERR ' + e.message)); p.on('console', m => { if (m.type() === 'error') errs.push(m.text()); });
  const fetched = []; p.on('response', r => { if (r.url().includes('samples')) fetched.push(r.url().split('/').pop() + ' ' + r.status()); });
  await p.goto('http://localhost:8766/index.html'); await p.waitForTimeout(6000);
  console.log('fetched', fetched, 'heroDone', await p.isVisible('#heroDone'), 'src', await p.evaluate(() => S.src && [S.src.width, S.src.height, S.sourceName]));
  await p.screenshot({ path: __dirname + '/srv_1home.png' });
  await p.click('#heroOpen'); await p.waitForTimeout(1500); console.log('hint', await p.$eval('#hint', e => e.textContent)); await p.screenshot({ path: __dirname + '/srv_2flat.png' });
  await p.click('#t_crop'); await p.waitForTimeout(400); await p.screenshot({ path: __dirname + '/srv_3crop.png' });
  await p.click('#rotR'); await p.waitForTimeout(1500); console.log('rot', await p.evaluate(() => [S.rot, S.view, S.output.width, S.output.height]), await p.$eval('#hint', e => e.textContent)); await p.screenshot({ path: __dirname + '/srv_4rot.png' });
  await p.click('#t_crop'); await p.waitForTimeout(400); console.log('view after tap crop', await p.evaluate(() => S.view));
  await p.click('#t_crop'); await p.waitForTimeout(300); console.log('sheet', await p.evaluate(() => S.sheet));
  // brush after rotation
  await p.click('#t_brush'); await p.waitForTimeout(300); const bx = await p.$eval('#view', e => { const r = e.getBoundingClientRect(); return [r.x, r.y, r.width, r.height]; });
  await p.mouse.move(bx[0] + bx[2] * 0.5, bx[1] + bx[3] * 0.6); await p.mouse.down(); await p.mouse.move(bx[0] + bx[2] * 0.6, bx[1] + bx[3] * 0.6, { steps: 5 }); await p.mouse.up(); await p.waitForTimeout(800);
  console.log('strokes', await p.evaluate(() => S.strokes.length)); await p.screenshot({ path: __dirname + '/srv_5brush.png' });
  await p.click('#t_brush'); await p.click('#backBtn'); await p.waitForTimeout(300);
  await p.click('#sampleCraft'); await p.waitForTimeout(5000); console.log('craft', await p.evaluate(() => [S.mode, S.sourceName, S.src.width, S.src.height, S.craft.info]), await p.$eval('#hint', e => e.textContent));
  await p.click('#t_adjust'); await p.waitForTimeout(400); await p.screenshot({ path: __dirname + '/srv_6craftadj.png', fullPage: false });
  await p.$eval('#tilt', e => { e.value = -8; e.dispatchEvent(new Event('input')); }); await p.waitForTimeout(1500); await p.click('#rotL'); await p.waitForTimeout(1500);
  console.log('craft turn', await p.evaluate(() => [S.rot, S.tilt, S.output.width, S.output.height])); await p.screenshot({ path: __dirname + '/srv_7craftturn.png' });
  await p.click('#t_info'); await p.waitForTimeout(300); await p.$eval('#caption', e => { e.checked = true; e.dispatchEvent(new Event('change')); }); await p.waitForTimeout(800); console.log('caption ok', await p.evaluate(() => S.output.height));
  await p.click('#saveBtn'); await p.waitForTimeout(3000); console.log('overlay', await p.isVisible('#overlay')); await p.screenshot({ path: __dirname + '/srv_8save.png' });
  console.log('ERR', errs); await b.close();
})();
