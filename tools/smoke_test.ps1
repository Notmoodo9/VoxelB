# Windows smoke test: launch the game with --autoclose, wait for it to quit,
# and check the exit code and voxel.log. Used by CI; also runnable locally:
#   powershell -ExecutionPolicy Bypass -File tools\smoke_test.ps1 -Config debug
param(
    [ValidateSet('debug', 'release')] [string] $Config = 'release',
    [int] $AutocloseMs = 8000,
    [int] $TimeoutMs = 60000
)
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)

$exe = "build\$Config\voxelb.exe"
$log = "build\$Config\voxel.log"
if (-not (Test-Path $exe)) { Write-Error "missing $exe - run build.bat $Config first" }
if (Test-Path $log) { Remove-Item $log }

Write-Host "launching $exe --selftest --autoclose $AutocloseMs"
$p = Start-Process -FilePath $exe -ArgumentList "--selftest --autoclose $AutocloseMs" -PassThru
$null = $p.Handle                       # keep the handle so ExitCode is available
if (-not $p.WaitForExit($TimeoutMs)) {
    $p.Kill()
    Write-Host "FAIL: did not exit within $TimeoutMs ms"
    if (Test-Path $log) { Get-Content $log }
    exit 1
}
$code = $p.ExitCode
Write-Host "---- $log ----"
if (Test-Path $log) { Get-Content $log } else { Write-Host "(no log written)" }
Write-Host "--------------"
Write-Host "exit code: $code"

$text = if (Test-Path $log) { Get-Content $log -Raw } else { '' }
if ($code -ne 0) { Write-Host "FAIL: exit code $code"; exit 1 }
if ($text -notmatch 'window created, client area') { Write-Host 'FAIL: window was not created'; exit 1 }
if ($text -notmatch 'OpenGL core context created') { Write-Host 'FAIL: no OpenGL context'; exit 1 }
if ($text -notmatch 'selftest: PASS') { Write-Host 'FAIL: arena/pool/job self test did not pass'; exit 1 }
if ($text -notmatch 'world: quad buffer created') { Write-Host 'FAIL: world GPU buffer not created'; exit 1 }
if ($text -notmatch 'stream: view complete') { Write-Host 'FAIL: streamer never finished loading the view'; exit 1 }
if ($text -notmatch 'text renderer ready') { Write-Host 'FAIL: text renderer/shaders did not start'; exit 1 }
if ($text -match 'ERROR') { Write-Host 'FAIL: errors in the log'; exit 1 }
if ($text -notmatch 'perf: ') { Write-Host 'FAIL: no frame timing (perf) line'; exit 1 }
if ($text -notmatch 'clean exit, code = 0') { Write-Host 'FAIL: no clean exit in log'; exit 1 }
Write-Host "PASS ($Config)"
exit 0
