param([string]$Device = 'emulator-5554', [string]$Adb = 'adb')
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$apk = Join-Path $projectRoot 'packages/flutter_chromium_webview/example/build/app/outputs/flutter-apk/app-release.apk'
$outputPath = Join-Path $projectRoot 'docs/validation'
New-Item -ItemType Directory -Force -Path $outputPath | Out-Null
$snapshotPath = Join-Path $outputPath 'android-release-smoke-ui.xml'
function Invoke-Android([string[]]$Arguments) {
  & $Adb -s $Device @Arguments
  if ($LASTEXITCODE) { throw "Android command failed: $($Arguments[0])" }
}
function Wait-Node([scriptblock]$Match) {
  $deadline = (Get-Date).AddSeconds(25)
  do {
    & $Adb -s $Device shell uiautomator dump /sdcard/chromium-smoke-ui.xml 2>&1 | Out-Null
    if ($LASTEXITCODE) { continue } # The accessibility root may not exist during startup.
    Invoke-Android @('pull', '/sdcard/chromium-smoke-ui.xml', $snapshotPath) | Out-Null
    [xml]$snapshot = Get-Content -LiteralPath $snapshotPath -Raw
    $nodes = @($snapshot.SelectNodes('//node') | Where-Object $Match)
    if ($nodes.Count) { return $nodes[0] }
  } while ((Get-Date) -lt $deadline)
  throw "Expected Android UI node not found; inspect $snapshotPath"
}
function Tap-Node($Node) {
  $coordinates = @([regex]::Matches($Node.bounds, '\d+') | ForEach-Object { [int]$_.Value })
  if ($coordinates.Count -ne 4) { throw 'Missing UI bounds' }
  $x = [int](($coordinates[0] + $coordinates[2]) / 2)
  $y = [int](($coordinates[1] + $coordinates[3]) / 2)
  Invoke-Android @('shell', 'input', 'tap', "$x", "$y")
}
try {
  'Running Android release smoke check.' | Set-Content (Join-Path $outputPath 'android-release-smoke.log')
  Invoke-Android @('install', '-r', $apk)
  Invoke-Android @('shell', 'wm', 'dismiss-keyguard')
  Invoke-Android @('shell', 'am', 'start', '-W', '-n', 'com.example.flutter_chromium_webview_example/.MainActivity')
  Tap-Node (Wait-Node { $_.'content-desc' -eq 'Test pages' })
  Tap-Node (Wait-Node { $_.'content-desc' -eq 'Input test' })
  Tap-Node (Wait-Node { $_.class -eq 'android.widget.EditText' -and $_.hint -eq 'First field' })
  # Wait for the keyboard and viewport resize to settle before injecting keys.
  Wait-Node { $_.class -eq 'android.widget.EditText' -and $_.hint -eq 'First field' -and $_.focused -eq 'true' } | Out-Null
  Invoke-Android @('shell', 'input', 'text', 'ppplayer-android')
  Wait-Node { $_.class -eq 'android.widget.EditText' -and $_.text -eq 'ppplayer-android' } | Out-Null
  Invoke-Android @('shell', 'input', 'keyevent', 'KEYCODE_BACK')
  Tap-Node (Wait-Node { $_.class -eq 'android.widget.Button' -and $_.text -eq 'Alert' })
  Wait-Node { $_.'content-desc' -eq 'Hello from Chromium!' -or $_.text -eq 'Hello from Chromium!' } | Out-Null
  Tap-Node (Wait-Node { $_.'content-desc' -eq 'OK' -or $_.text -eq 'OK' })
  Wait-Node { $_.class -eq 'android.widget.EditText' -and $_.text -eq 'ppplayer-android' } | Out-Null
  'Release startup, native touch, keyboard input and JavaScript alert passed.' | Set-Content (Join-Path $outputPath 'android-release-smoke.log')
} catch {
  "FAILED: $($_.Exception.Message)" | Set-Content (Join-Path $outputPath 'android-release-smoke.log')
  throw
} finally {
  Invoke-Android @('shell', 'screencap', '-p', '/sdcard/chromium-smoke.png')
  Invoke-Android @('pull', '/sdcard/chromium-smoke.png', (Join-Path $outputPath 'android-release.png')) | Out-Null
}
