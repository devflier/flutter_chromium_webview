param(
  [string]$BundlePath = "",
  [int]$IdleSeconds = 10
)
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $BundlePath) {
  $BundlePath = Join-Path $repoRoot 'packages\flutter_chromium_webview\example\build\windows\x64\runner\Release'
}
$exe = Join-Path (Resolve-Path -LiteralPath $BundlePath).Path 'flutter_chromium_webview_example.exe'
if (-not (Test-Path $exe)) {
  throw "Release executable not found: $exe. Run 'flutter build windows --release' first."
}

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public class BenchmarkWindowCloser {
  public delegate bool Callback(IntPtr h, IntPtr p);
  [DllImport("user32.dll")] static extern bool EnumWindows(Callback callback, IntPtr p);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder b, int count);
  [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, uint message, IntPtr w, IntPtr l);
  public static bool HasWindow(uint pid) {
    bool found = false;
    EnumWindows((h, p) => {
      uint owner; GetWindowThreadProcessId(h, out owner);
      if (owner == pid) {
        var title = new StringBuilder(256); GetWindowText(h, title, title.Capacity);
        if (title.ToString() == "flutter_chromium_webview_example") found = true;
      }
      return true;
    }, IntPtr.Zero);
    return found;
  }
  public static bool Close(uint pid) {
    bool closed = false;
    EnumWindows((h, p) => {
      uint owner; GetWindowThreadProcessId(h, out owner);
      if (owner == pid) {
        var title = new StringBuilder(256); GetWindowText(h, title, title.Capacity);
        if (title.ToString() == "flutter_chromium_webview_example")
          closed = PostMessage(h, 0x10, IntPtr.Zero, IntPtr.Zero);
      }
      return true;
    }, IntPtr.Zero);
    return closed;
  }
}
'@

function Get-ProcessTree([int]$RootPid) {
  $all = Get-CimInstance Win32_Process | Select-Object ProcessId, ParentProcessId, Name, WorkingSetSize, PrivatePageCount
  $byParent = @{}
  foreach ($p in $all) {
    $ppid = [int]$p.ParentProcessId
    if (-not $byParent.ContainsKey($ppid)) { $byParent[$ppid] = @() }
    $byParent[$ppid] += $p
  }
  $result = @()
  $queue = [System.Collections.Queue]::new()
  $queue.Enqueue($RootPid)
  $seen = @{}
  while ($queue.Count -gt 0) {
    $curr = $queue.Dequeue()
    if ($seen.ContainsKey($curr)) { continue }
    $seen[$curr] = $true
    $proc = $all | Where-Object { $_.ProcessId -eq $curr } | Select-Object -First 1
    if ($proc) { $result += $proc }
    if ($byParent.ContainsKey($curr)) {
      foreach ($child in $byParent[$curr]) { $queue.Enqueue([int]$child.ProcessId) }
    }
  }
  return $result
}

$logDir = Join-Path $env:TEMP 'fcw_bench_logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$stderr = Join-Path $logDir 'bench-stderr.log'
$stdout = Join-Path $logDir 'bench-stdout.log'
if (Test-Path $stderr) { Remove-Item $stderr -Force }
if (Test-Path $stdout) { Remove-Item $stdout -Force }

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$proc = Start-Process -FilePath $exe -WorkingDirectory $BundlePath -WindowStyle Hidden `
  -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
$rootPid = $proc.Id

$startupMs = -1
while ($sw.Elapsed.TotalSeconds -lt 25) {
  $proc.Refresh()
  if ($proc.HasExited) { throw "Process exited prematurely" }
  $initialized = (Test-Path -LiteralPath $stderr) -and
    ((Get-Content -LiteralPath $stderr -Raw) -match '\[CEF\] Initialization result: 1')
  if ($initialized -and [BenchmarkWindowCloser]::HasWindow([uint32]$rootPid)) {
    $startupMs = [Math]::Round($sw.Elapsed.TotalMilliseconds, 1)
    break
  }
  Start-Sleep -Milliseconds 50
}

# Allow initial page load to settle
Start-Sleep -Seconds 4

$logicalCores = [Environment]::ProcessorCount
$cpuBefore = @{}
$treeStart = Get-ProcessTree -RootPid $rootPid
foreach ($p in $treeStart) {
  try {
    $gp = Get-Process -Id $p.ProcessId -ErrorAction Stop
    $cpuBefore[$p.ProcessId] = $gp.TotalProcessorTime.TotalSeconds
  } catch {}
}

$peakRssMb = 0.0
$peakPrivMb = 0.0
$rssSamples = @()
$privSamples = @()
$childCounts = @()

$sampleWatch = [System.Diagnostics.Stopwatch]::StartNew()
for ($s = 0; $s -lt $IdleSeconds; $s++) {
  Start-Sleep -Seconds 1
  $tree = Get-ProcessTree -RootPid $rootPid
  $rssBytes = ($tree | Measure-Object -Property WorkingSetSize -Sum).Sum
  $privBytes = ($tree | Measure-Object -Property PrivatePageCount -Sum).Sum
  $rssMb = [Math]::Round($rssBytes / 1MB, 2)
  $privMb = [Math]::Round($privBytes / 1MB, 2)
  $rssSamples += $rssMb
  $privSamples += $privMb
  $childCounts += ([Math]::Max(0, $tree.Count - 1))
  if ($rssMb -gt $peakRssMb) { $peakRssMb = $rssMb }
  if ($privMb -gt $peakPrivMb) { $peakPrivMb = $privMb }
}
$elapsedSec = $sampleWatch.Elapsed.TotalSeconds

$treeEnd = Get-ProcessTree -RootPid $rootPid
$totalCpuDelta = 0.0
$mainCpuDelta = 0.0
foreach ($p in $treeEnd) {
  try {
    $gp = Get-Process -Id $p.ProcessId -ErrorAction Stop
    $prev = if ($cpuBefore.ContainsKey($p.ProcessId)) { $cpuBefore[$p.ProcessId] } else { 0.0 }
    $delta = [Math]::Max(0.0, $gp.TotalProcessorTime.TotalSeconds - $prev)
    $totalCpuDelta += $delta
    if ($p.ProcessId -eq $rootPid) { $mainCpuDelta = $delta }
  } catch {}
}

$mainSingleCorePct = [Math]::Round(($mainCpuDelta / $elapsedSec) * 100.0, 2)
$treeSingleCorePct = [Math]::Round(($totalCpuDelta / $elapsedSec) * 100.0, 2)
$mainSystemCpuPct = [Math]::Round($mainSingleCorePct / $logicalCores, 2)
$treeSystemCpuPct = [Math]::Round($treeSingleCorePct / $logicalCores, 2)
$avgRssMb = [Math]::Round(($rssSamples | Measure-Object -Average).Average, 2)
$avgPrivMb = [Math]::Round(($privSamples | Measure-Object -Average).Average, 2)
$maxChildren = ($childCounts | Measure-Object -Maximum).Maximum

$closeWatch = [System.Diagnostics.Stopwatch]::StartNew()
$closed = [BenchmarkWindowCloser]::Close([uint32]$rootPid)
$exitedCleanly = $proc.WaitForExit(15000)
$closeMs = [Math]::Round($closeWatch.Elapsed.TotalMilliseconds, 1)
if (-not $exitedCleanly) {
  Stop-Process -Id $rootPid -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Milliseconds 500
$cefShutdownOk = (Test-Path -LiteralPath $stderr) -and
  ((Get-Content -LiteralPath $stderr -Raw) -match '\[CEF\] Shutdown complete')
$survivors = @(Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -eq $exe })
$orphans = $survivors.Count

$report = [ordered]@{
  platform = 'windows-x64'
  buildMode = 'Release'
  logicalProcessors = $logicalCores
  startupMs = $startupMs
  idleWindowSec = [Math]::Round($elapsedSec, 2)
  mainProcessIdleCpuSingleCorePct = $mainSingleCorePct
  mainProcessIdleCpuSystemPct = $mainSystemCpuPct
  processTreeIdleCpuSingleCorePct = $treeSingleCorePct
  processTreeIdleCpuSystemPct = $treeSystemCpuPct
  avgTreeWorkingSetMb = $avgRssMb
  peakTreeWorkingSetMb = $peakRssMb
  avgTreePrivateBytesMb = $avgPrivMb
  peakTreePrivateBytesMb = $peakPrivMb
  maxChildProcesses = $maxChildren
  windowClosePosted = $closed
  exitClean = $exitedCleanly
  cefShutdownComplete = $cefShutdownOk
  shutdownMs = $closeMs
  orphanProcesses = $orphans
}
$report | ConvertTo-Json -Depth 4
if (-not $exitedCleanly -or -not $cefShutdownOk -or $orphans -gt 0) {
  exit 1
}
