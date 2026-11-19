#!/usr/bin/env python3
"""Read the MGU IPv4 configuration through the BMW ENET gateway (HSFZ/UDS).

Discovery (UDP/6811) yields the gateway address. This module then connects to
that gateway on TCP/6801, sends UDS ReadDataByIdentifier 0x172A to ECU 0x63,
and parses the three IPv4 addresses returned by the MGU.
"""
import select
import socket
import struct
import time

ENET_PORT = 6801
TESTER = 0xF4
MGU_ECU = 0x63
TYPE_DIAG = 0x0001
REQUEST_IP = bytes.fromhex("22 17 2A")
POSITIVE_PREFIX = bytes.fromhex("62 17 2A 00")
MAX_FRAME = 1024 * 1024


class MguDiagnosticError(Exception):
    """The gateway connection or MGU IP read failed."""


def parse_mgu_ip(payload):
    """Return (mgu_ip, gateway_ip, route_ip) from a 0x172A UDS response."""
    idx = payload.find(POSITIVE_PREFIX)
    if idx < 0:
        raise MguDiagnosticError("UDS response does not contain 62 17 2A 00")
    body = payload[idx + len(POSITIVE_PREFIX):]
    if len(body) < 12:
        raise MguDiagnosticError("UDS 0x172A response is shorter than 12 address bytes")
    addresses = tuple(socket.inet_ntoa(body[i:i + 4]) for i in (0, 4, 8))
    if addresses[0] == "0.0.0.0":
        raise MguDiagnosticError("MGU returned an unspecified head-unit address")
    return addresses


def _read_exact(sock, size, deadline):
    chunks = bytearray()
    while len(chunks) < size:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise MguDiagnosticError("Timed out waiting for the ENET diagnostic response")
        readable, _, _ = select.select([sock], [], [], remaining)
        if not readable:
            raise MguDiagnosticError("Timed out waiting for the ENET diagnostic response")
        chunk = sock.recv(size - len(chunks))
        if not chunk:
            raise MguDiagnosticError("ENET gateway closed the diagnostic connection")
        chunks.extend(chunk)
    return bytes(chunks)


def read_mgu_ip(gateway_ip, port=ENET_PORT, timeout=3.0, log=None):
    """Read MGU IP through a discovered gateway; this is read-only UDS."""
    log = log or (lambda message: None)
    try:
        with socket.create_connection((gateway_ip, port), timeout=timeout) as sock:
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            # HSFZ: 4-byte body length, 2-byte frame type, tester, ECU, UDS.
            body = bytes((TESTER, MGU_ECU)) + REQUEST_IP
            sock.sendall(struct.pack(">IH", len(body), TYPE_DIAG) + body)
            log("HSFZ TCP %s:%d connected; sent UDS 22 17 2A to ECU 0x63" %
                (gateway_ip, port))

            deadline = time.monotonic() + timeout
            while True:
                header = _read_exact(sock, 6, deadline)
                length, frame_type = struct.unpack(">IH", header)
                if length < 2 or length > MAX_FRAME:
                    raise MguDiagnosticError("Gateway returned an invalid HSFZ frame length")
                frame = _read_exact(sock, length, deadline)
                if frame_type != TYPE_DIAG or len(frame) < 2:
                    continue
                src, dst, payload = frame[0], frame[1], frame[2:]
                if src != MGU_ECU or dst != TESTER or not payload:
                    continue
                if payload[0] == 0x7F:
                    nrc = payload[2] if len(payload) > 2 else 0
                    raise MguDiagnosticError("MGU rejected UDS 0x22 (NRC 0x%02X)" % nrc)
                if payload.startswith(bytes.fromhex("62 17 2A")):
                    result = parse_mgu_ip(payload)
                    log("UDS 0x172A returned MGU=%s, gateway=%s, route=%s" % result)
                    return result
    except (OSError, TimeoutError) as exc:
        raise MguDiagnosticError("Cannot read MGU IP through gateway %s:%d: %s" %
                                 (gateway_ip, port, exc)) from exc
