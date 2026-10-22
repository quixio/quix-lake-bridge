<#
.SYNOPSIS
    Downloads and installs the bridge on Windows.

.DESCRIPTION
    The script reads the machine, picks one of the two asset names, downloads the
    MSI from the release page and runs it.

        win-x64     win-arm64

    The MSI creates the service under the virtual account NT SERVICE\quix-bridge,
    and it starts it. It also registers the task \Quix\Bridge Update. The task
    runs every 5 minutes and installs the release the gateway offers. It installs
    nothing when config.yaml sets update.channel to manual.

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

# Windows PowerShell 5.1 runs on .NET Framework. There, RuntimeInformation can be
# missing, or its OSArchitecture can be empty. So an empty string is a valid answer.
function Read-OsArchitecture {
    $info = 'System.Runtime.InteropServices.RuntimeInformation' -as [type]
    if (-not $info) { return '' }
    try { return [string]$info::OSArchitecture } catch { return '' }
}

# The first value that names a known machine wins. A 32-bit shell on 64-bit Windows
# sets PROCESSOR_ARCHITECTURE to x86, also on ARM64. PROCESSOR_ARCHITEW6432 then
# names the real machine.
function Resolve-BridgeRuntime([string[]]$Values) {
    foreach ($value in $Values) {
        switch ("$value".Trim()) {
            { $_ -in 'X64', 'AMD64' } { return 'win-x64' }
            'ARM64' { return 'win-arm64' }
        }
    }
    return $null
}

$seen = @((Read-OsArchitecture), $env:PROCESSOR_ARCHITEW6432, $env:PROCESSOR_ARCHITECTURE)
$runtime = Resolve-BridgeRuntime $seen
if (-not $runtime) {
    throw ("The bridge has no build for this machine. OSArchitecture='$($seen[0])', " +
        "PROCESSOR_ARCHITEW6432='$($seen[1])', PROCESSOR_ARCHITECTURE='$($seen[2])'. " +
        "Download the MSI by hand from https://github.com/$Repo/releases.")
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

# ---- the first start, for the person who watches this shell -------------------

# The MSI's own BridgeTrayStart action starts the tray right after the install, but
# only when somebody could see the install (UILevel 3 or higher). This script always
# runs msiexec with /qn, so that action never fires, and the tray waited for the next
# sign in. This script starts the tray and the console itself, the same de-elevated
# way the MSI would: explorer.exe runs the target in the signed-in person's own
# session, never with this script's own administrator token.
function Resolve-BridgeTrayShortcut([string]$StartupFolder) {
    return Join-Path $StartupFolder 'Quix Lake Bridge.lnk'
}

# explorer.exe reads its whole command line as one target. Start-Process joins the
# argument without quotes, so the shortcut path ("Start Menu", "Quix Lake Bridge.lnk")
# reached explorer as several words, and explorer opened the Documents folder. The
# quotes keep the target one word. explorer with no target also opens a folder, so an
# empty target starts nothing.
function Format-ExplorerTarget([string]$Target) {
    $bare = "$Target".Trim().Trim('"')
    if (-not $bare) { return $null }
    return '"' + $bare + '"'
}

function Start-DeElevated([string]$Target) {
    $argument = Format-ExplorerTarget $Target
    if (-not $argument) { return $false }
    Start-Process -FilePath (Join-Path $env:WINDIR 'explorer.exe') -ArgumentList $argument
    return $true
}

# explorer hands a URL to the default browser. With no browser for https, it opens a
# folder or a "How do you want to open this?" dialog. So the script opens the console
# only when the person has a default browser.
function Test-DefaultBrowser {
    try {
        $key = 'HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice'
        return [bool](Get-ItemProperty -Path $key -Name ProgId -ErrorAction Stop).ProgId
    }
    catch {
        return $false
    }
}

# A silent deployment tool can run this script with nobody watching, and it can run
# with no desktop at all. Only a real interactive session gets the tray and the
# browser; 'quix-bridge status' still works with neither.
function Test-InteractiveInstall {
    return [Environment]::UserInteractive -and $env:SESSIONNAME -and $env:SESSIONNAME -ne 'Services'
}

# Reads the one-time login URL from a completed 'quix-bridge ui' run. The URL is a
# credential, so this reads only the in-memory text the command printed, and the
# caller never writes that text to $log or to this screen.
function Read-UiLoginUrl([string]$UiOutput) {
    $line = ($UiOutput -split "`r?`n") | Where-Object { $_ -like 'URL:*' } | Select-Object -First 1
    if (-not $line) { return $null }
    return $line.Substring(5).Trim()
}

# ---- an install that is already there ---------------------------------------

# The UpgradeCode of quix-bridge.wxs. Every version of the MSI carries it, so Windows
# Installer finds every registered bridge product by it.
$BridgeUpgradeCode = '{8F2A7C14-3D5E-4B90-9A61-2C7E5D0B4F38}'

# The answer for the version this script installs, against the registered versions.
#   install  no bridge product, or only older ones. A plain run upgrades an older one.
#   repair   the same version is registered. A plain run of the same MSI is a
#            maintenance run: it puts nothing back, so a lost service or a lost config
#            folder stays lost. A repair runs the service install again.
#   newer    a newer version is registered. The MSI refuses a downgrade.
function Resolve-MsiPlan([string]$Target, [string[]]$Installed) {
    $want = [version]$Target
    $seen = @($Installed | Where-Object { $_ } | ForEach-Object { [version]$_ })
    if ($seen -contains $want) { return 'repair' }
    if (@($seen | Where-Object { $_ -gt $want }).Count -gt 0) { return 'newer' }
    return 'install'
}

# The registered bridge products: the product code, the version and the file name
# Windows Installer keeps for the package. The COM object ships with Windows.
# The object has no type information in PowerShell, so each read goes through
# InvokeMember. A machine where the read fails gets a plain install, as before.
function Get-BridgeProducts {
    try {
        $installer = New-Object -ComObject WindowsInstaller.Installer
        $type = $installer.GetType()
        $codes = $type.InvokeMember('RelatedProducts', 'GetProperty', $null, $installer, @($BridgeUpgradeCode))
        foreach ($code in @($codes)) {
            [pscustomobject]@{
                Code        = $code
                Version     = $type.InvokeMember('ProductInfo', 'GetProperty', $null, $installer, @($code, 'VersionString'))
                PackageName = $type.InvokeMember('ProductInfo', 'GetProperty', $null, $installer, @($code, 'PackageName'))
            }
        }
    }
    catch {
        Write-Host "The script could not read the installed products. It runs a plain install. $($_.Exception.Message)"
    }
}

# The lines of the MSI log that name the failure. Windows Installer writes
# "Return value 3" on the action that failed, and the lines just before it say why.
# msiexec writes the log in UTF-16, and Get-Content reads the byte order mark.
function Read-MsiFailure([string]$LogPath, [int]$Before = 12) {
    if (-not (Test-Path $LogPath)) { return @() }
    $lines = @(Get-Content -Path $LogPath)
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -match 'Return value 3') {
            $first = [Math]::Max(0, $index - $Before)
            return @($lines[$first..$index] | Where-Object { $_.Trim() -and $_ -notmatch 'Note: 1: 2205 ' })
        }
    }
    return @()
}

# ERROR_CANCELLED. The person said No to the administrator prompt.
$PromptCancelled = 1223

function Test-Administrator {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Runs msiexec and waits. A silent run (/qn) cannot show the rights prompt, so a shell
# with no administrator rights asks for them here, once, before msiexec starts. When the
# person cancels that prompt, Start-Process throws InvalidOperationException. The
# function then prints one line and answers 1223. Every other error stays an error.
function Invoke-Msiexec([string[]]$Arguments) {
    if (Test-Administrator) {
        return (Start-Process msiexec.exe -ArgumentList $Arguments -Wait -PassThru).ExitCode
    }
    try {
        return (Start-Process msiexec.exe -ArgumentList $Arguments -Verb RunAs -Wait -PassThru).ExitCode
    }
    catch [System.InvalidOperationException] {
        Write-Host 'You cancelled the administrator prompt. Nothing changed. Run the script again and click Yes.'
        return 1223
    }
}

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
    $products = @(Get-BridgeProducts)
    $plan = Resolve-MsiPlan $Version @($products | ForEach-Object { $_.Version })
    $msiArguments = @('/i')
    if ($plan -eq 'newer') {
        $newest = ($products | ForEach-Object { [version]$_.Version } | Measure-Object -Maximum).Maximum
        throw ("Quix Bridge $newest is already installed. It is newer than $Version, and the MSI refuses a downgrade. " +
            "The script installed nothing. Uninstall Quix Bridge in Settings > Apps first, or run the script with -Version $newest.")
    }
    if ($plan -eq 'repair') {
        # Windows Installer checks a repair against the file name it registered for the
        # package. The update task saves the MSI as quix-bridge-<version>.msi, and this
        # script saves it as quix-bridge-<version>-<runtime>.msi. With the wrong name the
        # repair fails with code 1603 before any action runs. So the script gives the
        # download the registered name.
        $registered = ($products | Where-Object { [version]$_.Version -eq [version]$Version } | Select-Object -First 1).PackageName
        if ($registered -and $registered -ne $asset) {
            $named = Join-Path $work $registered
            Copy-Item -Path $file -Destination $named -Force
            $file = $named
        }
        Write-Host "Quix Bridge $Version is already installed. The script repairs it."
        Write-Host 'The repair puts back the files, the service, the config folder and the update task. It keeps config.yaml when it is there.'
        $msiArguments += @("`"$file`"", 'REINSTALL=ALL', 'REINSTALLMODE=vamus')
    }
    else {
        $msiArguments += "`"$file`""
    }

    Write-Host 'Run the MSI. Windows asks for administrator rights.'
    $log = Join-Path $work 'install.log'
    $exitCode = Invoke-Msiexec ($msiArguments + @('/qn', '/l*v', "`"$log`""))
    if ($exitCode -eq $PromptCancelled) {
        # A file run ends with the code. A run through "irm | iex" must not close the
        # person's shell, so it sets the code and stops the script there.
        if ($PSCommandPath) { exit $PromptCancelled }
        $global:LASTEXITCODE = $PromptCancelled
        return
    }
    if ($exitCode -ne 0 -and $exitCode -ne 3010) {
        $failure = Read-MsiFailure $log
        if ($failure.Count -gt 0) {
            Write-Host 'The MSI log says:'
            $failure | ForEach-Object { Write-Host "  $_" }
        }
        throw ("The MSI failed with code $exitCode. The log is at $log. " +
            "When the run fails again, uninstall Quix Bridge in Settings > Apps, then run this script again.")
    }
    Write-Host 'The MSI installed the bridge and started the service.'
    Write-Host 'The MSI added the bridge folder to the system PATH.'

    if (Test-InteractiveInstall) {
        $shortcut = Resolve-BridgeTrayShortcut ([Environment]::GetFolderPath('CommonStartup'))
        if ((Test-Path $shortcut) -and (Start-DeElevated $shortcut)) {
            Write-Host 'Started the tray for this session.'
        }

        # The login URL is a credential, so the script never prints it. When it cannot
        # open the browser, it names the command that prints the URL.
        $opened = $false
        $exe = Join-Path $env:ProgramFiles 'Quix\Bridge\quix-bridge.exe'
        if ((Test-Path $exe) -and (Test-DefaultBrowser)) {
            try {
                $uiOutput = & $exe ui 2>$null | Out-String
                $url = Read-UiLoginUrl $uiOutput
                if ($url -and (Start-DeElevated $url)) {
                    $opened = $true
                    Write-Host 'Opened the console in the browser.'
                    Write-Host 'In Edge or Chrome, click Install in the console bar and tick Pin to taskbar. The console then has its own taskbar icon.'
                }
            }
            catch {
                # Best effort. The hint below still names the command.
            }
        }
        if (-not $opened) {
            Write-Host "The script did not open the console. Run 'quix-bridge ui' in a new administrator shell. It prints the login URL and the code."
        }
    }

    Write-Host "Done. Open a new shell, because this shell keeps the old PATH. Then run 'quix-bridge status' to read the state."
}
