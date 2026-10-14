import unittest,threading,json,urllib.request,urllib.error
from manual_buyback import Service,create_server,OWNER
from test_manual_buyback import FakeRPC,FakeCast
class HTTPTests(unittest.TestCase):
 def setUp(self):
  self.ready=threading.Event();self.origin='http://127.0.0.1:4173'
  def run():
   service=Service(':memory:',{'origin':self.origin},FakeRPC(),FakeCast(),lambda a,m,s:s=='FIXTURE_SIG');self.server=create_server(service,0);self.ready.set();self.server.serve_forever();self.server.server_close();service.db.close()
  self.thread=threading.Thread(target=run);self.thread.start();self.ready.wait(5);self.base='http://127.0.0.1:'+str(self.server.server_port)
 def tearDown(self):self.server.shutdown();self.thread.join(5)
 def request(self,path,body=None,cookie=None,origin=None):
  headers={'Origin':origin or self.origin,'Content-Type':'application/json'}
  if cookie:headers['Cookie']=cookie
  request=urllib.request.Request(self.base+path,data=None if body is None else json.dumps(body).encode(),headers=headers)
  try:
   with urllib.request.urlopen(request,timeout=10) as response:return response.status,json.load(response),response.headers
  except urllib.error.HTTPError as ex:return ex.code,None,ex.headers
 def test_private_api_auth_nonce_and_cookie_scope(self):
  self.assertEqual(self.request('/records')[0],401);code,challenge,_=self.request('/auth/challenge',{'address':OWNER});self.assertEqual(code,200)
  code,data,headers=self.request('/auth/login',{'nonce':challenge['nonce'],'signature':'FIXTURE_SIG'});self.assertEqual(code,200);cookie=headers['Set-Cookie'];self.assertIn('HttpOnly; SameSite=Strict; Path=/api/manual',cookie)
  self.assertEqual(self.request('/records',cookie=cookie)[0],200);self.assertEqual(self.request('/auth/login',{'nonce':challenge['nonce'],'signature':'FIXTURE_SIG'})[0],401)
  self.request('/auth/logout',{},cookie);self.assertEqual(self.request('/records',cookie=cookie)[0],401)
 def test_origin_and_wallet_guard(self):
  self.assertEqual(self.request('/public',origin='https://evil.example')[0],403);self.assertEqual(self.request('/auth/challenge',{'address':'0x'+'1'*40})[0],401)
 def test_amount_injection_and_unknown_execution_rejected(self):
  self.assertEqual(self.request('/records',{'kind':'BUYBACK','transactionHash':'0x'+'1'*64,'amount':'100'})[0],400);self.assertEqual(self.request('/execute',{})[0],404)
if __name__=='__main__':unittest.main()

