const { chromium } = require('playwright');
const fs=require('fs');process.chdir(__dirname);
const html='<!doctype html><html><head><meta charset=utf8><meta name=viewport content="width=device-width,initial-scale=1,viewport-fit=cover"><style>[hidden]{display:none!important}</style></head><body>'+fs.readFileSync('/home/user/kidart/kidart.html','utf8')+'</body></html>';
fs.writeFileSync(__dirname+'/_ui.html',html);
const D=__dirname+'/ui_';
(async()=>{
 const b=await chromium.launch();
 const errs=[];
 async function mk(opts){ const p=await b.newPage(opts); p.on('console',m=>{ if(m.type()==='error'||m.type()==='warning') errs.push(m.type()+': '+m.text()); }); p.on('pageerror',e=>errs.push('PAGEERR '+e.message)); await p.goto('file://'+__dirname+'/_ui.html'); await p.waitForTimeout(2500); return p; }
 const ovf=async(p,tag)=>{ const r=await p.evaluate(()=>[document.documentElement.scrollWidth, innerWidth]); console.log(tag,'scrollW',r[0],'innerW',r[1], r[0]<=r[1]?'OK':'OVERFLOW'); };
 const p=await mk({viewport:{width:390,height:844},deviceScaleFactor:2});
 await ovf(p,'home'); console.log('fonts', await p.evaluate(()=>[...new Set([...document.fonts].filter(f=>f.status==='loaded').map(f=>f.family+' '+f.weight))].join(', '))); console.log('heroRaw', await p.$eval('#heroRaw',e=>e.naturalWidth)); await p.screenshot({path:D+'1-home.png'});
 await p.screenshot({path:D+'1b-home-full.png', fullPage:true});
 await p.click('#heroOpen'); await p.waitForTimeout(600);
 console.log('hint:', await p.$eval('#hint',e=>e.textContent));
 await ovf(p,'edit'); await p.screenshot({path:D+'2-edit-flat.png'});
 // drag compare
 const bx=await p.$eval('#view',e=>{const r=e.getBoundingClientRect();return [r.x,r.y,r.width,r.height]});
 await p.mouse.move(bx[0]+bx[2]/2,bx[1]+bx[3]/2); await p.mouse.down(); await p.mouse.move(bx[0]+bx[2]*0.25,bx[1]+bx[3]/2,{steps:5}); await p.mouse.up();
 console.log('split', await p.evaluate(()=>S.split.toFixed(2)));
 // adjust sheet + slider
 await p.click('#t_adjust'); await p.waitForTimeout(300);
 await p.$eval('#strength',e=>{e.value=90;e.dispatchEvent(new Event('input'))}); await p.waitForTimeout(800);
 console.log('strength', await p.evaluate(()=>S.params.strength));
 await ovf(p,'adjust'); await p.screenshot({path:D+'3-sheet-adjust.png'});
 await p.click('#t_crop'); await p.waitForTimeout(300); console.log('view', await p.evaluate(()=>S.view)); await p.screenshot({path:D+'4-sheet-crop.png'});
 await p.click('#t_brush'); await p.waitForTimeout(300); console.log('tool', await p.evaluate(()=>S.tool));
 await p.mouse.move(bx[0]+40,bx[1]+bx[3]/2); await p.mouse.down(); await p.mouse.move(bx[0]+80,bx[1]+bx[3]/2+10,{steps:4}); await p.mouse.up(); await p.waitForTimeout(400);
 console.log('strokes', await p.evaluate(()=>S.strokes.length)); await p.screenshot({path:D+'5-sheet-brush.png'});
 await p.click('#undo'); console.log('after undo', await p.evaluate(()=>S.strokes.length));
 await p.click('#t_info'); await p.waitForTimeout(300); await p.fill('#kidName','小明'); await p.fill('#kidBirth','2020-03-01'); await p.waitForTimeout(200);
 console.log('age', await p.$eval('#ageOut',e=>e.textContent)); await ovf(p,'info'); await p.screenshot({path:D+'6-sheet-info.png'});
 await p.click('#t_info'); await p.waitForTimeout(200); console.log('sheet closed', await p.evaluate(()=>S.sheet));
 // save -> overlay
 await p.click('#saveBtn'); await p.waitForTimeout(800); console.log('overlay visible', await p.isVisible('#overlay')); await p.screenshot({path:D+'7-overlay.png'});
 await p.click('#overlayClose'); console.log('overlay closed', !(await p.isVisible('#overlay')));
 // add to session
 await p.click('#addBtn'); await p.waitForSelector('.thumb',{timeout:20000}); await p.waitForTimeout(300); console.log('home after add', await p.isVisible('#home'), 'thumbs', await p.$$eval('.thumb',a=>a.length));
 await p.screenshot({path:D+'8-home-session.png'});
 // craft sample
 await p.click('#sampleCraft'); await p.waitForTimeout(3500); console.log('mode', await p.evaluate(()=>S.mode));
 await p.click('#compareBtn'); await p.waitForTimeout(300);
 await p.screenshot({path:D+'9-edit-craft.png'});
 await p.click('#t_adjust'); await p.waitForTimeout(300); await p.click('.swatch[data-bg="grad"]'); await p.$eval('#sens',e=>{e.value=70;e.dispatchEvent(new Event('input'))}); await p.waitForTimeout(1500);
 await p.screenshot({path:D+'10-craft-adjust.png'});
 await p.click('#t_brush'); await p.waitForTimeout(200); await p.click('#toolRestore'); console.log('tool', await p.evaluate(()=>S.tool));
 // switch mode in edit
 await p.click('#eModeFlat'); await p.waitForTimeout(3000); console.log('mode after switch', await p.evaluate(()=>S.mode), 'cropBtn visible', await p.isVisible('#t_crop'));
 await p.click('#backBtn'); await p.click('#modeCraft'); console.log('pick', await p.evaluate(()=>pickMode));
 await p.click('.thumb'); await p.waitForTimeout(600); console.log('thumb overlay', await p.isVisible('#overlay')); await p.keyboard.press('Escape');
 await ovf(p,'end');
 // small phone
 const s=await mk({viewport:{width:375,height:667},deviceScaleFactor:2}); await ovf(s,'375 home'); await s.click('#heroOpen'); await s.waitForTimeout(500); await s.click('#t_info'); await s.waitForTimeout(300); await ovf(s,'375 info'); await s.screenshot({path:D+'11-375-info.png'});
 const w=await mk({viewport:{width:430,height:932},deviceScaleFactor:2}); await ovf(w,'430 home');
 // desktop
 const dsk=await mk({viewport:{width:1280,height:800}}); await dsk.screenshot({path:D+'12-desktop-home.png'}); await dsk.click('#heroOpen'); await dsk.waitForTimeout(600); await ovf(dsk,'desk'); await dsk.screenshot({path:D+'13-desktop-edit.png'});
 // dark
 const dk=await mk({viewport:{width:390,height:844},deviceScaleFactor:2,colorScheme:'dark'}); await dk.screenshot({path:D+'14-dark-home.png'}); await dk.click('#heroOpen'); await dk.waitForTimeout(800); await dk.screenshot({path:D+'14b-dark-edit-flat.png'}); await dk.click('#backBtn'); await dk.click('#sampleCraft'); await dk.waitForTimeout(3500); await dk.click('#t_adjust'); await dk.waitForTimeout(300); await dk.screenshot({path:D+'15-dark-edit.png'});
 console.log('ERRORS:', errs.length? errs.join('\n'): 'none');
 await b.close();})();
