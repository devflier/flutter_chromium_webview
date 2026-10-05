package dev.devflier.flutter_chromium_webview;

import android.annotation.SuppressLint;
import android.content.Context;
import android.content.MutableContextWrapper;
import android.graphics.Bitmap;
import android.net.Uri;
import android.os.Message;
import android.os.Handler;
import android.os.Looper;
import android.view.View;
import android.view.ViewGroup;
import android.webkit.JsPromptResult;
import android.webkit.JsResult;
import android.webkit.PermissionRequest;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;

import androidx.webkit.ProfileStore;
import androidx.webkit.WebViewCompat;
import androidx.webkit.WebViewFeature;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.StandardMessageCodec;
import io.flutter.plugin.platform.PlatformView;
import io.flutter.plugin.platform.PlatformViewFactory;

import org.json.JSONArray;
import org.json.JSONObject;
import java.nio.charset.StandardCharsets;
import java.io.ByteArrayInputStream;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Iterator;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

/** Android system Chromium WebView backend. All access runs on Flutter's UI thread. */
public final class FlutterChromiumWebviewPlugin implements FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware {
  private static final String PROFILE_PREFIX = "flutter_chromium_private_";
  private final Map<Integer, Browser> browsers = new HashMap<>();
  private Context context;
  private Context activityContext;
  private MethodChannel channel;
  private int nextId;
  private String session;
  @Override public void onAttachedToActivity(ActivityPluginBinding binding) { activityContext = binding.getActivity(); }
  @Override public void onDetachedFromActivity() { activityContext = null; }
  @Override public void onDetachedFromActivityForConfigChanges() { onDetachedFromActivity(); }
  @Override public void onReattachedToActivityForConfigChanges(ActivityPluginBinding binding) { onAttachedToActivity(binding); }
  private static void deleteProfileWhenUnused(String name, int attempt) {
    try { ProfileStore.getInstance().deleteProfile(name); }
    catch (IllegalStateException inUse) {
      // WebView destruction can release the provider asynchronously. Profiles
      // still held by the provider are retried, then cleaned on the next launch.
      if (attempt < 6) new Handler(Looper.getMainLooper()).postDelayed(
        () -> deleteProfileWhenUnused(name, attempt + 1), Math.min(2000, 100L << attempt));
    }
  }
  private static Map<String, Object> map(Object... values) {
    Map<String, Object> result = new HashMap<>();
    for (int index = 0; index < values.length; index += 2)
      result.put((String) values[index], values[index + 1]);
    return result;
  }

  @Override public void onAttachedToEngine(FlutterPluginBinding binding) {
    context = binding.getApplicationContext();
    channel = new MethodChannel(binding.getBinaryMessenger(), "flutter_chromium_webview");
    channel.setMethodCallHandler(this);
    binding.getPlatformViewRegistry().registerViewFactory("flutter_chromium_webview/browser",
      new PlatformViewFactory(StandardMessageCodec.INSTANCE) {
        @Override public PlatformView create(Context viewContext, int viewId, Object args) {
          Object id = args instanceof Map ? ((Map<?, ?>) args).get("browserId") : null;
          Browser browser = id instanceof Number ? browsers.get(((Number) id).intValue()) : null;
          if (browser == null) throw new IllegalStateException("Browser is unavailable");
          return new BrowserView(viewContext, browser);
        }
      });
  }
  @Override public void onDetachedFromEngine(FlutterPluginBinding binding) {
    channel.setMethodCallHandler(null);
    for (Browser browser : browsers.values()) browser.destroy();
    browsers.clear(); channel = null; context = null;
    activityContext = null;
  }
  private void event(Browser browser, String name, Map<String, Object> args) {
    if (channel == null || browser.closed) return;
    channel.invokeMethod("onBrowserEvent", map("browserId", browser.id, "event", name, "args", args));
  }
  private static String string(MethodCall call, String key) {
    Object value = call.argument(key);
    if (!(value instanceof String)) throw new IllegalArgumentException("Expected string: " + key);
    return (String) value;
  }
  private static String origin(String value) {
    Uri uri = Uri.parse(value);
    String scheme = uri.getScheme();
    String host = uri.getHost();
    if (!("http".equals(scheme) || "https".equals(scheme)) || host == null || host.isEmpty()
        || uri.getUserInfo() != null) throw new IllegalArgumentException("Expected HTTP(S) URL");
    int port = uri.getPort();
    return scheme + "://" + (host.contains(":") ? "[" + host + "]" : host).toLowerCase(java.util.Locale.ROOT)
      + (port == -1 || port == ("https".equals(scheme) ? 443 : 80) ? "" : ":" + port);
  }
  private static void documentUrl(String value) {
    origin(value);
    if (!value.equals(value.trim()) || Uri.parse(value).getFragment() != null)
      throw new IllegalArgumentException("Invalid document URL");
  }
  private void cleanupProfiles() {
    if (!WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE)) return;
    for (String name : ProfileStore.getInstance().getAllProfileNames()) {
      if (name.startsWith(PROFILE_PREFIX)) {
        // An active profile may belong to another Flutter engine. Never force deletion.
        try { ProfileStore.getInstance().deleteProfile(name); } catch (IllegalStateException ignored) { }
      }
    }
  }
  @Override public void onMethodCall(MethodCall call, MethodChannel.Result result) {
    try {
      if ("initialize".equals(call.method)) {
        String requested = string(call, "sessionId");
        if (!requested.equals(session)) {
          for (Browser browser : browsers.values()) browser.destroy();
          browsers.clear(); session = requested; cleanupProfiles();
        }
        result.success(true); return;
      }
      if ("getPlatformVersion".equals(call.method)) { result.success("Android " + android.os.Build.VERSION.RELEASE); return; }
      if ("createBrowser".equals(call.method)) {
        if (session == null) throw new IllegalStateException("Initialize before creating browsers");
        int id = ++nextId;
        Browser browser = new Browser(id, call);
        browsers.put(id, browser);
        result.success(map("browserId", id, "textureId", -1, "popupTextureId", -1));
        browser.web.loadUrl(string(call, "initialUrl")); return;
      }
      Object id = call.argument("browserId");
      Browser browser = id instanceof Number ? browsers.get(((Number) id).intValue()) : null;
      if ("disposeBrowser".equals(call.method)) {
        if (browser != null) { browsers.remove(browser.id); browser.destroy(); }
        result.success(null); return;
      }
      if (browser == null || browser.closed) { result.error("BROWSER_NOT_FOUND", "Browser is unavailable", null); return; }
      WebView web = browser.web;
      switch (call.method) {
        case "loadRequest": browser.document = null; web.loadUrl(string(call, "url")); break;
        case "loadHtmlString": {
          String html = string(call, "html"), url = string(call, "baseUrl");
          try {
            documentUrl(url);
            if (html.getBytes(StandardCharsets.UTF_8).length > 4194304) throw new IllegalArgumentException("HTML exceeds 4 MiB");
          } catch (IllegalArgumentException error) { result.error("INVALID_HTML", error.getMessage(), null); return; }
          browser.document = new HtmlDocument(url, html.getBytes(StandardCharsets.UTF_8));
          web.loadUrl(url); break;
        }
        case "reload":
          web.reload(); break;
        case "goBack": if (web.canGoBack()) web.goBack(); break;
        case "goForward": if (web.canGoForward()) web.goForward(); break;
        case "executeJavaScript": web.evaluateJavascript(string(call, "js"), ignored -> result.success(null)); return;
        case "setUserAgent": {
          String ua = string(call, "userAgent");
          if (ua.length() > 4096 || !ua.chars().allMatch(unit -> unit >= 32 && unit <= 126))
            throw new IllegalArgumentException("Invalid user-agent");
          web.getSettings().setUserAgentString(ua.isEmpty() ? null : ua); break;
        }
        case "setFocus":
          browser.pendingFocus = Boolean.TRUE.equals(call.argument("focused"));
          if (browser.pendingFocus && web.getWindowToken() != null) web.requestFocus();
          else if (!browser.pendingFocus) web.clearFocus(); break;
        case "updateBrowserSize": break; // PlatformView owns native layout and device scaling.
        case "closeJSDialog": {
          Object dialogId = call.argument("dialogId");
          JsResult dialog = dialogId instanceof Number ? browser.dialogs.remove(((Number) dialogId).intValue()) : null;
          if (dialog != null) {
            if (!Boolean.TRUE.equals(call.argument("success"))) dialog.cancel();
            else if (dialog instanceof JsPromptResult) ((JsPromptResult) dialog).confirm(string(call, "userInput"));
            else dialog.confirm();
          }
          break;
        }
        case "closeContextMenu": break; // Android handles native selection UI.
        case "sendPointerEvent": result.error("UNSUPPORTED_FEATURE", "Android uses native touch and pointer input", null); return;
        default: result.notImplemented(); return;
      }
      result.success(null);
    } catch (Exception error) { result.error("ANDROID_WEBVIEW_ERROR", error.toString(), null); }
  }

  private final class Browser {
    final int id;
    final WebView web;
    final MutableContextWrapper viewContext;
    BrowserView viewOwner;
    final Map<Integer, JsResult> dialogs = new HashMap<>();
    String profile;
    volatile HtmlDocument document;
    boolean closed;
    boolean pendingFocus;
    int nextDialog;
    @SuppressLint("SetJavaScriptEnabled") Browser(int id, MethodCall call) throws Exception {
      this.id = id;
      viewContext = new MutableContextWrapper(activityContext == null ? context : activityContext);
      web = new WebView(viewContext);
      web.addOnAttachStateChangeListener(new View.OnAttachStateChangeListener() {
        @Override public void onViewAttachedToWindow(View view) { if (pendingFocus) web.requestFocus(); }
        @Override public void onViewDetachedFromWindow(View view) { web.clearFocus(); }
      });
      try {
        boolean gesture = !Boolean.FALSE.equals(call.argument("mediaPlaybackRequiresUserGesture"));
        String explicitProfile = call.argument("profileName");
        if (explicitProfile != null || !gesture) {
          if (!WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE))
            throw new UnsupportedOperationException("Persistent profiles and isolated autoplay require WebView MULTI_PROFILE support");
          profile = explicitProfile != null ? explicitProfile : PROFILE_PREFIX + UUID.randomUUID().toString().replace("-", "");
          WebViewCompat.setProfile(web, profile);
        }
        WebSettings settings = web.getSettings();
        settings.setJavaScriptEnabled(true); settings.setDomStorageEnabled(true);
        settings.setAllowFileAccess(false); settings.setAllowContentAccess(false);
        settings.setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);
        settings.setMediaPlaybackRequiresUserGesture(gesture);
        settings.setSupportMultipleWindows(true);
        installBridge(new JSONObject(string(call, "javascriptChannels")));
        web.setWebViewClient(new WebViewClient() {
          @Override public WebResourceResponse shouldInterceptRequest(WebView view, WebResourceRequest request) {
            HtmlDocument snapshot = document;
            if (snapshot == null || !request.isForMainFrame() || !"GET".equals(request.getMethod())
                || !snapshot.url.equals(request.getUrl().toString())) return null;
            Map<String, String> headers = new HashMap<>();
            headers.put("Cache-Control", "no-store");
            return new WebResourceResponse("text/html", "UTF-8", 200, "OK", headers,
              new ByteArrayInputStream(snapshot.bytes));
          }
          @Override public void onPageStarted(WebView view, String url, Bitmap icon) {
            cancelDialogs();
            event(Browser.this, "transientUiDismissed", map());
            event(Browser.this, "urlChanged", map("url", url)); loading(true);
          }
          @Override public void onPageFinished(WebView view, String url) {
            event(Browser.this, "urlChanged", map("url", url)); loading(false);
          }
          @Override public void doUpdateVisitedHistory(WebView view, String url, boolean reload) {
            event(Browser.this, "urlChanged", map("url", url));
          }
          @Override public void onReceivedError(WebView view, WebResourceRequest request, WebResourceError error) {
            if (request.isForMainFrame()) event(Browser.this, "loadError", map("errorCode", error.getErrorCode(),
              "errorText", error.getDescription().toString(), "failedUrl", request.getUrl().toString()));
          }
          @Override public boolean onRenderProcessGone(WebView view, android.webkit.RenderProcessGoneDetail detail) {
            event(Browser.this, "loadError", map("errorCode", -1, "errorText", "WebView renderer exited", "failedUrl", view.getUrl() == null ? "" : view.getUrl()));
            browsers.remove(id); destroy(); return true;
          }
        });
        web.setWebChromeClient(new WebChromeClient() {
          @Override public void onReceivedTitle(WebView view, String title) { event(Browser.this, "titleChanged", map("title", title == null ? "" : title)); }
          @Override public void onPermissionRequest(PermissionRequest request) { request.deny(); }
          @Override public boolean onJsAlert(WebView view, String url, String text, JsResult result) { return dialog(0, text, "", result); }
          @Override public boolean onJsConfirm(WebView view, String url, String text, JsResult result) { return dialog(1, text, "", result); }
          @Override public boolean onJsPrompt(WebView view, String url, String text, String value, JsPromptResult result) { return dialog(2, text, value, result); }
          @Override public boolean onJsBeforeUnload(WebView view, String url, String text, JsResult result) { result.cancel(); return true; }
          @Override public boolean onCreateWindow(WebView view, boolean dialog, boolean gesture, Message result) {
            String url = view.getHitTestResult().getExtra();
            event(Browser.this, "newWindowRequested", map("url", url == null ? "" : url, "targetFrameName", "",
              "targetDisposition", 0, "userGesture", gesture, "sourceBrowserId", id)); return false;
          }
          @Override public void onShowCustomView(View view, CustomViewCallback callback) { callback.onCustomViewHidden(); }
        });
      } catch (Exception error) { destroy(); throw error; }
    }
    void loading(boolean value) { event(this, "loadingStateChanged", map("isLoading", value, "canGoBack", web.canGoBack(), "canGoForward", web.canGoForward())); }
    boolean dialog(int type, String text, String value, JsResult result) {
      int dialogId = ++nextDialog; dialogs.put(dialogId, result);
      event(this, "jsDialog", map("dialogId", dialogId, "type", type, "message", text, "defaultPrompt", value == null ? "" : value)); return true;
    }
    void installBridge(JSONObject policies) throws Exception {
      if (policies.length() == 0) return;
      if (!WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER)
          || !WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT))
        throw new UnsupportedOperationException("Origin-checked channels require an updated Android WebView");
      JSONObject bindings = new JSONObject();
      Set<String> allOrigins = new HashSet<>();
      Iterator<String> names = policies.keys(); int index = 0;
      while (names.hasNext()) {
        String name = names.next();
        if (!name.matches("[A-Za-z_$][A-Za-z0-9_$]{0,127}")) throw new IllegalArgumentException("Invalid channel name");
        JSONArray raw = policies.getJSONArray(name); Set<String> origins = new HashSet<>();
        for (int n = 0; n < raw.length(); n++) {
          String value = raw.getString(n); documentUrl(value);
          Uri uri = Uri.parse(value);
          if (uri.getQuery() != null || !(uri.getPath() == null || uri.getPath().isEmpty() || uri.getPath().equals("/")))
            throw new IllegalArgumentException("Expected exact origin");
          origins.add(origin(value));
        }
        if (origins.isEmpty()) throw new IllegalArgumentException("Empty origin allowlist");
        String object = "__chromiumNative" + index++; bindings.put(name, object); allOrigins.addAll(origins);
        WebViewCompat.addWebMessageListener(web, object, origins, (view, message, sourceOrigin, mainFrame, proxy) -> {
          if (closed || !mainFrame || message.getType() != androidx.webkit.WebMessageCompat.TYPE_STRING) return;
          try {
            String actual = origin(sourceOrigin.toString());
            if (!origins.contains(actual)) return;
            JSONObject payload = new JSONObject(message.getData());
            String text = payload.getString("message");
            if (text.getBytes(StandardCharsets.UTF_8).length > 65536 || !actual.equals(payload.getString("origin"))
                || !payload.getString("href").equals(web.getUrl()) || !actual.equals(origin(web.getUrl()))) return;
            event(this, "javascriptMessage", map("channel", name, "message", text, "origin", actual));
          } catch (Exception ignored) { /* Untrusted/opaque/malformed messages are dropped. */ }
        });
      }
      String script = "(()=>{if(window.top!==window)return;const bindings=" + bindings + ";const securityOrigin=window.origin;"
        + "Object.defineProperty(window,'chromiumPostMessage',{configurable:false,writable:false,value:(name,message)=>{"
        + "if(typeof name!=='string'||typeof message!=='string'||new TextEncoder().encode(message).length>65536||!Object.hasOwn(bindings,name))return false;"
        + "const bridge=window[bindings[name]];if(!bridge||securityOrigin==='null')return false;"
        + "bridge.postMessage(JSON.stringify({message,origin:securityOrigin,href:location.href}));return true;}});})();";
      WebViewCompat.addDocumentStartJavaScript(web, script, allOrigins);
    }
    void destroy() {
      if (closed) return; closed = true;
      document = null;
      viewOwner = null;
      cancelDialogs();
      if (web.getParent() instanceof ViewGroup) ((ViewGroup) web.getParent()).removeView(web);
      web.stopLoading(); web.setWebChromeClient(null); web.setWebViewClient(new WebViewClient()); web.destroy();
      if (profile != null && profile.startsWith(PROFILE_PREFIX)) {
        String retiredProfile = profile; profile = null;
        deleteProfileWhenUnused(retiredProfile, 0);
      }
    }
    void cancelDialogs() {
      for (JsResult dialog : dialogs.values()) dialog.cancel();
      dialogs.clear();
    }
  }
  private static final class HtmlDocument {
    final String url;
    final byte[] bytes;
    HtmlDocument(String url, byte[] bytes) { this.url = url; this.bytes = bytes; }
  }
  private static final class BrowserView implements PlatformView {
    private final Browser browser;
    private final WebView web;
    private final MutableContextWrapper viewContext;
    private final Context applicationContext;
    private final android.app.Activity activity;
    BrowserView(Context context, Browser browser) {
      this.browser = browser; web = browser.web;
      viewContext = browser.viewContext;
      applicationContext = context.getApplicationContext();
      Context unwrapped = context;
      while (unwrapped instanceof android.content.ContextWrapper && !(unwrapped instanceof android.app.Activity))
        unwrapped = ((android.content.ContextWrapper) unwrapped).getBaseContext();
      activity = unwrapped instanceof android.app.Activity ? (android.app.Activity) unwrapped : null;
      viewContext.setBaseContext(context);
      web.setAlpha(1f);
      web.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_AUTO);
      if (web.getParent() instanceof ViewGroup) ((ViewGroup) web.getParent()).removeView(web);
      browser.viewOwner = this;
    }
    @Override public View getView() { return web; }
    @Override public void dispose() {
      if (browser.viewOwner == this) {
        browser.viewOwner = null;
        if (web.getParent() instanceof ViewGroup) ((ViewGroup) web.getParent()).removeView(web);
        // A detached WebView is treated as hidden by Chromium, which pauses media. Park it in a
        // 1x1 fully transparent (but VISIBLE) host so playback continues without the Flutter widget.
        if (activity != null && !browser.closed) {
          View decor = activity.getWindow().getDecorView();
          if (decor instanceof ViewGroup) {
            web.setAlpha(0f);
            web.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS);
            ((ViewGroup) decor).addView(web, new ViewGroup.LayoutParams(1, 1));
          }
        } else {
          viewContext.setBaseContext(applicationContext);
        }
      }
    }
  }
}
