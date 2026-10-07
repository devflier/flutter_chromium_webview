import sys

path = '/Users/veneno/Projects/packages/flutter_chromium_webview/packages/flutter_chromium_webview/android/src/main/java/dev/devflier/flutter_chromium_webview/FlutterChromiumWebviewPlugin.java'
with open(path, 'r') as f:
    content = f.read()

target = "((ViewGroup) decor).addView(web, new ViewGroup.LayoutParams(1, 1));"
replacement = "((ViewGroup) decor).addView(web, new ViewGroup.LayoutParams(1, 1));\n            android.util.Log.i(\"ChromiumBG\", \"webview=\" + web.hashCode() + \" parked on DecorView\");"

if target in content:
    content = content.replace(target, replacement)
    with open(path, 'w') as f:
        f.write(content)
else:
    print("Target not found")
