param([Parameter(Mandatory=$true)][string]$Destination, [switch]$NoBuild)
$ErrorActionPreference = 'Stop'
if (![System.IO.Path]::IsPathRooted($Destination)) { throw 'Destination must be absolute' }
$Destination = [System.IO.Path]::GetFullPath($Destination).TrimEnd('\')
if (Test-Path -LiteralPath $Destination) { throw 'Choose a new output directory' }
$projectRoot = Split-Path -Parent $PSScriptRoot
$examplePath = Join-Path $projectRoot 'packages/flutter_chromium_webview/example'
Push-Location $examplePath
try {
  if (!$NoBuild) {
    & flutter pub get --enforce-lockfile
    if ($LASTEXITCODE) { throw 'Locked dependency resolution failed' }
    & flutter build windows --release --no-pub
    if ($LASTEXITCODE) { throw 'Release build failed' }
  }
  $bundle = Join-Path $examplePath 'build/windows/x64/runner/Release'
  foreach ($file in @('flutter_chromium_webview_example.exe', 'flutter_chromium_webview_example.dll', 'libcef.dll', 'LICENSE.txt')) {
    if (!(Test-Path -LiteralPath (Join-Path $bundle $file))) { throw "Missing bundle file: $file" }
  }
  New-Item -ItemType Directory -Path $Destination | Out-Null
  Get-ChildItem -LiteralPath $bundle | Where-Object { $_.Name -ne 'cef_sub.exe' -and $_.Extension -ne '.pdb' } |
    ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $Destination -Recurse }
  Copy-Item -LiteralPath (Join-Path $projectRoot 'LICENSE') -Destination (Join-Path $Destination 'LICENSE.flutter_chromium_webview')
  Copy-Item -LiteralPath (Join-Path $projectRoot 'docs/security.md') -Destination (Join-Path $Destination 'SECURITY.md')
  Copy-Item -LiteralPath (Join-Path $projectRoot 'docs/release-readiness.md') -Destination (Join-Path $Destination 'RELEASE-STATUS.md')
  $hashes = Get-ChildItem -LiteralPath $Destination -Recurse -File | Sort-Object FullName | ForEach-Object {
    $relative = $_.FullName.Substring($Destination.Length + 1).Replace('\', '/')
    "$( (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLower() )  $relative"
  }
  $hashes | Set-Content -LiteralPath (Join-Path $Destination 'SHA256SUMS') -Encoding UTF8
  Write-Output "Bundle created: $Destination"
} finally { Pop-Location }
