param([string]$Device = 'emulator-5554', [switch]$LiveYoutube, [switch]$HeadlessYoutube)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$packagePath = Join-Path $projectRoot 'packages/flutter_chromium_webview'
$diagnostics = Join-Path $projectRoot 'docs/validation/android'
New-Item -ItemType Directory -Force -Path $diagnostics | Out-Null
& flutter --version 2>&1 | Set-Content (Join-Path $diagnostics 'flutter-version.txt')
& dart --version 2>&1 | Set-Content (Join-Path $diagnostics 'dart-version.txt')
& java -version 2>&1 | Set-Content (Join-Path $diagnostics 'java-version.txt')
& python3 -m unittest discover -s $PSScriptRoot -p test_android_diagnostics.py -v
if ($LASTEXITCODE) { throw 'Android diagnostic wrapper regressions failed' }
& python3 (Join-Path $PSScriptRoot 'ensure_monorepo_overrides.py')
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
    & python3 (Join-Path $PSScriptRoot 'android_diagnostic_stage.py') --directory (Join-Path $diagnostics $suite) --device $Device flutter test "integration_test/$suite.dart" -d $Device --no-pub -v
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
