import {test} from 'node:test';
import assert from 'node:assert/strict';
import {projectStatus} from '../tools/protocol-api.mjs';
test('buyback counters require pinned snapshot and never imply clearance',()=>{
 let raw={buybackObservation:{activated:true,totalBNBSpentWei:'100',totalCOMPDBurnedBaseUnits:'1000'}};
 assert.equal(projectStatus(raw).flow.buybackObservation.totalBNBSpentWei,null);
 raw.publicSnapshot={chainId:56,blockHash:'0x'+'1'.repeat(64)};
 const flow=projectStatus(raw).flow;assert.equal(flow.buybackObservation.totalBNBSpentWei,'100');
 assert.equal(flow.buybackStatus,'MANUAL_ONLY_TREASURY_EXECUTION_BLOCKED');assert.equal(flow.burns.length,0);
 assert.equal(flow.buybackObservation.qualification,'NOT_VERIFIED_ROUTES_DISPOSAL_AND_GRAPH');
 raw.buybackObservation.totalBNBSpentWei='fake';assert.equal(projectStatus(raw).flow.buybackObservation.totalBNBSpentWei,null);
});
