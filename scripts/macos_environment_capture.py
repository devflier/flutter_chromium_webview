#!/usr/bin/env python3
"""Runner environment evidence for macOS performance isolation (diagnostic only).

Subcommands:
  snapshot DIR   one-shot hardware/OS/GPU/virtualization description
  sample DIR     periodic load/CPU/memory-pressure samples until DIR/sampler.stop appears
  decoder DIR    best-effort decoder evidence extracted from retained CEF logs
  manifest DIR   SHA-256 manifest of every file under DIR

Nothing here changes pass/fail verdicts or selects thresholds. A missing or
failed probe is recorded as such rather than skipped.
"""
import argparse
import datetime
import hashlib
import json
import re
import subprocess
import sys
import time
from pathlib import Path


def run(command, timeout=60):
    try:
        done = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
        return {'command': command, 'exitCode': done.returncode,
                'output': (done.stdout + done.stderr)[-20000:]}
    except (OSError, subprocess.TimeoutExpired) as error:
        return {'command': command, 'exitCode': None, 'error': str(error)}


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def snapshot(directory):
    probes = {
        'swVers': ['sw_vers'],
        'xcode': ['xcodebuild', '-version'],
        'sysctl': ['/usr/sbin/sysctl', 'hw.model', 'hw.memsize', 'hw.ncpu', 'hw.physicalcpu',
                   'hw.logicalcpu', 'hw.perflevel0.logicalcpu', 'hw.perflevel1.logicalcpu',
                   'machdep.cpu.brand_string', 'kern.hv_vmm_present', 'kern.osversion'],
        'uname': ['uname', '-a'],
        'uptimeLoad': ['uptime'],
        'memoryPressure': ['/usr/bin/memory_pressure', '-Q'],
        'vmStat': ['/usr/bin/vm_stat'],
        'displays': ['/usr/sbin/system_profiler', 'SPDisplaysDataType'],
        'hardware': ['/usr/sbin/system_profiler', 'SPHardwareDataType'],
        'powerSettings': ['/usr/bin/pmset', '-g'],
        'thermal': ['/usr/bin/pmset', '-g', 'therm'],
        'flutter': ['flutter', '--version'],
        'topCpu': ['top', '-l', '2', '-n', '0', '-s', '1'],
    }
    report = {'capturedUtc': now(), 'probes': {name: run(cmd) for name, cmd in probes.items()}}
    # Interpret only what the raw output states; do not infer GPU/decoder capability.
    sysctl = report['probes']['sysctl'].get('output', '')
    match = re.search(r'kern\.hv_vmm_present:\s*(\d)', sysctl)
    report['virtualized'] = None if not match else match.group(1) == '1'
    display = report['probes']['displays'].get('output', '')
    report['metalSupportLines'] = [line.strip() for line in display.splitlines()
                                   if re.search(r'Metal|Chipset|Cores|Model', line)]
    report['hardwareVideoDecode'] = ('NOT DIRECTLY OBSERVED: system_profiler does not report '
                                     'VideoToolbox availability; see decoder.json for log evidence')
    (directory / 'environment.json').write_text(json.dumps(report, indent=2))


def sample(directory):
    stop = directory / 'sampler.stop'
    out = directory / 'runner-samples.jsonl'
    with out.open('a') as handle:
        while not stop.exists():
            record = {'utc': now(), 'monotonic': time.monotonic()}
            record['uptime'] = run(['uptime'], 10).get('output', '').strip()
            record['memoryPressure'] = run(['/usr/bin/memory_pressure', '-Q'], 10).get('output', '').strip()
            top = run(['top', '-l', '2', '-n', '0', '-s', '1'], 20).get('output', '')
            # The second sample is the interval measurement; the first is since boot.
            cpu = [line for line in top.splitlines() if line.startswith('CPU usage')]
            record['cpuUsage'] = cpu[-1] if cpu else None
            procs = run(['ps', '-axo', 'pid,%cpu,rss,etime,comm', '-r'], 10).get('output', '')
            record['topProcesses'] = procs.splitlines()[:12]
            handle.write(json.dumps(record) + '\n')
            handle.flush()
            for _ in range(10):
                if stop.exists():
                    break
                time.sleep(1)


def decoder(directory):
    """Collect decoder strings from retained logs. Strings are hints, not proof."""
    pattern = re.compile(r'(VideoToolbox\w*|MojoVideoDecoder\w*|VideoDecoderFallback\w*|'
                         r'Dav1d\w*|VpxVideoDecoder\w*|FFmpegVideoDecoder\w*|'
                         r'hardware[ _-]?(?:decod|accel)\w*|software[ _-]?decod\w*)', re.I)
    found = {}
    for log in directory.rglob('cef*.log'):
        counts = {}
        for line in log.read_text(errors='replace').splitlines():
            for item in pattern.findall(line):
                counts[item] = counts.get(item, 0) + 1
        found[str(log.relative_to(directory))] = counts
    (directory / 'decoder.json').write_text(json.dumps({
        'capturedUtc': now(),
        'interpretation': 'Log strings are hints only. They do not prove hardware or software '
                          'decode; actual decode path is UNMEASURED unless a platform decoder '
                          'name is reported by Chromium media telemetry.',
        'logs': found}, indent=2))


def manifest(directory):
    lines = []
    for path in sorted(p for p in directory.rglob('*') if p.is_file() and p.name != 'SHA256SUMS'):
        digest = hashlib.sha256()
        with path.open('rb') as handle:
            for block in iter(lambda: handle.read(1 << 20), b''):
                digest.update(block)
        lines.append(f'{digest.hexdigest()}  {path.relative_to(directory)}')
    (directory / 'SHA256SUMS').write_text('\n'.join(lines) + '\n')
    print(f'{len(lines)} files hashed')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('command', choices=['snapshot', 'sample', 'decoder', 'manifest'])
    parser.add_argument('directory', type=Path)
    args = parser.parse_args()
    args.directory.mkdir(parents=True, exist_ok=True)
    globals()[args.command](args.directory)
    sys.exit(0)
