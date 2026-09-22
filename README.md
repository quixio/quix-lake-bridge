# Quix Lake Bridge

The Quix Lake Bridge lets Quix Cloud read and write folders on a machine you own. The bridge opens one outbound connection to Quix. You open no inbound port, and the list of shared folders stays on your machine.

## Install

Pair the bridge from **Settings > Quix Lake > your connection > Bridges > Pair a bridge** in Quix Cloud. Then run the install command on the machine.

Linux and macOS:

```bash
curl -fsSL https://github.com/quixio/quix-lake-bridge/raw/main/install.sh | sh
```

Windows (PowerShell, as administrator):

```powershell
irm https://github.com/quixio/quix-lake-bridge/raw/main/install.ps1 | iex
```

Install one version:

```bash
QUIX_BRIDGE_VERSION=0.1.0 sh install.sh
```

```powershell
.\install.ps1 -Version 0.1.0
```

The builds are not signed yet. Both scripts check the download against `SHA256SUMS` from the same release, and they stop if the hash does not match. Check a manual download against `SHA256SUMS` before you run it.

## Status

The Quix Lake Bridge is in preview. The first release is not published yet, so the install scripts stop with "could not read the newest release" until it is.
