"""Preserve Flutter output and Android state without masking command failures."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import time


def snapshot(directory, device, name, arguments):
    try:
        result = subprocess.run(
            ['adb', '-s', device, *arguments], capture_output=True,
            text=True, errors='replace', timeout=30,
        )
        (directory / name).write_text(result.stdout + result.stderr)
        return result.returncode
    except (OSError, subprocess.TimeoutExpired) as error:
        (directory / name).write_text(str(error))
        return -1


def run(directory, device, command):
    directory.mkdir(parents=True, exist_ok=True)
    snapshot(directory, device, 'device.txt', ['shell', 'getprop'])
    # Clear the device buffers so each stage's logs describe that launch.
    snapshot(directory, device, 'logcat-clear.txt', ['logcat', '-b', 'all', '-c'])
    started = time.time()
    status = 1
    try:
        with (directory / 'flutter.log').open('w') as output:
            process = subprocess.Popen(
                command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, errors='replace', bufsize=1,
            )
            with process.stdout:
                for line in process.stdout:
                    output.write(line)
                    output.flush()
                    print(line, end='', flush=True)
            status = process.wait()
    finally:
        diagnostics = {}
        for name, arguments in {
            'logcat.txt': ['logcat', '-b', 'all', '-d', '-v', 'threadtime'],
            'crashes.txt': ['logcat', '-b', 'crash', '-d', '-v', 'threadtime'],
            'processes.txt': ['shell', 'ps', '-A'],
            'memory.txt': ['shell', 'dumpsys', 'meminfo'],
            'activity.txt': ['shell', 'dumpsys', 'activity', 'activities'],
            'exit-info.txt': ['shell', 'dumpsys', 'activity', 'exit-info',
                              'com.example.flutter_chromium_webview_example'],
        }.items():
            diagnostics[name] = snapshot(directory, device, name, arguments)
        (directory / 'result.json').write_text(json.dumps({
            'command': command, 'exitStatus': status,
            'durationSeconds': time.time() - started,
            'diagnosticExitStatuses': diagnostics,
        }, indent=2) + '\n')
    return status if status >= 0 else 128 - status


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', required=True, type=Path)
    parser.add_argument('--device', required=True)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if not args.command:
        parser.error('a command is required')
    sys.exit(run(args.directory, args.device, args.command))
