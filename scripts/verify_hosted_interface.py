"""Reject path/local-only interface resolution before publication readiness."""
import json
from pathlib import Path
import sys
from urllib.parse import unquote, urlparse


def verify(config, expected_version=None):
    if expected_version is None:
        pubspec = Path(__file__).resolve().parent.parent / 'packages' / 'flutter_chromium_webview' / 'pubspec.yaml'
        if pubspec.exists():
            for line in pubspec.read_text().splitlines():
                if 'flutter_chromium_webview_platform_interface:' in line:
                    expected_version = line.split(':')[-1].strip().lstrip('^')
                    break
        if not expected_version:
            expected_version = '0.1.7'

    packages = json.loads(config.read_text())['packages']
    package = next(p for p in packages if p['name'] == 'flutter_chromium_webview_platform_interface')
    uri = package['rootUri']
    path = Path(unquote(urlparse(uri).path)) if uri.startswith('file:') else (config.parent / uri).resolve()
    if path.name != f'flutter_chromium_webview_platform_interface-{expected_version}' or 'hosted' not in path.parts or 'pub.dev' not in path.parts:
        raise ValueError(f'BLOCKED: expected actual hosted interface {expected_version}; local override or other version resolved')
    print(f'PASS: hosted interface {expected_version}:', path)


if __name__ == '__main__':
    verify(Path(sys.argv[1]))
