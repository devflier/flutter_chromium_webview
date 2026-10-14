"""Keep Chromium, Metal and Flutter counters distinct; no unapproved performance gate."""
import argparse
import json
import math
from pathlib import Path


def stats(values):
    values = sorted(v for v in values if isinstance(v, (float, int)) and math.isfinite(v))
    if not values:
        return None
    return {'count': len(values), 'average': sum(values) / len(values),
            'p95': values[math.ceil(.95 * len(values)) - 1],
            'p99': values[math.ceil(.99 * len(values)) - 1], 'maximum': values[-1]}


def analyze(data):
    samples = data.get('samples', [])
    windows = []
    errors = []
    for a, b in zip(samples, samples[1:]):
        seconds = b['elapsedSeconds'] - a['elapsedSeconds']
        if seconds <= 0:
            errors.append('Nonpositive sample interval')
            continue
        first = {(q['targetId'], q.get('contextId'), q['videoIndex']): q for q in a['rendering'].get('videoQuality', [])}
        for q in b['rendering'].get('videoQuality', []):
            key = (q['targetId'], q.get('contextId'), q['videoIndex'])
            old = first.get(key)
            if old is None:
                continue
            total = q['totalVideoFrames'] - old['totalVideoFrames']
            drops = q['droppedVideoFrames'] - old['droppedVideoFrames']
            presented = None
            if isinstance(q.get('presentedFrames'), int) and isinstance(old.get('presentedFrames'), int):
                presented = q['presentedFrames'] - old['presentedFrames']
            if total < 0 or drops < 0 or drops > total or (presented is not None and presented < 0):
                errors.append('Counter reset/incompatible interval: ' + str(key))
                continue
            windows.append({'identity': key, 'seconds': seconds, 'videoTotalDelta': total,
                'videoDroppedDelta': drops, 'videoDropFraction': drops / total if total else None,
                'chromiumSubmittedFps': presented / seconds if presented is not None else None,
                'metalCompletionFps': (b['rendering']['completedMetalFrames'] - a['rendering']['completedMetalFrames']) / seconds,
                'decodedDelta': q.get('decodedFrames', 0) - old.get('decodedFrames', 0) if isinstance(q.get('decodedFrames'), int) and isinstance(old.get('decodedFrames'), int) else None})
    callback_frames = [f for s in samples for f in (s.get('localMedia') or {}).get('timingFrames', [])]
    flutter = [f for s in samples for f in s.get('flutterTimings', [])]
    native = [f for s in samples for f in s.get('rendering', {}).get('pipelineFrames', [])]
    native_intervals = [b['callbackMs'] - a['callbackMs'] for a, b in zip(native, native[1:]) if b['callbackMs'] >= a['callbackMs']]
    callback_intervals = [b['callbackTime'] - a['callbackTime'] for a, b in zip(callback_frames, callback_frames[1:]) if b['callbackTime'] >= a['callbackTime']]
    callback_ids = [b['presentedFrames'] - a['presentedFrames'] for a, b in zip(callback_frames, callback_frames[1:])]
    if any(delta < 0 for delta in callback_ids):
        errors.append('Callback compositor counter reset; timing identity not continuous')
    flutter_intervals = [(b['vsyncMicros'] - a['vsyncMicros']) / 1000 for a, b in zip(flutter, flutter[1:]) if b['vsyncMicros'] >= a['vsyncMicros']]
    missing = []
    if not windows:
        missing.append('No compatible counter intervals')
    if not callback_frames:
        missing.append('No per-frame Chromium callback timing')
    if not flutter and data.get('pipelineMode', 'full') == 'full':
        missing.append('No Flutter frame timing')
    if data.get('performanceDiagnostics') and not native:
        missing.append('No native callback timing')
    if any(s.get('rendering', {}).get('pipelineOverflow', 0) for s in samples):
        missing.append('Native callback buffer overflow')
    overflow = max([(s.get('localMedia') or {}).get('timingOverflow', 0) for s in samples] or [0])
    if overflow:
        missing.append('Bounded callback log overflow: ' + str(overflow))
    total = sum(w['videoTotalDelta'] for w in windows)
    drops = sum(w['videoDroppedDelta'] for w in windows)
    return {'diagnosticVerdict': 'FAIL' if errors else ('INCONCLUSIVE' if missing else 'PASS'),
        'performanceAcceptance': 'INCONCLUSIVE: product requirements and numeric gates pending approval',
        'counterErrors': errors, 'missingEvidence': missing, 'windows': windows,
        'matchedDropFraction': drops / total if total else None, 'matchedTotalDelta': total, 'matchedDroppedDelta': drops,
        'callbackRepeatedCompositorIds': sum(delta == 0 for delta in callback_ids),
        'compositorFramesWithoutObservedCallback': sum(max(0, delta - 1) for delta in callback_ids),
        'callbackGapMeaning': 'Missing callbacks are not necessarily dropped media frames; compositor IDs and video drop counts are separate',
        'chromiumCallbackIntervalMs': stats(callback_intervals),
        'chromiumCallbackDelayAfterSubmissionMs': stats([f['callbackTime'] - f['presentationTime'] for f in callback_frames]),
        'chromiumExpectedDisplayMinusCallbackMs': stats([f['expectedDisplayTime'] - f['callbackTime'] for f in callback_frames]),
        'decodeProcessingMs': stats([f['processingDuration'] * 1000 for f in callback_frames if isinstance(f.get('processingDuration'), (int, float))]),
        'flutterVsyncIntervalMs': stats(flutter_intervals),
        'flutterBuildMs': stats([f['buildMicros'] / 1000 for f in flutter]),
        'flutterRasterMs': stats([f['rasterMicros'] / 1000 for f in flutter]),
        'flutterTotalSpanMs': stats([f['totalSpanMicros'] / 1000 for f in flutter]),
        'nativeCallbackIntervalMs': stats(native_intervals),
        'nativeBlitMs': stats([f['blitMs'] for f in native]) if data.get('pipelineMode') != 'cef-only' else None,
        'pipelineMode': data.get('pipelineMode', 'full'),
        'experimentOnly': data.get('experimentOnly', False),
        'cpuAndRss': [{'elapsedSeconds': s['elapsedSeconds'], 'processes': s.get('processes', [])} for s in samples],
        'unmeasured': ['Actual display presentation and scanout', 'Correlated per-video-frame IOSurface/Metal/Flutter identity',
                      'End-to-end latency', 'Separately classified predecode vs compositor drops', 'Audio/video synchronization (silent fixture)'],
        'definitions': {'presentedFrames': 'requestVideoFrameCallback: frames submitted for Chromium composition; not Flutter display presentation',
                        'metal': 'Completed GPU blit; not one-to-one video frame or scanout',
                        'flutter': 'Engine frame timings; not video-frame-specific; not display scanout',
                        'dropFraction': 'Matched video element/context interval droppedVideoFrames delta / totalVideoFrames delta; reset intervals rejected'}}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--report', type=Path, required=True)
    p.add_argument('--directory', type=Path, required=True)
    args = p.parse_args()
    args.directory.mkdir(parents=True, exist_ok=True)
    data = json.loads(args.report.read_text())
    result = analyze(data)
    (args.directory / 'metrics.json').write_text(json.dumps(result, indent=2) + '\n')
    (args.directory / 'summary.md').write_text('# Playback performance diagnostics\n\n' + json.dumps({k:v for k,v in result.items() if k not in ['windows','cpuAndRss']}, indent=2) + '\n')
    return 1 if result['diagnosticVerdict'] == 'FAIL' or (data.get('performanceDiagnostics') and result['missingEvidence']) else 0


if __name__ == '__main__':
    raise SystemExit(main())
