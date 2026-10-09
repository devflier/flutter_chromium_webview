#!/usr/bin/env python3
"""Sequential control runs; profiling only attaches to the selected run's renderer."""
import json, os, signal, subprocess, sys, time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
OUT=Path(__file__).resolve().parent
EXAMPLE=ROOT/'packages/flutter_chromium_webview/example'
PYTHON=Path('/tmp/chromium-soak-plots/bin/python')
runs={'runs':[]}; native=[]
def save():
 (OUT/'runs.json').write_text(json.dumps(runs,indent=2))
def read(path):
 try:return json.loads(path.read_text())
 except (FileNotFoundError,json.JSONDecodeError):return {}
def recorder(template,pid,label,seconds):
 trace=OUT/f'{label}-{template.lower()}.trace'
 log=OUT/f'{label}-{template.lower()}.log'
 stream=log.open('w')
 process=subprocess.Popen(['xcrun','xctrace','record','--template',template,'--attach',str(pid),'--time-limit',f'{seconds}s','--output',str(trace),'--no-prompt'],stdout=stream,stderr=subprocess.STDOUT)
 record={'template':template,'pid':pid,'startedUtc':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),'trace':trace.name,'log':log.name,'requestedSeconds':seconds}
 native.append((process,stream,time.monotonic(),record));return record
def poll_native():
 for item in list(native):
  process,stream,started,record=item
  if process.poll() is None and time.monotonic()-started>180:
   process.send_signal(signal.SIGINT);record['interruptedAfterSeconds']=time.monotonic()-started
   try:process.wait(timeout=15)
   except subprocess.TimeoutExpired:process.terminate()
  if process.poll() is not None:
   record['exitCode']=process.returncode;stream.close();native.remove(item);save()

# Preserve the current uninterrupted 20-minute growth/disposal measurement.
while not read(OUT/'youtube.json').get('finishedUtc'): time.sleep(2)
for workload,label in [('static','static'),('animated','animated')]:
 report=OUT/(label+'.json'); log=OUT/(label+'-flutter.log');env=os.environ.copy();env.update(CEF_INPUT_TEST_USE_MOCK_KEYCHAIN='1',CEF_PROFILE_DEBUG_PORT='9229')
 run={'workload':workload,'label':label,'startedUtc':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),'profilers':[],'vmmap':[]};runs['runs'].append(run);save()
 command=['flutter','test','integration_test/allocation_profile_test.dart','-d','macos','--dart-define=ALLOCATION_PROFILE=true','--dart-define=SOAK_SECONDS=600','--dart-define=SOAK_INTERACTION_SECONDS=60',f'--dart-define=PROFILE_WORKLOAD={workload}',f'--dart-define=SOAK_REPORT={report}']
 with log.open('w') as stream:
  process=subprocess.Popen(command,cwd=EXAMPLE,env=env,stdout=stream,stderr=subprocess.STDOUT)
  cdp=None; chosen=None; captured=set(); leaks_done=False; alloc_done=False
  while process.poll() is None:
   r=read(report); samples=r.get('samples',[])
   if samples:
    s=samples[-1];elapsed=s['elapsedSeconds']
    if cdp is None:
     cdpstream=(OUT/(label+'-cdp.log')).open('w')
     cdp=subprocess.Popen([str(PYTHON),str(OUT/'cdp_profile.py'),'--prefix',label,'--output',str(OUT/(label+'-cdp.json')),'--harness',str(report),'--seconds','900'],stdout=cdpstream,stderr=subprocess.STDOUT)
    renderers=[p for p in s['processes'] if p['processType']=='renderer']
    if elapsed>=120 and renderers and chosen is None:
     chosen=max(renderers,key=lambda p:p['rssKiB'])['pid'];run['profiledRendererPid']=chosen
    if chosen and elapsed>=120 and not alloc_done:
     run['profilers'].append(recorder('Allocations',chosen,label,60));alloc_done=True;save()
    if chosen and elapsed>=240 and not leaks_done and not native:
     run['profilers'].append(recorder('Leaks',chosen,label,30));leaks_done=True;save()
    for checkpoint in [120,300,550]:
     if chosen and elapsed>=checkpoint and checkpoint not in captured:
      captured.add(checkpoint);name=f'{label}-vmmap-{checkpoint}s.txt'
      with (OUT/name).open('w') as f:
       result=subprocess.run(['vmmap','-summary',str(chosen)],stdout=f,stderr=subprocess.STDOUT,timeout=30)
      run['vmmap'].append({'elapsedSeconds':elapsed,'pid':chosen,'file':name,'exitCode':result.returncode});save()
   poll_native();time.sleep(2)
  run['flutterExitCode']=process.returncode;run['completedUtc']=time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime());save()
  if cdp:
   try:cdp.wait(timeout=45)
   except subprocess.TimeoutExpired:cdp.terminate()
   cdpstream.close()
  for _ in range(100):
   poll_native()
   if not native:break
   time.sleep(1)
  if process.returncode:raise RuntimeError(f'{label} failed; see {log}')
runs['complete']=True;save()
