import sys

path = '/Users/veneno/Projects/packages/flutter_chromium_webview/packages/flutter_chromium_webview/android/src/main/java/dev/devflier/flutter_chromium_webview/FlutterChromiumWebviewPlugin.java'
with open(path, 'r') as f:
    content = f.read()

vd_class = """
  // EXPERIMENT B: Background Host
  /*
  private static class BackgroundHost {
    private android.hardware.display.VirtualDisplay virtualDisplay;
    private android.app.Presentation presentation;
    private android.widget.FrameLayout container;

    void start(Context context) {
      if (virtualDisplay != null) return;
      android.hardware.display.DisplayManager dm = (android.hardware.display.DisplayManager) context.getSystemService(Context.DISPLAY_SERVICE);
      virtualDisplay = dm.createVirtualDisplay("ChromiumBG", 1280, 720, 160, null, 0);
      presentation = new android.app.Presentation(context, virtualDisplay.getDisplay());
      container = new android.widget.FrameLayout(context);
      presentation.setContentView(container);
      presentation.show();
      android.util.Log.i("ChromiumBG", "BackgroundHost Presentation started");
    }

    void attach(WebView web) {
      if (container != null) {
        if (web.getParent() instanceof ViewGroup) ((ViewGroup) web.getParent()).removeView(web);
        container.addView(web, new android.widget.FrameLayout.LayoutParams(
            android.view.ViewGroup.LayoutParams.MATCH_PARENT, 
            android.view.ViewGroup.LayoutParams.MATCH_PARENT));
        android.util.Log.i("ChromiumBG", "WebView attached to BackgroundHost");
      }
    }

    void stop() {
      if (presentation != null) { presentation.dismiss(); presentation = null; }
      if (virtualDisplay != null) { virtualDisplay.release(); virtualDisplay = null; }
      container = null;
      android.util.Log.i("ChromiumBG", "BackgroundHost Presentation stopped");
    }
  }
  private BackgroundHost bgHost;
  */
"""

target = "private void event(Browser browser, String name, Map<String, Object> args) {"
if target in content:
    content = content.replace(target, vd_class + "\n  " + target)
    with open(path, 'w') as f:
        f.write(content)
else:
    print("Target not found")
