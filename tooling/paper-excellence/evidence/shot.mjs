import { chromium } from '/Volumes/SATECHI/github/barkpark/js/node_modules/node_modules/playwright/index.mjs';
const OUT='/Volumes/SATECHI/dev-caches/tmp/claude-code/claude-501/-Volumes-SATECHI-github-barkpark/ae630efc-99c8-4191-8e9e-010f5bff94de/scratchpad/shots';
const slugs=process.argv.slice(2);
const b=await chromium.launch();
for(const s of slugs){
 for(const theme of ['light','dark']){
  for(const w of [1440,768]){
   const ctx=await b.newContext({viewport:{width:w,height:1200},colorScheme:theme,deviceScaleFactor:1});
   const p=await ctx.newPage();
   await p.goto(`https://guerrilla.barkpark.cloud/papers/${s}`,{waitUntil:'networkidle',timeout:45000});
   await p.screenshot({path:`${OUT}/${s}__${theme}__${w}.png`,fullPage:false});
   if(theme==='light'&&w===1440){
     const m=await p.evaluate(()=>{
       const art=document.querySelector('article,main,.bp-paper-surface,.paper-body')||document.body;
       const ps=[...art.querySelectorAll('p')].filter(e=>e.textContent.trim().length>120);
       const p0=ps[0];const cs=p0?getComputedStyle(p0):null;
       const h2=art.querySelector('h2');const h1=art.querySelector('h1');
       const ar=art.getBoundingClientRect();
       return {docW:document.documentElement.clientWidth,
         container:art.className||art.tagName, containerW:+ar.width.toFixed(1), containerLeft:+ar.left.toFixed(1),
         pCount:ps.length,
         p:cs&&{fontSize:cs.fontSize,lineHeight:cs.lineHeight,textAlign:cs.textAlign,hyphens:cs.hyphens+'/'+cs.webkitHyphens,family:cs.fontFamily.split(',')[0],color:cs.color,width:+p0.getBoundingClientRect().width.toFixed(1)},
         h1:h1&&{fs:getComputedStyle(h1).fontSize,fam:getComputedStyle(h1).fontFamily.split(',')[0],weight:getComputedStyle(h1).fontWeight},
         h2:h2&&{fs:getComputedStyle(h2).fontSize,weight:getComputedStyle(h2).fontWeight},
         bodyBg:getComputedStyle(document.body).backgroundColor,
         blockTypes:[...new Set([...document.querySelectorAll('[data-block-type]')].map(e=>e.dataset.blockType))],
       };
     });
     console.log(JSON.stringify({slug:s,...m}));
   }
   await ctx.close();
  }
 }
}
await b.close();
