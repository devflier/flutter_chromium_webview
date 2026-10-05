#include "include/cef_texture.h"
#include <array>
#include <atomic>
#include <iostream>
#include <thread>

namespace {
void Require(bool value, const char* message) {
  if (!value) { std::cerr << message << std::endl; std::exit(1); }
}
const FlutterDesktopPixelBuffer* Sample(FlutterChromiumTexture& texture) {
  return std::get<flutter::PixelBufferTexture>(*texture.GetTextureVariant()).CopyPixelBuffer(1, 1);
}
void Release(const FlutterDesktopPixelBuffer* buffer) {
  buffer->release_callback(buffer->release_context);
}
}
int main() {
  std::array<uint8_t, 4> first = {1, 2, 3, 255};
  std::array<uint8_t, 16> resized = {4, 5, 6, 255, 4, 5, 6, 255, 4, 5, 6, 255, 4, 5, 6, 255};
  const FlutterDesktopPixelBuffer* retained;
  {
    FlutterChromiumTexture texture;
    Require(Sample(texture) == nullptr, "Empty texture must not expose uninitialized pixels");
    texture.UpdateBuffer(first.data(), 1, 1);
    retained = Sample(texture);
    Require(retained->buffer[0] == 3 && retained->buffer[2] == 1, "BGRA conversion failed");
    texture.UpdateBuffer(resized.data(), 2, 2);
    Require(retained->width == 1 && retained->buffer[0] == 3, "Resize invalidated in-flight frame");
    texture.UpdateBuffer(first.data(), -1, 1);
    texture.UpdateBuffer(first.data(), 16385, 1);
    texture.UpdateBuffer(nullptr, 1, 1);
    auto* valid = Sample(texture);
    Require(valid->width == 2 && valid->height == 2, "Invalid paint replaced valid frame");
    Release(valid);
  }
  Require(retained->buffer[0] == 3, "Texture disposal invalidated engine-owned frame");
  Release(retained);

  FlutterChromiumTexture texture;
  texture.UpdateBuffer(first.data(), 1, 1);
  std::atomic<bool> done = false;
  std::thread producer([&] {
    for (int i = 0; i < 10000; ++i) texture.UpdateBuffer(i % 2 ? first.data() : resized.data(), i % 2 ? 1 : 2, i % 2 ? 1 : 2);
    done = true;
  });
  do {
    auto* frame = Sample(texture);
    Require(frame && (frame->width == 1 || frame->width == 2), "Concurrent sample has invalid dimensions");
    const uint8_t expected = frame->width == 1 ? 3 : 6;
    std::this_thread::yield();
    for (size_t i = 0; i < frame->width * frame->height * 4; i += 4) Require(frame->buffer[i] == expected, "Concurrent paint overwrote sampled frame");
    Release(frame);
  } while (!done);
  producer.join();

  // Resize stress: repeatedly cycle through very different surface sizes while
  // the "engine" keeps one earlier frame leased across each resize. Every
  // sampled frame must have the dimensions and pixels of the latest paint, and
  // a leased frame must stay intact. Frames are reference counted, so memory
  // is bounded by the frames in flight (latest + leased), not by resize count.
  {
    struct Size { int w, h; };
    const Size cycle[] = {{300, 300}, {1920, 1080}, {3840, 2160}, {640, 480}, {3840, 2160}};
    FlutterChromiumTexture stress;
    const FlutterDesktopPixelBuffer* leased = nullptr;
    uint8_t leased_marker = 0;
    for (int round = 0; round < 6; ++round) {
      for (const Size& s : cycle) {
        const uint8_t marker = static_cast<uint8_t>(10 + (round * 7 + s.w) % 200);
        std::vector<uint8_t> bgra(static_cast<size_t>(s.w) * s.h * 4, marker);
        stress.UpdateBuffer(bgra.data(), s.w, s.h);
        auto* frame = Sample(stress);
        Require(frame && frame->width == static_cast<size_t>(s.w) &&
                    frame->height == static_cast<size_t>(s.h),
                "Stress frame has wrong dimensions");
        Require(frame->buffer[0] == marker &&
                    frame->buffer[static_cast<size_t>(s.w) * s.h * 4 - 1] == marker,
                "Stress frame has wrong pixels");
        if (leased) {
          Require(leased->buffer[0] == leased_marker, "Leased frame was overwritten by a resize");
          Release(leased);
        }
        leased = frame;
        leased_marker = marker;
      }
    }
    Release(leased);
  }
  std::cout << "Texture ownership, resize, invalid-input, concurrent-paint and resize-stress regressions passed" << std::endl;
}
