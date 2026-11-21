#include "include/cef_texture.h"
#include <algorithm>
#include <cstring>
#include <new>

#if defined(_M_X64) || defined(__x86_64__)
#include <emmintrin.h>
#include <tmmintrin.h>
#ifdef _MSC_VER
#include <intrin.h>
#endif
#endif

namespace {

#if defined(_M_X64) || defined(__x86_64__)
bool HasSsse3() {
  static const bool supported = []() {
#ifdef _MSC_VER
    int info[4] = {};
    __cpuid(info, 1);
    return (info[2] & (1 << 9)) != 0;
#else
    return __builtin_cpu_supports("ssse3") != 0;
#endif
  }();
  return supported;
}
#endif

void ConvertBgraToRgba(const uint8_t* src, uint8_t* dst, size_t byte_count) {
  size_t i = 0;
#if defined(_M_X64) || defined(__x86_64__)
  if (HasSsse3()) {
    const __m128i mask = _mm_setr_epi8(
        2, 1, 0, 3,
        6, 5, 4, 7,
        10, 9, 8, 11,
        14, 13, 12, 15);
    for (; i + 16 <= byte_count; i += 16) {
      __m128i px = _mm_loadu_si128(reinterpret_cast<const __m128i*>(src + i));
      __m128i swapped = _mm_shuffle_epi8(px, mask);
      _mm_storeu_si128(reinterpret_cast<__m128i*>(dst + i), swapped);
    }
  } else {
    const __m128i ga_mask = _mm_set1_epi32(static_cast<int>(0xFF00FF00u));
    const __m128i rb_mask = _mm_set1_epi32(0x000000FF);
    for (; i + 16 <= byte_count; i += 16) {
      __m128i px = _mm_loadu_si128(reinterpret_cast<const __m128i*>(src + i));
      __m128i ga = _mm_and_si128(px, ga_mask);
      __m128i b_to_r = _mm_slli_epi32(_mm_and_si128(px, rb_mask), 16);
      __m128i r_to_b = _mm_and_si128(_mm_srli_epi32(px, 16), rb_mask);
      __m128i swapped = _mm_or_si128(ga, _mm_or_si128(b_to_r, r_to_b));
      _mm_storeu_si128(reinterpret_cast<__m128i*>(dst + i), swapped);
    }
  }
#endif
  for (; i < byte_count; i += 4) {
    uint32_t v;
    std::memcpy(&v, src + i, 4);
    v = (v & 0xFF00FF00u) | ((v & 0xFFu) << 16) | ((v >> 16) & 0xFFu);
    std::memcpy(dst + i, &v, 4);
  }
}

}  // namespace

void FlutterChromiumTexture::Pool::Return(std::shared_ptr<Frame> frame) {
  if (!frame) return;
  std::lock_guard<std::mutex> lock(mutex);
  if (cleared || free_frames.size() >= kMaxPooledFrames) {
    return;
  }
  free_frames.push_back(std::move(frame));
}

FlutterChromiumTexture::FlutterChromiumTexture()
    : pool_(std::make_shared<Pool>()) {
  variant_ = std::make_unique<flutter::TextureVariant>(
      flutter::PixelBufferTexture([this](size_t width, size_t height) {
        return this->CopyPixels(width, height);
      }));
}

FlutterChromiumTexture::~FlutterChromiumTexture() {
  Clear();
}

flutter::TextureVariant* FlutterChromiumTexture::GetTextureVariant() {
  return variant_.get();
}

std::shared_ptr<FlutterChromiumTexture::Frame>
FlutterChromiumTexture::AcquireFrame(size_t required_size) {
  std::shared_ptr<Frame> candidate;
  std::vector<std::shared_ptr<Frame>> evicted;
  {
    std::lock_guard<std::mutex> lock(pool_->mutex);
    pool_->cleared = false;
    if (!pool_->free_frames.empty()) {
      // Prefer an exact-capacity match if available.
      size_t best_index = pool_->free_frames.size() - 1;
      for (size_t i = 0; i < pool_->free_frames.size(); ++i) {
        const size_t cap = pool_->free_frames[i]->pixels.capacity();
        if (cap >= required_size && cap <= required_size * 2) {
          best_index = i;
          break;
        }
      }
      candidate = std::move(pool_->free_frames[best_index]);
      pool_->free_frames.erase(pool_->free_frames.begin() + best_index);

      // Evict any remaining oversized pooled buffers immediately when shrinking
      // from a higher resolution (e.g. 4K/1080p fullscreen -> mini-player).
      auto it = pool_->free_frames.begin();
      while (it != pool_->free_frames.end()) {
        if ((*it)->pixels.capacity() > required_size * 2) {
          evicted.push_back(std::move(*it));
          it = pool_->free_frames.erase(it);
        } else {
          ++it;
        }
      }
    }
  }
  evicted.clear();

  try {
    if (!candidate) {
      candidate = std::make_shared<Frame>();
      candidate->pixels.resize(required_size);
      allocation_count_.fetch_add(1, std::memory_order_relaxed);
    } else if (candidate->pixels.capacity() > required_size * 2) {
      // Release excessive memory after shrinking from a large resolution.
      std::vector<uint8_t>(required_size).swap(candidate->pixels);
      allocation_count_.fetch_add(1, std::memory_order_relaxed);
    } else {
      const size_t prev_cap = candidate->pixels.capacity();
      candidate->pixels.resize(required_size);
      if (candidate->pixels.capacity() != prev_cap) {
        allocation_count_.fetch_add(1, std::memory_order_relaxed);
      }
    }
  } catch (const std::bad_alloc&) {
    return nullptr;
  }
  return candidate;
}

void FlutterChromiumTexture::UpdateBuffer(const void* buffer, int width, int height) {
  static const std::vector<DirtyRect> kNoDirtyRects;
  UpdateBuffer(buffer, width, height, kNoDirtyRects);
}

void FlutterChromiumTexture::UpdateBuffer(
    const void* buffer,
    int width,
    int height,
    const std::vector<DirtyRect>& dirty_rects) {
  if (!buffer || width <= 0 || height <= 0 || width > 16384 || height > 16384) {
    return;
  }
  const size_t w = static_cast<size_t>(width);
  const size_t h = static_cast<size_t>(height);
  const size_t size = w * h * 4;
  const auto* src_base = static_cast<const uint8_t*>(buffer);

  // Fast path: for small partial repaints (under 25% of total frame area),
  // update the active frame in-place under mutex_ if and only if no Flutter
  // Lease currently references it (use_count() == 1). Because mutex_ serializes
  // CopyPixels, use_count() cannot increase while the lock is held.
  if (!dirty_rects.empty()) {
    size_t dirty_area = 0;
    for (const auto& r : dirty_rects) {
      const int x0 = std::clamp(r.x, 0, width);
      const int y0 = std::clamp(r.y, 0, height);
      const int x1 = std::clamp(r.x + r.width, 0, width);
      const int y1 = std::clamp(r.y + r.height, 0, height);
      if (x1 > x0 && y1 > y0) {
        dirty_area += static_cast<size_t>(x1 - x0) * static_cast<size_t>(y1 - y0);
      }
    }
    if (dirty_area > 0 && dirty_area * 4 < w * h) {
      std::lock_guard<std::mutex> lock(mutex_);
      if (frame_ && frame_->width == w && frame_->height == h &&
          frame_->pixels.size() == size && frame_.use_count() == 1) {
        uint8_t* dst_base = frame_->pixels.data();
        const size_t stride = w * 4;
        for (const auto& r : dirty_rects) {
          const int x0 = std::clamp(r.x, 0, width);
          const int y0 = std::clamp(r.y, 0, height);
          const int x1 = std::clamp(r.x + r.width, 0, width);
          const int y1 = std::clamp(r.y + r.height, 0, height);
          if (x1 <= x0 || y1 <= y0) continue;
          const size_t row_bytes = static_cast<size_t>(x1 - x0) * 4;
          const size_t x_offset = static_cast<size_t>(x0) * 4;
          for (int y = y0; y < y1; ++y) {
            const size_t offset = static_cast<size_t>(y) * stride + x_offset;
            ConvertBgraToRgba(src_base + offset, dst_base + offset, row_bytes);
          }
        }
        return;
      }
    }
  }

  auto next = AcquireFrame(size);
  if (!next) {
    return;  // Preserve the last valid frame on OOM.
  }
  next->width = w;
  next->height = h;

  ConvertBgraToRgba(src_base, next->pixels.data(), size);

  std::shared_ptr<Frame> previous;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    previous = std::move(frame_);
    frame_ = std::move(next);
  }
  // If no engine lease holds the previous frame, immediately recycle it.
  if (previous && previous.use_count() == 1) {
    pool_->Return(std::move(previous));
  }
}

size_t FlutterChromiumTexture::pooled_frame_count() const {
  std::lock_guard<std::mutex> lock(pool_->mutex);
  return pool_->free_frames.size();
}

size_t FlutterChromiumTexture::pooled_capacity_bytes() const {
  std::lock_guard<std::mutex> lock(pool_->mutex);
  size_t total = 0;
  for (const auto& f : pool_->free_frames) {
    if (f) total += f->pixels.capacity();
  }
  return total;
}

void FlutterChromiumTexture::Clear() {
  std::shared_ptr<Frame> previous;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    previous = std::move(frame_);
  }
  {
    std::lock_guard<std::mutex> lock(pool_->mutex);
    pool_->cleared = true;
    pool_->free_frames.clear();
  }
  previous.reset();
}

const FlutterDesktopPixelBuffer* FlutterChromiumTexture::CopyPixels(
    size_t width, size_t height) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!frame_) {
    return nullptr;
  }
  auto* lease = new (std::nothrow) Lease();
  if (!lease) return nullptr;
  lease->frame = frame_;
  lease->pool = pool_;
  lease->buffer.width = lease->frame->width;
  lease->buffer.height = lease->frame->height;
  lease->buffer.buffer = lease->frame->pixels.data();
  lease->buffer.release_context = lease;
  lease->buffer.release_callback = [](void* context) {
    auto* released = static_cast<Lease*>(context);
    auto returned = std::move(released->frame);
    auto pool = released->pool.lock();
    delete released;
    if (pool && returned && returned.use_count() == 1) {
      pool->Return(std::move(returned));
    }
  };
  return &lease->buffer;
}
