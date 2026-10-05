# Security status

This prototype is not a browser-grade security boundary. Do not ship it as one.

The CEF archive is pinned to `149.0.4+g2f1bfd8+chromium-149.0.7827.156`, SHA-256
`6d43607675e47ed6bfa40d1cfce136d04e7720529f8f1c4435d4ba1dcd1839b2`.
Updates require an explicit version/checksum change and regression testing; the
build never selects a newer CEF automatically. Maintainers must track Chromium
and CEF security updates before deploying to untrusted content.

CEF sandboxing remains enabled. Windows requires the same-executable bootstrap
runner described in [windows.md](windows.md); the legacy separate subprocess
executable is not used. There is no automatic `--no-sandbox` fallback,
no disabled web security, and no ignored certificate errors. Successful startup
alone does not prove sandbox confinement. User-namespace and sandbox support on
the deployment host still require verification. CPU graphics switches affect
rendering, not Chromium web security.

`executeJavaScript` is a host-to-page capability. There is no general page-to-Dart
JavaScript bridge. Treat page titles, errors, dialog text, and new-window URLs as
untrusted content. A new-window event is only a URL handoff: CEF cancels the
original popup; opener relationships, POST bodies and window handles are not
preserved. Hosts must validate schemes and destinations before external launch
or loading local files. The plugin does not implement a navigation allowlist or
prevent the host from loading `file:` URLs.

Browser instances share the configured CEF profile/cache and may share cookies
and storage. Independent controller/texture ownership is not profile isolation.
Use an application-specific absolute cache directory and do not share it between
simultaneous application processes. The subprocess is an ordinary executable;
the build does not install setuid helpers or alter host security settings.

Shipping requires review of CEF's bundled `lib/LICENSE.txt`, Flutter/Dart and
application dependency notices. The project's MIT license does not relicense
third-party binaries. Proprietary codecs and DRM are not provided or promised.
