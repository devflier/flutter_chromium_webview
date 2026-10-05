param([string]$Device = 'emulator-5554', [switch]$LiveYoutube, [switch]$HeadlessYoutube)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$packagePath = Join-Path $projectRoot 'packages/flutter_chromium_webview'
Push-Location $packagePath
try {
  & flutter pub get
  if ($LASTEXITCODE) { throw 'Dependency resolution failed' }
  & flutter analyze
  if ($LASTEXITCODE) { throw 'Package analysis failed' }
  & flutter test
  if ($LASTEXITCODE) { throw 'Dart regressions failed' }
  Set-Location (Join-Path $packagePath 'example')
  & flutter pub get
  if ($LASTEXITCODE) { throw 'Example dependency resolution failed' }
  & flutter analyze
  if ($LASTEXITCODE) { throw 'Example analysis failed' }
  & flutter test test
  if ($LASTEXITCODE) { throw 'Example regressions failed' }
  foreach ($suite in @('android_backend_test', 'javascript_bridge_test', 'html_loading_test', 'browser_settings_test', 'youtube_adapter_test')) {
    & flutter test "integration_test/$suite.dart" -d $Device --no-pub
    if ($LASTEXITCODE) { throw "Android integration failed: $suite" }
  }
  if ($LiveYoutube) {
    & flutter test integration_test/youtube_live_test.dart -d $Device --no-pub --dart-define=YOUTUBE_LIVE=true
    if ($LASTEXITCODE) { throw 'Live YouTube check failed' }
  }
  if ($HeadlessYoutube) {
    & flutter test integration_test/youtube_live_test.dart -d $Device --no-pub --dart-define=YOUTUBE_LIVE=true --dart-define=YOUTUBE_HEADLESS=true
    if ($LASTEXITCODE) { throw 'Headless YouTube check failed' }
  }
  # Refresh plugin registration after integration tests, which add their own
  # Android plugin only to the test build.
  & flutter build apk --release
  if ($LASTEXITCODE) { throw 'Release APK build failed' }
  & (Join-Path $PSScriptRoot 'smoke_android.ps1') -Device $Device
  if ($LASTEXITCODE) { throw 'Android release smoke check failed' }
} finally { Pop-Location }
