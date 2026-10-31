# win-tunnel-lite.ps1 - lightweight auto-reconnect tunnel (cmd loop, ~10 MB)
# Run once, normal user is usually enough; use Administrator if task registration fails.
$ErrorActionPreference = 'Stop'
$D = 'D:\dsh'
New-Item -ItemType Directory -Force "$D\logs", "$D\ssh" | Out-Null

Write-Host "== 1/5 stopping old tunnel pieces"
Get-ScheduledTask -TaskName 'DSH-Tunnel' -ErrorAction SilentlyContinue | Stop-ScheduledTask -ErrorAction SilentlyContinue
Get-CimInstance Win32_Process -Filter "Name='ssh.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*dsh*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

Write-Host "== 2/5 writing batch loop"
$cmd = @'
@echo off
:loop
for %%A in ("D:\dsh\logs\tunnel.log") do if %%~zA GTR 1048576 del /q "D:\dsh\logs\tunnel.log" >nul 2>&1
echo [%date% %time%] connect >> "D:\dsh\logs\tunnel.log"
ssh -N -o BatchMode=yes -F "D:\dsh\ssh\config" dsh >> "D:\dsh\logs\tunnel.log" 2>&1
echo [%date% %time%] dropped, retry in 10s >> "D:\dsh\logs\tunnel.log"
ping -n 11 127.0.0.1 >nul
goto loop
'@
Set-Content -Path "$D\ssh\tunnel-loop.cmd" -Value $cmd -Encoding ASCII

Write-Host "== 3/5 writing hidden launcher"
$vbs = @'
CreateObject("WScript.Shell").Run "cmd /c ""D:\dsh\ssh\tunnel-loop.cmd""", 0, False
'@
Set-Content -Path "$D\ssh\tunnel-launch.vbs" -Value $vbs -Encoding ASCII

Write-Host "== 4/5 registering task (runs at logon, no window)"
$action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"{0}\ssh\tunnel-launch.vbs"' -f $D)
$trigger = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Days 3650) `
    -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName 'DSH-Tunnel' -Action $action -Trigger $trigger `
    -Settings $settings -Description 'DSH reverse tunnel (lightweight cmd loop)' -Force | Out-Null
Start-ScheduledTask -TaskName 'DSH-Tunnel'

Write-Host "== 5/5 waiting for connection"
Start-Sleep -Seconds 8
Get-Content "$D\logs\tunnel.log" -Tail 6 -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "processes now:" -ForegroundColor Cyan
Get-Process cmd, ssh -ErrorAction SilentlyContinue |
    Select-Object Name, Id, @{n = 'RAM_MB'; e = { [math]::Round($_.WorkingSet64 / 1MB, 1) } } |
    Format-Table -AutoSize

Write-Host "Done. Reconnects automatically; total RAM about 10 MB." -ForegroundColor Green
Write-Host "  status: Get-Content D:\dsh\logs\tunnel.log -Tail 5"
Write-Host "  stop:   Stop-ScheduledTask -TaskName 'DSH-Tunnel'; Get-Process ssh | Stop-Process"
