# MGU SDK donor extraction

The diagnostics GUI includes **Extract SDK from MGU**. It uses the SSH target already entered in the GUI and runs `scripts/extract-mgu-sdk.sh`.

## How it works

1. The Mac opens an SSH session to the MGU.
2. The remote command runs `mgu-deploy.sh sdk-donor --json` (or the installed shim at `/var/opt/mgu-deploy/mgu-deploy.sh`).
3. The deploy tool locates a stock BMW OAP Browserify bundle that contains the `oap-sdk` core, builds its SDK module representation, and places the results in `/run/mgu-deploy/sdk-donor/`.
4. The command returns JSON metadata with `path`, `module`, `donor`, and `sdkVersion` fields.
5. The Mac validates that both returned paths are inside `/run/mgu-deploy/sdk-donor/`, downloads the Browserify bundle and generated SDK module using SCP, and writes the original JSON response and a README beside them.

The implementation deliberately delegates donor selection and SDK extraction to the MGU's own deploy tool. It does not try to scrape application folders or guess which package contains a compatible SDK. The remote `sdk-donor` command does not take the deploy lock, install packages, restart services, or modify OAP apps. It does create or refresh a cache under `/run`, which is volatile and normally disappears on reboot.

## Run from the GUI

Start the application:

```bash
python3 scripts/mgu_diagnostics_gui.py
```

Find the MGU or enter its SSH target, then press **Extract SDK from MGU**. SSH key authentication is expected; the GUI does not request or store passwords.

## Run from Terminal (make the script executable once)

```bash
chmod +x scripts/extract-mgu-sdk.sh
./scripts/extract-mgu-sdk.sh root@192.168.1.50
```

Requirements on macOS: `ssh`, `scp`, and Python 3.

The result is saved under `mgu-sdk/sdk-extract-<timestamp>/`:

- `sdk-donor.js` — selected Browserify SDK donor bundle.
- `oap-sdk/` — generated SDK module (`index.js` and `package.json`).
- `sdk-donor-response.json` — raw JSON response when the MGU deploy donor interface succeeds.
- `x_call/` — downloaded source archive and unpacked files when the fallback method is used.
- `README.txt` — extraction metadata.

## Requirements and failure cases

- The MGU must have a compatible `mgu-deploy` tool installed, exposing `sdk-donor --json`.
- A stock donor must contain the SDK core modules. If none is available, the deploy tool exits unsuccessfully and the extraction cannot complete.
- SSH and SCP must be able to access the MGU using the supplied target.
- The extractor checks the remote path prefix before downloading; it refuses paths outside `/run/mgu-deploy/sdk-donor/`.

## Handling and licensing

The bundle and generated module are BMW-provided SDK material. Keep the extracted files local. Do not commit them to this repository or redistribute them unless the applicable licensing and redistribution permissions have been confirmed.

## Upstream mechanism

The `sdk-donor` interface and output layout are documented by the MGU deploy tool in [mgu-store](https://github.com/robertnisipeanu/mgu-store), under `deploy/unit/mgu-deploy.sh`. The related build workflow consumes a donor bundle through `MGU_SDK_DONOR` or `--sdk`, as described in [idrive-apps](https://github.com/robertnisipeanu/idrive-apps/blob/main/apps/robertn_waze_cluster/README.md).


## Alternative: extract SDK from x_call

The repository also includes a second method that retrieves the preinstalled `x_call@*.tgz` archive and reconstructs `oap-sdk` locally with the MIT-licensed `scripts/extract_sdk.js` utility. It also captures the SOME/IP interface catalogue, system inventory and asset index. See [Full MGU extraction](MGU_FULL_EXTRACTION.md). The two methods are independent: `sdk-donor` uses the MGU deploy tool's donor cache; the x_call method rebuilds the SDK from the Browserify bundle in a BMW app.
