#include <flutter_linux/flutter_linux.h>
#include <gmock/gmock.h>
#include <gtest/gtest.h>

#include "include/flutter_chromium_webview/flutter_chromium_webview_plugin.h"
#include "flutter_chromium_webview_plugin_private.h"
#include "include/cef_texture.h"
#include "include/cef_runtime_manager.h"
#include "include/cef_browser_handler.h"

namespace flutter_chromium_webview {
namespace test {

TEST(PendingCallbacks, RejectsStaleRepliesAndAllowsReentrantCancellation) {
  PendingCallbacks<std::function<void()>> callbacks;
  int completed = 0;
  int id = 0;
  id = callbacks.Add([&] { ++completed; EXPECT_FALSE(callbacks.Take(id)); });
  auto callback = callbacks.Take(id);
  ASSERT_TRUE(callback);
  callback();
  EXPECT_EQ(completed, 1);
  callbacks.Add([&] { ++completed; EXPECT_TRUE(callbacks.Drain().empty()); });
  auto pending = callbacks.Drain();
  for (auto& entry : pending) entry.second();
  EXPECT_EQ(completed, 2);
}

TEST(PendingCallbacks, BrowserResourcesAndIdentifiersAreIndependent) {
  PendingCallbacks<std::function<void()>> first, second;
  int completed = 0;
  auto old_id = first.Add([] {});
  auto second_id = second.Add([&] { ++completed; });
  first.Clear();
  EXPECT_FALSE(first.Take(old_id));
  EXPECT_GT(first.Add([] {}), old_id);
  auto callback = second.Take(second_id);
  ASSERT_TRUE(callback);
  callback();
  EXPECT_EQ(completed, 1);
}

TEST(CefTexture, EmptyFrameIsTransparent) {
  g_autoptr(FlutterChromiumTexture) tex = flutter_chromium_texture_new();
  const uint8_t* pixels = nullptr;
  uint32_t width = 0, height = 0;
  ASSERT_TRUE(FL_PIXEL_BUFFER_TEXTURE_GET_CLASS(tex)->copy_pixels(
      FL_PIXEL_BUFFER_TEXTURE(tex), &pixels, &width, &height, nullptr));
  ASSERT_EQ(width, 1u);
  ASSERT_EQ(height, 1u);
  EXPECT_EQ(pixels[3], 0);
}

TEST(CefTexture, ProducerCannotInvalidateRasterSnapshot) {
  g_autoptr(FlutterChromiumTexture) tex = flutter_chromium_texture_new();
  uint8_t first[] = {3, 2, 1, 255};
  flutter_chromium_texture_update_buffer(tex, first, 1, 1);
  const uint8_t* pixels = nullptr;
  uint32_t width, height;
  auto* klass = FL_PIXEL_BUFFER_TEXTURE_GET_CLASS(tex);
  ASSERT_TRUE(klass->copy_pixels(FL_PIXEL_BUFFER_TEXTURE(tex), &pixels, &width, &height, nullptr));
  uint8_t next[] = {9, 8, 7, 255, 6, 5, 4, 255};
  flutter_chromium_texture_update_buffer(tex, next, 2, 1);
  EXPECT_EQ(pixels[0], 1); // Old snapshot remains valid until next raster copy.
  const uint8_t* old_snapshot = pixels;
  ASSERT_TRUE(klass->copy_pixels(FL_PIXEL_BUFFER_TEXTURE(tex), &pixels, &width, &height, nullptr));
  EXPECT_EQ(width, 2u);
  EXPECT_EQ(pixels[0], 7);
  EXPECT_EQ(old_snapshot[0], 1); // Resizing does not free a previously returned allocation.
  flutter_chromium_texture_update_buffer(tex, next, -1, 1);
  flutter_chromium_texture_update_buffer(tex, next, 2147483647, 2147483647);
  ASSERT_TRUE(klass->copy_pixels(FL_PIXEL_BUFFER_TEXTURE(tex), &pixels, &width, &height, nullptr));
  EXPECT_EQ(width, 2u); // Invalid dimensions do not corrupt the last valid frame.
}

TEST(CefTexture, MainAndPopupFramesAreIndependent) {
  g_autoptr(FlutterChromiumTexture) main = flutter_chromium_texture_new();
  g_autoptr(FlutterChromiumTexture) popup = flutter_chromium_texture_new();
  uint8_t color[] = {0, 0, 255, 255};
  flutter_chromium_texture_update_buffer(main, color, 1, 1);
  const uint8_t* pixels = nullptr;
  uint32_t width, height;
  ASSERT_TRUE(FL_PIXEL_BUFFER_TEXTURE_GET_CLASS(popup)->copy_pixels(
      FL_PIXEL_BUFFER_TEXTURE(popup), &pixels, &width, &height, nullptr));
  EXPECT_EQ(pixels[3], 0);
}

TEST(CefTexture, ResizingAndConversion) {
  FlutterChromiumTexture* tex = flutter_chromium_texture_new();
  const uint8_t bgra[] = {
      255, 0, 0, 255, // Blue pixel (B, G, R, A)
      0, 255, 0, 255  // Green pixel (B, G, R, A)
  };
  flutter_chromium_texture_update_buffer(tex, bgra, 2, 1);

  const uint8_t* buffer = nullptr;
  uint32_t width = 0;
  uint32_t height = 0;
  GError* error = nullptr;

  FlPixelBufferTextureClass* klass = FL_PIXEL_BUFFER_TEXTURE_GET_CLASS(tex);
  gboolean success = klass->copy_pixels(FL_PIXEL_BUFFER_TEXTURE(tex), &buffer, &width, &height, &error);

  EXPECT_TRUE(success);
  EXPECT_EQ(width, 2);
  EXPECT_EQ(height, 1);
  ASSERT_NE(buffer, nullptr);

  // Converted to RGBA
  EXPECT_EQ(buffer[0], 0);
  EXPECT_EQ(buffer[1], 0);
  EXPECT_EQ(buffer[2], 255);
  EXPECT_EQ(buffer[3], 255);

  g_object_unref(tex);
}

TEST(CefRuntimeManager, LifecycleTransitions) {
  auto* runtime = CefRuntimeManager::GetInstance();
  // Ensure the state starts uninitialized in tests.
  EXPECT_EQ(runtime->GetState(), CefRuntimeState::kUninitialized);
  // We avoid calling Initialize() since it would spawn real CEF processes,
  // but we can verify the singleton works.
}

}  // namespace test
}  // namespace flutter_chromium_webview
