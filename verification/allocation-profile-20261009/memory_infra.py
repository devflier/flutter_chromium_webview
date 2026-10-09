#!/usr/bin/env python3
import asyncio,json,time,urllib.request
from pathlib import Path
from websockets.asyncio.client import connect
P=Path(__file__).resolve().parent
async def main():
 with urllib.request.urlopen('http://127.0.0.1:9229/json/version') as f:url=json.load(f)['webSocketDebuggerUrl']
 pending={};seq=0;done=asyncio.Event();records=[];events=[]
 async with connect(url,max_size=64*1024*1024) as ws:
  async def receive():
   async for raw in ws:
    m=json.loads(raw)
    if 'id' in m:
     f=pending.pop(m['id'],None)
     if f and not f.done():f.set_result(m)
    elif m.get('method')=='Tracing.dataCollected':events.extend(m['params']['value'])
    elif m.get('method')=='Tracing.tracingComplete':done.set()
  reader=asyncio.create_task(receive())
  async def call(method,params=None):
   nonlocal seq
   seq+=1;f=asyncio.get_running_loop().create_future();pending[seq]=f
   await ws.send(json.dumps({'id':seq,'method':method,'params':params or {}}));m=await asyncio.wait_for(f,45)
   if 'error' in m:raise RuntimeError(m['error'])
   return m.get('result',{})
  await call('Tracing.start',{'categories':'-*,disabled-by-default-memory-infra','options':'record-continuously'})
  try:
   for target in [0,900,1140,1210]:
    while True:
     try:r=json.loads((P/'youtube.json').read_text())
     except json.JSONDecodeError:await asyncio.sleep(1);continue
     s=r['samples'][-1];elapsed=s['elapsedSeconds']
     if target==0 or elapsed>=target or (target>=1200 and r.get('completedMeasurement')):break
     await asyncio.sleep(2)
    record={'harnessElapsedSeconds':elapsed,'requestedCheckpoint':target,'timestampUtc':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime())}
    try:record['dump']=await call('Tracing.requestMemoryDump',{'levelOfDetail':'detailed','deterministic':False})
    except Exception as e:record['error']=str(e)
    records.append(record);(P/'memory-infra-requests.json').write_text(json.dumps(records,indent=2))
   await call('Tracing.end');await asyncio.wait_for(done.wait(),30)
  finally:
   (P/'memory-infra.json').write_text(json.dumps({'traceEvents':events}));reader.cancel();await asyncio.gather(reader,return_exceptions=True)
asyncio.run(main())
