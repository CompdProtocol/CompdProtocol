// Offline fixture replay only; no payout or RPC transport.
import fs from 'node:fs';
import {buildFirstWindow} from './first-window.mjs';
const [input,output]=process.argv.slice(2);
if(!input||!output)throw Error('Usage: node first-window-cli.mjs fixture.json output.json');
const result=buildFirstWindow(JSON.parse(fs.readFileSync(input,'utf8')));
fs.writeFileSync(output,JSON.stringify(result,null,2)+'\n',{flag:'wx'});
