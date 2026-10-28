const L = require('./lib'); const fs = require('fs');
const R = '/tmp/claude-0/-home-user/bed2c260-5a9a-5d57-9a44-5819024f1478/scratchpad/real/';
const cases = [['wood', R + 'drawing_wood_orig.jpg', 'flat'], ['marble', R + 'drawing_marble_orig.jpg', 'flat'], ['flag', R + 'flag_marble_orig.jpg', 'craft'], ['cup', R + 'cup_orig.jpg', 'craft'], ['two', __dirname + '/img/two_parts.jpg', 'craft'], ['edge', __dirname + '/img/edge_part.jpg', 'craft']];
const [ver, base, cpu, tag] = [process.argv[2], process.argv[3] || L.BASE, +(process.argv[4] || 0), process.argv[5] || ''];
(async () => {
  const b = await L.launch();
  const p = await L.newPage(b, { w: 390, h: 844, cpu: cpu || undefined });
  await L.open(p, base + ver + '.html');
  const dump = async name => { const d = await p.evaluate(() => S.output.toDataURL('image/png')); fs.writeFileSync(`out/${ver}${tag}_${name}.png`, Buffer.from(d.split(',')[1], 'base64')); };
  const info = () => p.evaluate(() => ({ w: S.output.width, h: S.output.height, asp: +(S.output.height / S.output.width).toFixed(3), ml: S.mlDebug && { path: S.mlDebug.path, used: S.mlDebug.used, ms: S.mlDebug.ms, why: S.mlDebug.why, err: S.mlDebug.error }, nSig: typeof craftParts === 'function' && S.mode === 'craft' ? (craftParts() || {}).nSig : undefined, pick: !document.getElementById('pickBtn')?.hidden, hint: document.getElementById('hint').textContent, drops: S.pick ? S.pick.drops.length : 0 }));
  for (const s of ['flat', 'craft']) {
    await p.evaluate(k => document.getElementById(k === 'flat' ? 'sampleFlat' : 'sampleCraft').click(), s);
    await L.waitDone(p); if (s === 'craft') await p.waitForFunction(() => S.mlDebug.ms != null || S.mlDebug.path === 'none' || S.mlDebug.error, null, { timeout: 60000 }).catch(() => {});
    await p.waitForTimeout(300); await dump('sample_' + s); console.log(ver + tag, 'sample', s, JSON.stringify(await info()));
    await p.evaluate(() => document.getElementById('backBtn').click());
  }
  for (const [n, f, m] of cases) {
    const ms = await L.loadFile(p, f, m); await p.waitForTimeout(200);
    await dump(n); await p.screenshot({ path: `shots/proc_${ver}${tag}_${n}.png` });
    console.log(ver + tag, n, ms + 'ms', JSON.stringify(await info()));
  }
  console.log(ver + tag, 'errors', JSON.stringify(p._log.errors), JSON.stringify(p._log.console.filter(c => !/willReadFrequently/.test(c))));
  await b.close();
})();
