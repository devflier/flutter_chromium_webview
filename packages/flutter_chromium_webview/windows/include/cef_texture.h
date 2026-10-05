#ifndef FLUTTER_CHROMIUM_WEBVIEW_CEF_TEXTURE_H_
#define FLUTTER_CHROMIUM_WEBVIEW_CEF_TEXTURE_H_

#include <flutter/texture_registrar.h>
#include <mutex>
#include <memory>
#include <vector>

class FlutterChromiumTexture {
 public:
  FlutterChromiumTexture();
  ~FlutterChromiumTexture();

  // Returns the texture variant to register with Flutter.
  flutter::TextureVariant* GetTextureVariant();

  // Safely updates the internal buffer with BGRA data from CEF.
  // Converts BGRA to RGBA internally.
  void UpdateBuffer(const void* buffer, int width, int height);

 private:
  const FlutterDesktopPixelBuffer* CopyPixels(size_t width, size_t height);

  std::mutex mutex_;
  struct Frame {
    std::vector<uint8_t> pixels;
    size_t width;
    size_t height;
  };
  struct Lease {
    std::shared_ptr<const Frame> frame;
    FlutterDesktopPixelBuffer buffer;
  };
  std::shared_ptr<const Frame> frame_;
  
  std::unique_ptr<flutter::TextureVariant> variant_;
};

#endif  // FLUTTER_CHROMIUM_WEBVIEW_CEF_TEXTURE_H_
