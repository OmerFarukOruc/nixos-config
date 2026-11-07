# Lend this Windows machine's logged-in Chromium browser (Brave, Chrome, Chromium, Edge) to agents on devbox
# over the tailnet, only while a task needs it. The Linux and macOS version is browser-lend.
#   browser-lend.ps1 on [name]   forward tailnet TCP 9222 to the browser's CDP port and publish its websocket path on
#                                tailnet HTTPS 9223; [name] picks a browser whose profile folder contains it, e.g. chrome
#   browser-lend.ps1 off         stop both
#   browser-lend.ps1 status      show whether this machine lends a browser
# Run it with: powershell -ExecutionPolicy Bypass -File browser-lend.ps1 on
# First turn on remote debugging at <browser>://inspect/#remote-debugging. On the box an agent connects with
# brave-browser --on <this machine>, and the browser asks you to Allow it.
# CDP has no password: while it is on, every omer process on the box can drive this browser.
param([string]$Action, [string]$Name)

function Show-Usage { Get-Content $PSCommandPath | Select-Object -Skip 2 -First 4 | ForEach-Object { $_ -replace '^# *', '' } }
if ($args[0] -in '-h', '--help') {
  Show-Usage
  exit 0
}

$ts = (Get-Command tailscale -ErrorAction SilentlyContinue).Source
if (-not $ts) { $ts = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe' }
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

function Invoke-Tailscale {
  & $ts @args | Out-Null
  if ($LASTEXITCODE) { [Console]::Error.WriteLine("browser-lend: tailscale $args failed"); exit 1 }
}

switch ($Action) {
  'on' {
    $f = Get-ActivePortFile
    if (-not $f) { [Console]::Error.WriteLine('browser-lend: no browser with remote debugging on; turn it on at <browser>://inspect/#remote-debugging'); exit 1 }
    $port, $path = Get-Content $f.FullName
    Invoke-Tailscale serve --bg --tcp 9222 "tcp://127.0.0.1:$port"
    Invoke-Tailscale serve --bg --https=9223 "text:$path"
    $me = ((& $ts status --json | ConvertFrom-Json).Self.DNSName -split '\.')[0]
    "browser-lend: lending $($f.DirectoryName); on devbox run brave-browser --on $me"
  }
  'off' {
    & $ts serve --tcp 9222 off 2>$null | Out-Null
    & $ts serve --https=9223 off 2>$null | Out-Null
    'browser-lend: off'
  }
  'status' {
    $tcp = (& $ts serve status --json | ConvertFrom-Json).TCP
    if ($tcp -and $tcp.PSObject.Properties.Name -contains '9222') { 'on' } else { 'off' }
  }
  default {
    Show-Usage
    exit 2
  }
}
