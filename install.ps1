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

    The version comes from -Version. With no -Version, it comes from the
    QUIX_BRIDGE_VERSION environment variable, like install.sh. With neither, the
    script takes the newest release. A leading "v" is dropped, so "v0.1.0" and
    "0.1.0" both work.

    usage:
        irm https://github.com/quixio/quix-lake-bridge/raw/main/install.ps1 | iex
        .\install.ps1 -Version 0.1.0
        $env:QUIX_BRIDGE_VERSION = 'v0.1.0'; irm https://github.com/quixio/quix-lake-bridge/raw/main/install.ps1 | iex
#>
[CmdletBinding()]
param(
    [string]$Version = '',
    [string]$Repo = 'quixio/quix-lake-bridge',
    [switch]$Zip
)

$ErrorActionPreference = 'Stop'

# The parameter wins, then the environment, then 'latest'. The release tag carries a
# v and the asset name does not, so the number goes into both without it.
function Resolve-BridgeVersion([string]$Requested, [string]$FromEnvironment) {
    $value = if ($Requested.Trim()) { $Requested.Trim() } elseif ($FromEnvironment.Trim()) { $FromEnvironment.Trim() } else { 'latest' }
    if ($value -eq 'latest') { return $value }
    return $value -replace '^[vV]', ''
}

$Version = Resolve-BridgeVersion $Version $env:QUIX_BRIDGE_VERSION

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

# ---- check the download before anything runs ------------------------------

# SHA256SUMS comes from the same release. It must name this asset, and the hash must
# match. Any other answer stops the script before the file runs.
$sums = Join-Path $work 'SHA256SUMS'
Invoke-WebRequest -Uri "https://github.com/$Repo/releases/download/v$Version/SHA256SUMS" -OutFile $sums -UseBasicParsing
$expected = $null
foreach ($line in Get-Content -Path $sums) {
    $parts = $line.Trim() -split '\s+'
    if ($parts.Count -eq 2 -and $parts[1].TrimStart('*') -eq $asset) {
        $expected = $parts[0]
        break
    }
}
if (-not $expected) {
    throw "SHA256SUMS names no line for '$asset'. The script installed nothing."
}
$actual = (Get-FileHash -Path $file -Algorithm SHA256).Hash
if ($actual -ne $expected) {
    throw "The SHA256 of '$asset' does not match SHA256SUMS. The script installed nothing. Download the file again from the release page."
}
Write-Host "The SHA256 of '$asset' matches SHA256SUMS."

# The release is unsigned today. A signed MSI must still carry a valid signature: a
# broken signature means the file changed after it was signed, so the script stops.
# A zip cannot carry a signature, so the hash above is its whole check.
if (-not $Zip) {
    $signature = Get-AuthenticodeSignature -FilePath $file
    if ($signature.Status -eq 'NotSigned') {
        Write-Host 'This build is unsigned. The script checked its SHA256 only.'
    }
    elseif ($signature.Status -ne 'Valid') {
        throw "The signature of '$asset' is '$($signature.Status)'. The script installed nothing. Download the file again from the release page."
    }
    else {
        Write-Host "The publisher is $($signature.SignerCertificate.Subject)."
    }
}

# ---- install --------------------------------------------------------------

if ($Zip) {
    $target = Join-Path $env:ProgramFiles 'Quix\Bridge'
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    Expand-Archive -Path $file -DestinationPath $target -Force
    Write-Host "The script wrote $target."
    Write-Host "Run '$target\quix-bridge.exe service install' from an administrator prompt."
    # A zip install changes no PATH, so the hint names the full path.
    Write-Host "Done. Run '$target\quix-bridge.exe status' to read the state."
}
else {
    Write-Host 'Run the MSI. Windows asks for administrator rights.'
    $log = Join-Path $work 'install.log'
    $process = Start-Process msiexec.exe -ArgumentList @('/i', "`"$file`"", '/qn', '/l*v', "`"$log`"") -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        throw "The MSI failed with code $($process.ExitCode). The log is at $log."
    }
    Write-Host 'The MSI installed the bridge and started the service.'
    Write-Host 'The MSI added the bridge folder to the system PATH.'
    Write-Host "Done. Open a new shell, because this shell keeps the old PATH. Then run 'quix-bridge status' to read the state."
}
