import {holderProjection} from './holder-api.mjs';
export const POLICY = Object.freeze({chainId:56,reservedToken:'0x7b7Af51136574c91A12988989c0a08E98aE97777',
 agentWallet:'0xB878884A07Fc84e6A1336e15CA8C6580cD7164c3',assets:['NVDAx','TSLAx','AMZNx','AAPLx','SPYx'],
 bootstrap:{strategy:10,treasury:90},fees:{strategy:35,buyback:15,protocol:50},profit:{strategy:65,buyback:15,holders:10,protocol:10},
 cycleSeconds:28800,firstWindowSeconds:900,minimumHolderTokens:'500000',maximumRecipients:30});
const uint=v=>(typeof v==='string'&&/^\d{1,78}$/.test(v))&&BigInt(v)<(1n<<256n)?v:null;
const hash=v=>typeof v==='string'&&/^0x[0-9a-f]{64}$/i.test(v)?v:null;
const address=v=>typeof v==='string'&&/^0x[0-9a-f]{40}$/i.test(v)?v:null;
const integer=v=>Number.isSafeInteger(v)&&v>=0?v:null;
const STATES=new Set(['NOT_VERIFIED','NO_REALIZED_PROFIT','PAYOUT_STATUS_NOT_VERIFIED','NOT_SCHEDULED','RUNNING_OBSERVE_ONLY','RECORDED_OBSERVE_ONLY','WAITING_CAPITAL','PENDING','CONFIRMED','REVERTED','RETRY','SUBMITTING','SUBMISSION_UNKNOWN','DRY_RUN_RECORDED','OBSERVE_ONLY']);
const safeState=v=>STATES.has(v)?v:'NOT_VERIFIED';
function marketQualification(q,status,symbol){
 const state=['OPEN','CLOSED','UNKNOWN'].includes(q?.session?.state)?q.session.state:'UNKNOWN';
 const blockers=[];
 if(status!=='FRESH_REFERENCE_ONLY')blockers.push(status==='STALE_PRICE'?'STALE_PRICE':'PRICE_UNAVAILABLE');
 if(state!=='OPEN')blockers.push(state==='CLOSED'?'MARKET_CLOSED':'MARKET_SESSION_UNKNOWN');
 if(symbol!=='BNB')blockers.push('HALT_STATUS_UNKNOWN');
 return {session:{state,reason:typeof q?.session?.reason==='string'&&/^[A-Z_]{1,100}$/.test(q.session.reason)?q.session.reason:'CALENDAR_UNAVAILABLE',halt:symbol==='BNB'?'NOT_APPLICABLE':'UNKNOWN',basis:'SCHEDULED_SESSION_NOT_HALT_CLEARANCE'},referenceUsable:status==='FRESH_REFERENCE_ONLY',scheduledSessionUsable:state==='OPEN',tradingReady:false,blockers};
}
export function agentMarket(data,snapshot){
 const allowed=new Set(['STALE_PRICE','PRICE_UNAVAILABLE','FRESH_REFERENCE_ONLY']);
 const prices=snapshot?(Array.isArray(data.xstocks?.prices)?data.xstocks.prices:[]).slice(0,6).filter(x=>[...POLICY.assets,'BNB'].includes(x.symbol)&&address(x.feed)&&allowed.has(x.status)).map(x=>({symbol:x.symbol,feed:x.feed,status:x.status,priceUSD:typeof x.priceUSD==='string'&&/^\d{1,30}(\.\d{1,18})?$/.test(x.priceUSD)?x.priceUSD:null,ageSeconds:integer(x.ageSeconds),updatedAt:integer(x.updatedAt),heartbeatSeconds:integer(x.heartbeatSeconds),qualification:marketQualification(x.qualification,x.status,x.symbol)})):[];
 const history=snapshot?(Array.isArray(data.xstocks?.observationHistory)?data.xstocks.observationHistory:[]).slice(0,20).filter(x=>x.scope==='OBSERVATION_ONLY'&&x.engine==='xstocks_agent.decision'&&integer(x.evaluatedAt)!==null&&integer(x.cycle)!==null&&hash(x.blockHash)).map(x=>({cycle:x.cycle,evaluatedAt:x.evaluatedAt,blockHash:x.blockHash,scope:x.scope,results:(Array.isArray(x.results)?x.results:[]).slice(0,5).filter(r=>POLICY.assets.includes(r.market)&&r.status==='BLOCKED'&&r.decision==='NO_TRADE').map(r=>({market:r.market,timeframe:'8_HOUR_EVALUATION_CYCLE',status:'BLOCKED',decision:'NO_TRADE',reason:typeof r.reason==='string'&&/^[A-Z_]{1,100}$/.test(r.reason)?r.reason:'INPUTS_UNAVAILABLE',blockers:(Array.isArray(r.blockers)?r.blockers:[]).slice(0,10).filter(b=>typeof b==='string'&&/^[A-Z_]{1,100}$/.test(b)),confidence:null,entry:null,target:null,invalidation:null}))})):[];
 return {prices,observationHistory:history,latestEvaluation:history[0]||null,blockers:['LIVE_TRADING_NOT_AUTHORIZED','MARKET_SESSION_AND_HALT_NOT_VERIFIED','ROUTES_NOT_PRODUCTION_QUALIFIED'],
 positions:snapshot&&Array.isArray(data.xstocks?.positions)?data.xstocks.positions.slice(0,3).filter(x=>uint(x.id)!==null&&address(x.adapter)&&Number.isSafeInteger(x.state)&&x.state>=0&&x.state<=6).map(x=>({id:x.id,adapter:x.adapter,state:x.state,principalWei:typeof x.principal==='string'?uint(x.principal):Number.isSafeInteger(x.principal)&&x.principal>=0?String(x.principal):null,creditedWei:typeof x.credited==='string'?uint(x.credited):Number.isSafeInteger(x.credited)&&x.credited>=0?String(x.credited):null})):null};
}
export function projectStatus(raw=null){
 const connected=raw!==null&&typeof raw==='object'&&!Array.isArray(raw);
 const data=connected?raw:{};const ledger=data.ledger||{};
 const snapshot=data.publicSnapshot;
 if(snapshot&&(snapshot.chainId!==56||!hash(snapshot.blockHash)))throw Error('Invalid snapshot identity');
 const treasury={vaultBalanceWei:uint(ledger.vaultBalanceWei),receiverPendingWei:uint(ledger.receiverPendingWei),receiverForwardedWei:uint(ledger.receiverForwardedWei),strategyCapitalWei:uint(ledger.strategyCapitalWei??data.strategyCapitalWei),treasuryPrincipalWei:uint(ledger.treasuryPrincipalWei),
 buybackReserveWei:uint(ledger.buybackReserveWei),protocolReserveWei:uint(ledger.protocolReserveWei),holderReserveWei:uint(ledger.holderReserveWei??data.accruedHolderReserveWei),
 accountedWei:uint(ledger.accountedWei),activePrincipalWei:uint(ledger.activePrincipalWei),realizedProfitWei:uint(ledger.realizedProfitWei??data.realizedProfitWei),realizedLossWei:uint(ledger.realizedLossWei??data.realizedLossWei),
 feeSampleWei:uint(data.feeInflowWei),feeCoverage:uint(data.feeInflowWei)!==null?'VERIFIED_RECEIPT_SAMPLE_ONLY':'NOT_AVAILABLE'};
 const contracts={};
 if(snapshot)for(const key of ['kernel','receiver','factory','token','vaultPortal','portal','buybackExecutor','strategyExecutor','settlement']){
  const value=address(data.publicContracts?.[key]);if(value)contracts[key]={address:value,verification:'BACKEND_CODE_PIN_MATCH_NOT_INDEPENDENT_DEPLOYMENT_CLEARANCE'};
 }
 const burns=[];
 for(const receipt of Array.isArray(data.buybackBurnReceipts)?data.buybackBurnReceipts.slice(0,30):[]){
  if(!hash(receipt.transactionHash)||!hash(receipt.blockHash))continue;
  for(const event of Array.isArray(receipt.events)?receipt.events:[]){
   if(!/^0x[0-9a-f]{128}$/i.test(event.data)||!Array.isArray(event.topics)||event.topics.length!==3||!event.topics.every(hash))continue;
   const bnb=BigInt('0x'+event.data.slice(2,66)),token=BigInt('0x'+event.data.slice(66));if(bnb<=0n||token<=0n)continue;
   burns.push({transactionHash:receipt.transactionHash,blockHash:receipt.blockHash,bnbSpentWei:bnb.toString(),compdBurnedBaseUnits:token.toString(),verification:'BACKEND_CONFIRMED_RECEIPT'});
  }
 }
 const jobs=(Array.isArray(data.agentTransactions)?data.agentTransactions:[]).slice(0,20).map(x=>({cycle:integer(x.cycle),state:safeState(x.state),transactionHash:hash(x.txhash)}));
 const phase=['PRE_BONDING','MIGRATING','POST_BONDING_PANCAKE_REPORTED'].includes(data.bonding?.phase)?data.bonding.phase:'NOT_VERIFIED';
 const checkpoint=data.firstCheckpoint;
 const recovery=data.recovery||{};
 const lifecycle=snapshot&&['ACTIVE','PAUSED','SHUTDOWN_PENDING','TERMINATED','EMERGENCY_RECOVERY_LEGACY'].includes(recovery.lifecycle)?recovery.lifecycle:'NOT_VERIFIED';
 const recoveryRows=snapshot&&recovery.historyStatus==='CONFIRMED_RECENT_EVENT_WINDOW'?(Array.isArray(recovery.transactions)?recovery.transactions:[]).slice(0,30).filter(x=>hash(x.transactionHash)&&hash(x.blockHash)&&address(x.source)&&x.destination?.toLowerCase()==='0xfa8706aa97b07cb29096381f9101784ba0d1332b'&&uint(x.amount)!==null&&['NATIVE_FULL_RECOVERY','ACCIDENTAL_ERC20','CUSTODY_RECOVERY','EVIDENCE_RECOVERY'].includes(x.kind)&&x.verification==='CONFIRMED_PINNED_CONTRACT_EVENT').map(x=>({transactionHash:x.transactionHash,source:x.source,destination:'0xFa8706AA97B07cb29096381f9101784bA0d1332b',asset:address(x.asset)||(/^0x0{40}$/i.test(x.asset||'')?x.asset:null),amount:x.amount,kind:x.kind,verification:x.verification})):[];
 return {schemaVersion:1,availability:connected?'BACKEND_OBSERVATION':'NOT_AVAILABLE',observedAt:new Date().toISOString(),policy:POLICY,
 snapshot:snapshot?{blockNumber:typeof snapshot.blockNumber==='string'&&/^0x[0-9a-f]+$/i.test(snapshot.blockNumber)?snapshot.blockNumber:null,blockHash:hash(snapshot.blockHash),blockTimestamp:integer(snapshot.blockTimestamp),scope:'BACKEND_OBSERVATION_NOT_INDEPENDENT_DEPLOYMENT_CLEARANCE'}:null,
 treasury,agent:{status:data.xstocks?.mode==='OBSERVE_ONLY'?'OBSERVE_ONLY':'NOT_ACTIVATED_LIVE_TRADING_NOT_APPROVED',assets:POLICY.assets,cycleSeconds:28800,immediateEvaluation:safeState(data.immediateEvaluation),...agentMarket(data,snapshot),activeRunCount:integer(data.activeRunCount),unrealizedPnl:null,transactions:jobs,
 routes:POLICY.assets.map(symbol=>({symbol,status:'DISABLED_ROUTE_NOT_QUALIFIED'})),
 evaluations:(Array.isArray(data.xstocks?.evaluations)?data.xstocks.evaluations:[]).slice(0,20).filter(x=>integer(x.cycle)!==null&&x.scope==='DRY_RUN'&&['EVALUATED','ASSET_EVALUATED','LAUNCH_OBSERVE_ONLY','SETTLED','SIMULATED','PLANNED'].includes(x.stage)).map(x=>({cycle:x.cycle,stage:x.stage,scope:'DRY_RUN'})),
 risk:{maximumPositions:3,maximumPositionBps:1000,maximumExposureBps:3000,designedLossBps:300,dailyLossBps:500,drawdownBps:1000,latched:snapshot&&typeof data.xstocks?.risk?.latched==='boolean'?data.xstocks.risk.latched:null}},
 flow:{feeSampleWei:treasury.feeSampleWei,bonding:{phase,thresholdBaseUnits:uint(data.bonding?.thresholdBaseUnits),pool:address(data.bonding?.pool),verification:'STATE_OBSERVATION_NOT_ROUTE_APPROVAL'},buybackStatus:'MANUAL_ONLY_TREASURY_EXECUTION_BLOCKED',buybackObservation:{activated:snapshot&&typeof data.buybackObservation?.activated==='boolean'?data.buybackObservation.activated:null,totalBNBSpentWei:snapshot?uint(data.buybackObservation?.totalBNBSpentWei):null,totalCOMPDBurnedBaseUnits:snapshot?uint(data.buybackObservation?.totalCOMPDBurnedBaseUnits):null,qualification:'NOT_VERIFIED_ROUTES_DISPOSAL_AND_GRAPH'},burns,
 holders:{status:'NOT_ACTIVATED_FIRST_15_MINUTE_PAYOUT_UNSUPPORTED',launchTimestamp:integer(data.launchTimestamp),windowEnd:integer(data.firstWindowEnd),countdownSeconds:integer(data.firstDistributionCountdownSeconds),
 checkpoint:checkpoint?{observedAt:integer(checkpoint.observedAt),outcome:safeState(checkpoint.outcome),paidWei:uint(checkpoint.paidWei),meaning:'NON_PAYING_OBSERVER_CHECKPOINT_NOT_PAYOUT_EVIDENCE'}:null,...(data.holderRewards?holderProjection(data.holderRewards):{status:'NOT_ACTIVATED_VERIFIED_LAUNCH_AND_INDEX_REQUIRED',top30:[],payouts:[],allocatedWei:null,paidWei:null,pendingLiabilitiesWei:null})}},
 protocol:{chainId:56,reservedToken:POLICY.reservedToken,tokenStatus:'RESERVED_NOT_INDEPENDENTLY_VERIFIED_DEPLOYED',status:'NOT_ACTIVATED_FULL_UTILITY_NOT_QUALIFIED',launchTransactionHash:hash(data.launchTX),feeTransactionHash:hash(data.feeTX),contracts,
 recovery:{lifecycle,guardian:'0x34c5F07750aC19ff28d73FE039456Aa11e2f8eC1',treasury:'0xFa8706AA97B07cb29096381f9101784bA0d1332b',
 recoverableNativeWei:snapshot&&lifecycle==='TERMINATED'?uint(recovery.recoverableNativeWei):null,protectedHolderWei:snapshot?uint(recovery.protectedHolderWei):null,
 unsettledPrincipalWei:snapshot?uint(recovery.unsettledPrincipalWei):null,transactions:recoveryRows,
 connectedVaults:snapshot?(Array.isArray(recovery.connectedVaults)?recovery.connectedVaults:[]).slice(0,3).filter(x=>['receiver','strategyExecutor','buybackExecutor'].includes(x.name)&&address(x.address)?.toLowerCase()===contracts[x.name]?.address.toLowerCase()).map(x=>({name:x.name,address:x.address,recoverableNativeWei:lifecycle==='TERMINATED'?uint(x.recoverableNativeWei):null})):[],
 historyStatus:snapshot&&recovery.historyStatus==='CONFIRMED_RECENT_EVENT_WINDOW'?'CONFIRMED_RECENT_EVENT_WINDOW':'NOT_AVAILABLE',completeHistory:false}}};
}
export function statusEndpoint(value){
 if(!value)return null;
 const url=new URL(value);
 if(url.protocol!=='http:'||!['127.0.0.1','localhost','[::1]'].includes(url.hostname)||url.username||url.password||url.pathname!=='/status'||url.search||url.hash)throw Error('Status source must be a credential-free loopback /status URL');
 return url.href;
}
export async function fetchStatus(endpoint,fetcher=fetch){
 if(!endpoint)return projectStatus();
 const response=await fetcher(endpoint,{method:'GET',redirect:'error',signal:AbortSignal.timeout(30000)});
 if(!response.ok)throw Error('Observer unavailable');
 let length=0;const chunks=[];
 for await(const chunk of response.body){length+=chunk.length;if(length>1024*1024)throw Error('Status exceeds limit');chunks.push(chunk);}
 return projectStatus(JSON.parse(Buffer.concat(chunks).toString('utf8')));
}

