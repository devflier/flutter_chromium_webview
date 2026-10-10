"""The diagnostic wrapper must preserve the tested command's failure."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('stage', Path(__file__).with_name('macos_diagnostic_stage.py'))
stage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stage)


class DiagnosticTests(unittest.TestCase):
    def test_validation_continues_but_fails_after_an_independent_stage_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'scripts').mkdir()
            (root / 'scripts/macos_diagnostic_stage.py').write_text(
                'import sys\nprint(sys.argv[3], flush=True)\n'
                'sys.exit(7 if sys.argv[3] == "failed-test" else 0)\n')
            helper = Path(__file__).with_name('macos_validation_stages.sh')
            result = subprocess.run(['bash', '-c',
                'set -euo pipefail; root="$1"; diagnostics="$1"; source "$2"; '
                'run_stage failed-test; run_stage following-test; finish_stage_validation',
                'validation-test', str(root), str(helper)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn('following-test', result.stdout)
            self.assertIn('failed-test (exit 7)', result.stderr)

    def test_validation_succeeds_when_all_stages_succeed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'scripts').mkdir()
            (root / 'scripts/macos_diagnostic_stage.py').write_text('import sys\nsys.exit(0)\n')
            helper = Path(__file__).with_name('macos_validation_stages.sh')
            result = subprocess.run(['bash', '-c',
                'set -euo pipefail; root="$1"; diagnostics="$1"; source "$2"; '
                'run_stage passing-test; finish_stage_validation',
                'validation-test', str(root), str(helper)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_nonzero_status_and_complete_output_survive_collection(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(stage, 'capture'), \
                contextlib.redirect_stdout(io.StringIO()):
            root = Path(directory)
            code = stage.run('failed-test', [sys.executable, '-c',
                'import sys; print("before failure"); print("error detail", file=sys.stderr); sys.exit(7)'], root)
            self.assertEqual(code, 7)
            self.assertEqual(json.loads((root / 'failed-test/result.json').read_text())['exitStatus'], 7)
            output = (root / 'failed-test/output.log').read_text()
            self.assertIn('before failure', output)
            self.assertIn('error detail', output)
            self.assertEqual(stage.run('failed-test', [sys.executable, '-c', 'print("retry passed")'], root), 0)
            previous = list((root / 'history').glob('failed-test-*/result.json'))
            self.assertEqual(len(previous), 1)
            self.assertEqual(json.loads(previous[0].read_text())['exitStatus'], 7)
            self.assertIn('error detail', previous[0].with_name('output.log').read_text())

    def test_successful_command_with_surviving_helper_fails_validation(self):
        orphan = {42: {'pid': 42, 'ppid': 1, 'command': 'ChromiumWebView Helper'}}
        with tempfile.TemporaryDirectory() as directory, patch.object(stage, 'capture'), \
                patch.object(stage, 'cef_processes', side_effect=[{}, orphan]), \
                patch.object(stage.time, 'monotonic', side_effect=[0, 21]), \
                contextlib.redirect_stdout(io.StringIO()):
            root = Path(directory)
            self.assertEqual(stage.run('orphan', [sys.executable, '-c', 'print("command passed")'], root), 1)
            result = json.loads((root / 'orphan/result.json').read_text())
            self.assertEqual(result['commandExitStatus'], 0)
            self.assertEqual(result['exitStatus'], 1)
            self.assertEqual(json.loads((root / 'orphan/surviving-cef-processes.json').read_text())[0]['pid'], 42)


if __name__ == '__main__':
    unittest.main()
