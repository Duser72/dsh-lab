# win-devices.ps1 - device layer: ssh forwards for phone/serial/camera + USB shares
$ErrorActionPreference = 'Stop'
$D = 'D:\dsh'
$user = 'dsh-smb'

Write-Host "== 1/4 adding ssh forwards"
$cfg = "$D\ssh\config"
$raw = Get-Content $cfg -Raw
$need = @(
    'RemoteForward 127.0.0.1:15037 127.0.0.1:5037',
    'RemoteForward 127.0.0.1:15038 127.0.0.1:27015',
    'RemoteForward 127.0.0.1:15039 127.0.0.1:15039',
    'RemoteForward 127.0.0.1:15040 127.0.0.1:8554'
)
$added = 0
foreach ($l in $need) {
    if ($raw -notmatch [regex]::Escape($l)) {
        Add-Content -Path $cfg -Value $l
        Write-Host "   + $l"
        $added++
    }
}
if ($added -eq 0) { Write-Host "   already present" }

Write-Host "== 2/4 removable drives"
$disks = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=2"
if (-not $disks) { Write-Host "   none found - plug one in and re-run" }
foreach ($d in $disks) {
    $letter = $d.DeviceID
    $name = 'usb-' + $letter.TrimEnd(':').ToLower()
    if (Get-SmbShare -Name $name -ErrorAction SilentlyContinue) {
        Remove-SmbShare -Name $name -Force
    }
    New-SmbShare -Name $name -Path ($letter + '\') -ReadAccess $user -EncryptData $true | Out-Null
    Write-Host ("   {0} -> {1}\  read-only for {2}" -f $name, $letter, $user)
}

Write-Host "== 3/4 shares now"
Get-SmbShare | Where-Object { -not $_.Name.EndsWith('$') } |
    Select-Object Name, Path | Format-Table -AutoSize

Write-Host "== 4/4 restarting the stack"
Stop-Process -Name ssh, python, windows-mcp -Force -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "Done. Double-click the DSH shortcut to bring it back." -ForegroundColor Green
