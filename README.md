# Quix Lake Bridge

The Quix Lake Bridge lets Quix Cloud read and write folders on a machine you own. The bridge opens one outbound connection to Quix. You open no inbound port, and the list of shared folders stays on your machine.

## Supported platforms

| Platform | Status |
| --- | --- |
| Windows x64 (`win-x64`) | Supported |
| Windows Arm64 (`win-arm64`) | Supported |
| Linux x64 (`linux-x64`) | Supported |
| Linux Arm64 (`linux-arm64`) | Not yet |
| macOS | Not yet |

On macOS and on Linux Arm64, `install.sh` stops at once and names the supported platforms.

## Install

1. In Quix Cloud, go to **Settings > Quix Lake > your connection > Quix Lake Bridges > Pair a bridge**. This page gives you the quick config for the bridge.
2. Run the install command on the machine.

Linux:

```bash
curl -fsSL https://github.com/quixio/quix-lake-bridge/raw/main/install.sh | sh
```

Windows (PowerShell, as administrator):

```powershell
irm https://github.com/quixio/quix-lake-bridge/raw/main/install.ps1 | iex
```

On Windows, the MSI installs the bridge as a service, starts it, and adds `quix-bridge` to the system PATH. Open a new shell after the install, because the old shell keeps the old PATH. Then run `quix-bridge status`.

On Linux, the script installs the deb or the rpm when the machine has `dpkg` or `rpm`. Otherwise it installs the tar.gz to `/usr/local/bin`.

### Install one version

Both scripts read `QUIX_BRIDGE_VERSION`. A leading `v` is optional, so `0.1.0` and `v0.1.0` both work.

```bash
QUIX_BRIDGE_VERSION=0.1.0 sh install.sh
```

```powershell
$env:QUIX_BRIDGE_VERSION = '0.1.0'; irm https://github.com/quixio/quix-lake-bridge/raw/main/install.ps1 | iex
.\install.ps1 -Version 0.1.0
```

On Windows, `-Version` wins over `QUIX_BRIDGE_VERSION`.

### Linux libraries

The bridge needs ICU, OpenSSL and a CA trust store. The deb and the rpm name all three, so `apt` and `dnf` install them for you. With a tar.gz install, install them yourself:

- RHEL, AlmaLinux and Rocky: `dnf install libicu openssl-libs ca-certificates`
- Debian and Ubuntu: `apt install libicu<N> libssl<N> ca-certificates` (Debian 12 has `libicu72` and `libssl3`)

## Unsigned builds

The builds are not signed yet. Both scripts download `SHA256SUMS` from the same release and check the SHA-256 hash of the download. If the hash does not match, the script stops and installs nothing. If you download a file by hand, check it against `SHA256SUMS` before you run it.

## Where the bridge keeps its data

The config and the stored credentials live outside the package, so an upgrade does not change them:

- Windows: `C:\ProgramData\Quix\bridge`
- Linux: `/etc/quix-bridge`

A removal deletes them, except in these cases:

- Windows: run `msiexec /x ... KEEPDATA=1` to keep them.
- Debian and Ubuntu: `apt remove` keeps them. `apt purge` deletes them.
- RHEL and Rocky: rpm keeps them. Run `quix-bridge service uninstall --purge` before `rpm -e quix-bridge` to delete them.

## Automatic updates

The bridge takes no automatic update by default. To turn updates on, set `update.channel` to `stable` in `config.yaml`. A daily task (Windows) or timer (Linux) then checks for a new release.

## Status

The Quix Lake Bridge is in preview. The first release is not published yet, so the install scripts stop with "could not read the newest release" until it is.
