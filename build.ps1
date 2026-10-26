# ============================================================
# build.ps1 - one-shot build for BLHM studio (default: Debug HAP)
#
# TWO VERIFIED TRAPS this script exists to avoid:
#   1) JAVA_HOME points at C:\tools\jdk-21.0.12.1+1 but java.exe is NOT on PATH
#      -> hvigor fails at packaging with `spawn java ENOENT` (Error Code 00308018).
#         CMake / Ninja / CompileArkTS all pass; only PackageHap and SignHap die.
#   2) The hvigor daemon caches the environment of whichever process started it.
#      If a daemon was first started WITHOUT java on PATH, later builds keep
#      failing even after PATH is fixed.
#      -> always pass --no-daemon so every build uses the current process env.
#
# Also note: this machine's ExecutionPolicy forbids running .ps1 directly.
#   Use:  build.cmd            (incremental)
#         build.cmd -Clean     (clean then build)
#         build.cmd -Mode release
#
# KEEP THIS FILE ASCII-ONLY. powershell.exe 5.1 parses a BOM-less UTF-8 script
# as ANSI, so CJK comments/messages turn into mojibake.
# ============================================================
param(
    [switch]$Clean,
    [string]$Product = 'default',
    [string]$Mode = 'debug'
)

$ErrorActionPreference = 'Stop'

$DevEco  = 'C:\Program Files\Huawei\DevEco Studio'
$JdkHome = 'C:\tools\jdk-21.0.12.1+1'
$Hvigorw = Join-Path $DevEco 'tools\hvigor\bin\hvigorw.bat'

$env:DEVECO_SDK_HOME = Join-Path $DevEco 'sdk'
$env:JAVA_HOME       = $JdkHome
$env:PATH            = (Join-Path $JdkHome 'bin') + ';' + $env:PATH

foreach ($p in @($Hvigorw, (Join-Path $JdkHome 'bin\java.exe'), $env:DEVECO_SDK_HOME)) {
    if (-not (Test-Path $p)) { throw "missing dependency: $p" }
}

$hvArgs = @(
    'assembleHap', '--mode', 'module',
    '-p', "product=$Product",
    '-p', "buildMode=$Mode",
    '--no-daemon'
)
if ($Clean) { $hvArgs = @('clean') + $hvArgs }

Write-Host "==> hvigor $($hvArgs -join ' ')" -ForegroundColor Cyan
$sw = [Diagnostics.Stopwatch]::StartNew()
Push-Location $PSScriptRoot
try {
    & $Hvigorw @hvArgs
    $code = $LASTEXITCODE
} finally {
    Pop-Location
    $sw.Stop()
}

$outDir = Join-Path $PSScriptRoot "entry\build\$Product\outputs\$Product"
Write-Host ("==> elapsed {0:N1}s, exit code {1}" -f $sw.Elapsed.TotalSeconds, $code) -ForegroundColor Cyan
Get-ChildItem $outDir -Filter *.hap -ErrorAction SilentlyContinue |
    Select-Object Name, @{n = 'MB'; e = { [math]::Round($_.Length / 1MB, 1) } }, LastWriteTime |
    Format-Table -AutoSize

# IMPORTANT: the artifact is provisioned as type=release /
# app-distribution-type=app_gallery, so `hdc install` rejects it with
# "not trusted app source". Installing needs a DEBUG profile bound to the
# device UDID - see the handover notes.
exit $code
