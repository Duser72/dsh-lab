# win-start-dsh.ps1 - switch to manual mode: nothing runs at logon
#   installs a desktop shortcut "DSH" that starts tunnel + gateway + opens the web UI
#   the gateway kills Windows-MCP after 15 min idle and the whole stack after 30 min
$ErrorActionPreference = 'Stop'
$D = 'D:\dsh'
$SRC = 'http://100.74.117.79:8099/gateway.py'

Write-Host "== 1/6 removing logon tasks (nothing will auto-start anymore)"
foreach ($t in @('DSH-Tunnel', 'DSH-Gateway', 'DSH-MCP')) {
    Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue | Stop-ScheduledTask -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "   removed $t"
}

Write-Host "== 2/6 stopping anything still running"
Get-CimInstance Win32_Process -Filter "Name='ssh.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*dsh*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*gateway.py*' -or $_.Name -eq 'windows-mcp.exe' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

Write-Host "== 3/6 downloading latest gateway.py"
New-Item -ItemType Directory -Force "$D\proxy", "$D\logs" | Out-Null
Invoke-WebRequest -Uri $SRC -OutFile "$D\proxy\gateway.py" -UseBasicParsing
& "$D\mcp\venv\Scripts\python.exe" -c "import ast;ast.parse(open(r'D:\dsh\proxy\gateway.py',encoding='utf-8').read());print('   syntax ok')"

Write-Host "== 4/6 writing the launcher"
$vbs = @'
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh  = CreateObject("WScript.Shell")
sh.Run "ssh -N -o BatchMode=yes -F ""D:\dsh\ssh\config"" dsh", 0, False
sh.Run """D:\dsh\mcp\venv\Scripts\python.exe"" ""D:\dsh\proxy\gateway.py""", 0, False
WScript.Sleep 2500
url = "http://100.74.117.79:8080/"
p = "D:\dsh\work\dsh-url.txt"
If fso.FileExists(p) Then
  On Error Resume Next
  u = Trim(fso.OpenTextFile(p, 1).ReadAll)
  If Len(u) > 10 Then url = u
  On Error GoTo 0
End If
sh.Run url, 1, False
'@
Set-Content -Path "$D\proxy\start-dsh.vbs" -Value $vbs -Encoding ASCII

Write-Host "== 5/6 creating desktop shortcut"
$desk = [Environment]::GetFolderPath('Desktop')
$ws = New-Object -ComObject WScript.Shell
$lnkPath = Join-Path $desk 'DSH.lnk'
$lnk = $ws.CreateShortcut($lnkPath)
$lnk.TargetPath = 'wscript.exe'
$lnk.Arguments = '"D:\dsh\proxy\start-dsh.vbs"'
$lnk.WorkingDirectory = "$D\proxy"
$lnk.IconLocation = "$env:SystemRoot\System32\shell32.dll,137"
$lnk.Description = 'Start DSH: tunnel + gateway + web UI'
$lnk.Save()
Write-Host "   $lnkPath"

Write-Host "== 6/6 done"
Write-Host ""
Write-Host "Nothing starts at logon now." -ForegroundColor Green
Write-Host "Double-click the DSH shortcut when you want to use the agent."
Write-Host "It opens the web page; Windows-MCP starts only on first real use and"
Write-Host "shuts itself down after 15 min (whole stack after 30 min)."
