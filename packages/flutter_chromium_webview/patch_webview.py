import sys

path = '/Users/veneno/Projects/packages/flutter_chromium_webview/packages/flutter_chromium_webview/android/src/main/java/dev/devflier/flutter_chromium_webview/FlutterChromiumWebviewPlugin.java'
with open(path, 'r') as f:
    content = f.read()

target = "      web = new WebView(viewContext);"
replacement = """      web = new WebView(viewContext) {
        @Override
        protected void onWindowVisibilityChanged(int visibility) {
          super.onWindowVisibilityChanged(visibility);
          android.util.Log.i("ChromiumBG", "webview=" + hashCode() + " onWindowVisibilityChanged visibility=" + visibility);
        }
        @Override
        public void onPause() {
          super.onPause();
          android.util.Log.i("ChromiumBG", "webview=" + hashCode() + " onPause");
        }
        @Override
        public void onResume() {
          super.onResume();
          android.util.Log.i("ChromiumBG", "webview=" + hashCode() + " onResume");
        }
      };"""

if target in content:
    content = content.replace(target, replacement)
    with open(path, 'w') as f:
        f.write(content)
else:
    print("Target not found")
