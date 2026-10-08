# macOS input IPC (Step 4)

The software `OnPaint` → shared-memory → Flutter texture transport is unchanged.
JavaScript bridge IPC and IOSurface transport are separate follow-up work.

Flutter sends view-local **logical** coordinates; never multiply x/y or wheel
amounts by DPR. `createBrowser` and `resizeBrowser` carry `deviceScaleFactor`.
The host updates `GetScreenInfo`, calls `NotifyScreenInfoChanged` and `WasResized`.
Pointer messages carry the browser ID in both the envelope and payload, plus
`x`, `y`, `deviceScaleFactor`, `modifiers`, `mouseButton`, `clickCount`,
`scrollDeltaX`, and `scrollDeltaY`.

| Message | CEF API |
| --- | --- |
| mouseMove / mouseLeave | SendMouseMoveEvent (leave true for mouseLeave) |
| mouseDown / mouseUp | SendMouseClickEvent (up true for mouseUp) |
| scroll | SendMouseWheelEvent |
| setFocus | SetFocus |
| keyDown / keyUp / textInput | SendKeyEvent (RAWKEYDOWN / KEYUP / CHAR) |
| resizeBrowser | NotifyScreenInfoChanged + WasResized |

AppKit's text responder supplies hardware keys (`keyCode` is Windows virtual-key;
`scanCode` is the macOS hardware code) and Unicode UTF-16 `character` values.
Modifiers use **CEF** flags: CapsLock=1, Shift=2, Control=4, Alt=8, Command=128;
pointer buttons use Left=16, Middle=32, Right=64. IME composition/commit/cancel
remain separate messages. Reaffirming focus on the same browser preserves marked
text. Browser switches cancel composition and blur the previous browser.
Legacy `sendPointerEvent` / `sendKeyEvent` messages remain supported by the host.

Flutter tracks consecutive clicks per button (500 ms and 4 logical pixel radius,
up to triple click) and supplies the same click count on mouse-up. Focus loss is
sent to native code. Native teardown callbacks do not retain a raw browser proxy.
Both IPC socket writers suppress SIGPIPE and complete partial/interrupted writes;
input queued after disconnect is discarded, and pending requests fail.

## Verification

From the package directory:

```sh
flutter test test/input_coordinates_test.dart test/input_ipc_widget_test.dart
bash macos/Host/build_host.sh
bash macos/test/run_input_tests.sh
```

The host smoke test uses an HTTP fixture and DOM telemetry, **not** JS bridge IPC.
It checks hover, left/right/middle and double click, focused text input, keyboard
characters, Shift/Control/Alt/Command, mouse leave, wheel scrolling, resize/DPR,
two independent browser IDs, and close acknowledgement. It kills its own host
while inputs are queued. Native tests additionally exercise the actual Flutter
IPC client under peer death, failure callbacks, key-code/modifier encoding,
AppKit typing, IME, and focus ownership. Widget tests verify button routing,
double click, focus loss, two browser IDs, and coordinates at DPR 1/1.5/2.
PPPlayer's `integration_test/chromium_input_ipc_test.dart` additionally verifies
Flutter texture widgets route clicks and text to two independent browsers, resize
reaches CEF, and killing only its own host while input is queued releases native
browsers without crashing Flutter. Allow the initial compositor hit-test surface
to settle before injecting synthetic mouse events; navigation telemetry alone
is earlier than that surface.

Concurrent creation binds each browser to its exact session during
`CreateBrowserSync`/`OnAfterCreated`; selecting an arbitrary unbound session can
swap page, texture and input identities.

The smoke and integration tests opt into
`CEF_INPUT_TEST_USE_MOCK_KEYCHAIN=1`. This adds Chromium's test-only
`--use-mock-keychain` switch to isolated test launches, avoiding the Chromium Safe
Storage password prompt. Normal app launches continue using the real Keychain.

From PPPlayer's app directory:

```sh
CEF_INPUT_TEST_USE_MOCK_KEYCHAIN=1 flutter test integration_test/chromium_input_ipc_test.dart -d macos
flutter analyze
flutter build macos --debug --no-pub
```
