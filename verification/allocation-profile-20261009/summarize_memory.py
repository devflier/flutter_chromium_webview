#!/usr/bin/env python3
import json,csv
from pathlib import Path
P=Path(__file__).resolve().parent
trace=json.loads((P/'memory-infra.json').read_text())['traceEvents']
requests=json.loads((P/'memory-infra-requests.json').read_text())
pids=sorted({e['pid'] for e in trace if e.get('ph')=='v'})
keys=['malloc','malloc/allocated_objects','malloc/partitions/allocator','partition_alloc','partition_alloc/allocated_objects','partition_alloc/partitions/array_buffer','partition_alloc/partitions/buffer','blink_gc','blink_objects','v8','web_cache','skia','gpu','shared_memory']
rows=[]
for pid in pids:
 dumps=[e for e in trace if e.get('ph')=='v' and e['pid']==pid and 'allocators' in e['args']['dumps']]
 for i,e in enumerate(dumps):
  alloc=e['args']['dumps']['allocators']
  for k in keys:
   for attr in ['size','effective_size']:
    v=alloc.get(k,{}).get('attrs',{}).get(attr,{})
    if v.get('type')=='scalar' and v.get('units')=='bytes':
     rows.append({'pid':pid,'dumpIndex':i,'traceTimestampMicroseconds':e['ts'],'approxHarnessMinute':requests[i]['harnessElapsedSeconds']/60 if i<len(requests) else None,'category':k,'attribute':attr,'MiB':int(v['value'],16)/1048576})
with (P/'allocator-categories.csv').open('w',newline='') as f:
 w=csv.DictWriter(f,fieldnames=list(rows[0]));w.writeheader();w.writerows(rows)
(P/'allocator-categories.json').write_text(json.dumps(rows,indent=2))
print('Exported',len(rows),'category measurements; nested categories overlap and must not be summed.')
