#!/usr/bin/env python3
import csv,json,collections,re
from pathlib import Path
OUT=Path(__file__).resolve().parent

def fit(points):
 if len(points)<3:return None
 xs,ys=zip(*points);mx=sum(xs)/len(xs);my=sum(ys)/len(ys);xx=sum((x-mx)**2 for x in xs)
 if not xx:return None
 slope=sum((x-mx)*(y-my) for x,y in points)/xx
 return {'samples':len(points),'slopeMiBPerMinute':slope,'firstMiB':ys[0],'lastMiB':ys[-1],'minMiB':min(ys),'maxMiB':max(ys)}

def main():
 summaries={};flat=[];video_rows=[];heap_rows=[]
 for label in ['youtube','static','animated','youtube-native']:
  p=OUT/(label+'.json')
  if not p.exists():continue
  r=json.loads(p.read_text());samples=r['samples']
  if not samples:continue
  series=collections.defaultdict(list)
  for s in samples:
   for process in s['processes']:
    series[process['pid']].append((s['elapsedSeconds']/60,process['rssKiB']/1024,process['processType']))
    flat.append({'workload':label,'minute':s['elapsedSeconds']/60,'pid':process['pid'],'type':process['processType'],'rssMiB':process['rssKiB']/1024,'cpuPercent':process['cpuPercent']})
  last=samples[-1];disposed=r.get('disposalSamples',[]);idle=r.get('idleProcesses',[])
  ending=disposed[-1]['processes'] if disposed else []
  renderers={p['pid'] for p in last['processes'] if p['processType']=='renderer'}
  summary={'passedLiveGates':r['passed'],'failure':r.get('failure'),'minutes':last['elapsedSeconds']/60,'returnedToIdleBaseline':r.get('returnedToIdleBaseline'),
    'finalMetal':last['rendering']['completedMetalFrames'],'failedMetal':last['rendering']['failedMetalFrames'],'softwareFrames':last['rendering']['softwareFrames'],
    'processCountRange':[min(len(s['processes']) for s in samples),max(len(s['processes']) for s in samples)],
    'individualProcesses':{str(pid):{'type':ps[0][2],'after5Minutes':fit([(x,y) for x,y,_ in ps if x>=5]),'firstMiB':ps[0][1],'lastMiB':ps[-1][1]} for pid,ps in series.items()},
    'idleAggregateMiB':sum(p['rssKiB'] for p in idle)/1024,'beforeDisposalAggregateMiB':sum(p['rssKiB'] for p in last['processes'])/1024,
    'afterDisposalAggregateMiB':sum(p['rssKiB'] for p in ending)/1024 if disposed else None,
    'beforeDisposalWithoutTracingServiceMiB':sum(p['rssKiB'] for p in last['processes'] if '--utility-sub-type=tracing.mojom.TracingService' not in p['command'])/1024,
    'afterDisposalWithoutTracingServiceMiB':sum(p['rssKiB'] for p in ending if '--utility-sub-type=tracing.mojom.TracingService' not in p['command'])/1024 if disposed else None,
    'disposalSeconds':disposed[-1]['elapsedSeconds'] if disposed else None,
    'remainingRendererPids':sorted(renderers.intersection(p['pid'] for p in ending)) if disposed else None,
    'finalDisposedProcesses':[{'pid':p['pid'],'type':p['processType'],'utilitySubtype':re.search(r'--utility-sub-type=(\S+)',p['command']).group(1) if '--utility-sub-type=' in p['command'] else None,'rssMiB':p['rssKiB']/1024} for p in ending]}
  first_exits={}
  for pid in renderers:
   first_exits[str(pid)]=next((s['elapsedSeconds'] for s in disposed if pid not in [p['pid'] for p in s['processes']]),None)
  summary['rendererFirstAbsentSeconds']=first_exits
  cdp=OUT/(label+'-cdp.json')
  if cdp.exists():
   c=json.loads(cdp.read_text());previous={};deltas=[]
   for s in c['samples']:
    for target in s['targets']:
     if 'heap' in target:heap_rows.append({'workload':label,'minute':s['elapsedSeconds']/60,'target':target['targetId'],**target['heap'],**target.get('dom',{})})
    for ctx in s['contexts']:
     for i,v in enumerate(ctx.get('videos',[])):
      key=(ctx['session'],ctx['contextId'],i);old=previous.get(key);row={'workload':label,'minute':s['elapsedSeconds']/60,'session':ctx['session'],**v,'intervalDropRate':None,'presentedFps':None}
      if old:
       total=v['totalFrames']-old['totalFrames'];dropped=v['droppedFrames']-old['droppedFrames'];dt=(v['perfNow']-old['perfNow'])/1000
       if total>0 and dropped>=0:
        row['intervalDropRate']=dropped/total;deltas.append((total,dropped))
       if dt>0 and v['presentedFrames'] is not None and old['presentedFrames'] is not None and v['presentedFrames']>=old['presentedFrames']:
        row['presentedFps']=(v['presentedFrames']-old['presentedFrames'])/dt
      previous[key]=v;video_rows.append(row)
   summary['videoTelemetry']={'intervals':len(deltas),'framesAcrossNonResetIntervals':sum(n for n,d in deltas),'dropsAcrossNonResetIntervals':sum(d for n,d in deltas),'maxIntervalDropRate':max((d/n for n,d in deltas),default=None),'errors':c['errors']}
  summaries[label]=summary
 for name,rows in [('per-process.csv',flat),('video-quality.csv',video_rows),('heap-dom.csv',heap_rows)]:
  if rows:
   keys=list(dict.fromkeys(k for row in rows for k in row))
   with (OUT/name).open('w',newline='') as f:
    w=csv.DictWriter(f,fieldnames=keys);w.writeheader();w.writerows(rows)
 (OUT/'summary.json').write_text(json.dumps(summaries,indent=2))
 try:
  import matplotlib;matplotlib.use('Agg')
  import matplotlib.pyplot as plt
  fig,axes=plt.subplots(len(summaries),1,figsize=(11,4*len(summaries)),squeeze=False,constrained_layout=True)
  for ax,(label,summary) in zip(axes[:,0],summaries.items()):
   for pid,info in summary['individualProcesses'].items():
    if info['type']!='renderer':continue
    rows=[r for r in flat if r['workload']==label and str(r['pid'])==pid]
    ax.plot([r['minute'] for r in rows],[r['rssMiB'] for r in rows],label=f'Renderer {pid}')
   ax.set_title(label);ax.set_ylabel('RSS (MiB)');ax.set_xlabel('Minutes');ax.grid(alpha=.2);ax.legend()
  fig.suptitle('Profiled workload comparison — renderer RSS\nProfiler windows affect residency; RSS is not live heap size')
  fig.savefig(OUT/'renderer-trends.png',dpi=150);plt.close(fig)
 except ImportError:pass
 print(json.dumps(summaries,indent=2))
if __name__=='__main__':main()
