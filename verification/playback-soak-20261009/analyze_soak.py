#!/usr/bin/env python3
"""Summarize saved soak evidence without treating RSS thresholds as leak proof."""
import argparse
import csv
import json
from pathlib import Path


def regression(rows, key, start_minute):
    points = [(r['elapsedMinutes'], r[key]) for r in rows if r['elapsedMinutes'] >= start_minute]
    if len(points) < 3:
        return None
    xs, ys = zip(*points)
    mx, my = sum(xs) / len(xs), sum(ys) / len(ys)
    xx = sum((x - mx) ** 2 for x in xs)
    if not xx:
        return None
    slope = sum((x - mx) * (y - my) for x, y in points) / xx
    residual = sum((y - (my + slope * (x - mx))) ** 2 for x, y in points)
    total = sum((y - my) ** 2 for y in ys)
    return {'startMinute': xs[0], 'endMinute': xs[-1], 'samples': len(points),
            'slopePerMinute': slope, 'rSquared': 1 - residual / total if total else None,
            'min': min(ys), 'max': max(ys), 'start': ys[0], 'end': ys[-1]}


def analyze(path):
    report = json.loads(path.read_text())
    rows = []
    for sample in report['samples']:
        rendering = sample['rendering']
        host = next(p for p in sample['processes'] if p['pid'] == rendering['hostPid'])
        rows.append({'elapsedMinutes': sample['elapsedSeconds'] / 60,
                     'label': sample['label'], 'hostPid': rendering['hostPid'],
                     'hostRssMiB': host['rssKiB'] / 1024,
                     'totalRssMiB': sum(p['rssKiB'] for p in sample['processes']) / 1024,
                     'hostCpuPercent': host['cpuPercent'],
                     'totalCpuPercent': sum(p['cpuPercent'] for p in sample['processes']),
                     'numericDescriptors': sample['numericDescriptors'],
                     'lsofRows': sample['lsofRows'], 'processCount': len(sample['processes']),
                     'surfaceGeneration': rendering['surfaceGeneration'],
                     'completedMetalFrames': rendering['completedMetalFrames'],
                     'softwareFrames': rendering['softwareFrames'],
                     'failedMetalFrames': rendering['failedMetalFrames']})
    if not rows:
        raise ValueError('No playback samples')
    out = path.parent
    with (out / 'samples.csv').open('w', newline='') as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
    duration = rows[-1]['elapsedMinutes']
    summary = {'requestedSeconds': report['requestedSeconds'],
               'actualMinutes': duration, 'liveGatesPassed': report['passed'],
               'failure': report.get('failure'), 'hostPids': sorted({r['hostPid'] for r in rows}),
               'samples': len(rows), 'completedInteractions': sum(bool(i.get('completed')) for i in report['interactions']),
               'returnedToIdleBaseline': report.get('returnedToIdleBaseline'),
               'droppedFramesMeasured': False,
               'warmupExcludedMinutes': 5,
               'trendsAfter5Minutes': {k: regression(rows, k, 5) for k in ['hostRssMiB', 'totalRssMiB', 'numericDescriptors', 'processCount']},
               'trendsLast10Minutes': {k: regression(rows, k, max(5, duration - 10)) for k in ['hostRssMiB', 'totalRssMiB', 'numericDescriptors', 'processCount']}}
    checkpoints = []
    for minute in [0, 5, 15, 30, 60]:
        if minute > duration + 0.25:
            continue
        checkpoints.append(min(rows, key=lambda r: abs(r['elapsedMinutes'] - minute)) | {'checkpointMinute': minute})
    summary['checkpoints'] = checkpoints
    (out / 'summary.json').write_text(json.dumps(summary, indent=2))
    lines = ['# Playback soak results', '',
             f"Live rendering/resource gates: **{'passed' if report['passed'] else 'not passed'}**. Duration: {duration:.2f} minutes.", '',
             '| Checkpoint | Actual minute | Host RSS MiB | Host + helpers RSS MiB | Numeric FDs | Processes | Completed Metal frames | Software callbacks |',
             '| --- | --- | --- | --- | --- | --- | --- | --- |']
    for r in checkpoints:
        lines.append(f"| {r['checkpointMinute']} min | {r['elapsedMinutes']:.2f} | {r['hostRssMiB']:.1f} | {r['totalRssMiB']:.1f} | {r['numericDescriptors']} | {r['processCount']} | {r['completedMetalFrames']} | {r['softwareFrames']} |")
    lines += ['', '## Trends', '',
              '| Metric | Slope after 5 min | Slope in final 10 min | Final 10 min range |',
              '| --- | --- | --- | --- |']
    for key in ['hostRssMiB', 'totalRssMiB', 'numericDescriptors', 'processCount']:
        early = summary['trendsAfter5Minutes'][key]
        late = summary['trendsLast10Minutes'][key]
        if early and late:
            lines.append(f"| {key} | {early['slopePerMinute']:.3f}/min | {late['slopePerMinute']:.3f}/min | {late['min']:.1f}–{late['max']:.1f} |")
    lines += ['', 'Slopes are least-squares fits to interval samples. They are measurements, not automatic proof of a leak or a plateau. Correlate changes with the interaction timeline and caches.', '',
              f"Completed interactions: {summary['completedInteractions']}. Post-disposal return to idle baseline: {report.get('returnedToIdleBaseline')}.", '',
              'Actual decoded/dropped video frames remain unmeasured. Completed Metal blits and paint callbacks are separate metrics. The live gate verifies Metal progress and no additional software callbacks after startup.', '',
              'The data includes only the measured host and its descendants. Numeric FDs differ from lsof row count, which also includes mappings and nonnumeric handles. Aggregate RSS may double-count shared pages across processes.', '',
              'Fullscreen exercises the native Flutter window; hide/show detaches and reattaches the widget. No screenshot was captured because Computer Use access to the example app was unavailable. No architecture tuning was applied.', '']
    if report.get('failure'):
        lines += ['## Failure', '', str(report['failure']), '']
    (out / 'README.md').write_text('\n'.join(lines))
    try:
        import matplotlib
        matplotlib.use('Agg')
        import matplotlib.pyplot as plt
        from matplotlib.ticker import MaxNLocator
        fig, axes = plt.subplots(4, 1, figsize=(10, 11), sharex=True, constrained_layout=True)
        times = [r['elapsedMinutes'] for r in rows]
        axes[0].plot(times, [r['hostRssMiB'] for r in rows], label='Host RSS')
        axes[1].plot(times, [r['totalRssMiB'] for r in rows], label='Host + helpers RSS', color='#cc8730')
        axes[1].set_ylabel('Combined RSS (MiB)')
        axes[1].legend()
        axes[0].set_ylabel('RSS (MiB)')
        axes[0].legend()
        axes[2].plot(times, [r['numericDescriptors'] for r in rows], label='Host numeric FDs', color='#7450c0')
        axes[2].set_ylabel('File descriptors')
        axes[2].legend()
        axes[3].plot(times, [r['processCount'] for r in rows], label='Host + helper processes', color='#188878')
        axes[2].yaxis.set_major_locator(MaxNLocator(integer=True))
        counts = [r['processCount'] for r in rows]
        axes[3].set_ylim(min(counts) - .5, max(counts) + .5)
        axes[3].set_yticks(range(min(counts), max(counts) + 1))
        axes[3].set_ylabel('Process count')
        axes[3].set_xlabel('Minutes since confirmed playback')
        axes[3].legend()
        for axis in axes:
            axis.axvspan(0, min(5, duration), alpha=.1, color='gray')
            axis.grid(alpha=.2)
            for action in report['interactions']:
                if action.get('completed') and action.get('action') == 'switch-track':
                    axis.axvline(action['elapsedSeconds'] / 60, color='#cc8730', linestyle=':', alpha=.65)
        fig.suptitle('Real YouTube playback soak — resource trends\nGray: initial warm-up; dotted orange: track switches')
        fig.savefig(out / 'resource-trends.png', dpi=160)
        plt.close(fig)
    except ImportError:
        pass
    print(json.dumps(summary, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('report', type=Path)
    analyze(parser.parse_args().report)
