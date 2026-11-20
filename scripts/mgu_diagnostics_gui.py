#!/usr/bin/env python3
"""MGU SDK Extractor & Logger GUI for macOS.

Tkinter front-end inspired by cauliflowermossgrape/idrive7-8-ssh-root gui.py.
It delegates collection to the read-only SSH shell collector; it does not
flash, configure, restart or otherwise modify the head unit.
"""
import os
import queue
import socket
from concurrent.futures import ThreadPoolExecutor, as_completed
import subprocess
import sys
import threading
from datetime import datetime
import tkinter as tk
from tkinter import messagebox, scrolledtext, ttk

import mgu_discovery
import mgu_hsfz

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
COLLECTOR = os.path.join(HERE, "collect-mgu-logs.sh")
SDK_EXTRACTOR = os.path.join(HERE, "extract-mgu-sdk.sh")
FULL_EXTRACTOR = os.path.join(HERE, "extract-mgu-full.sh")
FULL_OUTDIR = os.path.join(os.path.expanduser("~"), "BMW_MGU_Extract")
OUTDIR = os.path.join(ROOT, "mgu-diagnostics")
SDK_OUTDIR = os.path.join(ROOT, "mgu-sdk")

BG = "#0e1319"
PANEL = "#161d26"
PANEL_HI = "#202935"
FIELD = "#0a0e13"
LINE = "#2a3542"
LINE_SOFT = "#1d2530"
TEXT = "#e8eef6"
MUTED = "#9aa9bd"
DIM = "#6f7f93"
HEADER_BG = "#0a0d12"
ACCENT = "#3b82f6"
ACCENT_HI = "#2f6fe0"
ACCENT_LT = "#86b4ff"
GREEN = "#35c281"
AMBER = "#e0a93a"
RED = "#e2554f"
CONSOLE_BG = "#070a0e"
CONSOLE_FG = "#c8d4e4"
DISABLED = "#38424f"
DISABLED_FG = "#79838f"
M_LBLUE = "#4fb3e8"
M_DBLUE = "#315fd4"
M_RED = "#e8323f"
UI, UI_SEMI, MONO = "SF Pro Text", "SF Pro Display", "Menlo"
OUTER = 22


class QueueWriter:
    def __init__(self, target):
        self.target = target

    def put(self, value):
        self.target.put(value)


class App:
    def __init__(self, root):
        self.root = root
        self.events = queue.Queue()
        self.worker = None
        self.process = None
        self.sdk_process = None
        self.full_process = None
        self.download_process = None
        self.sdk_busy = False
        self.full_busy = False
        self.download_busy = False
        self.old_logs_busy = False
        self.old_logs_process = None
        self.dcsm2_logs_busy = False
        self.dcsm2_logs_process = None
        self.full_output_dir = None
        self.full_output_host = None
        self.busy = False
        self.discovery_busy = False
        self.detected_gateway = None
        self.session_log = None
        self.archive_path = None

        root.title("MGU SDK Extractor & Logger")
        root.configure(bg=BG)
        root.minsize(820, 650)
        root.geometry("940x760")

        self.host = tk.StringVar(value="root@")
        self.ssh_key = tk.StringVar(value="")
        self.ssh_port = tk.StringVar(value="22")
        self.duration = tk.StringVar(value="600")
        self.keep_remote = tk.BooleanVar(value=False)

        self._style()
        self._build()
        self.root.after(100, self._drain)
        self.root.protocol("WM_DELETE_WINDOW", self._close)

    def _style(self):
        style = ttk.Style()
        try:
            style.theme_use("clam")
        except tk.TclError:
            pass
        style.configure("TFrame", background=BG)
        style.configure("TLabel", background=BG, foreground=TEXT, font=(UI, 10))
        style.configure("Hint.TLabel", background=BG, foreground=MUTED, font=(UI, 9))
        style.configure("Card.TLabel", background=PANEL, foreground=TEXT, font=(UI, 10))
        style.configure("CardHint.TLabel", background=PANEL, foreground=MUTED, font=(UI, 9))
        style.configure("TCombobox", fieldbackground=PANEL_HI, background=PANEL_HI,
                        foreground=TEXT, arrowcolor=MUTED, bordercolor=LINE,
                        lightcolor=PANEL_HI, darkcolor=PANEL_HI, padding=(8, 5))
        style.map("TCombobox", fieldbackground=[("readonly", PANEL_HI)],
                  foreground=[("readonly", TEXT)])
        self.root.option_add("*TCombobox*Listbox.background", PANEL)
        self.root.option_add("*TCombobox*Listbox.foreground", TEXT)
        self.root.option_add("*TCombobox*Listbox.selectBackground", ACCENT)
        self.root.option_add("*TCombobox*Listbox.selectForeground", "#ffffff")

        def button(name, bg, active, fg="#ffffff", font=(UI, 10, "bold"), pad=(13, 10)):
            style.configure(name, background=bg, foreground=fg, font=font,
                            padding=pad, borderwidth=0, relief="flat", focuscolor=bg)
            style.map(name, background=[("active", active), ("disabled", DISABLED)],
                      foreground=[("disabled", DISABLED_FG)])
        button("Hero.TButton", ACCENT, ACCENT_HI, font=(UI_SEMI, 15, "bold"), pad=(16, 17))
        button("Ghost.TButton", PANEL_HI, "#273340", TEXT, font=(UI, 9), pad=(11, 7))
        button("Danger.TButton", "#2a1716", "#381e1d", "#f29a94", font=(UI, 9, "bold"))

    def _label(self, parent, text, **kwargs):
        return tk.Label(parent, text=text, **kwargs)

    def _section(self, parent, text, color=M_LBLUE, bg=PANEL):
        row = tk.Frame(parent, bg=bg)
        tk.Frame(row, bg=color, width=3, height=13).pack(side="left", padx=(0, 10))
        self._label(row, text, bg=bg, fg=MUTED, font=(UI, 9, "bold")).pack(side="left")
        return row

    def _entry(self, parent, variable, width=34):
        return tk.Entry(parent, textvariable=variable, width=width, font=(MONO, 11),
                        bg=FIELD, fg=TEXT, insertbackground=ACCENT_LT, relief="flat",
                        highlightthickness=1, highlightbackground=LINE,
                        highlightcolor=ACCENT)

    def _build(self):
        header = tk.Frame(self.root, bg=HEADER_BG)
        header.pack(fill="x")
        mark = tk.Canvas(header, width=38, height=24, bg=HEADER_BG, highlightthickness=0, bd=0)
        for x, color in ((0, M_LBLUE), (12, M_DBLUE), (24, M_RED)):
            mark.create_polygon(x, 24, x + 8, 24, x + 14, 0, x + 6, 0,
                                fill=color, outline=color)
        mark.pack(side="left", padx=(18, 13), pady=16)
        title = tk.Frame(header, bg=HEADER_BG)
        title.pack(side="left", pady=12)
        self._label(title, "MGU SDK EXTRACTOR  /  LOGGER", bg=HEADER_BG,
                    fg=TEXT, font=(UI_SEMI, 15)).pack(anchor="w")
        self._label(title, "BMW iDrive 7 · SSH capture · cluster-render + DCSM2",
                    bg=HEADER_BG, fg=MUTED, font=(UI, 9)).pack(anchor="w")

        stripe = tk.Frame(self.root, bg=LINE)
        stripe.pack(fill="x")
        for color in (M_LBLUE, M_DBLUE, M_RED):
            tk.Frame(stripe, bg=color, width=68, height=3).pack(side="left")

        body = tk.Frame(self.root, bg=BG)
        body.pack(fill="both", expand=True, padx=OUTER, pady=(18, 0))

        card = tk.Frame(body, bg=PANEL, highlightthickness=1, highlightbackground=LINE)
        card.pack(fill="x")
        inner = tk.Frame(card, bg=PANEL)
        inner.pack(fill="x", padx=18, pady=16)

        self._section(inner, "SSH CONNECTION").pack(fill="x")
        conn = tk.Frame(inner, bg=PANEL)
        conn.pack(fill="x", pady=(10, 0))
        self._label(conn, "SSH target", bg=PANEL, fg=TEXT, font=(UI, 10)).grid(
            row=0, column=0, sticky="w", padx=(0, 10))
        self._entry(conn, self.host, 27).grid(row=0, column=1, sticky="w", ipady=5)
        self.detect_btn = ttk.Button(conn, text="Find MGU", style="Ghost.TButton",
                                      command=self.detect_mgu)
        self.detect_btn.grid(row=0, column=2, padx=(10, 0), sticky="w")
        self._label(conn, "SSH port", bg=PANEL, fg=TEXT, font=(UI, 9)).grid(
            row=0, column=3, sticky="e", padx=(14, 6))
        self._entry(conn, self.ssh_port, 7).grid(row=0, column=4, sticky="w", ipady=5)
        self._label(conn, "UDP 6811 finds ZGW; TCP 6801 reads MGU IP (UDS 0x172A); SSH uses TCP 22.",
                    bg=PANEL, fg=MUTED, font=(UI, 8)).grid(
            row=1, column=1, columnspan=4, sticky="w", pady=(5, 0))
        self._label(conn, "SSH identity (optional)", bg=PANEL, fg=TEXT,
                    font=(UI, 9)).grid(row=2, column=0, sticky="w", padx=(0, 10), pady=(9, 0))
        self._entry(conn, self.ssh_key, 44).grid(
            row=2, column=1, columnspan=3, sticky="ew", ipady=4, pady=(9, 0))
        self.find_key_btn = ttk.Button(conn, text="Find root key on disk",
                                          style="Ghost.TButton", command=self.find_root_key)
        self.find_key_btn.grid(row=2, column=4, padx=(8, 0), pady=(9, 0), sticky="w")
        self._label(conn, "Example: ~/.ssh/mgu_root_key · leave empty to use ssh-agent/config",
                    bg=PANEL, fg=MUTED, font=(UI, 8)).grid(
            row=3, column=1, columnspan=4, sticky="w", pady=(4, 0))

        tk.Frame(inner, bg=LINE_SOFT, height=1).pack(fill="x", pady=15)
        self._section(inner, "CAPTURE WINDOW", AMBER).pack(fill="x")
        opts = tk.Frame(inner, bg=PANEL)
        opts.pack(fill="x", pady=(10, 0))
        self._label(opts, "Duration", bg=PANEL, fg=TEXT, font=(UI, 10)).pack(side="left")
        self.duration_box = ttk.Combobox(opts, textvariable=self.duration, state="readonly",
                                         values=("300", "600", "900", "1800", "3600"), width=10)
        self.duration_box.pack(side="left", padx=(10, 7))
        self._label(opts, "seconds  ·  5 / 10 / 15 / 30 / 60 min",
                    bg=PANEL, fg=MUTED, font=(UI, 8)).pack(side="left")
        tk.Checkbutton(opts, text="Keep temporary archive on MGU",
                       variable=self.keep_remote, bg=PANEL, fg=TEXT,
                       activebackground=PANEL, activeforeground=TEXT,
                       selectcolor=FIELD, font=(UI, 9)).pack(side="right")

        note = tk.Frame(body, bg=BG)
        note.pack(fill="x", pady=(13, 0))
        self._label(note,
            "Read-only collection. No flashing, coding, service restarts or changes to OAP. "
            "SSH key authentication is expected; the app never asks for or stores your password.",
            bg=BG, fg=MUTED, font=(UI, 9), justify="left", wraplength=860
        ).pack(anchor="w")

        self.start_btn = ttk.Button(body, text="Start diagnostic capture",
                                    style="Hero.TButton", command=self.start)
        self.start_btn.pack(fill="x", pady=(16, 0))
        self.extract_btn = ttk.Button(body, text="Extract SDK from MGU",
                                      style="Ghost.TButton", command=self.extract_sdk)
        self.extract_btn.pack(fill="x", pady=(8, 0))
        self.get_lists_btn = ttk.Button(body, text="Get lists · SDK + system + asset index",
                                         style="Ghost.TButton", command=self.extract_full)
        self.get_lists_btn.pack(fill="x", pady=(8, 0))
        self.download_assets_btn = ttk.Button(body, text="Download assets",
                                              style="Ghost.TButton", command=self.download_assets,
                                              state="disabled")
        self.download_assets_btn.pack(fill="x", pady=(7, 0))
        self.old_logs_btn = ttk.Button(body, text="Download all old Apex Dash logs",
                                       style="Ghost.TButton", command=self.download_old_logs)
        self.old_logs_btn.pack(fill="x", pady=(7, 0))
        self.dcsm2_logs_btn = ttk.Button(body, text="Download DCSM2 Lab logs only",
                                         style="Ghost.TButton", command=self.download_dcsm2_logs)
        self.dcsm2_logs_btn.pack(fill="x", pady=(7, 0))

        loghdr = tk.Frame(body, bg=BG)
        loghdr.pack(fill="x", pady=(18, 7))
        self._section(loghdr, "LIVE SESSION LOG", ACCENT, BG).pack(side="left")
        ttk.Button(loghdr, text="Open full extract", style="Ghost.TButton",
                   command=self.open_full_output).pack(side="right", padx=(7, 0))
        ttk.Button(loghdr, text="Open SDK folder", style="Ghost.TButton",
                   command=self.open_sdk_output).pack(side="right", padx=(7, 0))
        ttk.Button(loghdr, text="Open output folder", style="Ghost.TButton",
                   command=self.open_output).pack(side="right")

        console_frame = tk.Frame(body, bg=LINE)
        console_frame.pack(fill="both", expand=True, pady=(0, 12))
        self.console = scrolledtext.ScrolledText(
            console_frame, height=14, wrap="word", font=(MONO, 9),
            bg=CONSOLE_BG, fg=CONSOLE_FG, insertbackground=ACCENT_LT,
            relief="flat", borderwidth=0, padx=12, pady=10,
            selectbackground="#1d3350", selectforeground=TEXT)
        self.console.pack(fill="both", expand=True, padx=1, pady=1)
        self.console.configure(state="disabled")

        status = tk.Frame(self.root, bg=HEADER_BG)
        status.pack(fill="x")
        self.led = tk.Canvas(status, width=14, height=14, bg=HEADER_BG, highlightthickness=0)
        self.led_dot = self.led.create_oval(3, 3, 11, 11, fill=GREEN, outline=GREEN)
        self.led.pack(side="left", padx=(16, 9), pady=7)
        self.status = self._label(status, "Ready · waiting for MGU",
                                  bg=HEADER_BG, fg=MUTED, font=(UI, 9))
        self.status.pack(side="left", pady=7)

    def _set_status(self, text, color=None):
        self.status.configure(text=text)
        if color:
            self.led.itemconfig(self.led_dot, fill=color, outline=color)

    def _append(self, text):
        self.console.configure(state="normal")
        self.console.insert("end", text)
        self.console.see("end")
        self.console.configure(state="disabled")
        if self.session_log:
            try:
                with open(self.session_log, "a", encoding="utf-8") as log:
                    log.write(text)
            except OSError:
                pass

    def _drain(self):
        try:
            while True:
                kind, payload = self.events.get_nowait()
                if kind == "line":
                    self._append(payload)
                elif kind == "done":
                    self._finish(payload)
                elif kind == "discover_done":
                    self._discovery_finished(payload)
                elif kind == "key_search_done":
                    self._key_search_finished(payload)
                elif kind == "sdk_done":
                    self._sdk_finished(payload)
                elif kind == "full_done":
                    self._full_finished(payload)
                elif kind == "download_done":
                    self._download_finished(payload)
                elif kind == "old_logs_done":
                    self._old_logs_finished(payload)
                elif kind == "dcsm2_logs_done":
                    self._dcsm2_logs_finished(payload)
        except queue.Empty:
            pass
        self.root.after(100, self._drain)

    def find_root_key(self):
        if self.discovery_busy or self.busy or self.sdk_busy or self.full_busy or self.download_busy:
            return
        self.find_key_btn.configure(state="disabled")
        self._set_status("Searching local disk for MGU SSH keys", AMBER)
        self._append("\n[key search] Scanning your home folder for likely MGU/root SSH private keys...\n")

        def run():
            home = os.path.expanduser("~")
            skip_dirs = {
                ".Trash", ".cache", ".npm", ".cargo", ".rustup", ".local",
                "node_modules", ".git", "Library", "Pictures", "Music",
                "Movies", "Applications", "Virtual Machines",
            }
            candidates = []
            scanned = 0
            for current, dirs, files in os.walk(home):
                dirs[:] = [d for d in dirs if d == ".ssh" or (d not in skip_dirs and not d.startswith("."))]
                for name in files:
                    lower = name.lower()
                    likely_name = (
                        ("mgu" in lower and ("key" in lower or "root" in lower))
                        or lower in ("id_rsa", "id_ed25519", "id_ecdsa")
                        or (current.endswith(os.sep + ".ssh") and "key" in lower)
                    )
                    if not likely_name:
                        continue
                    path = os.path.join(current, name)
                    try:
                        if not os.path.isfile(path) or os.path.islink(path):
                            continue
                        with open(path, "rb") as stream:
                            header = stream.read(256)
                        if (b"PRIVATE KEY" in header or b"openssh-key-v1" in header
                                or lower in ("id_rsa", "id_ed25519", "id_ecdsa")):
                            candidates.append(path)
                    except (OSError, PermissionError):
                        continue
                scanned += 1
                if scanned % 500 == 0:
                    self.events.put(("line", "[key search] Scanned %d folders...\n" % scanned))
            self.events.put(("key_search_done", candidates))

        self.key_search_worker = threading.Thread(target=run, daemon=True)
        self.key_search_worker.start()

    def _key_search_finished(self, candidates):
        self.find_key_btn.configure(state="normal")
        if not candidates:
            self._append("[key search] No likely SSH private keys found in your home folder.\n")
            self._set_status("No local SSH key found", AMBER)
            return
        self._append("[key search] Found %d possible key file(s):\n" % len(candidates))
        for path in candidates:
            self._append("  " + path + "\n")
        if len(candidates) == 1:
            selected = candidates[0]
            if messagebox.askyesno("MGU root key found",
                                   "Use this key for the SSH connection?\n\n" + selected):
                self.ssh_key.set(selected)
                self._set_status("SSH identity selected", GREEN)
            else:
                self._set_status("Key found · selection unchanged", MUTED)
            return

        dialog = tk.Toplevel(self.root)
        dialog.title("Select MGU SSH key")
        dialog.configure(bg=PANEL)
        dialog.transient(self.root)
        dialog.grab_set()
        tk.Label(dialog, text="Choose the private key to use for the MGU connection:",
                 bg=PANEL, fg=TEXT, font=(UI, 10)).pack(anchor="w", padx=14, pady=(14, 8))
        listing = tk.Listbox(dialog, width=88, height=min(12, len(candidates)),
                             bg=FIELD, fg=TEXT, selectbackground=ACCENT,
                             font=(MONO, 9), relief="flat")
        for path in candidates:
            listing.insert("end", path)
        listing.pack(fill="both", expand=True, padx=14, pady=4)

        def choose():
            selection = listing.curselection()
            if not selection:
                return
            self.ssh_key.set(candidates[selection[0]])
            self._set_status("SSH identity selected", GREEN)
            dialog.destroy()

        buttons = tk.Frame(dialog, bg=PANEL)
        buttons.pack(fill="x", padx=14, pady=12)
        ttk.Button(buttons, text="Use selected key", style="Ghost.TButton",
                   command=choose).pack(side="right")
        ttk.Button(buttons, text="Cancel", style="Ghost.TButton",
                   command=dialog.destroy).pack(side="right", padx=(0, 8))
        listing.bind("<Double-Button-1>", lambda _event: choose())

    def detect_mgu(self):
        if self.busy or self.discovery_busy or self.sdk_busy or self.full_busy or self.download_busy:
            return
        self.discovery_busy = True
        self.detect_btn.configure(state="disabled")
        self.start_btn.configure(state="disabled")
        self.extract_btn.configure(state="disabled")
        self.get_lists_btn.configure(state="disabled")
        self.download_assets_btn.configure(state="disabled")
        self._set_status("Searching ENET networks · UDP 6811", AMBER)
        self._append("\n[discovery] Searching for BMW ENET gateway on all active IPv4 interfaces...\n")

        def log(*parts, **kwargs):
            self.events.put(("line", " ".join(str(p) for p in parts) + "\n"))

        def run():
            try:
                gateways = mgu_discovery.discover(
                    timeout_ms=700, overall_ms=3500, log=log)
                resolved = []
                for gw in gateways:
                    try:
                        addresses = mgu_hsfz.read_mgu_ip(gw.ip, log=log)
                        resolved.append((gw, addresses, None))
                    except Exception as exc:
                        log("[discovery] Gateway %s found, but MGU IP read failed: %s" %
                            (gw.ip, exc))
                        resolved.append((gw, None, str(exc)))
                self.events.put(("discover_done", (gateways, resolved, None)))
            except Exception as exc:
                self.events.put(("discover_done", ([], [], str(exc))))

        self.discovery_worker = threading.Thread(target=run, daemon=True)
        self.discovery_worker.start()

    def _discovery_finished(self, result):
        gateways, resolved, error = result
        self.discovery_busy = False
        self.detect_btn.configure(state="normal")
        self.start_btn.configure(state="normal" if not self.busy and not self.sdk_busy and not self.full_busy and not self.download_busy and not self.old_logs_busy else "disabled")
        self.extract_btn.configure(state="normal" if not self.busy and not self.sdk_busy and not self.full_busy and not self.download_busy and not self.old_logs_busy else "disabled")
        self.get_lists_btn.configure(state="normal" if not self.busy and not self.sdk_busy and not self.full_busy and not self.download_busy and not self.old_logs_busy else "disabled")
        self.download_assets_btn.configure(state="normal" if self.full_output_dir and not self.busy and not self.sdk_busy and not self.full_busy and not self.download_busy and not self.old_logs_busy else "disabled")
        if error:
            self._append("[discovery] ERROR: %s\n" % error)
            self._set_status("Discovery failed · see session log", RED)
            return
        if not gateways:
            self._append("[discovery] No ENET gateway replied on UDP 6811.\n")
            self._append("[discovery] Check ENET connection, adapter and vehicle power.\n")
            self._set_status("No ENET gateway found", AMBER)
            return

        for gw in gateways:
            self._append("[discovery] Found ZGW %s%s\n" %
                         (gw.ip, " · VIN " + gw.vin if gw.vin else ""))
        successful = [item for item in resolved if item[1] is not None]
        for gw, addresses, read_error in resolved:
            if addresses:
                mgu_ip, gateway_ip, route_ip = addresses
                self._append("[discovery] UDS 0x172A: MGU=%s · ZGW=%s · route=%s\n" %
                             (mgu_ip, gateway_ip, route_ip))
            else:
                self._append("[discovery] Could not read MGU IP via %s: %s\n" %
                             (gw.ip, read_error or "no response"))
        if not successful:
            self._set_status("ZGW found · MGU IP read failed", AMBER)
            return

        selected, addresses, _ = successful[0]
        self.detected_gateway = selected.ip
        mgu_ip = addresses[0]
        self.host.set("root@" + mgu_ip)
        self.ssh_port.set("22")
        self._append("[discovery] Selected MGU %s via ZGW %s. SSH target: %s:22\n" %
                     (mgu_ip, selected.ip, self.host.get().strip()))
        if len(successful) > 1:
            self._append("[discovery] %d MGU(s) resolved; first response selected.\n" %
                         len(successful))
        self._set_status("MGU IP resolved · SSH TCP 22 ready", GREEN)

    def start(self):
        if self.busy or self.sdk_busy or self.discovery_busy or self.full_busy or self.download_busy:
            return
        host = self.host.get().strip()
        if not host or host == "root@":
            messagebox.showerror("SSH target required",
                                 "Enter root@MGU-IP or an SSH host alias.")
            return
        if any(ch.isspace() for ch in host):
            messagebox.showerror("Invalid SSH target",
                                 "Use one SSH destination, without spaces.")
            return
        duration = int(self.duration.get())
        if not os.path.isfile(COLLECTOR):
            messagebox.showerror("Collector not found",
                                 "Expected scripts/collect-mgu-logs.sh next to this GUI.")
            return
        os.makedirs(OUTDIR, exist_ok=True)
        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        self.session_log = os.path.join(OUTDIR, "session-" + stamp + ".log")
        self.archive_path = None
        self.console.configure(state="normal")
        self.console.delete("1.0", "end")
        self.console.configure(state="disabled")
        self._append("MGU SDK Extractor & Logger\n")
        self._append("Target: %s · SSH port: %s\nCapture: %s seconds\n\n" % (host, self.ssh_port.get().strip(), duration))
        self.busy = True
        self.start_btn.configure(state="disabled")
        self.detect_btn.configure(state="disabled")
        self.extract_btn.configure(state="disabled")
        self.get_lists_btn.configure(state="disabled")
        self.download_assets_btn.configure(state="disabled")
        self.duration_box.configure(state="disabled")
        self._set_status("Connecting · preparing read-only capture", AMBER)

        args = ["bash", COLLECTOR, host, str(duration)]
        if self.keep_remote.get():
            args.append("--keep-remote")

        ssh_env = self._ssh_env()

        def run():
            try:
                self.process = subprocess.Popen(
                    args, cwd=ROOT, env=ssh_env, stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                    text=True, bufsize=1, universal_newlines=True)
                for line in self.process.stdout:
                    self.events.put(("line", line))
                code = self.process.wait()
                self.events.put(("done", (code, None)))
            except Exception as exc:
                self.events.put(("done", (1, str(exc))))

        self.worker = threading.Thread(target=run, daemon=True)
        self.worker.start()

    def _finish(self, result):
        code, error = result
        self.busy = False
        self.process = None
        self.start_btn.configure(state="normal")
        self.detect_btn.configure(state="normal")
        self.extract_btn.configure(state="normal")
        self.get_lists_btn.configure(state="normal")
        self.download_assets_btn.configure(state="normal" if self.full_output_dir else "disabled")
        self.duration_box.configure(state="readonly")
        if error:
            self._append("\nERROR: %s\n" % error)
        if code == 0:
            self._set_status("Complete · archive downloaded to mgu-diagnostics", GREEN)
            self._append("\nCapture completed. Upload the .tar.gz archive from mgu-diagnostics.\n")
        else:
            self._set_status("Failed · inspect the session log above", RED)
            self._append("\nCollector exited with code %s. Check SSH access and the log above.\n" % code)


    def extract_sdk(self):
        if self.busy or self.discovery_busy or self.sdk_busy or self.full_busy or self.download_busy:
            return
        host = self.host.get().strip()
        if not host or host == "root@":
            messagebox.showerror("SSH target required",
                                 "Find the MGU or enter root@MGU-IP / an SSH host alias.")
            return
        if any(ch.isspace() for ch in host):
            messagebox.showerror("Invalid SSH target",
                                 "Use one SSH destination, without spaces.")
            return
        if not os.path.isfile(SDK_EXTRACTOR):
            messagebox.showerror("SDK extractor not found",
                                 "Expected scripts/extract-mgu-sdk.sh next to this GUI.")
            return
        self.sdk_busy = True
        self.start_btn.configure(state="disabled")
        self.detect_btn.configure(state="disabled")
        self.extract_btn.configure(state="disabled")
        self.get_lists_btn.configure(state="disabled")
        self.download_assets_btn.configure(state="disabled")
        self._set_status("Extracting BMW OAP SDK donor", AMBER)
        self._append("\n[sdk] Starting SDK donor extraction from %s...\n" % host)

        ssh_env = self._ssh_env()

        def run():
            try:
                self.sdk_process = subprocess.Popen(
                    ["bash", SDK_EXTRACTOR, host], cwd=ROOT, env=ssh_env,
                    stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT, text=True, bufsize=1,
                    universal_newlines=True)
                for line in self.sdk_process.stdout:
                    self.events.put(("line", line))
                code = self.sdk_process.wait()
                self.events.put(("sdk_done", (code, None)))
            except Exception as exc:
                self.events.put(("sdk_done", (1, str(exc))))

        self.sdk_worker = threading.Thread(target=run, daemon=True)
        self.sdk_worker.start()

    def _sdk_finished(self, result):
        code, error = result
        self.sdk_busy = False
        self.sdk_process = None
        self.start_btn.configure(state="normal")
        self.detect_btn.configure(state="normal")
        self.extract_btn.configure(state="normal")
        self.get_lists_btn.configure(state="normal")
        self.download_assets_btn.configure(state="normal" if self.full_output_dir else "disabled")
        if error:
            self._append("[sdk] ERROR: %s\n" % error)
        if code == 0:
            self._set_status("SDK donor downloaded · see mgu-sdk folder", GREEN)
            self._append("[sdk] Extraction complete. Keep the BMW SDK material local.\n")
        else:
            self._set_status("SDK extraction failed · inspect the console", RED)
            self._append("[sdk] Extractor exited with code %s.\n" % code)


    def _ssh_env(self):
        port = self.ssh_port.get().strip()
        if not port.isdigit() or not 1 <= int(port) <= 65535:
            raise ValueError("SSH port must be a number from 1 to 65535.")
        env = os.environ.copy()
        env["MGU_SSH_PORT"] = port
        key = self.ssh_key.get().strip()
        if key:
            env["MGU_SSH_KEY"] = os.path.expanduser(key)
        else:
            env.pop("MGU_SSH_KEY", None)
        return env

    def extract_full(self):
        if self.busy or self.discovery_busy or self.sdk_busy or self.full_busy or self.download_busy:
            return
        host = self.host.get().strip()
        if not host or host == "root@":
            messagebox.showerror("SSH target required",
                                 "Find the MGU or enter root@MGU-IP / an SSH host alias.")
            return
        if any(ch.isspace() for ch in host):
            messagebox.showerror("Invalid SSH target", "Use one SSH destination, without spaces.")
            return
        if not os.path.isfile(FULL_EXTRACTOR) or not os.path.isfile(os.path.join(HERE, "extract_sdk.js")):
            messagebox.showerror("Extractor not found",
                                 "Expected scripts/extract-mgu-full.sh and scripts/extract_sdk.js.")
            return
        self.full_busy = True
        self.start_btn.configure(state="disabled")
        self.detect_btn.configure(state="disabled")
        self.extract_btn.configure(state="disabled")
        self.get_lists_btn.configure(state="disabled")
        self._set_status("Getting SDK, system information and resource lists", AMBER)
        self._append("\n[lists] Getting SDK, system information and asset index from %s...\n" % host)

        ssh_env = self._ssh_env()

        def run():
            try:
                self.full_process = subprocess.Popen(
                    ["bash", FULL_EXTRACTOR, "--lists", host], cwd=ROOT, env=ssh_env,
                    stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT, text=True, bufsize=1,
                    universal_newlines=True)
                output_dir = None
                for line in self.full_process.stdout:
                    if line.startswith("OUTPUT_DIR="):
                        output_dir = line.strip().split("=", 1)[1]
                    self.events.put(("line", line))
                code = self.full_process.wait()
                self.events.put(("full_done", (code, None, output_dir)))
            except Exception as exc:
                self.events.put(("full_done", (1, str(exc), None)))

        self.full_worker = threading.Thread(target=run, daemon=True)
        self.full_worker.start()

    def _full_finished(self, result):
        code, error, output_dir = result
        self.full_busy = False
        self.full_process = None
        self.full_output_dir = output_dir if code == 0 else None
        self.full_output_host = self.host.get().strip() if self.full_output_dir else None
        self.start_btn.configure(state="normal")
        self.detect_btn.configure(state="normal")
        self.extract_btn.configure(state="normal")
        self.get_lists_btn.configure(state="normal")
        self.download_assets_btn.configure(state="normal" if self.full_output_dir else "disabled")
        if error:
            self._append("[lists] ERROR: %s\n" % error)
        if code == 0 and self.full_output_dir:
            self._set_status("Lists ready · assets can be downloaded", GREEN)
            self._append("[lists] Index ready: %s\n" % self.full_output_dir)
        else:
            self._set_status("List collection failed · inspect the console", RED)
            self._append("[lists] Extractor exited with code %s.\n" % code)

    def download_assets(self):
        if self.busy or self.discovery_busy or self.sdk_busy or self.full_busy or self.download_busy:
            return
        host = self.host.get().strip()
        if not host or host == "root@":
            messagebox.showerror("SSH target required", "Enter the MGU SSH target used to create the index.")
            return
        if not self.full_output_dir or host != self.full_output_host or not os.path.isfile(os.path.join(self.full_output_dir, "assets", "file_index.txt")):
            messagebox.showerror("Asset index unavailable", "Run Get lists for this MGU first to create a matching resource index.")
            self.download_assets_btn.configure(state="disabled")
            return
        self.download_busy = True
        self.start_btn.configure(state="disabled")
        self.detect_btn.configure(state="disabled")
        self.extract_btn.configure(state="disabled")
        self.get_lists_btn.configure(state="disabled")
        self.download_assets_btn.configure(state="disabled")
        self._set_status("Downloading indexed MGU assets", AMBER)
        self._append("\n[assets] Downloading files from the saved index...\n")
        ssh_env = self._ssh_env()
        def run():
            try:
                self.download_process = subprocess.Popen(
                    ["bash", FULL_EXTRACTOR, "--download-assets", host, self.full_output_dir],
                    cwd=ROOT, env=ssh_env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT, text=True, bufsize=1, universal_newlines=True)
                for line in self.download_process.stdout:
                    self.events.put(("line", line))
                code = self.download_process.wait()
                self.events.put(("download_done", (code, None)))
            except Exception as exc:
                self.events.put(("download_done", (1, str(exc))))
        self.download_worker = threading.Thread(target=run, daemon=True)
        self.download_worker.start()

    def download_old_logs(self):
        if self.busy or self.discovery_busy or self.sdk_busy or self.full_busy or self.download_busy or self.old_logs_busy:
            return
        host = self.host.get().strip()
        if not host or host == "root@":
            messagebox.showerror("SSH target required", "Find the MGU or enter root@MGU-IP / an SSH host alias.")
            return
        if any(ch.isspace() for ch in host):
            messagebox.showerror("Invalid SSH target", "Use one SSH destination, without spaces.")
            return
        script = os.path.join(HERE, "fetch-apex-dash-logs.sh")
        if not os.path.isfile(script):
            messagebox.showerror("Log downloader not found", "Expected scripts/fetch-apex-dash-logs.sh next to this GUI.")
            return
        self.old_logs_busy = True
        self.old_logs_btn.configure(state="disabled")
        self.start_btn.configure(state="disabled")
        self.detect_btn.configure(state="disabled")
        self.extract_btn.configure(state="disabled")
        self.get_lists_btn.configure(state="disabled")
        self.download_assets_btn.configure(state="disabled")
        self._set_status("Downloading historical Apex Dash logs", AMBER)
        self._append("\n[old logs] Searching MGU for existing Apex Dash log files...\n")
        ssh_env = self._ssh_env()

        def run():
            try:
                self.old_logs_process = subprocess.Popen(
                    ["bash", script, host], cwd=ROOT, env=ssh_env,
                    stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT, text=True, bufsize=1,
                    universal_newlines=True)
                for line in self.old_logs_process.stdout:
                    self.events.put(("line", line))
                code = self.old_logs_process.wait()
                self.events.put(("old_logs_done", (code, None)))
            except Exception as exc:
                self.events.put(("old_logs_done", (1, str(exc))))

        self.old_logs_worker = threading.Thread(target=run, daemon=True)
        self.old_logs_worker.start()

    def _old_logs_finished(self, result):
        code, error = result
        self.old_logs_busy = False
        self.old_logs_process = None
        self.old_logs_btn.configure(state="normal")
        self.start_btn.configure(state="normal")
        self.detect_btn.configure(state="normal")
        self.extract_btn.configure(state="normal")
        self.get_lists_btn.configure(state="normal")
        self.download_assets_btn.configure(state="normal" if self.full_output_dir else "disabled")
        if error:
            self._append("[old logs] ERROR: %s\n" % error)
        if code == 0:
            self._set_status("Historical Apex Dash logs downloaded", GREEN)
            self._append("[old logs] Archive saved in mgu-diagnostics.\n")
        elif code == 4:
            self._set_status("No historical Apex Dash logs found", AMBER)
            self._append("[old logs] No matching log files were found in the searched MGU locations.\n")
        else:
            self._set_status("Historical log download failed", RED)
            self._append("[old logs] Downloader exited with code %s.\n" % code)

    def download_dcsm2_logs(self):
        if (self.busy or self.discovery_busy or self.sdk_busy or self.full_busy
                or self.download_busy or self.old_logs_busy or self.dcsm2_logs_busy):
            return
        host = self.host.get().strip()
        if not host or host == "root@":
            messagebox.showerror("SSH target required",
                                 "Find the MGU or enter root@MGU-IP / an SSH host alias.")
            return
        if any(ch.isspace() for ch in host):
            messagebox.showerror("Invalid SSH target", "Use one SSH destination, without spaces.")
            return
        script = os.path.join(HERE, "fetch-dcsm2-lab-logs.sh")
        if not os.path.isfile(script):
            messagebox.showerror("DCSM2 Lab downloader not found",
                                 "Expected scripts/fetch-dcsm2-lab-logs.sh next to this GUI.")
            return
        self.dcsm2_logs_busy = True
        self.dcsm2_logs_btn.configure(state="disabled")
        self.start_btn.configure(state="disabled")
        self.detect_btn.configure(state="disabled")
        self.extract_btn.configure(state="disabled")
        self.get_lists_btn.configure(state="disabled")
        self.download_assets_btn.configure(state="disabled")
        self.old_logs_btn.configure(state="disabled")
        self._set_status("Downloading saved DCSM2 Lab logs", AMBER)
        self._append("\n[DCSM2 Lab] Retrieving saved dcsm2_lab.log files only; no live capture...\n")
        ssh_env = self._ssh_env()

        def run():
            try:
                self.dcsm2_logs_process = subprocess.Popen(
                    ["bash", script, host], cwd=ROOT, env=ssh_env,
                    stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT, text=True, bufsize=1,
                    universal_newlines=True)
                for line in self.dcsm2_logs_process.stdout:
                    self.events.put(("line", line))
                code = self.dcsm2_logs_process.wait()
                self.events.put(("dcsm2_logs_done", (code, None)))
            except Exception as exc:
                self.events.put(("dcsm2_logs_done", (1, str(exc))))

        self.dcsm2_logs_worker = threading.Thread(target=run, daemon=True)
        self.dcsm2_logs_worker.start()

    def _dcsm2_logs_finished(self, result):
        code, error = result
        self.dcsm2_logs_busy = False
        self.dcsm2_logs_process = None
        self.dcsm2_logs_btn.configure(state="normal")
        self.start_btn.configure(state="normal")
        self.detect_btn.configure(state="normal")
        self.extract_btn.configure(state="normal")
        self.get_lists_btn.configure(state="normal")
        self.download_assets_btn.configure(state="normal" if self.full_output_dir else "disabled")
        self.old_logs_btn.configure(state="normal")
        if error:
            self._append("[DCSM2 Lab] ERROR: %s\n" % error)
        if code == 0:
            self._set_status("Saved DCSM2 Lab logs downloaded", GREEN)
            self._append("[DCSM2 Lab] Archive saved in mgu-diagnostics.\n")
        elif code == 4:
            self._set_status("No saved DCSM2 Lab logs found", AMBER)
            self._append("[DCSM2 Lab] No dcsm2_lab.log files were found.\n")
        else:
            self._set_status("DCSM2 Lab log download failed", RED)
            self._append("[DCSM2 Lab] Downloader exited with code %s.\n" % code)

    def _download_finished(self, result):
        code, error = result
        self.download_busy = False
        self.download_process = None
        self.start_btn.configure(state="normal")
        self.detect_btn.configure(state="normal")
        self.extract_btn.configure(state="normal")
        self.get_lists_btn.configure(state="normal")
        self.download_assets_btn.configure(state="normal" if self.full_output_dir else "disabled")
        if error:
            self._append("[assets] ERROR: %s\n" % error)
        if code == 0:
            self._set_status("Assets downloaded · see full extract folder", GREEN)
            self._append("[assets] Download complete.\n")
        else:
            self._set_status("Asset download failed · inspect the console", RED)
            self._append("[assets] Download exited with code %s.\n" % code)

    def open_full_output(self):
        os.makedirs(FULL_OUTDIR, exist_ok=True)
        try:
            subprocess.Popen(["open", FULL_OUTDIR])
        except Exception as exc:
            messagebox.showinfo("Full extraction folder", "%s\n\n%s" % (FULL_OUTDIR, exc))

    def open_output(self):
        os.makedirs(OUTDIR, exist_ok=True)
        try:
            subprocess.Popen(["open", OUTDIR])
        except Exception as exc:
            messagebox.showinfo("Output folder", "%s\n\n%s" % (OUTDIR, exc))

    def open_sdk_output(self):
        os.makedirs(SDK_OUTDIR, exist_ok=True)
        try:
            subprocess.Popen(["open", SDK_OUTDIR])
        except Exception as exc:
            messagebox.showinfo("SDK output folder", "%s\n\n%s" % (SDK_OUTDIR, exc))

    def _close(self):
        if self.busy or self.sdk_busy or self.full_busy or self.download_busy or self.old_logs_busy or self.dcsm2_logs_busy:
            if not messagebox.askyesno(
                "Capture is running",
                "Closing will terminate the active SSH operation. Temporary data may remain on the MGU. Close anyway?"):
                return
            if self.process and self.process.poll() is None:
                self.process.terminate()
            if self.sdk_process and self.sdk_process.poll() is None:
                self.sdk_process.terminate()
            if self.full_process and self.full_process.poll() is None:
                self.full_process.terminate()
            if self.download_process and self.download_process.poll() is None:
                self.download_process.terminate()
            if self.old_logs_process and self.old_logs_process.poll() is None:
                self.old_logs_process.terminate()
            if self.dcsm2_logs_process and self.dcsm2_logs_process.poll() is None:
                self.dcsm2_logs_process.terminate()
        self.root.destroy()


def main():
    root = tk.Tk()
    App(root)
    root.mainloop()


if __name__ == "__main__":
    main()
