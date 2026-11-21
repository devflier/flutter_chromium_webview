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

  // Buffer reuse: steady-state 1080p paints with immediate release must reuse
  // pooled buffers instead of allocating a fresh 8 MB vector every frame.
  {
    FlutterChromiumTexture pooled;
    std::vector<uint8_t> hd_frame(1920 * 1080 * 4, 0x42);
    for (int i = 0; i < 60; ++i) {
      pooled.UpdateBuffer(hd_frame.data(), 1920, 1080);
      auto* sampled = Sample(pooled);
      Require(sampled && sampled->width == 1920 && sampled->height == 1080,
              "Pooled HD frame dimensions mismatch");
      Release(sampled);
    }
    Require(pooled.allocation_count() <= 2,
            "Steady-state paints must reuse pooled frame buffers");
    // Clear drops retained buffers while preserving any currently leased frame.
    auto* leased = Sample(pooled);
    pooled.Clear();
    Require(Sample(pooled) == nullptr, "Clear must drop active frame");
    Require(leased->buffer[0] == 0x42, "Clear must not invalidate leased frame");
    Release(leased);
  }

  // Oversized pooled buffer eviction on shrink: shrinking from 1080p to 160x90
  // must evict all oversized pooled buffers immediately instead of retaining 8 MB.
  {
    FlutterChromiumTexture shrink_tex;
    std::vector<uint8_t> hd_frame(1920 * 1080 * 4, 0x33);
    // Prime 2 pooled buffers at 1080p.
    shrink_tex.UpdateBuffer(hd_frame.data(), 1920, 1080);
    auto* lease1 = Sample(shrink_tex);
    shrink_tex.UpdateBuffer(hd_frame.data(), 1920, 1080);
    auto* lease2 = Sample(shrink_tex);
    shrink_tex.UpdateBuffer(hd_frame.data(), 1920, 1080);
    Release(lease1);
    Release(lease2);
    Require(shrink_tex.pooled_frame_count() == 2,
            "Expected 2 pooled HD frames before shrink");

    std::vector<uint8_t> mini_frame(160 * 90 * 4, 0x55);
    shrink_tex.UpdateBuffer(mini_frame.data(), 160, 90);
    // After shrinking, no oversized 1080p buffer should remain in the pool.
    Require(shrink_tex.pooled_capacity_bytes() <= 1920u * 1080u * 4u,
            "Oversized pooled frames were not evicted on shrink");
    shrink_tex.UpdateBuffer(mini_frame.data(), 160, 90);
    Require(shrink_tex.pooled_capacity_bytes() <= 160u * 90u * 4u * 4u,
            "All pooled frames must fit shrunk size after second small paint");
  }

  // Dirty-rect partial in-place update when unleased, and safe full-frame
  // double-buffered fallback when a Flutter Lease is currently held.
  {
    FlutterChromiumTexture dirty_tex;
    const int w = 64, h = 64;
    std::vector<uint8_t> bgra(w * h * 4, 0);
    for (int i = 0; i < w * h; ++i) {
      bgra[i * 4 + 0] = 10;   // B
      bgra[i * 4 + 1] = 20;   // G
      bgra[i * 4 + 2] = 30;   // R
      bgra[i * 4 + 3] = 255;  // A
    }
    dirty_tex.UpdateBuffer(bgra.data(), w, h);
    const size_t allocs_before = dirty_tex.allocation_count();

    // Mutate a 4x4 dirty rect at (8, 8) while NO lease is held.
    for (int y = 8; y < 12; ++y) {
      for (int x = 8; x < 12; ++x) {
        size_t idx = (static_cast<size_t>(y) * w + x) * 4;
        bgra[idx + 0] = 100;  // B -> R=200
        bgra[idx + 1] = 150;  // G
        bgra[idx + 2] = 200;  // R -> B=100
        bgra[idx + 3] = 255;
      }
    }
    dirty_tex.UpdateBuffer(bgra.data(), w, h, {{8, 8, 4, 4}});
    Require(dirty_tex.allocation_count() == allocs_before,
            "Unleased small dirty rect should update in-place without allocating");

    auto* leased = Sample(dirty_tex);
    Require(leased != nullptr, "Sample after dirty update failed");
    size_t inside = (static_cast<size_t>(9) * w + 9) * 4;
    size_t outside = (static_cast<size_t>(0) * w + 0) * 4;
    Require(leased->buffer[inside + 0] == 200 && leased->buffer[inside + 2] == 100,
            "Dirty rect pixels were not updated");
    Require(leased->buffer[outside + 0] == 30 && leased->buffer[outside + 2] == 10,
            "Untouched pixels outside dirty rect were corrupted");

    // Now mutate (8, 8) again WHILE leased is held -> must NOT overwrite leased!
    for (int y = 8; y < 12; ++y) {
      for (int x = 8; x < 12; ++x) {
        size_t idx = (static_cast<size_t>(y) * w + x) * 4;
        bgra[idx + 2] = 250;  // new R
      }
    }
    dirty_tex.UpdateBuffer(bgra.data(), w, h, {{8, 8, 4, 4}});
    Require(leased->buffer[inside + 0] == 200,
            "Dirty rect update mutated an engine-leased frame!");
    Release(leased);

    auto* latest = Sample(dirty_tex);
    Require(latest->buffer[inside + 0] == 250,
            "Latest frame did not contain updated pixels after leased fallback");
    Release(latest);
  }

  // SIMD / scalar tail BGRA -> RGBA conversion accuracy across unaligned pixel counts.
  {
    const int widths[] = {1, 2, 3, 4, 5, 7, 15, 16, 17, 31, 33};
    for (int w : widths) {
      std::vector<uint8_t> bgra(static_cast<size_t>(w) * 4);
      for (int p = 0; p < w; ++p) {
        bgra[p * 4 + 0] = static_cast<uint8_t>((p * 3 + 1) & 0xFF);  // B
        bgra[p * 4 + 1] = static_cast<uint8_t>((p * 5 + 2) & 0xFF);  // G
        bgra[p * 4 + 2] = static_cast<uint8_t>((p * 7 + 3) & 0xFF);  // R
        bgra[p * 4 + 3] = static_cast<uint8_t>((p * 11 + 4) & 0xFF); // A
      }
      FlutterChromiumTexture simd_tex;
      simd_tex.UpdateBuffer(bgra.data(), w, 1);
      auto* sampled = Sample(simd_tex);
      Require(sampled && sampled->width == static_cast<size_t>(w) && sampled->height == 1,
              "SIMD conversion dimensions mismatch");
      for (int p = 0; p < w; ++p) {
        Require(sampled->buffer[p * 4 + 0] == bgra[p * 4 + 2] &&
                sampled->buffer[p * 4 + 1] == bgra[p * 4 + 1] &&
                sampled->buffer[p * 4 + 2] == bgra[p * 4 + 0] &&
                sampled->buffer[p * 4 + 3] == bgra[p * 4 + 3],
                "SIMD BGRA->RGBA pixel mismatch");
      }
      Release(sampled);
    }
  }
  std::cout << "Texture ownership, pool reuse, SIMD conversion, resize, invalid-input, concurrent-paint and resize-stress regressions passed" << std::endl;
}
