# win-mcp-daemon.ps1 - start Windows-MCP at logon and restart it if it dies
# Run once, Administrator recommended.
$ErrorActionPreference = 'Stop'
$D = 'D:\dsh'
New-Item -ItemType Directory -Force "$D\logs", "$D\mcp" | Out-Null

if (-not (Test-Path "$D\mcp\start-mcp.ps1")) {
    throw "start-mcp.ps1 not found - run win-setup-mcp.ps1 first"
}

Write-Host "== 1/5 writing batch loop"
$cmd = @'
@echo off
:loop
for %%A in ("D:\dsh\logs\mcp.log") do if %%~zA GTR 1048576 del /q "D:\dsh\logs\mcp.log" >nul 2>&1
echo [%date% %time%] start >> "D:\dsh\logs\mcp.log"
powershell -NoProfile -ExecutionPolicy Bypass -File "D:\dsh\mcp\start-mcp.ps1" >> "D:\dsh\logs\mcp.log" 2>&1
echo [%date% %time%] exited, restart in 10s >> "D:\dsh\logs\mcp.log"
ping -n 11 127.0.0.1 >nul
goto loop
'@
Set-Content -Path "$D\mcp\mcp-loop.cmd" -Value $cmd -Encoding ASCII

Write-Host "== 2/5 writing hidden launcher"
$vbs = @'
CreateObject("WScript.Shell").Run "cmd /c ""D:\dsh\mcp\mcp-loop.cmd""", 0, False
'@
Set-Content -Path "$D\mcp\mcp-launch.vbs" -Value $vbs -Encoding ASCII

Write-Host "== 3/5 registering task"
$action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"{0}\mcp\mcp-launch.vbs"' -f $D)
$trigger = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Days 3650) `
    -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName 'DSH-MCP' -Action $action -Trigger $trigger `
    -Settings $settings -Description 'Windows-MCP server (restarts automatically)' -Force | Out-Null
Start-ScheduledTask -TaskName 'DSH-MCP'

Write-Host "== 4/5 waiting for port 18080"
$ok = $false
for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Seconds 2
    $l = Get-NetTCPConnection -LocalPort 18080 -State Listen -ErrorAction SilentlyContinue
    if ($l) { $ok = $true; break }
}
Write-Host "== 5/5 result"
if ($ok) {
    $l | Select-Object LocalAddress, LocalPort | Format-Table -AutoSize
    $bad = $l | Where-Object { $_.LocalAddress -notin @('127.0.0.1', '::1') }
    if ($bad) {
        Write-Host "!! exposed beyond localhost - stopping" -ForegroundColor Red
        Get-CimInstance Win32_Process -Filter "Name='windows-mcp.exe'" |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
        throw "port 18080 bound to a non-local address"
    }
    Write-Host "OK - listening on localhost only" -ForegroundColor Green
} else {
    Write-Host "not listening. tail of $D\logs\mcp.log:" -ForegroundColor Red
    Get-Content "$D\logs\mcp.log" -Tail 20 -ErrorAction SilentlyContinue
    throw "Windows-MCP did not start"
}

Write-Host ""
Write-Host "Both daemons installed:" -ForegroundColor Cyan
Get-ScheduledTask -TaskName 'DSH-Tunnel', 'DSH-MCP' -ErrorAction SilentlyContinue |
    Select-Object TaskName, State | Format-Table -AutoSize
