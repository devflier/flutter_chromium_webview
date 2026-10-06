import Flutter
import UIKit
import WebKit

class ScriptHandler: NSObject, WKScriptMessageHandler {
    var browserId: Int
    var channel: FlutterMethodChannel?
    
    init(browserId: Int, channel: FlutterMethodChannel?) {
        self.browserId = browserId
        self.channel = channel
    }
    
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        channel?.invokeMethod("onBrowserEvent", arguments: [
            "browserId": browserId,
            "event": message.name,
            "args": message.body
        ])
    }
}

public class FlutterChromiumWebviewPlugin: NSObject, FlutterPlugin {
  private var channel: FlutterMethodChannel?
  private var webViews: [Int: WKWebView] = [:]
  private var nextBrowserId = 1

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "flutter_chromium_webview", binaryMessenger: registrar.messenger())
    let instance = FlutterChromiumWebviewPlugin()
    instance.channel = channel
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]
    
    switch call.method {
    case "initialize":
      result(true)
      
    case "createBrowser":
      let browserId = nextBrowserId
      nextBrowserId += 1
      
      let config = WKWebViewConfiguration()
      config.allowsInlineMediaPlayback = true
      if #available(iOS 10.0, *) {
          config.mediaTypesRequiringUserActionForPlayback = []
      }
      
      if let jsonChannels = args?["javascriptChannels"] as? String,
         let data = jsonChannels.data(using: .utf8),
         let channels = try? JSONSerialization.jsonObject(with: data) as? [String] {
          let handler = ScriptHandler(browserId: browserId, channel: self.channel)
          for channelName in channels {
              config.userContentController.add(handler, name: channelName)
          }
      }
      
      let webView = WKWebView(frame: .zero, configuration: config)
      webViews[browserId] = webView
      
      if let initialUrlString = args?["initialUrl"] as? String,
         let initialUrl = URL(string: initialUrlString) {
          webView.load(URLRequest(url: initialUrl))
      }
      
      result([
        "browserId": browserId,
        "textureId": 0,
        "popupTextureId": 0
      ])
      
    case "disposeBrowser":
      if let browserId = args?["browserId"] as? Int {
        webViews.removeValue(forKey: browserId)
      }
      result(nil)
      
    case "loadUrl":
      if let browserId = args?["browserId"] as? Int,
         let urlString = args?["url"] as? String,
         let webView = webViews[browserId],
         let url = URL(string: urlString) {
        webView.load(URLRequest(url: url))
      }
      result(nil)
      
    case "loadHtml":
      if let browserId = args?["browserId"] as? Int,
         let html = args?["html"] as? String,
         let baseUrlString = args?["baseUrl"] as? String,
         let webView = webViews[browserId],
         let baseUrl = URL(string: baseUrlString) {
        webView.loadHTMLString(html, baseURL: baseUrl)
      }
      result(nil)
      
    case "executeJavaScript":
      if let browserId = args?["browserId"] as? Int,
         let js = args?["javaScript"] as? String,
         let webView = webViews[browserId] {
        webView.evaluateJavaScript(js) { _, _ in }
      }
      result(nil)
      
    default:
      result(nil)
    }
  }
}
