"""Reject path/local-only interface resolution before publication readiness."""
import json
from pathlib import Path
import sys
from urllib.parse import unquote, urlparse


def verify(config):
    packages = json.loads(config.read_text())['packages']
    package = next(p for p in packages if p['name'] == 'flutter_chromium_webview_platform_interface')
    uri = package['rootUri']
    path = Path(unquote(urlparse(uri).path)) if uri.startswith('file:') else (config.parent / uri).resolve()
    if path.name != 'flutter_chromium_webview_platform_interface-0.1.6' or 'hosted' not in path.parts or 'pub.dev' not in path.parts:
        raise ValueError('BLOCKED: expected actual hosted interface 0.1.6; local override or other version resolved')
    print('PASS: hosted interface 0.1.6:', path)


if __name__ == '__main__':
    verify(Path(sys.argv[1]))
