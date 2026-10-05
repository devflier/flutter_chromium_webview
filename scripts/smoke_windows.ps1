param(
  [Parameter(Mandatory=$true)][string]$Bundle,
  [Parameter(Mandatory=$true)][string]$LogDirectory
)
$ErrorActionPreference = 'Stop'
$Bundle = (Resolve-Path -LiteralPath $Bundle).Path
New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
$LogDirectory = (Resolve-Path -LiteralPath $LogDirectory).Path
$executable = Join-Path $Bundle 'flutter_chromium_webview_example.exe'
$stderr = Join-Path $LogDirectory 'windows-packaged-stderr.log'
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public class ChromiumSmokeWindow {
  public delegate bool Callback(IntPtr h, IntPtr p);
  [DllImport("user32.dll")] static extern bool EnumWindows(Callback callback, IntPtr p);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder b, int count);
  [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, uint message, IntPtr w, IntPtr l);
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
$testProcess = Start-Process -FilePath $executable -WorkingDirectory $Bundle -WindowStyle Hidden `
  -RedirectStandardOutput (Join-Path $LogDirectory 'windows-packaged-stdout.log') `
  -RedirectStandardError $stderr -PassThru
try {
  $deadline = [DateTime]::UtcNow.AddSeconds(45)
  do {
    Start-Sleep -Milliseconds 500
    $testProcess.Refresh()
    if ($testProcess.HasExited) { throw 'Application exited before CEF startup' }
    $initialized = (Test-Path -LiteralPath $stderr) -and
      ((Get-Content -LiteralPath $stderr -Raw) -match '\[CEF\] Initialization result: 1')
  } while (!$initialized -and [DateTime]::UtcNow -lt $deadline)
  if (!$initialized) { throw 'CEF startup timed out' }
  Start-Sleep -Seconds 3
  if (![ChromiumSmokeWindow]::Close([uint32]$testProcess.Id)) { throw 'No application window to close' }
  if (!$testProcess.WaitForExit(20000)) { throw 'Normal window close timed out' }
  if ($testProcess.ExitCode -ne 0) { throw "Application exit: $($testProcess.ExitCode)" }
  if ((Get-Content -LiteralPath $stderr -Raw) -notmatch '\[CEF\] Shutdown complete') {
    throw 'Missing CEF shutdown completion'
  }
  $survivors = Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -eq $executable }
  if ($survivors) { throw 'CEF subprocesses survived normal close' }
  Write-Output 'Copied Windows bundle startup and normal shutdown passed'
} finally {
  $testProcess.Refresh()
  if (!$testProcess.HasExited) { Stop-Process -Id $testProcess.Id }
}
