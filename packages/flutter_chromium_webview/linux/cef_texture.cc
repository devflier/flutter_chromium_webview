#include "include/cef_texture.h"
#include <cstring>
#include <cstdlib>
#include <vector>

struct _FlutterChromiumTexture {
  FlPixelBufferTexture parent_instance;
  std::mutex* mutex;
  uint8_t* rgba_buffer;
  std::vector<uint8_t>* render_buffer;
  std::vector<std::vector<uint8_t>>* retired_buffers;
  uint32_t width;
  uint32_t height;
};

G_DEFINE_TYPE(FlutterChromiumTexture, flutter_chromium_texture, fl_pixel_buffer_texture_get_type())

static gboolean flutter_chromium_texture_copy_pixels(FlPixelBufferTexture* texture,
                                                     const uint8_t** buffer,
                                                     uint32_t* width,
                                                     uint32_t* height,
                                                     GError** error) {
  FlutterChromiumTexture* self = FLUTTER_CHROMIUM_TEXTURE(texture);

  // Only the raster thread updates this snapshot. CEF can replace the producer
  // buffer after this callback without invalidating Flutter's returned pixels.
  self->mutex->lock();

  if (!self->rgba_buffer || self->width == 0 || self->height == 0) {
    // Flutter may sample the texture before CEF delivers its first frame.
    // Return a valid transparent pixel instead of a failed callback with no
    // GError (which some engine versions dereference while reporting failure).
    static const uint8_t transparent_pixel[4] = {0, 0, 0, 0};
    *buffer = transparent_pixel;
    *width = 1;
    *height = 1;
    self->mutex->unlock();
    return TRUE;
  }

  const size_t bytes = static_cast<size_t>(self->width) * self->height * 4;
  if (bytes > self->render_buffer->capacity()) {
    // Flutter's API requires returned allocations to survive unregistration.
    // Geometric growth bounds retained allocation sizes across repeated resizes.
    size_t capacity = 4;
    while (capacity < bytes) capacity *= 2;
    std::vector<uint8_t> replacement;
    replacement.reserve(capacity);
    self->retired_buffers->push_back(std::move(*self->render_buffer));
    *self->render_buffer = std::move(replacement);
  }
  self->render_buffer->assign(self->rgba_buffer, self->rgba_buffer + bytes);
  *buffer = self->render_buffer->data();
  *width = self->width;
  *height = self->height;

  self->mutex->unlock();
  return TRUE;
}

static void flutter_chromium_texture_dispose(GObject* object) {
  FlutterChromiumTexture* self = FLUTTER_CHROMIUM_TEXTURE(object);
  
  if (self->mutex) {
    self->mutex->lock();
    if (self->rgba_buffer) {
      free(self->rgba_buffer);
      self->rgba_buffer = nullptr;
    }
    self->mutex->unlock();
    delete self->mutex;
    self->mutex = nullptr;
  }
  delete self->render_buffer;
  self->render_buffer = nullptr;
  delete self->retired_buffers;
  self->retired_buffers = nullptr;

  G_OBJECT_CLASS(flutter_chromium_texture_parent_class)->dispose(object);
}

static void flutter_chromium_texture_class_init(FlutterChromiumTextureClass* klass) {
  GObjectClass* object_class = G_OBJECT_CLASS(klass);
  object_class->dispose = flutter_chromium_texture_dispose;

  FlPixelBufferTextureClass* pb_class = FL_PIXEL_BUFFER_TEXTURE_CLASS(klass);
  pb_class->copy_pixels = flutter_chromium_texture_copy_pixels;
}

static void flutter_chromium_texture_init(FlutterChromiumTexture* self) {
  self->mutex = new std::mutex();
  self->rgba_buffer = nullptr;
  self->render_buffer = new std::vector<uint8_t>();
  self->retired_buffers = new std::vector<std::vector<uint8_t>>();
  self->width = 0;
  self->height = 0;
}

FlutterChromiumTexture* flutter_chromium_texture_new() {
  return FLUTTER_CHROMIUM_TEXTURE(g_object_new(flutter_chromium_texture_get_type(), nullptr));
}

void flutter_chromium_texture_update_buffer(FlutterChromiumTexture* self, const void* buffer, int width, int height) {
  // Reject invalid dimensions before signed arithmetic or allocation.
  if (!self || !buffer || width <= 0 || height <= 0 || width > 16384 || height > 16384) return;

  std::lock_guard<std::mutex> lock(*(self->mutex));

  size_t required_size = static_cast<size_t>(width) * static_cast<size_t>(height) * 4;
  if (!self->rgba_buffer || self->width != width || self->height != height) {
    auto* replacement = static_cast<uint8_t*>(malloc(required_size));
    if (!replacement) return; // Preserve the last valid frame on allocation failure.
    free(self->rgba_buffer);
    self->rgba_buffer = replacement;
    self->width = width;
    self->height = height;
  }

  if (self->rgba_buffer) {
    const uint8_t* bgra = static_cast<const uint8_t*>(buffer);
    uint8_t* rgba = self->rgba_buffer;
    
    // BGRA to RGBA conversion
    for (size_t i = 0; i < required_size; i += 4) {
      rgba[i] = bgra[i + 2];     // R
      rgba[i + 1] = bgra[i + 1]; // G
      rgba[i + 2] = bgra[i];     // B
      rgba[i + 3] = bgra[i + 3]; // A
    }
  }
}
