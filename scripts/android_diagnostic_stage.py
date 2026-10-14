"""Preserve Flutter output and Android state without masking command failures."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import time
import threading
from datetime import datetime, timezone


def utc():
    return datetime.now(timezone.utc).isoformat()


def monitor_processes(directory, device, stop):
    with (directory / 'process-lifetime.jsonl').open('w') as output:
        while not stop.is_set():
            try:
                result = subprocess.run(['adb', '-s', device, 'shell', 'ps', '-A'],
                    capture_output=True, text=True, errors='replace', timeout=5)
                row = {'utc': utc(), 'exitStatus': result.returncode,
                       'processes': [line for line in result.stdout.splitlines()
                                     if 'chromium_webview' in line or 'webview' in line],
                       'stderr': result.stderr}
            except (OSError, subprocess.TimeoutExpired) as error:
                row = {'utc': utc(), 'error': str(error)}
            output.write(json.dumps(row) + '\n')
            output.flush()
            stop.wait(1)


def start_capture(directory, device):
    output = (directory / 'logcat-persistent.txt').open('w')
    process = None
    error = None
    try:
        process = subprocess.Popen(['adb', '-s', device, 'logcat', '-b', 'all', '-v', 'threadtime'],
                                   stdout=output, stderr=subprocess.STDOUT)
    except OSError as failure:
        error = str(failure)
        output.write(error + '\n')
        output.flush()
    stop = threading.Event()
    monitor = threading.Thread(target=monitor_processes, args=(directory, device, stop), daemon=True)
    monitor.start()
    return process, output, stop, monitor, error


def stop_capture(capture):
    process, output, stop, monitor, error = capture
    stop.set()
    monitor.join(timeout=7)
    early_exit = process.poll() if process is not None else None
    if process is not None and early_exit is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
    output.close()
    return {'started': process is not None, 'startupError': error,
            'exitBeforeCollectorStop': early_exit,
            'monitorStopped': not monitor.is_alive()}


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
    snapshot(directory, device, 'adb-version.txt', ['version'])
    snapshot(directory, device, 'emulator-name.txt', ['emu', 'avd', 'name'])
    capture_started = utc()
    capture = start_capture(directory, device)
    started = time.time()
    command_started = utc()
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
        command_finished = utc()
        diagnostics = {}
        for name, arguments in {
            'logcat.txt': ['logcat', '-b', 'all', '-d', '-v', 'threadtime'],
            'crashes.txt': ['logcat', '-b', 'crash', '-d', '-v', 'threadtime'],
            'processes.txt': ['shell', 'ps', '-A'],
            'memory.txt': ['shell', 'dumpsys', 'meminfo'],
            'activity.txt': ['shell', 'dumpsys', 'activity', 'activities'],
            'exit-info.txt': ['shell', 'dumpsys', 'activity', 'exit-info',
                              'com.example.flutter_chromium_webview_example'],
            'tombstones-availability.txt': ['shell', 'ls', '-l', '/data/tombstones'],
            'native-crash-dropbox.txt': ['shell', 'dumpsys', 'dropbox', '--print', 'data_app_native_crash'],
        }.items():
            diagnostics[name] = snapshot(directory, device, name, arguments)
        persistent = stop_capture(capture)
        (directory / 'result.json').write_text(json.dumps({
            'command': command, 'exitStatus': status,
            'durationSeconds': time.time() - started,
            'diagnosticExitStatuses': diagnostics,
            'captureStartedUtc': capture_started,
            'commandStartedUtc': command_started,
            'commandFinishedUtc': command_finished,
            'captureFinishedUtc': utc(),
            'persistentCapture': persistent,
            'diagnosticCompleteness': 'INCONCLUSIVE' if not persistent['started'] or
                persistent['exitBeforeCollectorStop'] is not None else 'PASS',
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
