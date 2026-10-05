#include "include/cef_texture.h"

FlutterChromiumTexture::FlutterChromiumTexture() {
  variant_ = std::make_unique<flutter::TextureVariant>(
      flutter::PixelBufferTexture([this](size_t width, size_t height) {
        return this->CopyPixels(width, height);
      }));
}

FlutterChromiumTexture::~FlutterChromiumTexture() {}

flutter::TextureVariant* FlutterChromiumTexture::GetTextureVariant() {
  return variant_.get();
}

void FlutterChromiumTexture::UpdateBuffer(const void* buffer, int width, int height) {
  if (!buffer || width <= 0 || height <= 0 || width > 16384 || height > 16384) return;
  const size_t size = static_cast<size_t>(width) * static_cast<size_t>(height) * 4;
  std::shared_ptr<Frame> next;
  try {
    next = std::make_shared<Frame>();
    next->pixels.resize(size);
  } catch (const std::bad_alloc&) {
    return; // Preserve the last valid frame.
  }
  next->width = static_cast<size_t>(width);
  next->height = static_cast<size_t>(height);

  const uint8_t* src = static_cast<const uint8_t*>(buffer);
  uint8_t* dst = next->pixels.data();

  // Convert BGRA to RGBA
  for (size_t i = 0; i < size; i += 4) {
    dst[i] = src[i + 2];     // R
    dst[i + 1] = src[i + 1]; // G
    dst[i + 2] = src[i];     // B
    dst[i + 3] = src[i + 3]; // A
  }
  std::lock_guard<std::mutex> lock(mutex_);
  frame_ = std::move(next);
}

const FlutterDesktopPixelBuffer* FlutterChromiumTexture::CopyPixels(size_t width, size_t height) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!frame_) {
    return nullptr;
  }
  auto* lease = new (std::nothrow) Lease();
  if (!lease) return nullptr;
  lease->frame = frame_;
  lease->buffer.width = lease->frame->width;
  lease->buffer.height = lease->frame->height;
  lease->buffer.buffer = lease->frame->pixels.data();
  lease->buffer.release_context = lease;
  lease->buffer.release_callback = [](void* context) {
    delete static_cast<Lease*>(context);
  };
  return &lease->buffer;
}
