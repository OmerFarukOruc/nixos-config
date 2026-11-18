# Lend this Windows machine's logged-in Chromium browser (Brave, Chrome, Chromium, Edge) to agents on devbox, only
# while a task needs it. The Linux and macOS version is browser-lend.
#   browser-lend.ps1 on [name]   forward a loopback port on devbox to the browser's DevTools port over SSH; [name] picks
#                                a browser whose profile folder contains it, e.g. chrome
#   browser-lend.ps1 off         stop the forward
#   browser-lend.ps1 status      show whether this machine lends a browser
# Run it with: powershell -ExecutionPolicy Bypass -File browser-lend.ps1 on
# First turn on remote debugging at <browser>://inspect/#remote-debugging. On devbox an agent connects with
# box-browser --brave --on <this machine>, and the browser asks you to Allow it.
# DevTools has no password: while it is on, every process of the SSH user on devbox, and root there, can drive this
# browser. BROWSER_LEND_HOST names another SSH destination than devbox.
param([string]$Action, [string]$Name)

function Show-Usage { Get-Content $PSCommandPath | Select-Object -Skip 2 -First 4 | ForEach-Object { $_ -replace '^# *', '' } }
if ($Action -in '-h', '--help') {
  Show-Usage
  exit 0
}

$sshHost = if ($env:BROWSER_LEND_HOST) { $env:BROWSER_LEND_HOST } else { 'devbox' }
$me = $env:COMPUTERNAME.ToLower()
$lent = ".local/state/browser-lend/$me"
$pidFile = Join-Path $env:TEMP 'browser-lend.pid'
$lockFile = Join-Path $env:TEMP 'browser-lend.lock'
$errFile = Join-Path $env:TEMP 'browser-lend.err'
$files = 'BraveSoftware\Brave-Browser', 'Google\Chrome', 'Chromium', 'Microsoft\Edge' |
  ForEach-Object { Join-Path $env:LOCALAPPDATA "$_\User Data\DevToolsActivePort" }

function Test-Listening([int]$Port) {
  try { (New-Object Net.Sockets.TcpClient '127.0.0.1', $Port).Close(); $true } catch { $false }
}

function Get-ActivePortFile {
  Get-Item $files -ErrorAction SilentlyContinue |
    Where-Object { $_.Length -gt 0 -and (-not $Name -or $_.FullName -match [regex]::Escape($Name)) } |
    Sort-Object LastWriteTime -Descending |
    Where-Object { Test-Listening ((Get-Content $_.FullName)[0]) } |
    Select-Object -First 1
}

function Get-Tunnel {
  if (-not (Test-Path $pidFile)) { return }
  $id, $start = Get-Content $pidFile
  $p = Get-Process -Id $id -ErrorAction SilentlyContinue
  if ($p -and $p.ProcessName -eq 'ssh' -and $p.StartTime.ToString('o') -eq $start) { $p } else { Remove-Item $pidFile }
}

switch ($Action) {
  'on' {
    try { $lock = [IO.File]::Open($lockFile, 'OpenOrCreate', 'ReadWrite', 'None') }
    catch { [Console]::Error.WriteLine('browser-lend: another browser-lend.ps1 on runs'); exit 1 }
    if (Get-Tunnel) { [Console]::Error.WriteLine('browser-lend: already lending; run browser-lend.ps1 off first'); exit 1 }
    $f = Get-ActivePortFile
    if (-not $f) { [Console]::Error.WriteLine('browser-lend: no browser with remote debugging on; turn it on at <browser>://inspect/#remote-debugging'); exit 1 }
    $port, $path = Get-Content $f.FullName
    # A remote forward to port 0 makes sshd pick a free port, and ssh names it on stderr.
    $p = Start-Process ssh -PassThru -WindowStyle Hidden -RedirectStandardError $errFile -ArgumentList @(
      '-N', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', '-o', 'ServerAliveInterval=30',
      '-o', 'ExitOnForwardFailure=yes', '-R', "127.0.0.1:0:127.0.0.1:$port", $sshHost)
    $remotePort = $null
    for ($i = 0; $i -lt 30 -and -not $remotePort -and -not $p.HasExited; $i++) {
      Start-Sleep -Seconds 1
      $m = Select-String -Path $errFile -Pattern 'Allocated port (\d+)' -ErrorAction SilentlyContinue | Select-Object -First 1
      if ($m) { $remotePort = $m.Matches[0].Groups[1].Value }
    }
    if (-not $remotePort) {
      if (-not $p.HasExited) { Stop-Process -Id $p.Id }
      [Console]::Error.WriteLine("browser-lend: the forward to $sshHost failed: $(Get-Content $errFile -Raw)"); exit 1
    }
    ssh -o BatchMode=yes $sshHost "umask 077; mkdir -p .local/state/browser-lend && printf '%s %s\n' $remotePort $path > $lent"
    if ($LASTEXITCODE) { Stop-Process -Id $p.Id; [Console]::Error.WriteLine("browser-lend: could not write $lent on $sshHost"); exit 1 }
    Set-Content $pidFile $p.Id, $p.StartTime.ToString('o')
    $lock.Close()
    "browser-lend: lending $($f.DirectoryName); on $sshHost run box-browser --brave --on $me"
  }
  'off' {
    $t = Get-Tunnel
    ssh -o BatchMode=yes $sshHost "rm -f $lent" 2>$null
    if ($LASTEXITCODE) { [Console]::Error.WriteLine("browser-lend: could not remove $lent on $sshHost") }
    if ($t) { Stop-Process -Id $t.Id }
    Remove-Item $pidFile -ErrorAction SilentlyContinue
    'browser-lend: off'
  }
  'status' {
    if (Get-Tunnel) { 'on' } else { 'off' }
  }
  default {
    Show-Usage
    exit 2
  }
}
