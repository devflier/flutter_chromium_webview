# Security Policy

## Reporting Security Vulnerabilities

If you discover a security vulnerability in `flutter_chromium_webview`, please **do NOT** open a public issue on GitHub.

Instead, please report security vulnerabilities responsibly by contacting the maintainers or emailing the security contact:
- **Email**: `lucasveneno@yandex.com`

Please include:
1. Description of the vulnerability.
2. Steps to reproduce or proof-of-concept code.
3. Affected platforms (macOS, Windows, Linux, Android) and versions.
4. Potential impact.

We will acknowledge receipt within 48 hours and work with you to analyze, patch, and release a fix before public disclosure.

## Security Architecture & Boundaries

### Embedded CEF Runtimes (Desktop)
- The CEF runtime is pinned to version `149.0.4+g2f1bfd8+chromium-149.0.7827.156` with verified SHA-256 binary checksums.
- Automatic or silent upgrades are deliberately disabled to prevent supply chain tampering.
- CEF sandboxing remains enabled. Windows runs the sandboxed runner bootstrap; macOS configures separate signed helper variants for renderers, GPU, and utility processes.
- There is no automatic `--no-sandbox` fallback.

### JavaScript Bridge
- JavaScript channels use explicit origin allowlists (`allowedOrigins`).
- Inbound messages across the bridge are capped at 64 KiB UTF-8 to prevent buffer exhaustion and native heap memory attacks.
- Untrusted content (dialog text, page titles, popup URLs) must be validated by the host application prior to external handling.

### Android System WebView
- Android uses the device's installed system Chromium WebView provider.
- Cleartext HTTP is restricted in production by default; HTTPS is strongly enforced.

For detailed security background, see [docs/security.md](docs/security.md).
