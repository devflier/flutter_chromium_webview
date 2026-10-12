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
            with patch('android_diagnostic_stage.subprocess.run') as adb:
                adb.return_value = subprocess.CompletedProcess([], 0, 'device log\n', '')
                status = run(directory, 'emulator-5554', [
                    sys.executable, '-c', 'print("startup failure"); raise SystemExit(7)',
                ])
            self.assertEqual(status, 7)
            self.assertIn('startup failure', (directory / 'flutter.log').read_text())
            self.assertEqual((directory / 'crashes.txt').read_text(), 'device log\n')
            self.assertEqual(json.loads((directory / 'result.json').read_text())['exitStatus'], 7)
            self.assertEqual(adb.call_count, 8)

    def test_unavailable_adb_does_not_replace_test_result(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            with patch('android_diagnostic_stage.subprocess.run', side_effect=OSError('adb unavailable')):
                status = run(directory, 'emulator-5554', [sys.executable, '-c', 'pass'])
            self.assertEqual(status, 0)
            result = json.loads((directory / 'result.json').read_text())
            self.assertTrue(all(value == -1 for value in result['diagnosticExitStatuses'].values()))
            self.assertIn('adb unavailable', (directory / 'logcat.txt').read_text())


if __name__ == '__main__':
    unittest.main()
