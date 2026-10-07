import sys

path = '/Users/veneno/Projects/packages/flutter_chromium_webview/packages/flutter_chromium_webview/android/src/main/java/dev/devflier/flutter_chromium_webview/FlutterChromiumWebviewPlugin.java'
with open(path, 'r') as f:
    content = f.read()

target1 = "public final class FlutterChromiumWebviewPlugin implements FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware {"
rep1 = """import android.app.Application;
import android.os.Bundle;

public final class FlutterChromiumWebviewPlugin implements FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware, Application.ActivityLifecycleCallbacks {"""

target2 = "  @Override public void onAttachedToActivity(ActivityPluginBinding binding) { activityContext = binding.getActivity(); }"
rep2 = """  @Override public void onAttachedToActivity(ActivityPluginBinding binding) { 
    activityContext = binding.getActivity(); 
    binding.getActivity().getApplication().registerActivityLifecycleCallbacks(this);
  }"""

target3 = "  @Override public void onDetachedFromActivity() { activityContext = null; }"
rep3 = """  @Override public void onDetachedFromActivity() { 
    if (activityContext != null) {
      ((android.app.Activity) activityContext).getApplication().unregisterActivityLifecycleCallbacks(this);
    }
    activityContext = null; 
  }"""

target4 = "  private void event(Browser browser, String name, Map<String, Object> args) {"
rep4 = """
  private void logBg(String event) {
    if (browsers.isEmpty()) return;
    for (Browser b : browsers.values()) {
      boolean attached = b.web != null && b.web.getParent() != null;
      String parent = attached ? b.web.getParent().getClass().getSimpleName() : "null";
      int windowVisibility = b.web != null ? b.web.getWindowVisibility() : -1;
      android.util.Log.i("ChromiumBG", "webview=" + (b.web != null ? b.web.hashCode() : "null") 
        + " event=" + event + " attached=" + attached + " parent=" + parent + " windowVis=" + windowVisibility);
    }
  }

  @Override public void onActivityCreated(android.app.Activity activity, Bundle savedInstanceState) {}
  @Override public void onActivityStarted(android.app.Activity activity) { logBg("activityStarted"); }
  @Override public void onActivityResumed(android.app.Activity activity) { logBg("activityResumed"); }
  @Override public void onActivityPaused(android.app.Activity activity) { logBg("activityPaused"); }
  @Override public void onActivityStopped(android.app.Activity activity) { 
    logBg("activityStopped"); 
    // EXPERIMENT B: Reparent to VirtualDisplay
    /*
    for (Browser b : browsers.values()) {
      if (b.web != null) {
        if (b.web.getParent() instanceof ViewGroup) {
          ((ViewGroup) b.web.getParent()).removeView(b.web);
        }
        // attach to virtual display presentation...
      }
    }
    */
  }
  @Override public void onActivitySaveInstanceState(android.app.Activity activity, Bundle outState) {}
  @Override public void onActivityDestroyed(android.app.Activity activity) { logBg("activityDestroyed"); }

  private void event(Browser browser, String name, Map<String, Object> args) {"""

if target1 in content:
    content = content.replace(target1, rep1).replace(target2, rep2).replace(target3, rep3).replace(target4, rep4)
    with open(path, 'w') as f:
        f.write(content)
else:
    print("Target not found")
