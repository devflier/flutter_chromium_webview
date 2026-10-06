# Linux native input validation — 2026-10-06

The supplied [GitHub Actions failure](https://github.com/devflier/flutter_chromium_webview/actions/runs/37450847229/job/112226766937) reaches the expected 320×240 viewport at DPR 1, but never records a click. The trace identifies the click phase; it does not establish the underlying timing cause.

The DPR-1 case passed locally under Xvfb before the fix. Restoring the skipped DPR-1.5 case exposed a separate, reproducible regression: sending `(50, 40)` produced DOM coordinates `(75, 60)`. Removing the extra DPR multiplication fixes this. CEF's [native event translation](https://github.com/chromiumembedded/cef/blob/master/libcef/browser/native/browser_platform_delegate_native_aura.cc) passes the view coordinates directly into the input event.

The integration test now waits for a native mouse move to reach the target after each resize, before sending exactly one mouse-down/mouse-up pair. This guards against asynchronous compositor/input readiness without retrying clicks. All three DPRs (1, 1.5, 2) and both viewport widths (320, 480) remain covered. Failures identify the phase and include native pointer and focus observations.

Linux validation now uses expanded test output and saves `docs/validation/linux-native.log`. GitHub Actions uploads that log even when validation fails.

Broader validation also exposed an unavailable WSLg audio endpoint: the autoplay test reported `stalled`, then passed unchanged after the endpoint recovered. CI now starts PulseAudio with a null sink, providing a real software audio output for the unmuted PCM playback checks without physical audio hardware. The autoplay assertions remain unchanged.

Verification:

- Windows native input integration: passed at all three DPRs.
- WSL Ubuntu 26.04, Flutter 3.47.5, Xvfb with GTK's X11 backend: native input integration passed at all three DPRs.
- Dart formatting, shell syntax, and workflow YAML parsing: passed.
- Linux package analysis, 63 package tests, example analysis, two example tests, and native lifecycle/input/dialog/JavaScript/HTML integration suites: passed under Xvfb.
- Browser settings/autoplay and YouTube integration: passed under Xvfb with an isolated PulseAudio null sink. Together with the preceding suites, all seven Linux native integration suites passed.
- Linux release build: passed (`build/linux/x64/release/bundle/flutter_chromium_webview_example`).

The initial `validate_linux.sh` invocation stopped at the unavailable audio endpoint. The remaining media suites and release build were then validated with an isolated software audio server; this is a completed validation matrix across two invocations, rather than a single uninterrupted script pass. Logs are saved in `linux-native.log`, `linux-headless-media.log`, and `linux-headless-pulse.log` beside this report.

The exact hosted CI environment uses Flutter 3.47.4. A new GitHub Actions run is still needed to confirm the original CI failure is resolved. These changes have not been committed or pushed.
