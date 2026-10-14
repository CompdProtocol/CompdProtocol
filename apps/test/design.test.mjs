import assert from 'node:assert/strict';
import {test} from 'node:test';
import {readFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {spawnSync} from 'node:child_process';
test('original CSS, branding, navigation, motion and vendor assets are byte-identical',async()=>{
 const baseline=JSON.parse(await readFile(new URL('design-baseline.json',import.meta.url),'utf8'));
 for(const [path,hash] of Object.entries(baseline))assert.equal(createHash('sha256').update(await readFile(new URL('../'+path,import.meta.url))).digest('hex'),hash,path);
});
test('all page inline scripts remain valid and mobile viewport/navigation structure is retained',async()=>{
 for(const name of ['index','treasury','agent','flow','protocol','docs','app']){
  const html=await readFile(new URL('../src/'+name+'.html',import.meta.url),'utf8');assert.match(html,/name="viewport" content="width=device-width, initial-scale=1"/);assert.match(html,/class="menu-toggle"/);assert.match(html,/aria-controls="site-menu"/);
  for(const match of html.matchAll(/<script(?![^>]*src=)[^>]*>([\s\S]*?)<\/script>/g)){const result=spawnSync(process.execPath,['--check','--input-type=commonjs'],{input:match[1],encoding:'utf8'});assert.equal(result.status,0,result.stderr);}
 }
});
test('four profit branches conserve100% and their portrait card bounds do not overlap',async()=>{
 const js=await readFile(new URL('../src/flow-page.js',import.meta.url),'utf8');
 const matches=[...js.matchAll(/id: 'q[1-4]', x: 915, y: (\d+),[^\n]+share: (\d+)/g)];assert.equal(matches.length,4);assert.equal(matches.reduce((n,m)=>n+Number(m[2]),0),100);
 const positions=matches.map(m=>Number(m[1])).sort((a,b)=>a-b);assert.ok(positions[0]-64>=0);assert.ok(positions.at(-1)+64<=560);for(let i=1;i<positions.length;i++)assert.ok(positions[i]-positions[i-1]>=128);
 assert.match(js,/c\.id\.startsWith\('q'\) \? 128 : 140/);
});
