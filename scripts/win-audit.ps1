# win-audit.ps1 - read-only audit, changes nothing
# Run: powershell -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\win-audit.ps1"
$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'
$VERSION = '1.1'

$Desktop = [Environment]::GetFolderPath('Desktop')
if (-not $Desktop) { $Desktop = $env:USERPROFILE }
$out = Join-Path $Desktop 'win-audit.txt'

$sb = [System.Text.StringBuilder]::new()
function W([string]$s) { [void]$sb.AppendLine($s); Write-Host $s }
function T([string]$s) { W ''; W ('===== ' + $s + ' =====') }

W ('win-audit v' + $VERSION + '  ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
W 'READ-ONLY. No settings are changed.'

# ---------- 1 ----------
T '1. BASIC'
W ('Computer: ' + $env:COMPUTERNAME)
W ('User    : ' + [Security.Principal.WindowsIdentity]::GetCurrent().Name)
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
W ('Admin   : ' + $isAdmin + '   (False = a few sections will be empty, that is normal)')
$os = Get-CimInstance Win32_OperatingSystem
if ($os) {
  W ('OS      : ' + $os.Caption + '  build ' + $os.BuildNumber)
  W ('Uptime  : ' + [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalHours, 1) + ' hours')
}
W ('TimeZone: ' + (Get-TimeZone).Id)

# ---------- 2 ----------
T '2. TCP LISTENERS'
$listen = @()
try { $listen = @(Get-NetTCPConnection -State Listen) } catch { }
if ($listen.Count -gt 0) {
  $procCache = @{}
  foreach ($c in ($listen | Sort-Object LocalPort)) {
    $pnum = [int]$c.OwningProcess
    if (-not $procCache.ContainsKey($pnum)) {
      $procCache[$pnum] = (Get-Process -Id $pnum -ErrorAction SilentlyContinue).ProcessName
    }
    $addr = [string]$c.LocalAddress
    $scope = 'SPECIFIC'
    if ($addr -match '^(0\.0\.0\.0|::|\[::\])$') { $scope = 'ALL-IFACES' }
    elseif ($addr -match '^(127\.|::1|\[::1\])') { $scope = 'LOCAL-ONLY' }
    W ('{0,-24} {1,-6} {2,-11} {3}' -f $addr, $c.LocalPort, $scope, $procCache[$pnum])
  }
} else {
  W '  (Get-NetTCPConnection unavailable, falling back to netstat)'
  netstat -ano | Select-String 'LISTENING' | ForEach-Object { W ('  ' + $_.ToString().Trim()) }
}

# ---------- 3 ----------
T '3. PORTS OF INTEREST'
$watch = 22, 445, 139, 3389, 5900, 8000, 8080, 18080, 18081, 53317, 5244, 2375
foreach ($p in $watch) {
  $hit = @($listen | Where-Object { [int]$_.LocalPort -eq $p })
  if ($hit.Count -eq 0) { W ('  {0,-6} not listening' -f $p); continue }
  foreach ($h in $hit) {
    $pn = (Get-Process -Id ([int]$h.OwningProcess) -ErrorAction SilentlyContinue).ProcessName
    $allIf = $false
    if ([string]$h.LocalAddress -match '^(0\.0\.0\.0|::|\[::\])$') { $allIf = $true }
    $note = ''
    if ($allIf) { $note = '   <== open on ALL interfaces' }
    W ('  {0,-6} {1,-22} {2}{3}' -f $p, [string]$h.LocalAddress, $pn, $note)
  }
}

# ---------- 4 ----------
T '4. PROCESSES OF INTEREST (with command line)'
$kw = 'localsend|openlist|alist|openclaw|hermes|windows-mcp|optimizerduck|yt-dlp|dsh|mcp|ollama|vmware|vmms|vmmem'
$procs = Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match $kw }
if ($procs) {
  foreach ($p in $procs) {
    W ('  PID {0,-7} {1}' -f $p.ProcessId, $p.Name)
    W ('      ' + [string]$p.CommandLine)
  }
} else { W '  none found' }

# ---------- 5 ----------
T '5. FIREWALL'
foreach ($f in (Get-NetFirewallProfile)) {
  W ('  {0,-8} Enabled={1}  DefaultInbound={2}' -f $f.Name, $f.Enabled, $f.DefaultInboundAction)
}
W '  Relevant inbound ALLOW rules:'
$rules = Get-NetFirewallRule -Direction Inbound -Enabled True -Action Allow
foreach ($r in ($rules | Where-Object { $_.DisplayName -match 'LocalSend|OpenList|AList|MCP|Python|Node\.js|Remote Desktop|File and Printer|SMB|Tailscale|VMware|Hyper-V' })) {
  W ('    ' + $r.DisplayName + '  [' + $r.Profile + ']')
}

# ---------- 6 ----------
T '6. SMB SERVER'
$smb = Get-SmbServerConfiguration
if ($smb) {
  W ('  SMB1=' + $smb.EnableSMB1Protocol + '  EncryptData=' + $smb.EncryptData + '  RequireSigning=' + $smb.RequireSecuritySignature)
} else { W '  (needs admin)' }
foreach ($s in (Get-SmbShare)) { W ('  Share: {0,-16} -> {1}' -f $s.Name, $s.Path) }

# ---------- 7 ----------
T '7. POWERTOYS / MOUSE WITHOUT BORDERS'
$pt = 'HKCU:\Software\Microsoft\PowerToys'
if (Test-Path $pt) {
  W ('  PowerToys present: ' + ((Get-ChildItem $pt).Name -join ', '))
} else { W '  PowerToys not found' }
$mwb = 'HKCU:\Software\Microsoft\PowerToys\MouseWithoutBorders'
if (Test-Path $mwb) {
  W '  --- MWB config ---'
  $txt = Get-ItemProperty $mwb | Out-String -Width 200
  foreach ($ln in $txt.Split([char]10)) { if ($ln.Trim()) { W ('  ' + $ln.TrimEnd()) } }
} else { W '  MWB not configured (not enabled or not paired)' }

# ---------- 8 ----------
T '8. FEATURES & SERVICES'
foreach ($f in 'OpenSSH.Server', 'OpenSSH.Client', 'Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform') {
  $st = Get-WindowsOptionalFeature -Online -FeatureName $f
  if ($st) { W ('  {0,-40} {1}' -f $f, $st.State) }
}
foreach ($sv in 'sshd', 'Tailscale', 'LanmanServer', 'WinDefend') {
  $s = Get-Service $sv
  W ('  SVC {0,-14} {1,-10} {2}' -f $sv, $s.Status, $s.StartType)
}

# ---------- 9 ----------
T '9. DISK ENCRYPTION'
$bl = Get-BitLockerVolume
if ($bl) {
  foreach ($v in $bl) { W ('  {0,-4} {1,-22} protection={2}' -f $v.MountPoint, $v.VolumeStatus, $v.ProtectionStatus) }
} else { W '  (needs admin or BitLocker not enabled)' }

# ---------- 10 ----------
T '10. INSTALLED APPS (keyword match)'
$keys = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
$apps = Get-ItemProperty $keys | Where-Object { $_.DisplayName -match 'LocalSend|OpenList|AList|OpenClaw|Hermes|PowerToys|Tailscale|OpenSSH|Python|Node\.js|Ollama|VMware' }
if ($apps) {
  $apps | Sort-Object DisplayName -Unique | ForEach-Object { W ('  {0}  {1}' -f $_.DisplayName, $_.DisplayVersion) }
} else { W '  none found' }

# ---------- 11 ----------
T '11. TAILSCALE STATUS'
$ts = & tailscale status 2>&1
if ($ts) { $ts | Select-Object -First 12 | ForEach-Object { W ('  ' + $_) } } else { W '  tailscale CLI not available' }

# ---------- done ----------
W ''
W ('Report saved to: ' + $out)
try { $sb.ToString() | Set-Content -Path $out -Encoding UTF8 -ErrorAction Stop }
catch { Write-Host ('Save failed: ' + $_.Exception.Message) -ForegroundColor Red }
