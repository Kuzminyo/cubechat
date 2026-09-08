const { chromium } = require('C:/Users/kuzme/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright');
const fs = require('fs');
const path = require('path');
(async()=>{
 const root='D:/projects/cubechat/design-previews/view-once-icons';
 const browser=await chromium.launch({channel:'msedge',headless:true});
 const page=await browser.newPage({viewport:{width:1180,height:800},deviceScaleFactor:1});
 await page.goto('file:///'+root+'/index.html');
 await page.screenshot({path:root+'/preview.png',fullPage:true});
 await page.screenshot({path:root+'/preview.jpg',fullPage:true,type:'jpeg',quality:87});
 const exportPage=await browser.newPage({viewport:{width:2048,height:2048},deviceScaleFactor:1});
 for(const file of fs.readdirSync(root+'/svg')){
  const source=fs.readFileSync(root+'/svg/'+file,'utf8');
  for(const [name,color] of Object.entries({ink:'#253125',white:'#F4F6F0',matcha:'#A3B58F'})){
   await exportPage.setContent('<style>html,body{margin:0;background:transparent}svg{display:block;width:2048px;height:2048px;color:'+color+'}</style>'+source);
   await exportPage.screenshot({path:root+'/png-2k/'+path.basename(file,'.svg')+'-'+name+'.png',omitBackground:true});
  }
 }
 await page.setViewportSize({width:390,height:844});
 await page.goto('file:///'+root+'/index.html');
 console.log(JSON.stringify({mobileOverflow:await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),svgCount:fs.readdirSync(root+'/svg').length,pngCount:fs.readdirSync(root+'/png-2k').length}));
 await browser.close();
})().catch(e=>{console.error(e);process.exit(1)});
