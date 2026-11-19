# MGU diagnostics collector (macOS)

A dark Tkinter desktop interface is available at `scripts/mgu_diagnostics_gui.py`.
It follows the diagnostic-cockpit layout and live-console pattern of
[`gui.py` in idrive7-8-ssh-root](https://github.com/cauliflowermossgrape/idrive7-8-ssh-root/blob/main/gui.py),
while using this repository's read-only collector for the actual SSH capture.

This tool runs **on your Mac**. It connects to the BMW MGU over SSH, records the
native `cluster-render` service and Apex Dash-related diagnostics while you
reproduce the failure, then downloads one compressed archive to the Mac.

It is read-only: it does not restart services, change configuration, install
packages, or write into OAP application directories. Temporary files are
written under `/tmp` on the MGU and removed after a successful download
(default behaviour).

## Requirements

- macOS with the built-in `ssh`, `scp`, `bash` and `tar`.
- For the GUI: Python 3 with Tkinter (some Homebrew Python builds require a separate Tcl/Tk-enabled installation).
- For **Full MGU Extract**: Node.js (to reconstruct the SDK locally from the x_call bundle).
- SSH access to the MGU. Use the account you normally use for diagnostics;
  `root` is recommended so system journal and process details are readable.
- The MGU must be reachable over the same network.

## Run — GUI (recommended)

On macOS with Python 3 and Tkinter installed, from the repository root:

```bash
python3 scripts/mgu_diagnostics_gui.py
```

Press **Find MGU** to run ENET discovery, or enter the SSH target manually (`root@MGU-IP` or an alias from `~/.ssh/config`). The discovery sends the BMW ENET UDP probe to port 6811 across active IPv4 interfaces and reads the `BMWVIN` reply marker. A discovered gateway IP is inserted as `root@IP`; you can still edit it. Then choose a capture duration and press **Start diagnostic capture**. The live console
shows connection, collection progress and archive download. Session output is
also saved under `mgu-diagnostics/`. The GUI uses SSH key authentication; it
does not collect or store passwords. The optional **SSH identity** field accepts a
private-key path such as `~/.ssh/mgu_root_key`; if blank, the normal SSH agent
and `~/.ssh/config` are used. The selected key is passed to the log collector
and both SDK extraction modes.

The discovery implementation is in `scripts/mgu_discovery.py`. It is adapted from the `mgu7/discovery.py` module in [idrive7-8-ssh-root](https://github.com/cauliflowermossgrape/idrive7-8-ssh-root), which is released under The Unlicense. It only performs the UDP discovery exchange; SSH authentication and log collection remain separate.

## Run — command line

From the repository root:

```bash
chmod +x scripts/collect-mgu-logs.sh
./scripts/collect-mgu-logs.sh root@192.168.1.50
```

Default capture is 10 minutes. Set a duration in seconds (30–7200):

```bash
./scripts/collect-mgu-logs.sh root@192.168.1.50 900
```

The archive is saved under `./mgu-diagnostics/`. Reproduce the DCSM2/renderer
failure during the capture window. Once the download finishes, upload the
`.tar.gz` archive to the conversation.

To retain the temporary copy on the MGU for manual inspection, append
`--keep-remote`.

## What it collects

- MGU OS, kernel, uptime, filesystem and memory snapshots.
- `cluster-render status`, `/run/cluster-render/status.txt`, renderer paths,
  process list, Unix sockets and network socket summary.
- Native renderer log and rotated log (initial copy and live tail).
- `cluster-render.service` journal, if systemd/journald is available.
- Relevant journal messages filtered for Apex Dash, OAP, DCSM2, RAMSES and
  cluster-render.
- Kernel `dmesg`, boot journal and final snapshots.
- Likely OAP application log files (only log/out/err files; no arbitrary app
  data or package contents).
- A five-second timeline of renderer status, processes, memory and sockets.

Missing commands, paths or services are recorded as unavailable; they do not
abort the collection.

## Important

The archive may contain VINs, device identifiers, local network details,
application paths or other diagnostic metadata. Review it before sharing
outside this conversation. The collector intentionally does not collect
credentials, SSH keys, user home directories, app databases or arbitrary
vehicle data.

If SSH host-key verification appears, verify the fingerprint before accepting.


SDK donor extraction is also available in the GUI and as a command-line action. See [MGU SDK extraction](MGU_SDK_EXTRACTION.md) for the exact SSH command, output files, prerequisites and handling notes.


For the x_call-based workflow, use the separate **Get lists** and **Download assets** actions. See [Full MGU extraction](MGU_FULL_EXTRACTION.md) for details.