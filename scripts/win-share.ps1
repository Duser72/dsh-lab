# win-share.ps1 - create SMB shares for DSH access
#   win-read  -> D:\            (READ ONLY, enforced by Windows share permission)
#   win-work  -> D:\dsh\work    (read/write, scratch area)
# Run as Administrator:
#   powershell -NoProfile -ExecutionPolicy Bypass -File "D:\dsh\tmp\win-share.ps1"
$ErrorActionPreference = 'Stop'
$User      = 'dsh-smb'
$ReadShare = 'win-read'
$WorkShare = 'win-work'
$WorkDir   = 'D:\dsh\work'

Write-Host "win-share v1.0" -ForegroundColor Cyan

# ---- 1. local account ----
$existing = Get-LocalUser -Name $User -ErrorAction SilentlyContinue
$rand = [guid]::NewGuid().ToString('N').Substring(0, 16)
$pw   = "Dsh${rand}aA1!"
$sp   = ConvertTo-SecureString $pw -AsPlainText -Force
if ($existing) {
    Write-Host "[1/4] account $User exists - resetting password"
    Set-LocalUser -Name $User -Password $sp -PasswordNeverExpires $true
} else {
    Write-Host "[1/4] creating local account $User"
    New-LocalUser -Name $User -Password $sp -FullName 'DSH SMB' `
        -Description 'SMB access for DSH agent' -PasswordNeverExpires -AccountNeverExpires | Out-Null
}

# ---- 2. work directory ----
Write-Host "[2/4] ensuring $WorkDir"
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null

# ---- 3. shares ----
Write-Host "[3/4] creating shares"
foreach ($s in @($ReadShare, $WorkShare)) {
    if (Get-SmbShare -Name $s -ErrorAction SilentlyContinue) {
        Remove-SmbShare -Name $s -Force
    }
}
New-SmbShare -Name $ReadShare -Path 'D:\' -ReadAccess $User -EncryptData $true | Out-Null
New-SmbShare -Name $WorkShare -Path $WorkDir -ChangeAccess $User -EncryptData $true | Out-Null

# ---- 4. report ----
Write-Host "[4/4] done"
Get-SmbShare -Name $ReadShare, $WorkShare | Format-Table Name, Path, EncryptData -AutoSize

Write-Host ""
Write-Host "===== COPY THESE TWO LINES TO DSH =====" -ForegroundColor Yellow
Write-Host "username: $User"
Write-Host "password: $pw"
Write-Host "=======================================" -ForegroundColor Yellow
