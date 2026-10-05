#pragma once

#include <algorithm>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <utility>
#include "include/cef_parser.h"
#include "include/cef_request_handler.h"

namespace chromium_html {
inline constexpr size_t kMaxHtmlBytes = 4 * 1024 * 1024;

class Response : public CefResourceHandler {
 public:
  explicit Response(std::shared_ptr<const std::string> html) : html_(std::move(html)) {}
  bool Open(CefRefPtr<CefRequest>, bool& handle, CefRefPtr<CefCallback>) override {
    handle = true;
    return true;
  }
  void GetResponseHeaders(CefRefPtr<CefResponse> response, int64_t& length,
      CefString&) override {
    response->SetStatus(200);
    response->SetMimeType("text/html");
    response->SetCharset("utf-8");
    response->SetHeaderByName("Cache-Control", "no-store", true);
    response->SetHeaderByName("X-Content-Type-Options", "nosniff", true);
    length = static_cast<int64_t>(html_->size());
  }
  bool Read(void* out, int count, int& read, CefRefPtr<CefResourceReadCallback>) override {
    read = 0;
    if (count <= 0 || offset_ >= html_->size()) return false;
    read = static_cast<int>(std::min(static_cast<size_t>(count), html_->size() - offset_));
    std::memcpy(out, html_->data() + offset_, read);
    offset_ += read;
    return true;
  }
  bool Skip(int64_t count, int64_t& skipped, CefRefPtr<CefResourceSkipCallback>) override {
    if (count < 0) { skipped = -2; return false; }
    skipped = std::min(count, static_cast<int64_t>(html_->size() - offset_));
    offset_ += static_cast<size_t>(skipped);
    return true;
  }
  void Cancel() override {}
 private:
  const std::shared_ptr<const std::string> html_;
  size_t offset_ = 0;
  IMPLEMENT_REFCOUNTING(Response);
};

class Request : public CefResourceRequestHandler {
 public:
  explicit Request(std::shared_ptr<const std::string> html) : html_(std::move(html)) {}
  CefRefPtr<CefResourceHandler> GetResourceHandler(CefRefPtr<CefBrowser>,
      CefRefPtr<CefFrame>, CefRefPtr<CefRequest>) override { return new Response(html_); }
 private:
  const std::shared_ptr<const std::string> html_;
  IMPLEMENT_REFCOUNTING(Request);
};

// UI writes and IO reads are synchronized. Each response owns an immutable
// snapshot, so replacement/disposal cannot invalidate an in-flight read.
class Documents : public CefRequestHandler {
 public:
  bool Set(const std::string& html, const std::string& url, std::string& canonical) {
    CefURLParts parts;
    if (html.size() > kMaxHtmlBytes || !CefParseURL(url, parts)) return false;
    const auto scheme = CefString(&parts.scheme).ToString();
    if ((scheme != "http" && scheme != "https") ||
        CefString(&parts.host).empty() || !CefString(&parts.username).empty() ||
        !CefString(&parts.password).empty() || url.find('#') != std::string::npos)
      return false;
    canonical = CefString(&parts.spec).ToString();
    auto data = std::make_shared<const std::string>(html);
    std::lock_guard<std::mutex> lock(mutex_);
    url_ = canonical;
    html_ = std::move(data);
    return true;
  }
  void Clear() {
    std::lock_guard<std::mutex> lock(mutex_);
    html_.reset();
    url_.clear();
  }
  CefRefPtr<CefResourceRequestHandler> GetResourceRequestHandler(
      CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, CefRefPtr<CefRequest> request,
      bool navigation, bool download, const CefString&, bool& disable_default) override {
    if (!frame || !frame->IsMain() || !navigation || download ||
        request->GetResourceType() != RT_MAIN_FRAME || request->GetMethod() != "GET")
      return nullptr;
    std::lock_guard<std::mutex> lock(mutex_);
    if (!html_ || request->GetURL().ToString() != url_) return nullptr;
    disable_default = true;
    return new Request(html_);
  }
 private:
  std::mutex mutex_;
  std::string url_;
  std::shared_ptr<const std::string> html_;
  IMPLEMENT_REFCOUNTING(Documents);
};
}  // namespace chromium_html
