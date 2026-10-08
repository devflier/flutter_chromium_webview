import os
import plistlib
import subprocess
from pathlib import Path

def get_bundle_paths(app_path):
    app = Path(app_path)
    if not app.exists(): return "Does not exist"
    
    fw_dir = app / "Contents/Frameworks/Chromium Embedded Framework.framework"
    res_dir = fw_dir / "Resources"
    locales_dir = fw_dir / "Resources"  # Locales are inside Resources in CEF macOS
    
    return {
        "bundle": app,
        "fw_dir": fw_dir,
        "res_dir": res_dir,
        "locales_dir": locales_dir,
        "fw_exists": fw_dir.exists(),
        "res_exists": res_dir.exists()
    }

standalone = "/Users/veneno/Projects/packages/flutter_chromium_webview/packages/flutter_chromium_webview/macos/Host/ChromiumWebViewHost.app"
nested = "/Users/veneno/Projects/packages/flutter_chromium_webview/packages/flutter_chromium_webview/example/build/macos/Build/Products/Debug/flutter_chromium_webview_example.app/Contents/Frameworks/ChromiumWebViewHost.app"

print("Standalone:", get_bundle_paths(standalone))
print("Nested:", get_bundle_paths(nested))
