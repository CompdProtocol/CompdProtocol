import test from 'node:test';
import assert from 'node:assert/strict';
import {projectStatus} from '../tools/protocol-api.mjs';
const snapshot={chainId:56,blockHash:'0x'+'1'.repeat(64),blockNumber:'0x1',blockTimestamp:1030};
test('actual market values stay observation only, amounts remain exact',()=>{
 const r=projectStatus({publicSnapshot:snapshot,xstocks:{mode:'OBSERVE_ONLY',prices:[{symbol:'TSLAx',feed:'0x'+'2'.repeat(40),priceUSD:'382.6',ageSeconds:100,status:'STALE_PRICE',updatedAt:930}],positions:[{id:'1',adapter:'0x'+'3'.repeat(40),state:1,principal:'10000000000000000',credited:'0'}]}});
 assert.equal(r.agent.status,'OBSERVE_ONLY');assert.equal(r.agent.prices[0].status,'STALE_PRICE');assert.equal(r.agent.positions[0].principalWei,'10000000000000000');assert.equal(r.treasury.strategyCapitalWei,null);assert.equal(r.agent.unrealizedPnl,null);assert.deepEqual(r.agent.transactions,[]);
});
test('no snapshot means no unpinned market or position claims',()=>{
 const r=projectStatus({xstocks:{prices:[{symbol:'TSLAx'}],positions:[]}});assert.deepEqual(r.agent.prices,[]);assert.equal(r.agent.positions,null);
});
