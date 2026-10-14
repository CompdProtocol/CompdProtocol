"""Pinned read-only recovery balances and bounded confirmed event history. No transaction controls."""
from agent_scheduler import address,hash32

GUARDIAN='0x34c5f07750ac19ff28d73fe039456aa11e2f8ec1'
TREASURY='0xfa8706aa97b07cb29096381f9101784ba0d1332b'
LIFECYCLES={0:'ACTIVE',1:'PAUSED',2:'SHUTDOWN_PENDING',3:'TERMINATED',4:'EMERGENCY_RECOVERY_LEGACY'}
EVENTS={
 'TerminatedFundsRecovered(uint256,uint256,uint256,uint256,uint256,uint256)':('NATIVE_FULL_RECOVERY',1,6),
 'AccidentalERC20Rescued(address,uint256)':('ACCIDENTAL_ERC20',3,0),
 'CustodyRecovered(address,uint256)':('CUSTODY_RECOVERY',2,1),
 'RecoveryReleased(bytes32,uint8,uint256)':('EVIDENCE_RECOVERY',3,1),
}

def recovery_snapshot(observer,block,view,state):
    ledger=state['ledger']; life=state['observedLifecycle']; k=observer.s.c['kernel']
    result=dict(lifecycle=LIFECYCLES.get(life,'NOT_VERIFIED'),guardian=GUARDIAN,treasury=TREASURY,
        recoverableNativeWei=None,protectedHolderWei=ledger['holderReserveWei'],unsettledPrincipalWei=ledger['activePrincipalWei'],
        connectedVaults=[],transactions=[],historyStatus='NOT_AVAILABLE',historyCoverage=None,
        verification='BACKEND_PINNED_READS_NOT_INDEPENDENT_CLEARANCE')
    b=ledger.get('vaultBalanceWei'); aq=int(ledger['accountedWei']); hr=int(ledger['holderReserveWei']); ap=int(ledger['activePrincipalWei'])
    if life==3 and ap==0 and b is not None and int(b)>=aq>=hr:result['recoverableNativeWei']=str(int(b)-hr)
    for name,addr in [('receiver',observer.c['receiver']),('strategyExecutor',observer.s.c['executor']),('buybackExecutor',observer.c['buybackExecutor'])]:
        amount=None
        if life==3 and ap==0:
            try:amount=str(int(observer.s.rpc.call('eth_getBalance',[addr,block]),16))
            except Exception:pass
        result['connectedVaults'].append(dict(name=name,address=addr,recoverableNativeWei=amount))
    try:
        result['transactions'],result['historyCoverage']=confirmed_recovery_events(observer,block)
        result['historyStatus']='CONFIRMED_RECENT_EVENT_WINDOW'
    except Exception:result['historyStatus']='NOT_VERIFIED_RECEIPTS_OR_HISTORY_UNAVAILABLE'
    return result

def confirmed_recovery_events(o,block):
    end=int(block,16)-o.s.c['confirmations']+1; start=max(0,end-127)
    coverage=dict(fromBlock=hex(start),toBlock=hex(max(0,end)),completeHistory=False)
    if end<0:return [],coverage
    known={address(o.s.c['kernel']):o.s.c['kernelCodeHash'],address(o.s.c['executor']):o.s.c['executorCodeHash'],
        address(o.c['receiver']):o.c['receiverCodeHash'],address(o.c['buybackExecutor']):o.c['buybackExecutorCodeHash']}
    topics={o.s.cast.run(['keccak',sig]).lower():details for sig,details in EVENTS.items()}
    logs=o.s.rpc.call('eth_getLogs',[dict(address=list(known),fromBlock=hex(start),toBlock=hex(end),topics=[list(topics)])])
    if not isinstance(logs,list) or len(logs)>100:raise ValueError('Bounded history unavailable')
    records=[]; seen=set()
    for log in logs:
        if log.get('removed'):continue
        emitter=address(log['address']); ts=log['topics']; details=topics.get(ts[0].lower()) if ts else None
        if emitter not in known or details is None:raise ValueError('Unexpected recovery event')
        kind,topic_count,words=details
        if len(ts)!=topic_count or len(log['data'])!=2+64*words:raise ValueError('Malformed recovery event')
        for t in ts:hash32(t) if int(t,16)!=0 else None
        txhash=hash32(log['transactionHash']); receipt=o.s.rpc.call('eth_getTransactionReceipt',[txhash]);tx=o.s.rpc.call('eth_getTransactionByHash',[txhash])
        n=int(log['blockNumber'],16)
        if not start<=n<=end or not receipt or int(receipt['status'],16)!=1 or hash32(receipt['transactionHash'])!=txhash or receipt['blockHash'].lower()!=log['blockHash'].lower() or int(receipt['blockNumber'],16)!=n:raise ValueError('Unconfirmed recovery')
        header=o.s.rpc.call('eth_getBlockByNumber',[hex(n),False])
        if not header or header['hash'].lower()!=receipt['blockHash'].lower():raise ValueError('Reorged recovery')
        if not tx or hash32(tx['hash'])!=txhash or address(tx['from'])!=GUARDIAN or int(tx.get('value','0x0'),16)!=0 or ('chainId' in tx and int(tx['chainId'],16)!=56):raise ValueError('Wrong recovery sender/network')
        code=o.s.rpc.call('eth_getCode',[emitter,hex(n)])
        if code=='0x' or o.s.cast.code_hash(code)!=hash32(known[emitter]):raise ValueError('Historical recovery code mismatch')
        if not any(x.get('logIndex')==log.get('logIndex') and x.get('address','').lower()==emitter and x.get('topics')==ts and x.get('data')==log['data'] and not x.get('removed',False) for x in receipt['logs']):raise ValueError('Event missing from receipt')
        values=[int(log['data'][2+i*64:2+(i+1)*64],16) for i in range(words)]
        asset=None;category=None; target=emitter
        if kind=='NATIVE_FULL_RECOVERY':
            if emitter!=address(o.s.c['kernel']) or values[0]!=sum(values[1:]):raise ValueError('Invalid native conservation')
            amount=values[0];sig='recoverAllTerminatedFunds()';asset='0x'+'0'*40
        elif kind=='ACCIDENTAL_ERC20':
            if emitter!=address(o.s.c['kernel']) or int(ts[1],16)>=2**160:raise ValueError('Wrong rescue emitter/asset')
            asset=address('0x'+ts[1][-40:]);amount=int(ts[2],16);sig='rescueAccidentalERC20(address,uint256)'
        elif kind=='CUSTODY_RECOVERY':
            if emitter==address(o.s.c['kernel']) or int(ts[1],16)>=2**160:raise ValueError('Wrong custody emitter/asset')
            asset='0x'+ts[1][-40:];amount=values[0];sig='recoverTerminatedFunds()' if int(asset,16)==0 else 'rescueAccidentalERC20(address,uint256)'
        else:
            if emitter!=address(o.s.c['kernel']):raise ValueError('Wrong evidence emitter')
            category=int(ts[2],16); methods=['recoverProtocol','recoverNoRecipient','recoverExpiredLiability','recoverTreasuryPrincipal','recoverPartialActivation','recoverActivationSealFailure','recoverShutdownTail']
            if category>6:raise ValueError('Unknown category')
            from agent_lifecycle import ChainView
            v=ChainView(o.s,hex(n));target=address('0x'+f'{v.one(emitter,"moduleAddress(uint8)",(3,)):040x}')
            pinned='0x'+f'{v.one(emitter,"moduleHash(uint8)",(3,)):064x}'
            if o.s.cast.code_hash(o.s.rpc.call('eth_getCode',[target,hex(n)]))!=pinned:raise ValueError('Recovery module pin mismatch')
            amount=values[0];asset='0x'+'0'*40;sig=methods[category]+'(bytes32)'
        selector=o.s.cast.run(['sig',sig]).lower();data=tx.get('input','').lower()
        if address(tx['to'])!=target or not data.startswith(selector) or amount<=0:raise ValueError('Wrong recovery transaction purpose')
        if sig=='rescueAccidentalERC20(address,uint256)' and data!=selector+asset[2:].rjust(64,'0')+f'{amount:064x}':raise ValueError('Rescue input mismatch')
        if sig.endswith('()') and data!=selector:raise ValueError('Unexpected recovery arguments')
        if kind=='EVIDENCE_RECOVERY' and data!=selector+ts[1][2:].lower():raise ValueError('Evidence ID mismatch')
        key=(txhash,log['logIndex'])
        if key in seen:continue
        seen.add(key);records.append(dict(transactionHash=txhash,blockHash=receipt['blockHash'],blockNumber=hex(n),logIndex=log['logIndex'],
            source=emitter,destination=TREASURY,asset=asset,amount=str(amount),kind=kind,category=category,verification='CONFIRMED_PINNED_CONTRACT_EVENT'))
    records.sort(key=lambda x:(int(x['blockNumber'],16),int(x['logIndex'],16)),reverse=True)
    return records[:30],coverage
