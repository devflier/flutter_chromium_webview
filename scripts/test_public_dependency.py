import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from verify_hosted_interface import verify


class HostedDependencyTests(unittest.TestCase):
    def test_local_override_or_missing_api_version_rejected(self):
        for uri in ['file:///tmp/local-interface', 'file:///tmp/hosted/pub.dev/flutter_chromium_webview_platform_interface-0.1.5',
                    'file:///tmp/hosted/untrusted.example/flutter_chromium_webview_platform_interface-0.1.6']:
            with tempfile.TemporaryDirectory() as root:
                p = Path(root) / 'package_config.json'
                p.write_text(json.dumps({'packages': [{'name': 'flutter_chromium_webview_platform_interface', 'rootUri': uri}]}))
                with self.assertRaises(ValueError): verify(p)

    def test_public_version_resolved(self):
        with tempfile.TemporaryDirectory() as root:
            p = Path(root) / 'package_config.json'
            p.write_text(json.dumps({'packages': [{'name': 'flutter_chromium_webview_platform_interface',
                                                  'rootUri': 'file:///tmp/hosted/pub.dev/flutter_chromium_webview_platform_interface-0.1.6'}]}))
            with contextlib.redirect_stdout(io.StringIO()): verify(p)


if __name__ == '__main__': unittest.main()
