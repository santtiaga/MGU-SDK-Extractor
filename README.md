# MGU SDK Extractor & Logger

A macOS desktop utility for inspecting and collecting data from BMW iDrive 7 / MGU head units over SSH.

## Features

- **Find MGU** — discovers the ENET gateway via UDP 6811.
- **Diagnostic capture** — collects renderer, DCSM2, OAP and system logs into a local archive.
- **SDK donor extraction** — uses the installed MGU deploy tool's `sdk-donor` interface.
- **Get lists** — retrieves the x_call bundle, reconstructs `oap-sdk` locally, captures system/SOME-IP information and builds an asset path index.
- **Download assets** — downloads resources referenced by the latest successful asset index, preserving their root filesystem paths.

## Run on macOS

Requirements: Python 3 with Tkinter, OpenSSH, Bash, tar; Node.js is additionally required for the x_call SDK/list extraction.

```bash
python3 scripts/mgu_diagnostics_gui.py
```

Enter `root@MGU-IP` or use **Find MGU**. SSH key authentication is used; the application does not ask for or store passwords.

## CLI

Diagnostic log capture:

```bash
./scripts/collect-mgu-logs.sh root@192.168.1.50 600
```

SDK + system lists and asset index:

```bash
MGU_SSH_KEY=~/.ssh/mgu_root_key ./scripts/extract-mgu-full.sh --lists root@192.168.1.50
```

Download indexed assets (replace the directory with the exact `OUTPUT_DIR` printed by stage 1):

```bash
MGU_SSH_KEY=~/.ssh/mgu_root_key ./scripts/extract-mgu-full.sh --download-assets root@192.168.1.50 "$HOME/BMW_MGU_Extract/YYYYMMDD-HHMMSS"
```

See [Full MGU extraction](docs/MGU_FULL_EXTRACTION.md), [SDK donor extraction](docs/MGU_SDK_EXTRACTION.md), and [diagnostic logging](docs/MGU_DIAGNOSTICS.md).

## Safety and limitations

The collectors are designed to be read-only on the MGU: they do not flash firmware, code ECUs, install packages, change OAP configuration or restart services. Diagnostic output can contain VINs, device identifiers, network details and proprietary BMW material; review it before sharing.

**Hardware validation:** these scripts and GUI have not yet been executed against a physical MGU as part of this repository migration. The asset-transfer path depends on the target MGU's tar implementation and should be verified on hardware.

## Third-party components

- `scripts/extract_sdk.js` is vendored from [cauliflowermossgrape/idrive7-apps](https://github.com/cauliflowermossgrape/idrive7-apps), under MIT; see [the included license](scripts/EXTRACT_SDK_LICENSE.txt).
- `scripts/mgu_discovery.py` is adapted from [cauliflowermossgrape/idrive7-8-ssh-root](https://github.com/cauliflowermossgrape/idrive7-8-ssh-root), released under The Unlicense.
