#!/usr/bin/env python3
"""Slabshot master server list.

Tiny stdlib-only HTTP service. Game servers POST a heartbeat every ~10s;
clients GET the list. Entries expire after TTL seconds without a heartbeat.

  POST /heartbeat  {"name","port","mode","map","players","max","version"[, "host"]}
  GET  /servers    {"servers": [{"host","port","name","mode","map","players","max","version"}]}
  GET  /health     "ok"

Environment:
  MASTER_PORT      listen port (default 27580)
  MASTER_KEY       if set, heartbeats with header X-Master-Key == key are
                   "trusted": they may advertise a custom "host" and are not
                   subject to the per-IP server limit. Without a key, servers
                   are listed by the IP they connect from.
  MASTER_TTL       seconds before a silent server is dropped (default 30)
  TRUST_PROXY      "1" to take the client IP from X-Forwarded-For (only when
                   behind a reverse proxy you control)
  MAX_PER_IP       max listed servers per source IP (default 8)
"""

import ipaddress
import json
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("MASTER_PORT", "27580"))
KEY = os.environ.get("MASTER_KEY", "")
TTL = float(os.environ.get("MASTER_TTL", "30"))
TRUST_PROXY = os.environ.get("TRUST_PROXY", "") == "1"
MAX_PER_IP = int(os.environ.get("MAX_PER_IP", "8"))
MIN_INTERVAL = 2.0  # seconds between heartbeats from one ip:port
MAX_BODY = 2048

_lock = threading.Lock()
_servers: dict[tuple[str, int], dict] = {}


def _clean_str(v, limit: int) -> str:
    s = str(v if v is not None else "")
    s = "".join(ch for ch in s if ch.isprintable())
    return s[:limit]


def _clamp_int(v, lo: int, hi: int, default: int) -> int:
    try:
        return max(lo, min(hi, int(v)))
    except (TypeError, ValueError):
        return default


def _prune(now: float) -> None:
    dead = [k for k, s in _servers.items() if now - s["seen"] > TTL]
    for k in dead:
        del _servers[k]


class Handler(BaseHTTPRequestHandler):
    server_version = "slabshot-master/1"

    def log_message(self, fmt, *args):  # quieter logs
        pass

    def _client_ip(self) -> str:
        if TRUST_PROXY:
            fwd = self.headers.get("X-Forwarded-For", "")
            if fwd:
                return fwd.split(",")[0].strip()
        return self.client_address[0]

    def _send(self, code: int, body, ctype="application/json") -> None:
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/health":
            return self._send(200, b"ok", "text/plain")
        if self.path.rstrip("/") == "/servers":
            now = time.time()
            with _lock:
                _prune(now)
                out = [
                    {k: s[k] for k in ("host", "port", "name", "mode", "map", "players", "max", "version")}
                    for s in _servers.values()
                ]
            out.sort(key=lambda s: -s["players"])
            return self._send(200, {"servers": out})
        self._send(404, {"error": "not found"})

    def do_POST(self):
        if self.path.rstrip("/") != "/heartbeat":
            return self._send(404, {"error": "not found"})
        length = _clamp_int(self.headers.get("Content-Length"), 0, MAX_BODY + 1, 0)
        if length == 0 or length > MAX_BODY:
            return self._send(413, {"error": "bad length"})
        try:
            body = json.loads(self.rfile.read(length))
            if not isinstance(body, dict):
                raise ValueError
        except (ValueError, UnicodeDecodeError):
            return self._send(400, {"error": "bad json"})

        ip = self._client_ip()
        trusted = bool(KEY) and self.headers.get("X-Master-Key", "") == KEY
        port = _clamp_int(body.get("port"), 1, 65535, 0)
        if port == 0:
            return self._send(400, {"error": "bad port"})

        host = ip
        if trusted and body.get("host"):
            host = _clean_str(body.get("host"), 253)
        else:
            try:
                addr = ipaddress.ip_address(ip)
                if addr.is_unspecified or addr.is_multicast:
                    return self._send(400, {"error": "bad source"})
            except ValueError:
                return self._send(400, {"error": "bad source"})

        now = time.time()
        key = (host, port)
        with _lock:
            _prune(now)
            prev = _servers.get(key)
            if prev and now - prev["seen"] < MIN_INTERVAL:
                return self._send(429, {"error": "too fast"})
            if not prev and not trusted:
                count = sum(1 for s in _servers.values() if s["src"] == ip)
                if count >= MAX_PER_IP:
                    return self._send(429, {"error": "too many servers from this ip"})
            _servers[key] = {
                "host": host,
                "port": port,
                "name": _clean_str(body.get("name"), 32) or "Slabshot server",
                "mode": _clean_str(body.get("mode"), 24),
                "map": _clean_str(body.get("map"), 24),
                "players": _clamp_int(body.get("players"), 0, 64, 0),
                "max": _clamp_int(body.get("max"), 1, 64, 64),
                "version": _clamp_int(body.get("version"), 0, 65535, 0),
                "src": ip,
                "seen": now,
            }
        self._send(200, {"ok": True})


def main() -> None:
    srv = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    srv.daemon_threads = True
    print(f"slabshot master listening on :{PORT} (ttl {TTL}s, key {'set' if KEY else 'off'})", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
