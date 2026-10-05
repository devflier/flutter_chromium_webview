#pragma once

#include <map>
#include <optional>
#include <set>
#include <string>
#include <utility>
#include "include/cef_app.h"
#include "include/cef_parser.h"
#include "include/cef_v8.h"

namespace chromium_bridge {
inline constexpr char kMessage[] = "flutter_chromium_webview.postMessage";
inline constexpr size_t kMaxMessageBytes = 65536;

// Opaque origins and subframes are deliberately excluded from the host bridge.
inline std::string Origin(const std::string& url) {
  CefURLParts parts;
  if (!CefParseURL(url, parts)) return {};
  auto scheme = CefString(&parts.scheme).ToString();
  if (scheme != "http" && scheme != "https") return {};
  auto origin = CefString(&parts.origin).ToString();
  while (!origin.empty() && origin.back() == '/') origin.pop_back();
  return origin;
}

struct Message { std::string channel, message, origin; };

class Policy {
 public:
  void Configure(const std::string& json) {
    channels_.clear();
    auto value = CefParseJSON(json, JSON_PARSER_RFC);
    if (!value || value->GetType() != VTYPE_DICTIONARY) return;
    auto dictionary = value->GetDictionary();
    CefDictionaryValue::KeyList keys;
    dictionary->GetKeys(keys);
    for (const auto& key : keys) {
      if (dictionary->GetType(key) != VTYPE_LIST) continue;
      auto list = dictionary->GetList(key);
      for (size_t i = 0; i < list->GetSize(); ++i) {
        if (list->GetType(i) != VTYPE_STRING) continue;
        auto origin = Origin(list->GetString(i).ToString());
        if (!origin.empty()) channels_[key.ToString()].insert(origin);
      }
    }
  }

  std::optional<Message> Receive(CefRefPtr<CefFrame> frame,
      CefProcessId source, CefRefPtr<CefProcessMessage> message) const {
    if (source != PID_RENDERER || !frame || !frame->IsMain() ||
        message->GetName() != kMessage) return std::nullopt;
    auto args = message->GetArgumentList();
    if (args->GetSize() != 4 || args->GetType(0) != VTYPE_STRING ||
        args->GetType(1) != VTYPE_STRING || args->GetType(2) != VTYPE_STRING ||
        args->GetType(3) != VTYPE_STRING)
      return std::nullopt;
    Message result{args->GetString(0).ToString(), args->GetString(1).ToString(),
                   Origin(frame->GetURL().ToString())};
    // Drop queued messages from a document which has since navigated away.
    if (args->GetString(2) != frame->GetURL() || result.origin.empty() ||
        args->GetString(3).ToString() != result.origin ||
        result.message.size() > kMaxMessageBytes) return std::nullopt;
    auto found = channels_.find(result.channel);
    if (found == channels_.end() || !found->second.count(result.origin))
      return std::nullopt;
    return result;
  }
 private:
  std::map<std::string, std::set<std::string>> channels_;
};

class PostMessage : public CefV8Handler {
 public:
  explicit PostMessage(std::string origin) : origin_(std::move(origin)) {}
  bool Execute(const CefString&, CefRefPtr<CefV8Value>,
      const CefV8ValueList& args, CefRefPtr<CefV8Value>& result,
      CefString& exception) override {
    if (args.size() != 2 || !args[0]->IsString() || !args[1]->IsString()) {
      exception = "chromiumPostMessage requires a channel and string message";
      return true;
    }
    auto channel = args[0]->GetStringValue().ToString();
    auto text = args[1]->GetStringValue().ToString();
    if (channel.empty() || channel.size() > 128 || text.size() > kMaxMessageBytes) {
      exception = "chromiumPostMessage exceeds the channel or message limit";
      return true;
    }
    auto frame = CefV8Context::GetCurrentContext()->GetFrame();
    if (!frame || !frame->IsMain()) { result = CefV8Value::CreateBool(false); return true; }
    auto message = CefProcessMessage::Create(kMessage);
    auto values = message->GetArgumentList();
    values->SetString(0, channel);
    values->SetString(1, text);
    values->SetString(2, frame->GetURL());
    values->SetString(3, origin_);
    frame->SendProcessMessage(PID_BROWSER, message);
    // Acceptance is asynchronous. This return value only confirms dispatch.
    result = CefV8Value::CreateBool(true);
    return true;
  }
 private:
  const std::string origin_;
  IMPLEMENT_REFCOUNTING(PostMessage);
};

class RendererApp : public CefApp, public CefRenderProcessHandler {
 public:
  CefRefPtr<CefRenderProcessHandler> GetRenderProcessHandler() override { return this; }
  void OnContextCreated(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame,
      CefRefPtr<CefV8Context> context) override {
    if (!frame->IsMain()) return;
    // Capture the document's security origin before page scripts can replace
    // window.origin. CSP-sandboxed HTTP documents have an opaque "null" origin.
    auto origin_value = context->GetGlobal()->GetValue("origin");
    const auto origin = origin_value && origin_value->IsString()
      ? origin_value->GetStringValue().ToString() : std::string();
    context->GetGlobal()->SetValue("chromiumPostMessage",
      CefV8Value::CreateFunction("chromiumPostMessage", new PostMessage(origin)),
      static_cast<cef_v8_propertyattribute_t>(V8_PROPERTY_ATTRIBUTE_READONLY |
        V8_PROPERTY_ATTRIBUTE_DONTDELETE));
  }
 private:
  IMPLEMENT_REFCOUNTING(RendererApp);
};
}  // namespace chromium_bridge
