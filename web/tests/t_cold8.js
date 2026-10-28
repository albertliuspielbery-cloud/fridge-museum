const L = require('./lib');
const R = '/tmp/claude-0/-home-user/bed2c260-5a9a-5d57-9a44-5819024f1478/scratchpad/real/';
(async () => {
  const b = await L.launch();
  for (const [cpu, cdn] of [[4,'ok']]) for (const f of ['flag_marble_orig.jpg','cup_orig.jpg']) {
    const p = await L.newPage(b, { w: 390, h: 844, cpu: cpu > 1 ? cpu : undefined, cdn });
    await L.open(p, L.BASE + 'v8.html');
    const t0 = Date.now(); await p.evaluate(() => { nextMode = 'craft'; }); await p.setInputFiles('#fileIn', R + f);
    await p.waitForFunction(() => S.src && S.output && document.getElementById('busy').hidden, null, { timeout: 90000 }); const tFirst = Date.now() - t0;
    await p.waitForFunction(() => S.mlDebug.used || S.mlDebug.path === 'none', null, { timeout: 90000 }).catch(() => {}); const tML = Date.now() - t0;
    console.log(`cold craft cpu${cpu} cdn=${cdn}`, f, 'first result', tFirst, 'ms; ML result', tML, 'ms', JSON.stringify(await p.evaluate(() => S.mlDebug)));
    await p._ctx.close();
  }
  await b.close(); })();
