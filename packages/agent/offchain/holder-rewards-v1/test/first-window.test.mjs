import test from 'node:test';import assert from 'node:assert/strict';
import {buildFirstWindow,regularWindowStart} from '../src/first-window.mjs';
const a=n=>'0x'+BigInt(n).toString(16).padStart(40,'0'),h=n=>'0x'+BigInt(n).toString(16).padStart(64,'0');
const token='0x7b7af51136574c91a12988989c0a08e98ae97777',u=10n**18n;
function fixture(events=[],profits=true){
 const blocks=[{number:'1',timestamp:'1000',hash:h(1),parentHash:h(0),transactions:[h(11)],receipts:[{transactionHash:h(11),transactionIndex:0,blockHash:h(1),logs:[{kind:'Transfer',address:token,from:a(0),to:a(1),value:(1000000n*u).toString(),logIndex:0}]}]},
 {number:'2',timestamp:'1450',hash:h(2),parentHash:h(1),transactions:[h(12)],receipts:[{transactionHash:h(12),transactionIndex:0,blockHash:h(2),logs:events}]},
 {number:'3',timestamp:'1900',hash:h(3),parentHash:h(2),transactions:[],receipts:[]}];
 if(profits)blocks[1].receipts[0].logs.push({kind:'StrategySettled',address:a(9),principal:'100',returned:'110',profit:'10',loss:'0',logIndex:events.length});
 return {mode:'TEST_ONLY',chainId:56,token,kernel:a(9),launchTimestamp:'1000',creationBlock:'1',blocks,
 closeBalances:[{address:a(1),balance:(1000000n*u).toString()}],closeSupply:(1000000n*u).toString(),exclusions:[],canonicalFirstEligibleWindow:'28800'};
}
test('launch mint tracks full 900 seconds; only realized 10% pool and no payout',()=>{
 const r=buildFirstWindow(fixture());assert.equal(r.poolWei,'1');assert.equal(r.recipients[0].weight,(1000000n*u*900n).toString());assert.equal(r.paidWei,'0');assert.equal(r.payoutStatus,'BLOCKED_CANONICAL_V3_8H_ONLY');
});
test('mid-window transfer changes rankings using both half-window balances',()=>{
 const f=fixture([{kind:'Transfer',address:token,from:a(1),to:a(2),value:(800000n*u).toString(),logIndex:0}]);
 f.closeBalances=[{address:a(1),balance:(200000n*u).toString()},{address:a(2),balance:(800000n*u).toString()}];
 const r=buildFirstWindow(f);assert.equal(r.recipients[0].address,a(1));assert.equal(r.recipients[0].weight,(1000000n*u*450n).toString());assert.equal(r.recipients[1].weight,(800000n*u*450n).toString());
});
test('minimum threshold is applied during accrual, matching canonical core',()=>{
 const f=fixture([{kind:'Transfer',address:token,from:a(1),to:a(2),value:(499999n*u).toString(),logIndex:0}]);
 f.closeBalances=[{address:a(1),balance:(500001n*u).toString()},{address:a(2),balance:(499999n*u).toString()}];
 assert.equal(buildFirstWindow(f).recipients.length,1);
});
test('top 30 tied holders sort ascending address; Hamilton rounding conserves pool',()=>{
 const f=fixture();f.blocks[0].receipts[0].logs=Array.from({length:35},(_,i)=>({kind:'Transfer',address:token,from:a(0),to:a(35-i),value:(500000n*u).toString(),logIndex:i}));
 f.closeSupply=(17500000n*u).toString();f.closeBalances=Array.from({length:35},(_,i)=>({address:a(i+1),balance:(500000n*u).toString()}));
 f.blocks[1].receipts[0].logs[0].returned='1103';f.blocks[1].receipts[0].logs[0].profit='1003';
 const r=buildFirstWindow(f);assert.equal(r.recipients.length,30);assert.equal(r.recipients[0].address,a(1));assert.equal(r.recipients.at(-1).address,a(30));assert.equal(r.recipients.reduce((n,x)=>n+BigInt(x.amountWei),0n),100n);
});
test('zero realized profit produces zero pool; treasury/fee and unrealized logs ignored',()=>{
 const f=fixture([],false);f.blocks[1].receipts[0].logs.push({kind:'NativeRevenueCredited',address:a(9),amount:'999999',logIndex:0});
 assert.equal(buildFirstWindow(f).poolWei,'0');assert.equal(buildFirstWindow(f).payoutStatus,'NO_REALIZED_PROFIT');
});
test('incomplete receipt chain and missing launch balances cannot pass',()=>{
 const f=fixture();f.blocks[0].receipts=[];assert.throws(()=>buildFirstWindow(f),/Missing/);
 const missing=fixture();missing.blocks[0].receipts[0].logs=[];assert.throws(()=>buildFirstWindow(missing),/Untracked|supply/);
});
test('duplicate/reorged transfers are rejected',()=>{
 const f=fixture();f.blocks[1].parentHash=h(99);assert.throws(()=>buildFirstWindow(f),/reorged/);
 const d=fixture();d.blocks[0].receipts[0].logs.push({...d.blocks[0].receipts[0].logs[0]});assert.throws(()=>buildFirstWindow(d),/Duplicate/);
});
test('close balance reconciliation rejects hidden non-standard transfers',()=>{
 const f=fixture();f.closeBalances[0].balance='1';assert.throws(()=>buildFirstWindow(f),/reconciliation/);
});
test('burn/sell at window end has zero duration and conserves supply',()=>{
 const f=fixture();f.blocks[2].transactions=[h(13)];f.blocks[2].receipts=[{transactionHash:h(13),blockHash:h(3),transactionIndex:0,logs:[{kind:'Transfer',address:token,from:a(1),to:a(0),value:(100000n*u).toString(),logIndex:0}]}];
 f.closeSupply=(900000n*u).toString();f.closeBalances[0].balance=f.closeSupply;
 assert.equal(buildFirstWindow(f).recipients[0].weight,(1000000n*u*900n).toString());
});
test('first-end crossing UTC boundary skips overlapping regular window',()=>{
 assert.equal(regularWindowStart(28900n,28800n),57600n);assert.equal(regularWindowStart(28800n,28800n),28800n);
});
test('dataset is deterministic across restart/replay; production inputs fail closed',()=>{
 const f=fixture();assert.equal(buildFirstWindow(f).datasetSHA256,buildFirstWindow(structuredClone(f)).datasetSHA256);
 f.mode='PRODUCTION';assert.throws(()=>buildFirstWindow(f),/Production replay blocked/);
});
