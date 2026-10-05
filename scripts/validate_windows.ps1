param([switch]$SkipRelease, [string]$CMake)
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
  if ($LASTEXITCODE) { throw 'Example widget regressions failed' }
  # Flutter 3.47's DesktopLogReader closes its stream after the first process.
  # Each suite needs a fresh Flutter invocation, on Windows and Linux alike.
  foreach ($suite in @('plugin_integration_test', 'input_scaling_test', 'native_ui_test', 'windows_keyboard_test', 'javascript_bridge_test', 'html_loading_test', 'browser_settings_test', 'youtube_adapter_test')) {
    & flutter test "integration_test/$suite.dart" -d windows --no-pub
    if ($LASTEXITCODE) { throw "Integration suite failed: $suite" }
  }
  # Integration tests leave a temporary Dart listener in generated_config.cmake.
  # Restore the normal target before invoking CMake outside flutter test.
  & flutter build windows --debug --no-pub
  if ($LASTEXITCODE) { throw 'Windows debug build failed' }
  if (!$CMake) {
    $cmakeCommand = Get-Command cmake -ErrorAction SilentlyContinue
    if ($cmakeCommand) { $CMake = $cmakeCommand.Source }
    else {
      $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
      $vsPath = & $vswhere -latest -property installationPath -requires Microsoft.VisualStudio.Component.VC.CMake.Project
      $CMake = Join-Path $vsPath 'Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe'
    }
  }
  & $CMake -S windows -B build/windows/x64 -DCHROMIUM_WEBVIEW_BUILD_TESTS=ON
  if ($LASTEXITCODE) { throw 'Native test configuration failed' }
  & $CMake --build build/windows/x64 --config Debug --target chromium_webview_texture_test
  if ($LASTEXITCODE) { throw 'Native test compilation failed' }
  & ./build/windows/x64/plugins/flutter_chromium_webview/Debug/chromium_webview_texture_test.exe
  if ($LASTEXITCODE) { throw 'Native frame ownership regressions failed' }
  if (!$SkipRelease) {
    & flutter build windows --release --no-pub
    if ($LASTEXITCODE) { throw 'Windows release build failed' }
  }
} finally {
  Pop-Location
}
