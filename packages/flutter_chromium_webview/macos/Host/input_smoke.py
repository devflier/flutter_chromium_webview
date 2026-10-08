#!/usr/bin/env python3
"""Real CEF input smoke test; page telemetry uses HTTP, no JS bridge IPC."""
import argparse, http.server, json, os, socket, struct, subprocess, threading, time
from pathlib import Path

def run(host):
 events=[]; messages=[]; lock=threading.Lock()
 page='''<!doctype html><style>body{margin:0;height:2000px}button{position:absolute;left:20px;top:20px;width:120px;height:30px}input{position:absolute;left:20px;top:70px;width:200px;height:30px}</style><button id="button">click</button><input id="field"><script>
 const id=location.pathname.slice(1);
 function report(e){fetch('/event',{method:'POST',body:JSON.stringify({id,type:e.type,x:e.clientX,y:e.clientY,button:e.button,detail:e.detail,key:e.key,shift:e.shiftKey,ctrl:e.ctrlKey,alt:e.altKey,meta:e.metaKey,value:field.value,width:innerWidth,dpr:devicePixelRatio,scroll:scrollY})})}
 for(const t of ['mouseover','mouseout','mouseleave','mousedown','mouseup','click','auxclick','contextmenu','wheel','keydown','keyup','input','focus','blur','resize','scroll']) addEventListener(t,e=>{if(t==='contextmenu')e.preventDefault();report(e)},true);
 report({type:'ready'});
 </script>'''
 class Handler(http.server.BaseHTTPRequestHandler):
  def log_message(self,*a): pass
  def do_GET(self):
   self.send_response(200);self.send_header('Content-Type','text/html');self.end_headers();self.wfile.write(page.encode())
  def do_POST(self):
   data=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
   with lock: events.append(data)
   self.send_response(204);self.end_headers()
 server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
 threading.Thread(target=server.serve_forever,daemon=True).start()
 sockpath=f'/tmp/cef-input-{os.getpid()}.sock'
 log=open('/tmp/ppplayer-input-host-runtime.log','w')
 proc=subprocess.Popen([host,f'--ipc-socket={sockpath}','--ipc-token=input-test',f'--parent-pid={os.getpid()}'],stdout=log,stderr=log,env={**os.environ,"CEF_INPUT_TEST_USE_MOCK_KEYCHAIN":"1"})
 s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM)
 def wait(pred,desc):
  until=time.monotonic()+15
  while time.monotonic()<until:
   with lock:
    if pred(): print('PASS',desc,flush=True);return
   if proc.poll() is not None: raise AssertionError(f'Host exited {proc.returncode}: {desc}')
   time.sleep(.02)
  raise AssertionError(f'Timeout {desc}; recent telemetry: {events[-8:]}')
 request=0
 def send(typ,bid=None,**payload):
  nonlocal request
  request+=1
  if bid is not None: payload['browserId']=bid
  data=json.dumps(dict(protocolVersion=1,type=typ,requestId=request,browserId=str(bid) if bid else None,payload=payload)).encode()
  s.sendall(struct.pack('!I',len(data))+data)
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
 def seen(bid,typ,**props):
  return any(e['id']==str(bid) and e['type']==typ and all(e.get(k)==v for k,v in props.items()) for e in events)
 def pointer(typ,bid,x,y,button=1,clicks=1,mods=0,dx=0,dy=0):
  send(typ,bid,x=x,y=y,deviceScaleFactor=2,modifiers=mods,mouseButton=button,clickCount=clicks,scrollDeltaX=dx,scrollDeltaY=dy)
 def click(bid,x,y,button=1,clicks=1):
  pointer('mouseDown',bid,x,y,button,clicks);pointer('mouseUp',bid,x,y,button,clicks)
 try:
  wait(lambda:Path(sockpath).exists(),'host starts')
  s.connect(sockpath);threading.Thread(target=reader,daemon=True).start();send('hello',token='input-test')
  wait(lambda:any(m['type']=='helloAck' for m in messages),'handshake')
  for bid in [7101,7102]:
   send('createBrowser',bid,url=f'http://127.0.0.1:{server.server_port}/{bid}',width=400,height=300,deviceScaleFactor=2)
  for bid in [7101,7102]:
   wait(lambda:seen(bid,'ready'),'page ready '+str(bid))
  send('setFocus',7101,focused=True)
  pointer('mouseMove',7101,30,30)
  wait(lambda:seen(7101,'mouseover',x=30,y=30),'hover in logical coordinates')
  for button,dom in [(1,0),(2,2),(3,1)]:
   click(7101,30,30,button)
   wait(lambda:seen(7101,'mousedown',button=dom),'button '+str(button))
  click(7101,30,30,clicks=2)
  wait(lambda:seen(7101,'click',detail=2),'double click count')
  click(7101,40,85)
  wait(lambda:seen(7101,'focus'),'field receives focus')
  send('keyDown',7101,keyCode=65,scanCode=0,character=65,modifiers=2)
  send('textInput',7101,keyCode=65,scanCode=0,character=65,unmodified_character=97,modifiers=2)
  send('keyUp',7101,keyCode=65,scanCode=0,character=65,modifiers=2)
  wait(lambda:seen(7101,'input',value='A'),'keyboard text')
  wait(lambda:seen(7101,'keydown',shift=True),'shift modifier')
  for bit,prop,key,scan in [(4,'ctrl',66,11),(8,'alt',67,8),(128,'meta',68,2)]:
   send('keyDown',7101,keyCode=key,scanCode=scan,modifiers=bit)
   send('keyUp',7101,keyCode=key,scanCode=scan,modifiers=bit)
   wait(lambda:seen(7101,'keydown',**{prop:True}),prop+' modifier')
  send('setFocus',7101,focused=False);send('setFocus',7102,focused=True)
  click(7102,40,85)
  send('textInput',7102,keyCode=66,scanCode=11,character=66,modifiers=0)
  wait(lambda:seen(7102,'input',value='B'),'second browser input is independent')
  assert not seen(7101,'input',value='AB')
  send('resizeBrowser',7102,width=600,height=400,deviceScaleFactor=1.5)
  wait(lambda:seen(7102,'resize',width=600,dpr=1.5),'resize and DPR')
  pointer('mouseMove',7102,50,85)
  wait(lambda:seen(7102,'mouseover',x=50,y=85),'coordinates after resize')
  pointer('mouseLeave',7102,601,401)
  wait(lambda:seen(7102,'mouseout'),'mouse leave')
  pointer('scroll',7102,250,200,dx=0,dy=-120)
  wait(lambda:any(e['id']=='7102' and e['type']=='scroll' and e['scroll']>0 for e in events),'scrolling')
  send('closeBrowser',7101)
  wait(lambda:any(m['type']=='closeBrowserAck' for m in messages),'close acknowledgement')
  for n in range(50): pointer('mouseMove',7102,n,n)
  proc.kill();proc.wait(timeout=10)
  print('PASS host killed during input; native client disconnect regression covers Flutter socket',flush=True)
 finally:
  if proc.poll() is None: proc.kill();proc.wait(timeout=10)
  s.close();server.shutdown();log.close()
  Path(sockpath).unlink(missing_ok=True)
  Path('/tmp/ppplayer-input-telemetry.json').write_text(json.dumps(events,indent=2))

if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--host',required=True);run(p.parse_args().host)
