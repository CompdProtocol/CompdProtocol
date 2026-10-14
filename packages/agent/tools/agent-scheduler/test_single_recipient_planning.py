import unittest
import test_holder_rewards as f
from holder_keeper import HolderKeeper
class SingleRecipientPlanning(unittest.TestCase):
 def setUp(self):
  self.fixture=f.HolderTests(methodName='runTest');self.fixture.setUp();self.fixture.close();self.index=self.fixture.x;self.leaves=[f.H(i+1) for i in range(30)];self.recipients=[f'0x{0x100+i:040x}' for i in range(30)]
  self.index.epoch=lambda *_:dict(poolWei='30',top30=[dict(address=a,amountWei='1') for a in self.recipients],indexedThroughHash=f.H(11))
  outer=self
  class View(f.ViewFixture):
   def __init__(self):super().__init__(30);self.paid_indices=set()
   def one(self,target,sig,args=()):
    if sig=='holderPaid(bytes32)':return int(args[0]-100 in self.paid_indices)
    return super().one(target,sig,args)
   def words(self,target,sig,args,count):
    if sig=='deriveWindow(uint64)':return [7,8,1900,30-len(self.paid_indices),1]
    if sig=='canonicalPayment(bytes32)':
     i=args[0]-1;return [5,int(outer.recipients[i],16),0,1,1,i not in self.paid_indices]
    if sig=='paymentData(bytes32)':
     i=args[0]-1;return [7,8,1,0,1,1,args[0],int(outer.recipients[i],16),0,1,1,1,1,0,0,100+i,i not in self.paid_indices]
    return super().words(target,sig,args,count)
  self.view=View();self.keeper=HolderKeeper(self.index)
 def tearDown(self):self.fixture.tearDown()
 def test_top30_each_has_an_independent_fixed_recipient_job(self):
  actions=self.keeper.plan(self.view,1000,1900,self.leaves)['actions'];self.assertEqual(len(actions),30);self.assertEqual([a['leaves'] for a in actions],[[l] for l in self.leaves]);self.assertTrue(all(a['to']==f.M and a['value']=='0' for a in actions))
 def test_restart_partial_payments_only_plan_unpaid_recipients(self):
  self.view.paid_indices=set(range(15));actions=HolderKeeper(self.index).plan(self.view,1000,1900,self.leaves)['actions'];self.assertEqual(len(actions),15);self.assertEqual([a['leaves'] for a in actions],[[l] for l in self.leaves[15:]])
 def test_incomplete_entitlement_set_still_rejected(self):
  with self.assertRaises(ValueError):self.keeper.plan(self.view,1000,1900,self.leaves[:-1])
if __name__=='__main__':unittest.main()
