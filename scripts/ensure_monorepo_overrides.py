#!/usr/bin/env python3
"""Ensure local monorepo dependency overrides exist for local builds and CI validation.

These files are gitignored and excluded by .pubignore so they never leak into published
packages, but they allow monorepo packages to resolve against unreleased local siblings.
"""
from pathlib import Path

root = Path(__file__).resolve().parent.parent

webview_override = root / "packages" / "flutter_chromium_webview" / "pubspec_overrides.yaml"
if not webview_override.exists():
    webview_override.write_text(
        "# Local monorepo development only. Not published (see .pubignore).\n"
        "dependency_overrides:\n"
        "  flutter_chromium_webview_platform_interface:\n"
        "    path: ../flutter_chromium_webview_platform_interface\n"
    )

example_override = (
    root / "packages" / "flutter_chromium_webview" / "example" / "pubspec_overrides.yaml"
)
if not example_override.exists():
    example_override.write_text(
        "# Local monorepo development only.\n"
        "dependency_overrides:\n"
        "  flutter_chromium_webview_platform_interface:\n"
        "    path: ../../flutter_chromium_webview_platform_interface\n"
    )
