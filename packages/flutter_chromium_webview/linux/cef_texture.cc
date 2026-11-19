#include "include/cef_texture.h"
#include <cstring>
#include <cstdlib>
#include <utility>
#include <vector>

struct _FlutterChromiumTexture {
  FlPixelBufferTexture parent_instance;
  std::mutex* mutex;
  std::vector<uint8_t>* staging_buffer;
  // Owned exclusively by Flutter's raster thread during copy_pixels / GL upload
  // and freed only on the raster thread (when clear_requested is handled) or in
  // GObject dispose after unregistration.
  std::vector<uint8_t>* front_buffer;
  uint32_t staging_width;
  uint32_t staging_height;
  uint32_t front_width;
  uint32_t front_height;
  bool has_new_frame;
  bool clear_requested;
};

G_DEFINE_TYPE(FlutterChromiumTexture, flutter_chromium_texture, fl_pixel_buffer_texture_get_type())

static gboolean flutter_chromium_texture_copy_pixels(FlPixelBufferTexture* texture,
                                                     const uint8_t** buffer,
                                                     uint32_t* width,
                                                     uint32_t* height,
                                                     GError** error) {
  static const uint8_t transparent_pixel[4] = {0, 0, 0, 0};
  FlutterChromiumTexture* self = FLUTTER_CHROMIUM_TEXTURE(texture);
  if (!self->mutex) {
    *buffer = transparent_pixel;
    *width = 1;
    *height = 1;
    return TRUE;
  }
  std::lock_guard<std::mutex> lock(*(self->mutex));
  if (!self->front_buffer || !self->staging_buffer) {
    *buffer = transparent_pixel;
    *width = 1;
    *height = 1;
    return TRUE;
  }

  if (self->clear_requested) {
    std::vector<uint8_t>().swap(*self->front_buffer);
    self->front_width = 0;
    self->front_height = 0;
    self->clear_requested = false;
  }

  if (self->has_new_frame) {
    // Swap staging_buffer into front_buffer in O(1) without a second frame copy,
    // then release the old buffer in staging_buffer so idle textures hold only
    // a single exact-sized frame buffer in physical memory.
    std::swap(*self->front_buffer, *self->staging_buffer);
    std::vector<uint8_t>().swap(*self->staging_buffer);
    self->front_width = self->staging_width;
    self->front_height = self->staging_height;
    self->staging_width = 0;
    self->staging_height = 0;
    self->has_new_frame = false;
  }

  if (self->front_buffer->empty() || self->front_width == 0 || self->front_height == 0) {
    // Flutter may sample the texture before CEF delivers its first frame.
    // Return a valid transparent pixel instead of a failed callback with no
    // GError (which some engine versions dereference while reporting failure).
    *buffer = transparent_pixel;
    *width = 1;
    *height = 1;
    return TRUE;
  }

  *buffer = self->front_buffer->data();
  *width = self->front_width;
  *height = self->front_height;
  return TRUE;
}

static void flutter_chromium_texture_dispose(GObject* object) {
  FlutterChromiumTexture* self = FLUTTER_CHROMIUM_TEXTURE(object);

  if (self->mutex) {
    std::lock_guard<std::mutex> lock(*(self->mutex));
    delete self->staging_buffer;
    self->staging_buffer = nullptr;
    delete self->front_buffer;
    self->front_buffer = nullptr;
    self->staging_width = 0;
    self->staging_height = 0;
    self->front_width = 0;
    self->front_height = 0;
    self->has_new_frame = false;
    self->clear_requested = false;
  }

  G_OBJECT_CLASS(flutter_chromium_texture_parent_class)->dispose(object);
}

static void flutter_chromium_texture_finalize(GObject* object) {
  FlutterChromiumTexture* self = FLUTTER_CHROMIUM_TEXTURE(object);
  delete self->mutex;
  self->mutex = nullptr;
  G_OBJECT_CLASS(flutter_chromium_texture_parent_class)->finalize(object);
}

static void flutter_chromium_texture_class_init(FlutterChromiumTextureClass* klass) {
  GObjectClass* object_class = G_OBJECT_CLASS(klass);
  object_class->dispose = flutter_chromium_texture_dispose;
  object_class->finalize = flutter_chromium_texture_finalize;

  FlPixelBufferTextureClass* pb_class = FL_PIXEL_BUFFER_TEXTURE_CLASS(klass);
  pb_class->copy_pixels = flutter_chromium_texture_copy_pixels;
}

static void flutter_chromium_texture_init(FlutterChromiumTexture* self) {
  self->mutex = new std::mutex();
  self->staging_buffer = new std::vector<uint8_t>();
  self->front_buffer = new std::vector<uint8_t>();
  self->staging_width = 0;
  self->staging_height = 0;
  self->front_width = 0;
  self->front_height = 0;
  self->has_new_frame = false;
  self->clear_requested = false;
}

FlutterChromiumTexture* flutter_chromium_texture_new() {
  return FLUTTER_CHROMIUM_TEXTURE(g_object_new(flutter_chromium_texture_get_type(), nullptr));
}

void flutter_chromium_texture_update_buffer(FlutterChromiumTexture* self, const void* buffer, int width, int height) {
  // Reject invalid dimensions before signed arithmetic or allocation.
  if (!self || !self->mutex || !buffer || width <= 0 || height <= 0 || width > 16384 || height > 16384) return;

  std::lock_guard<std::mutex> lock(*(self->mutex));
  if (!self->staging_buffer) return;

  const size_t required_size = static_cast<size_t>(width) * static_cast<size_t>(height) * 4;
  if (self->staging_buffer->capacity() > required_size * 2) {
    std::vector<uint8_t>(required_size).swap(*self->staging_buffer);
  } else {
    self->staging_buffer->resize(required_size);
  }

  self->staging_width = static_cast<uint32_t>(width);
  self->staging_height = static_cast<uint32_t>(height);

  const uint8_t* bgra = static_cast<const uint8_t*>(buffer);
  uint8_t* rgba = self->staging_buffer->data();

  // BGRA to RGBA conversion, one 32-bit word at a time (little-endian:
  // 0xAARRGGBB -> 0xAABBGGRR).
  for (size_t i = 0; i < required_size; i += 4) {
    uint32_t v;
    memcpy(&v, bgra + i, 4);
    v = (v & 0xFF00FF00u) | ((v & 0xFFu) << 16) | ((v >> 16) & 0xFFu);
    memcpy(rgba + i, &v, 4);
  }
  self->has_new_frame = true;
  self->clear_requested = false;
}

void flutter_chromium_texture_clear(FlutterChromiumTexture* self) {
  if (!self || !self->mutex) return;
  std::lock_guard<std::mutex> lock(*(self->mutex));
  if (self->staging_buffer) {
    std::vector<uint8_t>().swap(*self->staging_buffer);
  }
  self->staging_width = 0;
  self->staging_height = 0;
  self->has_new_frame = false;
  self->clear_requested = true;
}
