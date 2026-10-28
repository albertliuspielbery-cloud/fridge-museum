const L = require('./lib'); const fs=require('fs');
(async () => {
  const b = await L.launch(); const p = await L.newPage(b, { w: 390, h: 844 });
  await L.open(p, (process.env.B || L.BASE) + 'v9.html');
  for (const n of process.argv.slice(2)) {
    await L.loadFile(p, __dirname + '/img/' + n + '.jpg', 'craft'); await p.waitForTimeout(300);
    console.log(n, JSON.stringify(await p.evaluate(() => { const P = craftParts(); return { nSig: P && P.nSig, parts: P && P.list.filter(Boolean).map(q => [q.area, q.edge, q.sig]), drops: S.pick && S.pick.drops.length, chip: !document.getElementById('pickBtn').hidden, hint: document.getElementById('hint').textContent }; })));
    await p.screenshot({ path: `shots/edge${process.env.B?'N':''}_${n}.png` });
  }
  await b.close();
})();
