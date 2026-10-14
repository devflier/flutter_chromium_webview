"""Summarize separately identified isolation experiments; no release verdict."""
import json
from pathlib import Path
import sys

root = Path(sys.argv[1])
rows = []
for p in sorted(root.glob('[0-9][0-9]-*.json')):
    data = json.loads(p.read_text())
    metrics = json.loads((root / (p.stem + '-summary') / 'metrics.json').read_text())
    windows = metrics['windows']
    valid = [w for w in windows if w['chromiumSubmittedFps'] is not None]
    seconds = sum(w['seconds'] for w in valid)
    fps = sum(w['seconds'] * w['chromiumSubmittedFps'] for w in valid) / seconds if seconds else None
    native = data['samples']
    dt = native[-1]['elapsedSeconds'] - native[0]['elapsedSeconds']
    a, b = native[0]['rendering'], native[-1]['rendering']
    consumption = b.get('clientTexture', {})
    previous = a.get('clientTexture', {})
    rows.append({'run': p.stem, 'nativeAssertions': 'PASS' if data['passed'] else 'FAIL',
        'diagnostic': metrics['diagnosticVerdict'], 'seconds': data.get('actualSeconds'),
        'chromiumCompositorFps': fps, 'mediaDropFraction': metrics['matchedDropFraction'],
        'acceleratedCallbackRate': (b['acceleratedCallbacks'] - a['acceleratedCallbacks']) / dt,
        'metalCompletionRate': (b['completedMetalFrames'] - a['completedMetalFrames']) / dt,
        'surfaceSelectionRate': (consumption.get('surfaceSelections', 0) - previous.get('surfaceSelections', 0)) / dt if data.get('performanceDiagnostics') else None,
        'textureReadCallRate': (consumption.get('textureReadCalls', 0) - previous.get('textureReadCalls', 0)) / dt if data.get('performanceDiagnostics') else None,
        'nativeCallbackIntervalMs': metrics['nativeCallbackIntervalMs'], 'nativeBlitMs': metrics['nativeBlitMs'],
        'rssGrowthKiB': data.get('rssGrowthKiB'), 'experimentOnly': data.get('experimentOnly'),
        'flutterRasterMs': metrics['flutterRasterMs']})
(root / 'comparison.json').write_text(json.dumps({'runs': rows, 'performanceAcceptance': 'INCONCLUSIVE: no approved numerical criteria',
    'releaseMemoryAcceptance': 'NOT RUN: short/isolation runs cannot substitute',
    'instrumentationOverhead': 'Matched reverse ordering; descriptive comparisons only, no correction factor or significance threshold'}, indent=2) + '\n')
lines = ['# Pipeline isolation comparison', '', '| Run | Compositor FPS | CEF callback/s | Metal copy/s | Texture read calls/s | Media drop fraction |', '|---|---:|---:|---:|---:|---:|']
for row in rows:
    lines.append('| ' + row['run'] + ' | ' + ' | '.join(str(row[k]) for k in ['chromiumCompositorFps','acceleratedCallbackRate','metalCompletionRate','textureReadCallRate','mediaDropFraction']) + ' |')
lines += ['', 'Diagnostic only. Texture read calls are not unique displayed video frames. Counter rates use matched intervals within each process; no cross-clock latency. No unapproved performance threshold or memory-acceptance verdict is selected.']
(root / 'comparison.md').write_text('\n'.join(lines) + '\n')
