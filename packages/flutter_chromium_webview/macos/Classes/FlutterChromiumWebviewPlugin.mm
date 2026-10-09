#import "FlutterChromiumWebviewPlugin.h"
#import "ChromiumBackend.h"
#include "include/cef_application_mac.h"

@interface ChromiumWebViewApplication () <CefAppProtocol>
@property(nonatomic) BOOL handlingSendEvent;
- (void)finishTermination:(id)sender;
@end

@implementation ChromiumWebViewApplication
- (BOOL)isHandlingSendEvent { return self.handlingSendEvent; }
- (void)sendEvent:(NSEvent*)event {
  CefScopedSendingEvent scope;
  [super sendEvent:event];
}
- (void)terminate:(id)sender {
  chromium_macos::Runtime::Shared().RequestShutdown([self, sender] { [self finishTermination:sender]; });
}
- (void)finishTermination:(id)sender { [super terminate:sender]; }
@end

@implementation FlutterChromiumWebviewPlugin {
  FlutterMethodChannel* _channel;
  id _windowCloseObserver;
  std::unique_ptr<chromium_macos::Core> _core;
}
+ (void)registerWithRegistrar:(id<FlutterPluginRegistrar>)registrar {
  FlutterChromiumWebviewPlugin* plugin = [[self alloc] init];
  plugin->_channel = [FlutterMethodChannel methodChannelWithName:@"flutter_chromium_webview" binaryMessenger:registrar.messenger];
  plugin->_core = std::make_unique<chromium_macos::Core>(registrar, plugin->_channel);
  [registrar addMethodCallDelegate:plugin channel:plugin->_channel];
}
- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
  if (_core) _core->Handle(call, result);
  else result([FlutterError errorWithCode:@"DETACHED" message:@"Flutter engine detached" details:nil]);
}
- (void)dealloc {
  _core.reset();
}
@end
