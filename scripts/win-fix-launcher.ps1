# win-fix-launcher.ps1 - make the DSH shortcut safe to double-click repeatedly
$ErrorActionPreference = 'Stop'
$D = 'D:\dsh'

Write-Host "== 1/3 downloading gateway.py"
Invoke-WebRequest -Uri 'http://100.74.117.79:8099/gateway.py' -OutFile "$D\proxy\gateway.py" -UseBasicParsing
& "$D\mcp\venv\Scripts\python.exe" -c "import ast;ast.parse(open(r'D:\dsh\proxy\gateway.py',encoding='utf-8').read());print('   syntax ok')"

Write-Host "== 2/3 rewriting the launcher"
$vbs = @'
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh  = CreateObject("WScript.Shell")

' clear any stale instance first, so a second double-click cannot collide
sh.Run "taskkill /f /im ssh.exe", 0, True
sh.Run "taskkill /f /im windows-mcp.exe", 0, True
WScript.Sleep 800

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

Write-Host "== 3/3 done"
Write-Host ""
Write-Host "The DSH shortcut now clears stale processes before starting." -ForegroundColor Green
Write-Host "Double-click it twice in a row to verify it no longer breaks."
