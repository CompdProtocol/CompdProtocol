import test from 'node:test';
import assert from 'node:assert/strict';
import {projectStatus,POLICY} from '../tools/protocol-api.mjs';
test('exact five targets, disabled routes, no invented positions or prices',()=>{
 const a=projectStatus().agent;assert.deepEqual(a.assets,['NVDAx','TSLAx','AMZNx','AAPLx','SPYx']);
 assert.equal(a.routes.length,5);assert(a.routes.every(x=>x.status==='DISABLED_ROUTE_NOT_QUALIFIED'));assert.equal(a.positions,null);assert.equal(a.unrealizedPnl,null);
});
test('fixed risk limits',()=>{const r=projectStatus().agent.risk;assert.deepEqual([r.maximumPositions,r.maximumPositionBps,r.maximumExposureBps,r.designedLossBps,r.dailyLossBps,r.drawdownBps],[3,1000,3000,300,500,1000]);assert.equal(r.latched,null);});
test('dry-run history is explicitly labeled and private fields stripped',()=>{
 const a=projectStatus({xstocks:{evaluations:[{cycle:1,stage:'EVALUATED',scope:'DRY_RUN',secret:'key'},{cycle:2,stage:'EVALUATED',scope:'LIVE'}],positions:[{profit:999}],risk:{latched:true}}}).agent;
 assert.deepEqual(a.evaluations,[{cycle:1,stage:'EVALUATED',scope:'DRY_RUN'}]);assert.equal(a.positions,null);assert.equal(a.risk.latched,null);
});
test('untrusted backend cannot enable arbitrary route or expose quote pnl',()=>{
 const a=projectStatus({xstocks:{assets:['MSFTx'],routes:[{status:'ENABLED'}],unrealizedPnlWei:'100'}}).agent;
 assert.deepEqual(a.assets,POLICY.assets);assert(a.routes.every(x=>x.status.startsWith('DISABLED')));assert.equal(a.unrealizedPnl,null);
});
