#include <flutter_linux/flutter_linux.h>
#include <gmock/gmock.h>
#include <gtest/gtest.h>
#include <chrono>
#include <thread>

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
  ASSERT_TRUE(klass->copy_pixels(FL_PIXEL_BUFFER_TEXTURE(tex), &pixels, &width, &height, nullptr));
  EXPECT_EQ(width, 2u);
  EXPECT_EQ(pixels[0], 7);
  // Clearing the producer buffer must not invalidate the active raster front buffer until next copy_pixels.
  flutter_chromium_texture_clear(tex);
  EXPECT_EQ(pixels[0], 7);
  ASSERT_TRUE(klass->copy_pixels(FL_PIXEL_BUFFER_TEXTURE(tex), &pixels, &width, &height, nullptr));
  EXPECT_EQ(width, 1u);
  EXPECT_EQ(pixels[3], 0);
  // Invalid dimensions after a valid frame must not corrupt the last valid frame.
  flutter_chromium_texture_update_buffer(tex, next, 2, 1);
  ASSERT_TRUE(klass->copy_pixels(FL_PIXEL_BUFFER_TEXTURE(tex), &pixels, &width, &height, nullptr));
  EXPECT_EQ(width, 2u);
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
  runtime->ResetForTesting();
  EXPECT_EQ(runtime->GetState(), CefRuntimeState::kUninitialized);
  EXPECT_FALSE(runtime->pump_running());
  EXPECT_FALSE(runtime->shutdown_clean());
  EXPECT_FALSE(runtime->is_failed());

  // Simulate successful initialization.
  runtime->SetStateForTesting(CefRuntimeState::kReady);
  EXPECT_EQ(runtime->GetState(), CefRuntimeState::kReady);
  EXPECT_TRUE(runtime->pump_running());

  // Clean shutdown without active browsers.
  runtime->SetSkipCefCallsForTesting(true);
  runtime->Shutdown();
  EXPECT_EQ(runtime->GetState(), CefRuntimeState::kShutdownComplete);
  EXPECT_FALSE(runtime->pump_running());
  EXPECT_TRUE(runtime->shutdown_clean());
  EXPECT_FALSE(runtime->is_failed());
  runtime->ResetForTesting();
}

TEST(CefRuntimeManager, FailureInjection_BrowserCloseNotificationNeverArrives) {
  auto* runtime = CefRuntimeManager::GetInstance();
  runtime->ResetForTesting();
  runtime->SetStateForTesting(CefRuntimeState::kReady);
  runtime->SetSkipCefCallsForTesting(true);
  runtime->SetBrowserTimeoutForTesting(std::chrono::milliseconds(25));

  // Simulate an in-flight browser whose OnBeforeClose never arrives.
  runtime->BrowserPending();
  EXPECT_EQ(runtime->browser_count(), 1);

  runtime->Shutdown();

  // Invariant: Must transition to kShutdownFailed and NEVER claim clean shutdown.
  EXPECT_EQ(runtime->GetState(), CefRuntimeState::kShutdownFailed);
  EXPECT_TRUE(runtime->is_failed());
  EXPECT_FALSE(runtime->shutdown_clean());
  EXPECT_FALSE(runtime->pump_running());
  EXPECT_EQ(runtime->browser_count(), 1); // Preserves exact count for diagnostics.
  runtime->ResetForTesting();
}

TEST(CefRuntimeManager, FailureInjection_BrowserClosureDelayedPastTimeout) {
  auto* runtime = CefRuntimeManager::GetInstance();
  runtime->ResetForTesting();
  runtime->SetStateForTesting(CefRuntimeState::kReady);
  runtime->SetSkipCefCallsForTesting(true);
  runtime->SetBrowserTimeoutForTesting(std::chrono::milliseconds(25));

  runtime->BrowserPending();

  // Worker thread simulates late close arriving after the deadline.
  std::thread late_closer([runtime]() {
    std::this_thread::sleep_for(std::chrono::milliseconds(75));
    runtime->BrowserClosed();
  });

  runtime->Shutdown();

  EXPECT_EQ(runtime->GetState(), CefRuntimeState::kShutdownFailed);
  EXPECT_TRUE(runtime->is_failed());

  late_closer.join();

  // Late notification must not revive state or trigger CefShutdown().
  EXPECT_EQ(runtime->GetState(), CefRuntimeState::kShutdownFailed);
  runtime->ResetForTesting();
}

TEST(CefRuntimeManager, FailureInjection_CefUiBarrierTimeoutFailsWithoutCefShutdown) {
  auto* runtime = CefRuntimeManager::GetInstance();
  runtime->ResetForTesting();
  runtime->SetStateForTesting(CefRuntimeState::kReady);
  runtime->SetSkipCefCallsForTesting(true);
  runtime->SetBarrierTimeoutForTesting(std::chrono::milliseconds(25));
  runtime->SetInjectBarrierBlockForTesting(true);

  // active_browsers_ is 0, but barrier will time out.
  EXPECT_EQ(runtime->browser_count(), 0);

  runtime->Shutdown();

  // Invariant: Proceeding into CefShutdown on barrier timeout is unsafe.
  // Must fail explicitly.
  EXPECT_EQ(runtime->GetState(), CefRuntimeState::kShutdownFailed);
  EXPECT_TRUE(runtime->is_failed());
  EXPECT_FALSE(runtime->shutdown_clean());
  runtime->ResetForTesting();
}

TEST(CefRuntimeManager, FailureInjection_ShutdownRequestedTwiceIsIdempotent) {
  auto* runtime = CefRuntimeManager::GetInstance();
  runtime->ResetForTesting();
  runtime->SetStateForTesting(CefRuntimeState::kReady);
  runtime->SetSkipCefCallsForTesting(true);

  runtime->Shutdown();
  EXPECT_EQ(runtime->GetState(), CefRuntimeState::kShutdownComplete);

  // Second shutdown call must be a safe no-op.
  runtime->Shutdown();
  EXPECT_EQ(runtime->GetState(), CefRuntimeState::kShutdownComplete);
  EXPECT_TRUE(runtime->shutdown_clean());
  runtime->ResetForTesting();
}

TEST(CefRuntimeManager, FailureInjection_CloseCallbackArrivesJustBeforeTimeout) {
  auto* runtime = CefRuntimeManager::GetInstance();
  runtime->ResetForTesting();
  runtime->SetStateForTesting(CefRuntimeState::kReady);
  runtime->SetSkipCefCallsForTesting(true);
  runtime->SetBrowserTimeoutForTesting(std::chrono::milliseconds(150));

  runtime->BrowserPending();

  // Notification arrives well before 150 ms deadline.
  std::thread prompt_closer([runtime]() {
    std::this_thread::sleep_for(std::chrono::milliseconds(25));
    runtime->BrowserClosed();
  });

  runtime->Shutdown();
  prompt_closer.join();

  EXPECT_EQ(runtime->GetState(), CefRuntimeState::kShutdownComplete);
  EXPECT_TRUE(runtime->shutdown_clean());
  runtime->ResetForTesting();
}

TEST(CefRuntimeManager, FailureInjection_DrainsPendingGtkCallbacksBeforeShutdown) {
  auto* runtime = CefRuntimeManager::GetInstance();
  runtime->ResetForTesting();
  runtime->SetStateForTesting(CefRuntimeState::kReady);
  runtime->SetSkipCefCallsForTesting(true);

  bool gtk_callback_executed = false;
  CefRuntimeManager::PostToGtkMain([&gtk_callback_executed]() {
    gtk_callback_executed = true;
  });

  EXPECT_FALSE(gtk_callback_executed);

  // Shutdown must drain ready GMainContext sources via bounded iteration.
  runtime->Shutdown();

  EXPECT_TRUE(gtk_callback_executed);
  EXPECT_EQ(runtime->GetState(), CefRuntimeState::kShutdownComplete);
  runtime->ResetForTesting();
}

TEST(CefRuntimeManager, FailureInjection_ReinitializationPreventedInTerminalStates) {
  auto* runtime = CefRuntimeManager::GetInstance();
  runtime->ResetForTesting();

  // 1. After kShutdownFailed
  runtime->SetStateForTesting(CefRuntimeState::kShutdownFailed);
  EXPECT_FALSE(runtime->Initialize("/tmp/cache", 0, nullptr));
  EXPECT_EQ(runtime->GetState(), CefRuntimeState::kShutdownFailed);

  // 2. After kShutdownComplete
  runtime->SetStateForTesting(CefRuntimeState::kShutdownComplete);
  EXPECT_FALSE(runtime->Initialize("/tmp/cache", 0, nullptr));
  EXPECT_EQ(runtime->GetState(), CefRuntimeState::kShutdownComplete);

  // 3. After kInitFailed
  runtime->SetStateForTesting(CefRuntimeState::kInitFailed);
  EXPECT_FALSE(runtime->Initialize("/tmp/cache", 0, nullptr));
  EXPECT_EQ(runtime->GetState(), CefRuntimeState::kInitFailed);

  runtime->ResetForTesting();
}

TEST(LinuxContainerSandboxPolicy, DefaultAndNormalLinuxAlwaysPreserveNativeSandbox) {
  ContainerSandboxInputs normal;
  EXPECT_FALSE(ShouldDisableInnerSandboxForContainer(normal));

  // Explicit opt-in on an ordinary non-container Linux host MUST NOT disable
  // Chromium's sandbox.
  normal.allow_container_no_sandbox = true;
  EXPECT_FALSE(ShouldDisableInnerSandboxForContainer(normal));
}

TEST(LinuxContainerSandboxPolicy, ContainerRequiresExplicitOptInAndVerifiedConfinement) {
  // Snap without explicit opt-in stays sandboxed by default.
  ContainerSandboxInputs snap;
  snap.snap_env_set = true;
  snap.snap_name_set = true;
  snap.snap_dir_exists = true;
  EXPECT_FALSE(ShouldDisableInnerSandboxForContainer(snap));

  // Snap with explicit opt-in allows inner sandbox opt-out.
  snap.allow_container_no_sandbox = true;
  EXPECT_TRUE(ShouldDisableInnerSandboxForContainer(snap));

  // Missing verified Snap directory rejects opt-out.
  snap.snap_dir_exists = false;
  EXPECT_FALSE(ShouldDisableInnerSandboxForContainer(snap));

  // Flatpak without explicit opt-in stays sandboxed by default.
  ContainerSandboxInputs flatpak;
  flatpak.flatpak_id_set = true;
  flatpak.flatpak_info_exists = true;
  EXPECT_FALSE(ShouldDisableInnerSandboxForContainer(flatpak));

  // Flatpak with explicit opt-in and /.flatpak-info allows inner sandbox opt-out.
  flatpak.allow_container_no_sandbox = true;
  EXPECT_TRUE(ShouldDisableInnerSandboxForContainer(flatpak));

  // Spoofed FLATPAK_ID without /.flatpak-info rejects opt-out.
  flatpak.flatpak_info_exists = false;
  EXPECT_FALSE(ShouldDisableInnerSandboxForContainer(flatpak));
}

}  // namespace test
}  // namespace flutter_chromium_webview
