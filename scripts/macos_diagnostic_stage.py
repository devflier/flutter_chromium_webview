"""Run a macOS validation stage without losing its failure or diagnostics."""
import argparse
import datetime
import json
import os
import re
from pathlib import Path
import shutil
import subprocess
import time


def capture(command, path):
    with path.open('w') as output:
        try:
            subprocess.run(command, stdout=output, stderr=subprocess.STDOUT, timeout=30)
        except (OSError, subprocess.TimeoutExpired) as error:
            output.write(f'\nDiagnostic collection failed: {error}\n')


def processes(output):
    listing = subprocess.check_output(['ps', '-axo', 'pid,ppid,rss,%cpu,etime,command'], text=True)
    lines = listing.splitlines()
    output.write(lines[0] + '\n')
    relevant = re.compile(r'ChromiumWebView|flutter_chromium_webview|flutter_tools.snapshot (test|build)|xcodebuild')
    output.write('\n'.join(line for line in lines[1:] if relevant.search(line)) + '\n')


def cef_processes():
    listing = subprocess.check_output(['ps', '-axo', 'pid=,ppid=,command='], text=True)
    found = {}
    for line in listing.splitlines():
        fields = line.strip().split(None, 2)
        if len(fields) == 3 and re.search(r'/Contents/MacOS/ChromiumWebView(?:Host| Helper)', fields[2]):
            found[int(fields[0])] = {'pid': int(fields[0]), 'ppid': int(fields[1]),
                'command': re.sub(r'--ipc-token=\S+', '--ipc-token=<redacted>', fields[2])}
    return found


def run(name, command, directory):
    stage = directory / name
    if (stage / 'result.json').exists():
        history = directory / 'history'
        history.mkdir(parents=True, exist_ok=True)
        shutil.move(str(stage), str(history / f'{name}-{time.time_ns()}'))
    stage.mkdir(parents=True, exist_ok=True)
    for filename in ("cef_host.log", "cef.log", "result.json"):
        (stage / filename).unlink(missing_ok=True)
    before_cef = cef_processes()
    started = time.time()
    stamp = datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    with (stage / 'processes-before.txt').open('w') as output:
        processes(output)
    with (stage / 'output.log').open('w') as output, (stage / 'processes-during.txt').open('w') as tree:
        environment = dict(os.environ, CEF_HOST_LOG_FILE=str(stage / "cef_host.log"),
                           CEF_LOG_FILE=str(stage / "cef.log"))
        process = subprocess.Popen(command, stdout=output, stderr=subprocess.STDOUT, env=environment)
        # Poll only to collect process evidence; this adds no delay to the test.
        while True:
            try:
                code = process.wait(timeout=5)
                break
            except subprocess.TimeoutExpired:
                tree.write(f'\nUTC {datetime.datetime.now(datetime.timezone.utc).isoformat()}\n')
                tree.flush()
                processes(tree)
    command_code = code
    # Runner can exit before its host completes CEF shutdown. Observe completion
    # with a deadline; a surviving new host/helper makes validation fail.
    deadline = time.monotonic() + 20
    while True:
        remaining = {pid: item for pid, item in cef_processes().items() if pid not in before_cef}
        if not remaining or time.monotonic() >= deadline:
            break
        time.sleep(0.1)
    (stage / 'surviving-cef-processes.json').write_text(json.dumps(list(remaining.values()), indent=2) + '\n')
    if remaining and code == 0:
        code = 1
        with (stage / 'output.log').open('a') as output:
            output.write('\nValidation failed: new Chromium host/helper processes survived command exit.\n')
    (stage / 'result.json').write_text(json.dumps({
        'command': command, 'commandExitStatus': command_code, 'exitStatus': code, 'durationSeconds': time.time() - started,
        'hostLogPresent': (stage / 'cef_host.log').exists(),
        'cefLogPresent': (stage / 'cef.log').exists(),
    }, indent=2) + '\n')
    with (stage / 'processes-after.txt').open('w') as output:
        processes(output)
    capture(['/usr/bin/log', 'show', '--start', stamp, '--style', 'compact', '--predicate',
             'process CONTAINS "ChromiumWebView" OR process CONTAINS "flutter_chromium_webview_example"'],
            stage / 'application.log')
    crashes = stage / 'crashes'
    copied_crashes = []
    for folder in [Path.home() / 'Library/Logs/DiagnosticReports', Path('/Library/Logs/DiagnosticReports')]:
        if not folder.exists():
            continue
        for report in folder.glob('*'):
            if report.is_file() and report.stat().st_mtime >= started and any(
                token in report.name for token in ['Chromium', 'flutter_chromium_webview']
            ):
                crashes.mkdir(exist_ok=True)
                shutil.copy2(report, crashes / report.name)
                copied_crashes.append(report.name)
    (stage / 'crash-reports.json').write_text(json.dumps(copied_crashes, indent=2) + '\n')
    print((stage / 'output.log').read_text(errors='replace'), end='')
    print(f'[{name}] exit status {code}; diagnostics: {stage}', flush=True)
    return code


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--directory', type=Path, required=True)
    parser.add_argument('name')
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    raise SystemExit(run(args.name, args.command, args.directory.resolve()))
