#!/usr/bin/env python3
"""Real CEF request/results, document lifetime and renderer/host loss tests."""
import argparse, http.server, json, os, signal, socket, struct, subprocess, threading, time
from pathlib import Path

def run(host):
 events=[]; messages=[]; lock=threading.Lock()
 class Handler(http.server.BaseHTTPRequestHandler):
  def log_message(self,*args): pass
  def do_GET(self):
   self.send_response(200);self.send_header('Content-Type','text/html; charset=utf-8')
   if self.path=='/sandbox': self.send_header('Content-Security-Policy','sandbox allow-scripts')
   self.end_headers()
   self.wfile.write(b"""<!doctype html><title>JS IPC fixture</title><script>
   if(typeof chromiumPostMessage==='function') {
    chromiumPostMessage('unknown','must not arrive');
    chromiumPostMessage('player','ready:'+location.pathname);
   }
   fetch('/ready',{method:'POST',body:JSON.stringify({path:location.pathname,bridge:typeof chromiumPostMessage})});
   </script>""")
  def do_POST(self):
   with lock: events.append(json.loads(self.rfile.read(int(self.headers['Content-Length']))))
   self.send_response(204);self.end_headers()
 server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
 denied=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
 for fixture in [server,denied]:threading.Thread(target=fixture.serve_forever,daemon=True).start()
 origin=f'http://127.0.0.1:{server.server_port}'
 sockpath=f'/tmp/cef-js-{os.getpid()}.sock'
 log=open('/tmp/ppplayer-js-host-runtime.log','w')
 proc=subprocess.Popen([host,f'--ipc-socket={sockpath}','--ipc-token=js-test',f'--parent-pid={os.getpid()}'],stdout=log,stderr=log,env={**os.environ,'CEF_INPUT_TEST_USE_MOCK_KEYCHAIN':'1'})
 s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM)
 def wait(pred,desc):
  until=time.monotonic()+20
  while time.monotonic()<until:
   with lock:
    if pred():return
   if proc.poll() is not None:raise AssertionError(f'Host exited {proc.returncode}: {desc}')
   time.sleep(.01)
  raise AssertionError(f'Timeout {desc}; messages={messages[-5:]}')
 request=0
 def send(typ,bid=None,**payload):
  nonlocal request
  request+=1
  if bid is not None: payload['browserId']=bid
  data=json.dumps(dict(protocolVersion=1,type=typ,requestId=request,browserId=str(bid) if bid else None,payload=payload)).encode()
  s.sendall(struct.pack('!I',len(data))+data)
  return request
 def reader():
  buffer=b''
  try:
   while True:
    part=s.recv(65536)
    if not part:return
    buffer+=part
    while len(buffer)>=4:
     n=struct.unpack('!I',buffer[:4])[0]
     if len(buffer)<4+n:break
     msg=json.loads(buffer[4:4+n]);buffer=buffer[4+n:]
     with lock: messages.append(msg)
  except OSError: pass
 def response(rid):
  wait(lambda:any(m['requestId']==rid for m in messages),f'request {rid}')
  return next(m for m in messages if m['requestId']==rid)
 def evaluate(bid,js,timeout=2000):
  rid=send('evaluateJavaScript',bid,js=js,operationId=str(request+1),timeoutMs=timeout)
  return response(rid)['payload']
 def value(bid,js,expected):
  actual=evaluate(bid,js)
  assert actual.get('value')==expected and 'error' not in actual,(js,actual,expected)
 def error(bid,js,code,timeout=2000):
  actual=evaluate(bid,js,timeout)
  assert actual['error']['code']==code,actual
 def pending(count):
  actual=response(send('getJavaScriptDiagnostics'))['payload']['pendingJavaScript']
  assert actual==count,(actual,count)
 def ready(bid,path):
  wait(lambda:any(m['type']=='javascriptMessage' and m['payload']['browserId']==bid and m['payload']['message']=='ready:'+path for m in messages),'bridge ready '+path)
 try:
  wait(lambda:Path(sockpath).exists(),'host starts')
  s.connect(sockpath);threading.Thread(target=reader,daemon=True).start()
  assert 'javascript' in response(send('hello',token='js-test'))['payload']['capabilities']
  for bid in [8101,8102]:
   send('createBrowser',bid,url=f'{origin}/{bid}',width=400,height=300,deviceScaleFactor=2,javascriptChannels=json.dumps({'player':[origin]}))
  for bid in [8101,8102]:ready(bid,'/'+str(bid))
  print('PASS renderer → host → IPC bridge and concurrent browser identity',flush=True)
  for js,expected in [('42',42),('true',True),('null',None),('undefined',None),('"hello 🌍"','hello 🌍'),('[1,"two",null]',[1,'two',None]),('({nested:{a:1},flag:false})',{'nested':{'a':1},'flag':False}),('document.title','JS IPC fixture')]:value(8101,js,expected)
  print('PASS primitive, Unicode, array and object results',flush=True)
  error(8101,'throw new TypeError("fixture boom")','javascript_exception')
  error(8101,'Promise.reject(new RangeError("promise boom"))','javascript_exception')
  error(8101,'const cyclic={};cyclic.self=cyclic;cyclic','serialization_error')
  error(8101,'1n','serialization_error')
  error(8101,'"x".repeat(1048577)','result_too_large')
  print('PASS structured JS exceptions, serialization and result size errors',flush=True)
  requests=[send('evaluateJavaScript',8101,js=f'new Promise(r=>setTimeout(()=>r({n}),{(12-n)*5}))',operationId='parallel'+str(n),timeoutMs=2000) for n in range(12)]
  for n,rid in enumerate(requests):assert response(rid)['payload']['value']==n
  value(8101,'window.counter=0',0)
  ordered=[send('evaluateJavaScript',8101,js='++window.counter',operationId='ordered'+str(n),timeoutMs=2000) for n in range(6)]
  for n,rid in enumerate(ordered):assert response(rid)['payload']['value']==n+1
  value(8102,'typeof window.counter','undefined')
  print('PASS concurrent correlation, ordered starts and browser isolation',flush=True)
  error(8101,'new Promise(()=>{})','timeout',50);pending(0)
  rid=send('evaluateJavaScript',8101,js='new Promise(()=>{})',operationId='cancel-me',timeoutMs=2000)
  value(8101,'1',1);send('cancelJavaScript',8102,operationId='cancel-me');pending(1)
  send('cancelJavaScript',8101,operationId='cancel-me')
  assert response(rid)['payload']['error']['code']=='cancelled';pending(0)
  print('PASS timeout, scoped cancellation and no pending leaks',flush=True)
  rid=send('evaluateJavaScript',8101,js='new Promise(r=>setTimeout(()=>r("old"),500))',operationId='navigate',timeoutMs=2000)
  value(8101,'1',1)
  send('navigate',8101,url=origin+'/new')
  assert response(rid)['payload']['error']['code'] in ['navigation','stale_context']
  ready(8101,'/new');value(8101,'location.pathname','/new');pending(0)
  send('navigate',8101,url=f'http://127.0.0.1:{denied.server_port}/denied')
  wait(lambda:any(e['path']=='/denied' for e in events),'denied origin loaded')
  value(8101,'1',1)
  assert not any(m['type']=='javascriptMessage' and m['payload']['message']=='ready:/denied' for m in messages)
  send('navigate',8101,url=origin+'/sandbox')
  wait(lambda:any(e['path']=='/sandbox' for e in events),'opaque sandbox loaded')
  assert next(e for e in events if e['path']=='/sandbox')['bridge']=='undefined'
  value(8101,'typeof chromiumPostMessage','undefined')
  send('navigate',8101,url=origin+'/after');ready(8101,'/after')
  value(8101,'new Promise(resolve=>{const f=document.createElement("iframe");f.srcdoc=`<script>parent.postMessage(typeof chromiumPostMessage,"*")</script>`;addEventListener("message",e=>resolve(e.data),{once:true});document.body.append(f)})','undefined')
  assert all(m['payload']['channel']=='player' and m['payload']['origin']==origin for m in messages if m['type']=='javascriptMessage')
  print('PASS navigation invalidation, denied origin, opaque sandbox and subframe policy',flush=True)
  rid=send('evaluateJavaScript',8102,js='new Promise(()=>{})',operationId='close',timeoutMs=2000)
  value(8102,'1',1);response(send('closeBrowser',8102))
  assert response(rid)['payload']['error']['code']=='browser_closed';pending(0)
  error(8102,'1','browser_closed')
  print('PASS close rejects pending and stale browser requests',flush=True)
  rid=send('evaluateJavaScript',8101,js='new Promise(()=>{})',operationId='crash',timeoutMs=10000)
  value(8101,'1',1)
  children=subprocess.run(['/usr/bin/pgrep','-P',str(proc.pid)],capture_output=True,text=True).stdout.split()
  renderers=[]
  for child in children:
   command=subprocess.run(['/bin/ps','-p',child,'-o','args='],capture_output=True,text=True).stdout
   if '--type=renderer' in command:renderers.append(int(child))
  assert renderers,'Find only this host renderer children'
  for child in renderers:os.kill(child,signal.SIGKILL)
  assert response(rid)['payload']['error']['code']=='renderer_gone';pending(0)
  error(8101,'1','renderer_gone')
  send('navigate',8101,url=origin+'/recovered');ready(8101,'/recovered');value(8101,'2',2)
  print('PASS renderer death fails pending requests and navigation recovers',flush=True)
  rid=send('evaluateJavaScript',8101,js='new Promise(()=>{})',operationId='host-death',timeoutMs=10000)
  value(8101,'1',1);pending(1)
  proc.kill();proc.wait(timeout=10)
  print('PASS host killed with JS pending; Flutter integration checks caller failure',flush=True)
 finally:
  if proc.poll() is None:proc.kill();proc.wait(timeout=10)
  s.close();server.shutdown();denied.shutdown();log.close();Path(sockpath).unlink(missing_ok=True)

if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--host',required=True);run(p.parse_args().host)
