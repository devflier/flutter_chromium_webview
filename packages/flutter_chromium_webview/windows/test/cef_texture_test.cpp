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
  std::cout << "Texture ownership, resize, invalid-input and concurrent-paint regressions passed" << std::endl;
}
