#ifndef FLUTTER_CHROMIUM_WEBVIEW_CEF_TEXTURE_H_
#define FLUTTER_CHROMIUM_WEBVIEW_CEF_TEXTURE_H_

#include <flutter_linux/flutter_linux.h>
#include <glib-object.h>
#include <mutex>
#include <vector>

G_BEGIN_DECLS

G_DECLARE_FINAL_TYPE(FlutterChromiumTexture, flutter_chromium_texture, FLUTTER_CHROMIUM, TEXTURE, FlPixelBufferTexture)

FlutterChromiumTexture* flutter_chromium_texture_new();

// Safely updates the internal buffer with BGRA data from CEF.
// Converts BGRA to RGBA internally.
void flutter_chromium_texture_update_buffer(FlutterChromiumTexture* self, const void* buffer, int width, int height);

G_END_DECLS

#endif  // FLUTTER_CHROMIUM_WEBVIEW_CEF_TEXTURE_H_
