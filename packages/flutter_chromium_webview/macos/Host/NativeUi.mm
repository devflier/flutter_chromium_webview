#import "HostBrowserClient.h"

void HostBrowserClient::UiEvent(int64_t browserId, NSString* name, NSDictionary* args) {
    IPC::Message event;
    event.type = "event";
    event.payload = @{@"browserId": @(browserId), @"name": name, @"args": args};
    if (on_message_) on_message_(event);
}

bool HostBrowserClient::OnJSDialog(CefRefPtr<CefBrowser> browser, const CefString&,
    JSDialogType type, const CefString& message, const CefString& prompt,
    CefRefPtr<CefJSDialogCallback> callback, bool&) {
    const auto browserId = GetBrowserId(browser);
    const int id = next_ui_id_++;
    dialogs_[id] = {browserId, callback};
    UiEvent(browserId, @"jsDialog", @{@"dialogId": @(id), @"type": @(type),
        @"message": [NSString stringWithUTF8String:message.ToString().c_str()],
        @"defaultPrompt": [NSString stringWithUTF8String:prompt.ToString().c_str()]});
    return true;
}

void HostBrowserClient::CloseJSDialog(int64_t browserId, int id, bool success, const std::string& input) {
    auto found = dialogs_.find(id);
    if (found == dialogs_.end() || found->second.first != browserId) return;
    auto callback = found->second.second;
    dialogs_.erase(found);
    callback->Continue(success, input);
}

static NSArray* SerializeMenu(CefRefPtr<CefMenuModel> model) {
    NSMutableArray* items = [NSMutableArray array];
    for (size_t i = 0; i < model->GetCount(); ++i) {
        NSMutableDictionary* item = [@{@"commandId": @(model->GetCommandIdAt(i)),
            @"label": [NSString stringWithUTF8String:model->GetLabelAt(i).ToString().c_str()],
            @"type": @(model->GetTypeAt(i)), @"isEnabled": @(model->IsEnabledAt(i)),
            @"isChecked": @(model->IsCheckedAt(i))} mutableCopy];
        if (model->GetTypeAt(i) == MENUITEMTYPE_SUBMENU)
            item[@"subMenu"] = SerializeMenu(model->GetSubMenuAt(i));
        [items addObject:item];
    }
    return items;
}

bool HostBrowserClient::RunContextMenu(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame>,
    CefRefPtr<CefContextMenuParams> params, CefRefPtr<CefMenuModel> model,
    CefRefPtr<CefRunContextMenuCallback> callback) {
    const auto browserId = GetBrowserId(browser);
    const int id = next_ui_id_++;
    menus_[id] = {browserId, callback};
    UiEvent(browserId, @"contextMenuRequested", @{@"menuId": @(id),
        @"x": @(params->GetXCoord()), @"y": @(params->GetYCoord()), @"items": SerializeMenu(model)});
    return true;
}

void HostBrowserClient::CloseContextMenu(int64_t browserId, int id, int commandId) {
    auto found = menus_.find(id);
    if (found == menus_.end() || found->second.first != browserId) return;
    auto callback = found->second.second;
    menus_.erase(found);
    if (commandId < 0) callback->Cancel();
    else callback->Continue(commandId, EVENTFLAG_NONE);
}

void HostBrowserClient::OnResetDialogState(CefRefPtr<CefBrowser> browser) {
    const auto browserId = GetBrowserId(browser);
    std::vector<CefRefPtr<CefJSDialogCallback>> dialogs;
    std::vector<CefRefPtr<CefRunContextMenuCallback>> menus;
    for (auto it = dialogs_.begin(); it != dialogs_.end();) {
        if (it->second.first == browserId) { dialogs.push_back(it->second.second); it = dialogs_.erase(it); }
        else ++it;
    }
    for (auto it = menus_.begin(); it != menus_.end();) {
        if (it->second.first == browserId) { menus.push_back(it->second.second); it = menus_.erase(it); }
        else ++it;
    }
    // Remove ownership before CEF callbacks, which can synchronously re-enter.
    if (!dialogs.empty() || !menus.empty()) UiEvent(browserId, @"transientUiDismissed", @{});
    for (auto callback : dialogs) callback->Continue(false, "");
    for (auto callback : menus) callback->Cancel();
}

void HostBrowserClient::OnPopupShow(CefRefPtr<CefBrowser> browser, bool show) {
    UiEvent(GetBrowserId(browser), @"popupShow", @{@"show": @(show)});
}

void HostBrowserClient::OnPopupSize(CefRefPtr<CefBrowser> browser, const CefRect& rect) {
    UiEvent(GetBrowserId(browser), @"popupSize", @{@"x": @(rect.x), @"y": @(rect.y),
        @"width": @(rect.width), @"height": @(rect.height)});
}
