import {readFileSync} from 'node:fs';
import {pathToFileURL} from 'node:url';
import {domainFor,windowAndDistribution,computeDatasetHash,hamiltonAllocate,buildMerkle,leafHash,verifyPhase3Proof} from './core.mjs';
import {addressHex,bytes32Hex,uint,keccak256,canonicalJson} from './codec.mjs';
const ZERO='0x'+'0'.repeat(40),TOKEN='0x7b7af51136574c91a12988989c0a08e98ae97777';
function decimalize(value){
 if(typeof value==='bigint')return value.toString();
 if(typeof value==='number'){if(!Number.isSafeInteger(value))throw Error('Unsafe integer');return String(value);}
 if(Array.isArray(value))return value.map(decimalize);
 if(value&&typeof value==='object')return Object.fromEntries(Object.entries(value).map(([k,v])=>[k,decimalize(v)]));
 return value;
}
export function buildIndexedProposal(input){
 if(input.mode!=='DRY_RUN_INDEXED_PROPOSAL')throw Error('Unsigned proposal only; execution approval not inferred');
 const p=input.protocol,r=input.reward,e=input.evidence;
 if(uint(p.chainId,256)!==56n||addressHex(p.token)!==TOKEN)throw Error('Canonical identity');
 const start=uint(r.start,64),end=uint(r.end,64),launch=uint(p.launchTimestamp,64),firstEnd=launch+900n;
 const boundary=(firstEnd+28799n)/28800n*28800n;
 const valid=(start===launch&&end===firstEnd)||(start===firstEnd&&end===boundary&&end>start)||(start>=boundary&&start%28800n===0n&&end===start+28800n);
 if(!valid)throw Error('Invalid epoch');
 const pool=uint(r.poolWei,256);if(pool===0n)throw Error('Zero windows use finalizeZeroWindow');
 const ranked=r.top30.map(x=>({address:addressHex(x.address),weight:uint(x.weight,256)}));
 if(ranked.length===0||ranked.length>30)throw Error('Recipients require explicit evidence');
 const allocated=hamiltonAllocate(ranked,pool);
 if(allocated.some((x,i)=>x.payout!==uint(r.top30[i].amountWei,256)))throw Error('Indexer/allocation disagreement');
 const entries=allocated.filter(x=>x.payout>0n); // Zero-wei allocations remain displayed but never become an unpayable leaf.
 const config={chainId:56n,compdToken:TOKEN,vault:addressHex(p.kernel),distributor:addressHex(p.distributor),rewardAsset:ZERO,
 activationBlock:uint(p.creationBlock,256),activationBlockHash:bytes32Hex(p.creationBlockHash),activationTimestamp:launch,
 windowStart:start,windowEnd:end,algorithmVersion:1n,commitmentVersion:1n,exclusionVersion:uint(p.exclusionSetVersion,32)};
 if(uint(e.snapshotBlock,256)<config.activationBlock||uint(e.closeBlock,256)<=uint(e.snapshotBlock,256)||uint(e.finalityBlock,256)<uint(e.closeBlock,256))throw Error('Evidence ordering');
 const context={domainSeparator:domainFor(config)};Object.assign(context,windowAndDistribution(config,context.domainSeparator));
 const checkpoint={startBlock:config.activationBlock,blockNumber:uint(e.finalityBlock,256),blockHash:bytes32Hex(e.finalityBlockHash)};
 const hashes=computeDatasetHash(config,context,pool,pool,entries,bytes32Hex(p.exclusionSetHash),checkpoint);
 const merkle=buildMerkle(config,context,entries,pool,pool,hashes.datasetHash);
 if(!merkle.leaves.every((l,i)=>verifyPhase3Proof(l,merkle.proofs[i],merkle.root,entries.length)))throw Error('Proof self-check');
 const candidate={distributionId:context.distributionId,windowId:context.windowId,windowStart:start,windowEnd:end,rewardAsset:ZERO,
 windowPool:pool,payableTotal:pool,recipientCount:BigInt(entries.length),root:merkle.root,datasetHash:hashes.datasetHash,algorithmVersion:1n,version:1n,
 acceptedAt:0n,executableAfter:0n,empty:false,finalized:false,materializedCount:0n,materializedTotal:0n};
 const manifest=decimalize(input);
 const evidence={manifestHash:keccak256(canonicalJson(manifest)),entriesHash:hashes.entriesHash,snapshotBlock:uint(e.snapshotBlock,256),snapshotBlockHash:bytes32Hex(e.snapshotBlockHash),
 sourceStartBlock:config.activationBlock,closeBlock:uint(e.closeBlock,256),closeBlockHash:bytes32Hex(e.closeBlockHash),finalityBlock:checkpoint.blockNumber,finalityBlockHash:checkpoint.blockHash,
 exclusionSetVersion:config.exclusionVersion,exclusionSetHash:bytes32Hex(p.exclusionSetHash),replayCodeHash:bytes32Hex(e.replayCodeHash)};
 return JSON.parse(canonicalJson(decimalize({status:'DRY_RUN_UNSIGNED_CANDIDATE_NOT_INDEPENDENT_CLEARANCE',candidate,evidence,
 leafIds:merkle.leaves.map(leafHash),leaves:merkle.leaves,proofs:merkle.proofs,manifest,reviewSeconds:1800n})));
}
if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href){
 try{process.stdout.write(JSON.stringify(buildIndexedProposal(JSON.parse(readFileSync(0,'utf8')))));}
 catch{process.stderr.write('Indexed candidate verification failed\n');process.exitCode=1;}
}
