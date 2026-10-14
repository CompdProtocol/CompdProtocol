// Read-only backend observations, never simulation or implied payout approval.
const hash=x=>typeof x==='string'&&/^0x[0-9a-f]{64}$/i.test(x)?x:null;
const uint=x=>typeof x==='string'&&/^\d+$/.test(x)&&BigInt(x)<2n**256n?x:null;
const integer=x=>Number.isSafeInteger(x)&&x>=0?x:null;
const address=x=>typeof x==='string'&&/^0x[0-9a-f]{40}$/i.test(x)?x:null;
const label=x=>typeof x==='string'&&/^[A-Z0-9_]{1,100}$/.test(x)?x:'NOT_VERIFIED';
export function holderProjection(raw){
 if(!raw||!hash(raw.indexedThroughHash)||!integer(raw.indexedThroughBlock))return {status:'NOT_ACTIVATED_VERIFIED_LAUNCH_AND_INDEX_REQUIRED',top30:[],payouts:[],allocatedWei:null,paidWei:null,pendingLiabilitiesWei:null};
 return {status:'NOT_ACTIVATED_DRY_RUN_INDEXED',epochStatus:label(raw.currentEpochStatus),epochKind:label(raw.kind),
 epochStart:integer(raw.start),epochEnd:integer(raw.end),countdownSeconds:integer(raw.countdownSeconds),
 launchTimestamp:integer(raw.launchTimestamp),windowEnd:integer(raw.firstWindowEnd),
 allocatedWei:uint(raw.poolWei),paidWei:uint(raw.paidRewardsWei),pendingLiabilitiesWei:uint(raw.pendingLiabilitiesWei),
 availableFundsWei:uint(raw.availableRewardFundsWei),top30Scope:'CONFIRMED_EVENTS_CURRENT_WINDOW_PREVIEW',
 totalsScope:'ALL_INDEXED_KERNEL_PAYMENTS',checkpoint:raw.firstCheckpoint?{outcome:label(raw.firstCheckpoint.status),meaning:'BACKEND_OBSERVATION_NOT_INDEPENDENT_CLEARANCE'}:null,
 top30:(Array.isArray(raw.top30)?raw.top30:[]).slice(0,30).filter(x=>address(x.address)&&uint(x.weight)&&uint(x.amountWei)).map(x=>({address:x.address,weight:x.weight,amountWei:x.amountWei})),
 payouts:(Array.isArray(raw.payoutTransactions)?raw.payoutTransactions:[]).slice(-30).filter(x=>hash(x.transactionHash)&&address(x.recipient)&&uint(x.amount)).map(x=>({transactionHash:x.transactionHash,recipient:x.recipient,amountWei:x.amount})),
 indexedThroughBlock:integer(raw.indexedThroughBlock),indexedThroughHash:hash(raw.indexedThroughHash)};
}
