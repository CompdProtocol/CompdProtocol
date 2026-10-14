"""Deterministic transport doubles; no network, signing or private keys."""
import copy,hashlib
from holder_executor import FINALIZER,GUARDIAN
A=lambda n:'0x'+f'{n:040x}'
H=lambda n:'0x'+f'{n:064x}'
def config():
    return dict(chainId=56,productionExecutionEnabled=False,offlineFixture=True,finalizer=FINALIZER,permissionlessSender=A(22),contracts={k:dict(address=A(i),codeHash=H(100)) for i,k in enumerate(('kernel','state','candidate','distributor','holder'),1)},artifacts={k:dict(path='unused-test-artifact',sha256='a'*64) for k in ('kernel','state','candidate','distributor','holder')},maxGas=500000,maxGasPriceWei=10,dailyGasBudgetWei=20_000_000,confirmations=2,maxAttempts=3,retrySeconds=10,pendingTimeoutSeconds=100,maxPaymentRetries=3)
class Encoder:
    def encode(self,key,method,args):return '0x'+hashlib.sha256((key+method+str(args)).encode()).hexdigest()
class CastFixture:
    def code_hash(self,x):return H(100)
class Transport:
    offline_only=True
    def __init__(self):self.head=100;self.now=10000;self.price=2;self.estimate=200000;self.nonces={};self.txs={};self.receipts={};self.blocks={100:dict(number=hex(100),hash=H(100),timestamp=hex(self.now))};self.sent=[];self.raise_send=False;self.raise_read=False;self.chain=56;self.sender_balance=100_000_000;self.mine_status=1;self.changed=False
    def call(self,m,p):
        if self.raise_read:raise RuntimeError('fixture RPC unavailable')
        if m=='eth_chainId':return hex(self.chain)
        if m=='eth_blockNumber':return hex(self.head)
        if m=='eth_getBlockByNumber':return self.blocks.get(self.head if p[0]=='latest' else int(p[0],16))
        if m=='eth_getTransactionReceipt':return copy.deepcopy(self.receipts.get(p[0]))
        if m=='eth_getTransactionByHash':return copy.deepcopy(self.txs.get(p[0]))
        if m=='eth_getTransactionCount':return hex(self.nonces.get(p[0],0))
        if m=='eth_getCode':return '0x6000'
        if m=='eth_getBalance':return hex(1000 if p[0]==A(1) else self.sender_balance)
        if m=='eth_gasPrice':return hex(self.price)
        if m=='eth_estimateGas':return hex(self.estimate)
        if m=='eth_call':return '0x'
        raise AssertionError(m)
    def submit(self,tx):
        self.sent.append(copy.deepcopy(tx))
        if self.raise_send:raise TimeoutError('uncertain fixture send')
        h=H(len(self.sent)+1000);self.txs[h]=dict(tx,hash=h,input=tx['data']);self.head+=1;self.blocks[self.head]=dict(number=hex(self.head),hash=H(self.head),timestamp=hex(self.now));self.receipts[h]=dict(transactionHash=h,from_=tx['from'],to=tx['to'],blockNumber=hex(self.head),blockHash=H(self.head),status=hex(self.mine_status),gasUsed=hex(self.estimate));self.receipts[h]['from']=self.receipts[h].pop('from_');self.nonces[tx['from']]=int(tx['nonce'],16)+1;return h
    def advance(self):self.head+=1;self.blocks[self.head]=dict(number=hex(self.head),hash=H(self.head),timestamp=hex(self.now))
class View:
    def __init__(self,transport):self.r=transport;self.life=0;self.paid=False;self.terminal=False;self.expires=614800;self.status=1;self.payable=True;self.reserve=100;self.outstanding=100;self.complete=True;self.review=10000;self.finalized=False;self.bad_bind=False;self.bad_grace=False;self.bad_failure=False
    def one(self,to,sig,args=()):
        values={'GUARDIAN()':int(GUARDIAN,16),'holderState()':2,'candidateModule()':3,'distributor()':4,'finalizer()':int(FINALIZER,16),'moduleAddress(uint8)':5,'TERMINAL_GRACE()':604799 if self.bad_grace else 604800,'holderRewardReserve()':self.reserve,'accountedQuote()':1000,'outstandingHolderLiability()':self.outstanding,'lifecycle()':self.life,'holderPaid(bytes32)':int(self.paid),'hasFailure(bytes32)':1}
        if self.bad_bind and sig=='finalizer()':return 0
        return values[sig]
    def words(self,to,sig,args=(),count=1):
        if sig=='candidate(bytes32,uint32)':return [1,2,0,0,0,100,100,1,0,0,1,1,self.review-1800,self.review,0,int(self.finalized),1 if self.complete else 0,100]
        if sig=='failedHolder(bytes32)':return [99,10,101 if self.bad_failure else 100,55]
        if sig=='canonicalPayment(bytes32)':return [99,10,0,100,self.status,int(self.payable)]
        if sig=='paymentData(bytes32)':return [0,0,1,0,0,0,55,10,0,100,1,1,0,0,0,77,1]
        if sig=='terminalStatus(bytes32)':return [int(self.terminal),self.expires-604800,self.expires,77]
        raise AssertionError(sig)
