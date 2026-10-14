import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from android_diagnostic_stage import run


class AndroidDiagnosticsTests(unittest.TestCase):
    def test_failed_command_keeps_exit_status_and_diagnostics(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            with patch('android_diagnostic_stage.start_capture'), patch('android_diagnostic_stage.stop_capture', return_value={'started': True, 'exitBeforeCollectorStop': None}), patch('android_diagnostic_stage.subprocess.run') as adb:
                adb.return_value = subprocess.CompletedProcess([], 0, 'device log\n', '')
                status = run(directory, 'emulator-5554', [
                    sys.executable, '-c', 'print("startup failure"); raise SystemExit(7)',
                ])
            self.assertEqual(status, 7)
            self.assertIn('startup failure', (directory / 'flutter.log').read_text())
            self.assertEqual((directory / 'crashes.txt').read_text(), 'device log\n')
            self.assertEqual(json.loads((directory / 'result.json').read_text())['exitStatus'], 7)
            self.assertEqual(adb.call_count, 12)
            result = json.loads((directory / 'result.json').read_text())
            self.assertLessEqual(result['captureStartedUtc'], result['commandStartedUtc'])
            self.assertLessEqual(result['commandFinishedUtc'], result['captureFinishedUtc'])

    def test_unavailable_adb_does_not_replace_test_result(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            with patch('android_diagnostic_stage.start_capture'), patch('android_diagnostic_stage.stop_capture', return_value={'started': False, 'exitBeforeCollectorStop': None}), patch('android_diagnostic_stage.subprocess.run', side_effect=OSError('adb unavailable')):
                status = run(directory, 'emulator-5554', [sys.executable, '-c', 'pass'])
            self.assertEqual(status, 0)
            result = json.loads((directory / 'result.json').read_text())
            self.assertTrue(all(value == -1 for value in result['diagnosticExitStatuses'].values()))
            self.assertIn('adb unavailable', (directory / 'logcat.txt').read_text())
            self.assertEqual(result['diagnosticCompleteness'], 'INCONCLUSIVE')

    def test_persistent_logcat_survives_failed_flutter_process(self):
        import os
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            adb = directory / 'adb'
            adb.write_text('#!' + sys.executable + '\nimport sys,time\n'
                'if "logcat" in sys.argv and "-d" not in sys.argv and "-c" not in sys.argv:\n'
                ' print("persistent native lifecycle log",flush=True)\n'
                ' while True: time.sleep(0.01)\n'
                'else: print("device snapshot")\n')
            adb.chmod(0o755)
            with patch.dict(os.environ, {'PATH': str(directory) + os.pathsep + os.environ['PATH']}):
                status = run(directory, 'emulator-test', [sys.executable, '-c',
                    'import time;time.sleep(0.2);raise SystemExit(9)'])
            self.assertEqual(status, 9)
            self.assertIn('persistent native lifecycle log', (directory / 'logcat-persistent.txt').read_text())
            result = json.loads((directory / 'result.json').read_text())
            self.assertEqual(result['persistentCapture']['exitBeforeCollectorStop'], None)
            self.assertTrue(result['persistentCapture']['monitorStopped'])
            self.assertTrue((directory / 'process-lifetime.jsonl').read_text())


if __name__ == '__main__':
    unittest.main()
