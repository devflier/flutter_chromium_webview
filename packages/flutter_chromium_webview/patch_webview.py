import sys

with open("lib/flutter_chromium_webview.dart", "r") as f:
    content = f.read()

old_code = """          return LayoutBuilder(
            builder: (context, constraints) {
              if (widget.controller.textureId == null) {
                return const SizedBox.expand();
              }
              final size = constraints.biggest;"""

new_code = """          return LayoutBuilder(
            builder: (context, constraints) {
              if (widget.controller.textureId == null) {
                _currentSize = null;
                _currentDpr = null;
                return const SizedBox.expand();
              }
              final size = constraints.biggest;"""

if old_code in content:
    content = content.replace(old_code, new_code)
    with open("lib/flutter_chromium_webview.dart", "w") as f:
        f.write(content)
    print("Patched ChromiumWebView successfully.")
else:
    print("Old code not found.")

