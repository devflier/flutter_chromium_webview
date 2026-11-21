#ifndef FLUTTER_CHROMIUM_WEBVIEW_CEF_TEXTURE_H_
#define FLUTTER_CHROMIUM_WEBVIEW_CEF_TEXTURE_H_

#include <flutter/texture_registrar.h>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <mutex>
#include <vector>

class FlutterChromiumTexture {
 public:
  FlutterChromiumTexture();
  ~FlutterChromiumTexture();

  struct DirtyRect {
    int x = 0;
    int y = 0;
    int width = 0;
    int height = 0;
  };

  // Returns the texture variant to register with Flutter.
  flutter::TextureVariant* GetTextureVariant();

  // Safely updates the internal buffer with BGRA data from CEF.
  // Converts BGRA to RGBA internally using reusable pooled buffers.
  void UpdateBuffer(const void* buffer, int width, int height);

  // Safely updates the internal buffer using CEF's dirty rectangles when
  // possible, avoiding redundant full-frame BGRA->RGBA copies on small UI
  // repaints when no Flutter engine lease holds the current frame.
  void UpdateBuffer(const void* buffer,
                    int width,
                    int height,
                    const std::vector<DirtyRect>& dirty_rects);

  // Releases retained frame buffers immediately while keeping any currently
  // engine-leased pixel buffer alive until Flutter invokes its release callback.
  void Clear();

  // Diagnostic counter of heap Frame buffer allocations performed by this texture.
  size_t allocation_count() const {
    return allocation_count_.load(std::memory_order_relaxed);
  }

  // Diagnostic count of retained pooled frames and total retained capacity bytes.
  size_t pooled_frame_count() const;
  size_t pooled_capacity_bytes() const;

 private:
  static constexpr size_t kMaxPooledFrames = 2;

  struct Frame {
    std::vector<uint8_t> pixels;
    size_t width = 0;
    size_t height = 0;
  };

  struct Pool {
    std::mutex mutex;
    std::vector<std::shared_ptr<Frame>> free_frames;
    bool cleared = false;

    void Return(std::shared_ptr<Frame> frame);
  };

  struct Lease {
    std::shared_ptr<Frame> frame;
    std::weak_ptr<Pool> pool;
    FlutterDesktopPixelBuffer buffer = {};
  };

  std::shared_ptr<Frame> AcquireFrame(size_t required_size);
  const FlutterDesktopPixelBuffer* CopyPixels(size_t width, size_t height);

  std::mutex mutex_;
  std::shared_ptr<Frame> frame_;
  std::shared_ptr<Pool> pool_;
  std::atomic<size_t> allocation_count_{0};

  std::unique_ptr<flutter::TextureVariant> variant_;
};

#endif  // FLUTTER_CHROMIUM_WEBVIEW_CEF_TEXTURE_H_
