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
function Wait-Node([string]$Name, [scriptblock]$Match, [scriptblock]$Retry) {
  $deadline = (Get-Date).AddSeconds(25)
  do {
    & $Adb -s $Device shell uiautomator dump /sdcard/chromium-smoke-ui.xml 2>&1 | Out-Null
    if ($LASTEXITCODE) { continue } # The accessibility root may not exist during startup.
    Invoke-Android @('pull', '/sdcard/chromium-smoke-ui.xml', $snapshotPath) | Out-Null
    [xml]$snapshot = Get-Content -LiteralPath $snapshotPath -Raw
    $nodes = @($snapshot.SelectNodes('//node') | Where-Object $Match)
    if ($nodes.Count) { 
      $global:lastSuccessfulNode = $Name
      return $nodes[0] 
    }
    if ($Retry) { & $Retry $snapshot }
  } while ((Get-Date) -lt $deadline)
  throw "Wait-Node Timeout: Expected Android UI node '$Name' not found. Last successful checkpoint: '$global:lastSuccessfulNode'. Inspect $snapshotPath for current UI state."
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
  Tap-Node (Wait-Node -Name 'Test pages menu' { $_.'content-desc' -eq 'Test pages' -or $_.text -eq 'Test pages' })
  Tap-Node (Wait-Node -Name 'Input test item' { $_.'content-desc' -eq 'Input test' -or $_.text -eq 'Input test' })
  Tap-Node (Wait-Node -Name 'First field input' { $_.hint -eq 'First field' -or $_.text -eq 'First field' -or $_.'content-desc' -eq 'First field' })
  # Wait for the keyboard and viewport resize to settle before injecting keys.
  Wait-Node -Name 'First field focused' -Match { ($_.hint -eq 'First field' -or $_.text -eq 'First field' -or $_.'content-desc' -eq 'First field') -and $_.focused -eq 'true' } -Retry {
    param($CurrentSnapshot)
    # The first tap may focus the platform view while the page is still laying
    # out. Retry using current bounds; keep requiring DOM input focus and text.
    $field = @($CurrentSnapshot.SelectNodes('//node') | Where-Object {
      $_.'resource-id' -eq 'first' -and $_.bounds -ne '[0,0][0,0]'
    })
    if ($field.Count) { Tap-Node $field[0] }
  } | Out-Null
  Invoke-Android @('shell', 'input', 'text', 'ppplayer-android')
  Wait-Node -Name 'Input updated text' { $_.text -match 'ppplayer-android' -or $_.'content-desc' -match 'ppplayer-android' } | Out-Null
  Invoke-Android @('shell', 'input', 'keyevent', 'KEYCODE_BACK')
  Tap-Node (Wait-Node -Name 'Alert button' -Match {
    ($_.text -eq 'Alert' -or $_.'content-desc' -eq 'Alert') -and $_.bounds -ne '[0,0][0,0]'
  } -Retry {
    param($CurrentSnapshot)
    # Small emulator viewports expose off-screen nodes with zero bounds. Scroll
    # the actual WebView until the button is visible before attempting a tap.
    $webView = $CurrentSnapshot.SelectSingleNode('//node[@class="android.webkit.WebView"]')
    if ($webView) {
      $bounds = @([regex]::Matches($webView.bounds, '\d+') | ForEach-Object { [int]$_.Value })
      if ($bounds.Count -eq 4) {
        $x = [int](($bounds[0] + $bounds[2]) / 2)
        $startY = $bounds[3] - 60
        $endY = $bounds[1] + 60
        Invoke-Android @('shell', 'input', 'swipe', "$x", "$startY", "$x", "$endY", '350')
      }
    }
  })
  Wait-Node -Name 'Chromium alert dialog' { $_.'content-desc' -match 'Hello from Chromium!' -or $_.text -match 'Hello from Chromium!' } | Out-Null
  Tap-Node (Wait-Node -Name 'Alert OK button' { $_.'content-desc' -eq 'OK' -or $_.text -eq 'OK' })
  Wait-Node -Name 'Check input persists' { $_.text -match 'ppplayer-android' -or $_.'content-desc' -match 'ppplayer-android' } | Out-Null
  'Release startup, native touch, keyboard input and JavaScript alert passed.' | Set-Content (Join-Path $outputPath 'android-release-smoke.log')
} catch {
  "FAILED: $($_.Exception.Message)" | Set-Content (Join-Path $outputPath 'android-release-smoke.log')
  throw
} finally {
  Invoke-Android @('shell', 'screencap', '-p', '/sdcard/chromium-smoke.png')
  Invoke-Android @('pull', '/sdcard/chromium-smoke.png', (Join-Path $outputPath 'android-release.png')) | Out-Null
}
