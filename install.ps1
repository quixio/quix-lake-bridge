<#
.SYNOPSIS
    Downloads and installs the bridge on Windows.

.DESCRIPTION
    The script reads the machine, picks one of the two asset names, downloads the
    MSI from the release page and runs it.

        win-x64     win-arm64

    The MSI creates the service under the virtual account NT SERVICE\quix-bridge,
    and it starts it. It also registers the daily task \Quix\Bridge Update, which
    installs nothing unless config.yaml sets update.channel to stable.

    usage:
        irm https://github.com/quixio/quix-lake-bridge/raw/main/install.ps1 | iex
        .\install.ps1 -Version 0.1.0
#>
[CmdletBinding()]
param(
    [string]$Version = 'latest',
    [string]$Repo = 'quixio/quix-lake-bridge',
    [switch]$Zip
)

$ErrorActionPreference = 'Stop'

# ---- read the machine, and name the runtime -------------------------------

$machine = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
switch ($machine) {
    'X64'   { $runtime = 'win-x64' }
    'Arm64' { $runtime = 'win-arm64' }
    default { throw "The bridge has no build for the architecture '$machine'." }
}
Write-Host "This machine is $runtime."

# ---- resolve the version and the asset ------------------------------------

if ($Version -eq 'latest') {
    $release = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases/latest"
    $Version = $release.tag_name -replace '^v', ''
    if (-not $Version) { throw "The script could not read the newest release of $Repo." }
}
Write-Host "The version is $Version."

$extension = if ($Zip) { 'zip' } else { 'msi' }
$asset = "quix-bridge-$Version-$runtime.$extension"
$url = "https://github.com/$Repo/releases/download/v$Version/$asset"

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("quix-bridge-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $work | Out-Null
$file = Join-Path $work $asset

Write-Host "Download $url"
Invoke-WebRequest -Uri $url -OutFile $file -UseBasicParsing

# ---- check the signature before anything runs -----------------------------

# An unsigned download is a download nobody can trust. The script stops.
$signature = Get-AuthenticodeSignature -FilePath $file
if ($signature.Status -ne 'Valid') {
    throw "The signature of '$asset' is '$($signature.Status)'. The script installed nothing. Download the file again from the release page."
}
Write-Host "The publisher is $($signature.SignerCertificate.Subject)."

# ---- install --------------------------------------------------------------

if ($Zip) {
    $target = Join-Path $env:ProgramFiles 'Quix\Bridge'
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    Expand-Archive -Path $file -DestinationPath $target -Force
    Write-Host "The script wrote $target."
    Write-Host "Run '$target\quix-bridge.exe service install' from an administrator prompt."
}
else {
    Write-Host 'Run the MSI. Windows asks for administrator rights.'
    $log = Join-Path $work 'install.log'
    $process = Start-Process msiexec.exe -ArgumentList @('/i', "`"$file`"", '/qn', '/l*v', "`"$log`"") -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        throw "The MSI failed with code $($process.ExitCode). The log is at $log."
    }
    Write-Host 'The MSI installed the bridge and started the service.'
}

Write-Host "Done. Run 'quix-bridge status' to read the state."
