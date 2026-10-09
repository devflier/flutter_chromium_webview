#!/usr/bin/env python3
"""Bounded per-context heap/video telemetry; no snapshots retain inspected objects."""
import argparse, asyncio, json, time, urllib.request
from pathlib import Path
from websockets.asyncio.client import connect

VIDEO = r'''(() => Array.from(document.querySelectorAll('video')).map(v => {
if (!v.__cefProfile) {v.__cefProfile={presentedFrames:null,presentedAt:null};
const record=(now,m)=>{v.__cefProfile.presentedFrames=m.presentedFrames;v.__cefProfile.presentedAt=now;v.requestVideoFrameCallback(record)};
if(v.requestVideoFrameCallback)v.requestVideoFrameCallback(record);}
const q=v.getVideoPlaybackQuality ? v.getVideoPlaybackQuality() : null;
return {currentTime:v.currentTime,paused:v.paused,width:v.videoWidth,height:v.videoHeight,
qualityCreatedAt:q?.creationTime,totalFrames:q?.totalVideoFrames??null,droppedFrames:q?.droppedVideoFrames??null,
decodedFrames:v.webkitDecodedFrameCount??null,presentedFrames:v.__cefProfile.presentedFrames,presentedAt:v.__cefProfile.presentedAt,
perfNow:performance.now(),readyState:v.readyState};}))()'''

class CDP:
    def __init__(self, ws):
        self.ws=ws; self.seq=0; self.pending={}; self.contexts={}; self.media={}
    async def receive(self):
        async for raw in self.ws:
            msg=json.loads(raw)
            if 'id' in msg:
                fut=self.pending.pop(msg['id'],None)
                if fut and not fut.done(): fut.set_result(msg)
            else:
                sid=msg.get('sessionId',''); p=msg.get('params',{}); m=msg.get('method')
                if m=='Runtime.executionContextCreated':
                    c=p['context']; self.contexts[(sid,c['id'])]=c
                elif m=='Runtime.executionContextDestroyed': self.contexts.pop((sid,p['executionContextId']),None)
                elif m=='Runtime.executionContextsCleared':
                    self.contexts={k:v for k,v in self.contexts.items() if k[0]!=sid}
                elif m=='Media.playerPropertiesChanged':
                    key=(sid,p['playerId']); self.media.setdefault(key,{})
                    for prop in p['properties']:
                        if any(x in prop['name'].lower() for x in ['codec','decoder','resolution','dimension','frame','memory','buffer','pipeline','video','audio']):
                            value=prop['value']
                            if not '://' in value: self.media[key][prop['name']]=value[:1000]
    async def call(self, method, params=None, sid=None):
        self.seq+=1; n=self.seq; fut=asyncio.get_running_loop().create_future(); self.pending[n]=fut
        data={'id':n,'method':method,'params':params or {}}
        if sid: data['sessionId']=sid
        await self.ws.send(json.dumps(data))
        try:
            msg=await asyncio.wait_for(fut,10)
            if 'error' in msg: raise RuntimeError(str(msg['error']))
            return msg.get('result',{})
        finally: self.pending.pop(n,None)

async def main(args):
    path=Path(args.output); report={'samples':[],'errors':[], 'source':'CDP Runtime / HTMLVideoElement / HeapProfiler', 'heapSamplingIntervalBytes':65536}; start=time.monotonic(); sessions={}; last_profile=-1
    def save(): path.write_text(json.dumps(report,indent=2))
    for _ in range(90):
        try:
            with urllib.request.urlopen(f'http://127.0.0.1:{args.port}/json/version',timeout=2) as response: endpoint=json.load(response)['webSocketDebuggerUrl']
            break
        except Exception: await asyncio.sleep(1)
    else: raise RuntimeError('No diagnostic endpoint')
    async with connect(endpoint,max_size=32*1024*1024) as ws:
        c=CDP(ws); receiver=asyncio.create_task(c.receive())
        try:
            while True:
                targets=(await c.call('Target.getTargets'))['targetInfos']; active={t['targetId'] for t in targets}
                for tid in list(sessions):
                    if tid not in active:
                        sid=sessions.pop(tid); c.contexts={k:v for k,v in c.contexts.items() if k[0]!=sid}
                for t in targets:
                    if t['type'] not in ['page','iframe'] or t['targetId'] in sessions: continue
                    try:
                        sid=(await c.call('Target.attachToTarget',{'targetId':t['targetId'],'flatten':True}))['sessionId']; sessions[t['targetId']]=sid
                        for method, params in [('Runtime.enable',{}),('Performance.enable',{}),('Media.enable',{}),('HeapProfiler.startSampling',{'samplingInterval':65536})]:
                            try: await c.call(method,params,sid)
                            except Exception as e: report['errors'].append({'elapsed':time.monotonic()-start,'method':method,'error':str(e)})
                    except Exception as e: report['errors'].append({'attachError':str(e)})
                sample={'elapsedSeconds':time.monotonic()-start,'contexts':[],'targets':[], 'media':[{'session':k[0],'playerId':k[1],'properties':v} for k,v in c.media.items()]}
                for tid,sid in list(sessions.items()):
                    target={'targetId':tid,'sessionId':sid}
                    for method,key in [('Runtime.getHeapUsage','heap'),('Memory.getDOMCounters','dom'),('Performance.getMetrics','performance')]:
                        try: target[key]=await c.call(method,{},sid)
                        except Exception as e: target[key+'Error']=str(e)
                    sample['targets'].append(target)
                for (sid,ctx), info in list(c.contexts.items()):
                    if not info.get('auxData',{}).get('isDefault'): continue
                    try:
                        value=await c.call('Runtime.evaluate',{'expression':VIDEO,'contextId':ctx,'returnByValue':True},sid)
                        sample['contexts'].append({'session':sid,'contextId':ctx,'origin':info.get('origin'),'videos':value.get('result',{}).get('value',[]),'exception':value.get('exceptionDetails')})
                    except Exception as e: sample['contexts'].append({'contextId':ctx,'error':str(e)})
                report['samples'].append(sample)
                minute=int((time.monotonic()-start)//300)
                if minute>last_profile:
                    last_profile=minute
                    for tid,sid in list(sessions.items()):
                        try:
                            profile=await c.call('HeapProfiler.getSamplingProfile',{},sid)
                            (path.parent/f'{args.prefix}-heap-{minute*5:02d}m-{tid}.json').write_text(json.dumps(profile))
                        except Exception as e: report['errors'].append({'heapError':str(e)})
                # Keep instrumentation status explicit; profiler activity changes memory.
                if len(report['errors'])>100: report['errors']=report['errors'][-100:]
                save()
                if args.harness and Path(args.harness).exists():
                    try:
                        harness=json.loads(Path(args.harness).read_text())
                        if harness.get('finishedUtc'): break
                    except json.JSONDecodeError: pass
                if time.monotonic()-start>args.seconds: break
                await asyncio.sleep(args.interval)
            report['finished']=True; save()
        finally:
            receiver.cancel()
            await asyncio.gather(receiver,return_exceptions=True)

if __name__=='__main__':
    p=argparse.ArgumentParser(); p.add_argument('--port',type=int,default=9229); p.add_argument('--output',required=True);p.add_argument('--prefix',default='youtube');p.add_argument('--seconds',type=int,default=1500);p.add_argument('--interval',type=int,default=30);p.add_argument('--harness');args=p.parse_args();asyncio.run(main(args))
