#!/usr/bin/env python3
import json,subprocess,time,signal
from pathlib import Path
P=Path(__file__).resolve().parent
records=[]
def read():
 try:return json.loads((P/'youtube.json').read_text())
 except (FileNotFoundError,json.JSONDecodeError):return {}
def save():(P/'youtube-profilers.json').write_text(json.dumps(records,indent=2))
for seconds,template in [(120,'Allocations'),(270,'Leaks'),(1020,'Allocations')]:
 while True:
  r=read();ss=r.get('samples',[])
  if r.get('finishedUtc'):raise SystemExit()
  if ss and ss[-1]['elapsedSeconds']>=seconds:break
  time.sleep(2)
 s=ss[-1];pid=max((p for p in s['processes'] if p['processType']=='renderer'),key=lambda p:p['rssKiB'])['pid'];label=f'youtube-{seconds}s'
 with (P/f'{label}-vmmap.txt').open('w') as f:subprocess.run(['vmmap','-summary',str(pid)],stdout=f,stderr=subprocess.STDOUT,timeout=30)
 rec={'template':template,'pid':pid,'elapsedSeconds':s['elapsedSeconds'],'startUtc':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),'trace':f'{label}-{template.lower()}.trace'};records.append(rec);save()
 with (P/f'{label}-{template.lower()}.log').open('w') as f:
  proc=subprocess.Popen(['xcrun','xctrace','record','--template',template,'--attach',str(pid),'--time-limit','60s' if template=='Allocations' else '30s','--output',str(P/rec['trace']),'--no-prompt'],stdout=f,stderr=subprocess.STDOUT)
  try:proc.wait(timeout=180)
  except subprocess.TimeoutExpired:
   rec['interrupted']=True;proc.send_signal(signal.SIGINT)
   try:proc.wait(timeout=20)
   except subprocess.TimeoutExpired:proc.terminate();proc.wait(timeout=10)
  rec['exitCode']=proc.returncode;save()
