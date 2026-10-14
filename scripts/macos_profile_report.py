"""Validate RSS/video-observer evidence; never infer allocation ownership."""
import argparse
import json
from pathlib import Path


def assess(data, required_seconds=300):
    errors = []
    if data.get('experimentOnly') or data.get('pipelineMode', 'full') != 'full':
        errors.append('Isolation/short experiment is not release memory acceptance')
    samples = data.get('samples', [])
    if not data.get('observerStarted'):
        errors.append('Video observer never started')
    if len(samples) < 3:
        errors.append('Fewer than three usable RSS samples')
    if not data.get('completedMeasurement') or data.get('actualSeconds', 0) < required_seconds:
        errors.append('Required workload/duration did not complete')
    identities = set()
    rows = []
    for sample in samples:
        processes = sample.get('processes', [])
        if not processes or not any(p.get('processType') == 'host' for p in processes):
            errors.append('Host/process evidence missing')
        if not any(p.get('processType') == 'gpu-process' for p in processes):
            errors.append('GPU evidence missing during accelerated playback')
        if not any(p.get('processType') == 'renderer' for p in processes):
            errors.append('Renderer evidence missing during playback')
        for p in processes:
            if not isinstance(p.get('rssKiB'), int):
                errors.append('Invalid process RSS')
            identities.add((p.get('pid'), p.get('processType'), p.get('command')))
        media = sample.get('localMedia')
        if data.get('workload') == 'local-video' and (not media or media.get('frames', 0) <= 0):
            errors.append('Decoded local video not established')
        rows.append({'utc': sample.get('timestampUtc'), 'elapsedSeconds': sample.get('elapsedSeconds'),
                     'combinedRssKiB': sum(p.get('rssKiB', 0) for p in processes), 'processes': processes,
                     'rendering': sample.get('rendering'), 'localMedia': media})
    growth = data.get('rssGrowthKiB')
    rss = 'INCONCLUSIVE' if not isinstance(growth, (int, float)) else ('PASS' if growth < 75000 else 'FAIL')
    if rss == 'INCONCLUSIVE':
        errors.append('Strict RSS verdict unavailable')
    if not data.get('returnedToIdleBaseline'):
        errors.append('Tracked disposal ownership not restored')
    disposal = data.get('disposalSamples', [])
    if not disposal or disposal[-1].get('elapsedSeconds', 0) < data.get('disposalSeconds', 60):
        errors.append('Settled disposal observation missing or incomplete')
    elif any(p.get('processType') == 'renderer' for p in disposal[-1].get('processes', [])):
        errors.append('Renderer survives settled browser disposal')
    if not data.get('droppedFramesMeasured'):
        errors.append('Dropped-frame telemetry missing')
    dropped_delta = None
    if samples:
        first = (samples[0].get('rendering') or {}).get('videoQuality', [])
        last = (samples[-1].get('rendering') or {}).get('videoQuality', [])
        pairs = [(a, b) for a in first for b in last if (a.get('targetId'), a.get('videoIndex')) == (b.get('targetId'), b.get('videoIndex'))]
        if pairs and all(isinstance(a.get('droppedVideoFrames'), int) and isinstance(b.get('droppedVideoFrames'), int)
                         and b['droppedVideoFrames'] >= a['droppedVideoFrames'] for a, b in pairs):
            dropped_delta = sum(b['droppedVideoFrames'] - a['droppedVideoFrames'] for a, b in pairs)
    process_trends = []
    for pid, role, command in sorted(identities, key=str):
        points = [{'utc': s.get('timestampUtc'), 'rssKiB': p['rssKiB']} for s in samples
                  for p in s.get('processes', []) if p.get('pid') == pid and p.get('command') == command
                  and isinstance(p.get('rssKiB'), int)]
        if points:
            process_trends.append({'pid': pid, 'role': role, 'command': command, 'firstKiB': points[0]['rssKiB'],
                                   'finalKiB': points[-1]['rssKiB'], 'sampledPeakKiB': max(p['rssKiB'] for p in points),
                                   'deltaKiB': points[-1]['rssKiB'] - points[0]['rssKiB'], 'observations': points,
                                   'identityLimitation': 'PID/command observed; PID start-time reuse not resolved in legacy collector'})
    verdict = 'FAIL' if errors or rss == 'FAIL' or not data.get('passed') else 'PASS'
    return {'verdict': verdict, 'completenessErrors': sorted(set(errors)), 'sampleCount': len(samples),
            'strictRssAcceptance': rss, 'threshold': 'growth < 75000 KiB, second active sample to final active sample',
            'rssGrowthKiB': growth, 'measuredDroppedFrameDelta': dropped_delta, 'trackedCleanup': 'PASS' if data.get('returnedToIdleBaseline') else 'FAIL',
            'processIdentities': sorted(identities, key=str), 'processTrends': process_trends, 'samples': rows,
            'metric': 'CEF host and observed descendants RSS, not whole-app charged footprint',
            'allocationOwnership': 'INCONCLUSIVE: no allocator/heap profiler attached',
            'longTermLeakFreedom': 'NOT ESTABLISHED', 'historicalRssAcceptance': 'FAIL remains unchanged'}


def main(args):
    args.directory.mkdir(parents=True, exist_ok=True)
    try:
        result = assess(json.loads(args.report.read_text()), args.seconds)
    except (OSError, ValueError, TypeError, KeyError) as error:
        result = {'verdict': 'FAIL', 'completenessErrors': ['Missing/invalid artifact: ' + str(error)]}
    (args.directory / 'metrics.json').write_text(json.dumps(result, indent=2) + '\n')
    (args.directory / 'summary.md').write_text('# Deterministic media RSS profile\n\nVerdict: **' + result['verdict'] + '**\n\n' +
        '\n'.join('- ' + str(e) for e in result.get('completenessErrors', [])) +
        '\n\nStrict RSS: ' + result.get('strictRssAcceptance', 'INCONCLUSIVE') +
        '\n\nTracked cleanup, strict RSS, warm stability and leak freedom are separate. This is a sampled RSS/video-observer profile, not allocator ownership or whole-app footprint. Historical memory failures remain failed.\n')
    return 0 if result['verdict'] == 'PASS' else 1


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--report', type=Path, required=True)
    p.add_argument('--directory', type=Path, required=True)
    p.add_argument('--seconds', type=int, default=300)
    raise SystemExit(main(p.parse_args()))
