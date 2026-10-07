import sys

path = '/Users/veneno/Projects/packages/flutter_chromium_webview/packages/flutter_chromium_webview/lib/chromium_youtube_player.dart'
with open(path, 'r') as f:
    content = f.read()

target = """    if (decoded['Ready'] == true && _ready?.isCompleted == false) {"""

replacement = """    if (decoded['DebugHeartbeat'] != null) {
      print('[ChromiumBG] JS Heartbeat -> ' + decoded['DebugHeartbeat'].toString());
    }
    if (decoded['Ready'] == true && _ready?.isCompleted == false) {"""

content = content.replace(target, replacement)

with open(path, 'w') as f:
    f.write(content)
