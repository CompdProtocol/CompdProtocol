// Offline replay only. Existing V3 proof/payment graph accepts 8-hour windows, not 900s.
import {selectTop30,hamiltonAllocate,ELIGIBILITY_THRESHOLD} from './core.mjs';
import {addressHex,bytes32Hex,canonicalJson,sha256Hex,uint} from './codec.mjs';
const ZERO='0x'+'0'.repeat(40);
const TOKEN='0x7b7af51136574c91a12988989c0a08e98ae97777';
export function regularWindowStart(firstEnd,canonicalFirstEligible){
  const end=uint(firstEnd,64),canonical=uint(canonicalFirstEligible,64);
  return ((end+28799n)/28800n)*28800n>canonical?((end+28799n)/28800n)*28800n:canonical;
}
export function buildFirstWindow(bundle){
  if(bundle.mode!=='TEST_ONLY')throw Error('Production replay blocked: complete transfer semantics/source/finality adapter unavailable');
  if(bundle.chainId!==56||addressHex(bundle.token)!==TOKEN)throw Error('Frozen chain/token mismatch');
  const start=uint(bundle.launchTimestamp,64),end=start+900n;
  if(!Array.isArray(bundle.blocks)||!bundle.blocks.length)throw Error('Full contiguous block/receipt bundle required');
  const balances=new Map(),weights=new Map(),last=new Map(),seen=new Set();let supply=0n,previous=null,closed=false,pool=0n;
  const accrue=(a,t)=>{if(a===ZERO)return;const old=last.get(a)??start;const until=t<start?start:t>end?end:t;
    if(until<old)throw Error('Timestamp regressed');const b=balances.get(a)??0n;
    const next=(weights.get(a)??0n)+(b>=ELIGIBILITY_THRESHOLD?b*(until-old):0n);
    if(next>=(1n<<256n))throw Error('Eligible balance-time overflow');weights.set(a,next);last.set(a,until);};
  for(const block of bundle.blocks){
    const n=uint(block.number,256),ts=uint(block.timestamp,64),hash=bytes32Hex(block.hash);
    if(previous&&(n!==previous.n+1n||bytes32Hex(block.parentHash)!==previous.hash||ts<previous.ts))throw Error('Incomplete/reorged header chain');
    previous={n,ts,hash};if(ts>=end)closed=true;
    if(!Array.isArray(block.transactions)||!Array.isArray(block.receipts)||block.transactions.length!==block.receipts.length)throw Error('Missing transaction receipts');
    const receipts=new Map(block.receipts.map(r=>[bytes32Hex(r.transactionHash),r]));
    if(receipts.size!==block.receipts.length)throw Error('Duplicate receipts');
    let lastLog=-1n;
    for(let ti=0;ti<block.transactions.length;ti++){
      const tx=bytes32Hex(block.transactions[ti]),r=receipts.get(tx);
      if(!r||bytes32Hex(r.blockHash)!==hash||uint(r.transactionIndex,32)!==BigInt(ti)||!Array.isArray(r.logs))throw Error('Receipt identity mismatch');
      for(const log of r.logs){
        const index=uint(log.logIndex,32);if(index<=lastLog||seen.has(`${hash}:${index}`)||log.removed)throw Error('Duplicate/removed/unordered log');
        lastLog=index;seen.add(`${hash}:${index}`);
        if(log.kind==='Transfer'&&addressHex(log.address)===TOKEN){
          const from=addressHex(log.from),to=addressHex(log.to),value=uint(log.value,256);
          if(from===ZERO&&to===ZERO)throw Error('Invalid zero-to-zero transfer');
          // Replay all launch/mint history; NEVER invent a launch snapshot from an end balance.
          if(!previous||n<uint(bundle.creationBlock,256))throw Error('Unexpected pre-creation event');
          accrue(from,ts);accrue(to,ts);
          if(from===ZERO)supply+=value;
          else{const available=balances.get(from)??0n;if(available<value)throw Error('Missing mint/transfer history');balances.set(from,available-value);}
          if(to===ZERO){if(supply<value)throw Error('Supply underflow');supply-=value;}
          else balances.set(to,(balances.get(to)??0n)+value);
        }
        if(log.kind==='StrategySettled'&&addressHex(log.address)===addressHex(bundle.kernel)&&ts>=start&&ts<end){
          const principal=uint(log.principal,256),returned=uint(log.returned,256),profit=uint(log.profit,256),loss=uint(log.loss,256);
          if(profit!==(returned>principal?returned-principal:0n)||loss!==(returned<principal?principal-returned:0n))throw Error('Unrealized/incorrect profit evidence');
          pool+=profit*1000n/10000n;
        }
      }
    }
  }
  if(uint(bundle.blocks[0].number,256)!==uint(bundle.creationBlock,256)||!closed)throw Error('Creation-through-close coverage missing');
  for(const a of balances.keys())accrue(a,end);
  const checkpoint=new Map(bundle.closeBalances.map(x=>[addressHex(x.address),uint(x.balance,256)]));
  if(checkpoint.size!==bundle.closeBalances.length)throw Error('Duplicate close balances');
  for(const [a,b] of balances)if((checkpoint.get(a)??0n)!==b)throw Error('Historical balance reconciliation failed');
  for(const [a,b] of checkpoint)if((balances.get(a)??0n)!==b)throw Error('Untracked holder');
  if([...balances.values()].reduce((a,b)=>a+b,0n)!==supply||supply!==uint(bundle.closeSupply,256))throw Error('Historical supply reconciliation failed');
  // Preserve canonical threshold-at-accrual eligibility and exact integral ranking.
  const ranked=selectTop30(weights,bundle.exclusions);
  const allocations=hamiltonAllocate(ranked,pool).map(x=>({address:x.address,weight:x.weight.toString(),
    twabNumerator:x.weight.toString(),twabDenominator:'900',amountWei:x.payout.toString()}));
  const next=regularWindowStart(end,bundle.canonicalFirstEligibleWindow);
  const result={mode:'TEST_ONLY',start:start.toString(),end:end.toString(),poolWei:pool.toString(),recipients:allocations,
    payoutStatus:pool===0n?'NO_REALIZED_PROFIT':'BLOCKED_CANONICAL_V3_8H_ONLY',paidWei:'0',
    eligibilityRule:'CANONICAL_THRESHOLD_AT_ACCRUAL',tracking:'REPLAYED_TEST_BUNDLE_NOT_INDEPENDENT_SOURCE_VERIFICATION',nextRegularWindowStart:next.toString(),
    transitionGapSeconds:(next-end).toString(),transition:'NON_OVERLAP_PROPOSED_NOT_ONCHAIN_INTEGRATED'};
  result.datasetSHA256=sha256Hex(canonicalJson(result));return result;
}
