#pragma once
#import <Foundation/Foundation.h>
#include "include/cef_app.h"
#include "IpcServer.h"

class ChromiumHostApp : public CefApp, public CefBrowserProcessHandler {
public:
    ChromiumHostApp(NSString* socketPath, NSString* expectedToken, pid_t parentPid);

    virtual CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override {
        return this;
    }

    virtual void OnContextInitialized() override;
    virtual void OnBeforeCommandLineProcessing(const CefString& process_type, CefRefPtr<CefCommandLine> command_line) override;

    void StartIpcServer();
    bool StartupFailed() const { return _startupFailed; }

private:
    NSString* _socketPath;
    NSString* _expectedToken;
    pid_t _parentPid;
    bool _startupFailed = false;
    
    // We will use an Objective-C wrapper object to act as the delegate for IPC Server.
    void* _delegateWrapper;
    
    IMPLEMENT_REFCOUNTING(ChromiumHostApp);
};
