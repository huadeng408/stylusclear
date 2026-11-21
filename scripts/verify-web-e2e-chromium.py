#!/usr/bin/env python3
"""Headless Chromium CDP 3-Viewport E2E DOM Assertions + Authentic Screenshot & Chart Rasterizer."""
from __future__ import annotations

import argparse
import base64
import functools
import http.server
import json
import os
import shutil
import socket
import struct
import subprocess
import tempfile
import threading
import time
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WEB_DIR = ROOT / "web"
ASSETS_DIR = ROOT / "docs" / "assets"


def find_chromium() -> str | None:
    for cand in ("chromium", "chromium-browser", "google-chrome"):
        p = shutil.which(cand)
        if p:
            return p
    return None


class _QuietHandler(http.server.SimpleHTTPRequestHandler):
    extensions_map = {
        **http.server.SimpleHTTPRequestHandler.extensions_map,
        ".mjs": "application/javascript",
        ".js": "application/javascript",
        ".svg": "image/svg+xml",
    }
    def log_message(self, format: str, *args: object) -> None:  # noqa: A002
        return


def _start_server(directory: Path) -> tuple[http.server.ThreadingHTTPServer, int, str]:
    handler = functools.partial(_QuietHandler, directory=str(directory))
    http.server.ThreadingHTTPServer.allow_reuse_address = True
    bind_host = "127.0.0.2"
    try:
        httpd = http.server.ThreadingHTTPServer((bind_host, 0), handler)
    except OSError:
        bind_host = "127.0.0.1"
        httpd = http.server.ThreadingHTTPServer((bind_host, 0), handler)
    port = httpd.server_address[1]
    t = threading.Thread(target=httpd.serve_forever, daemon=True)
    t.start()
    return httpd, port, bind_host


class _CdpClient:
    def __init__(self, ws_url: str) -> None:
        u = urllib.parse.urlparse(ws_url)
        self.sock = socket.create_connection((u.hostname, u.port), timeout=15)
        key = base64.b64encode(os.urandom(16)).decode()
        req = (
            f"GET {u.path} HTTP/1.1\r\n"
            f"Host: {u.hostname}:{u.port}\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n\r\n"
        )
        self.sock.sendall(req.encode())
        buf = b""
        while b"\r\n\r\n" not in buf:
            buf += self.sock.recv(4096)
        self._id = 0
        self.exceptions: list[str] = []

    def _send_raw(self, obj: dict) -> None:
        data = json.dumps(obj).encode()
        mask = os.urandom(4)
        hdr = bytearray([0x81])
        n = len(data)
        if n < 126:
            hdr.append(0x80 | n)
        elif n < 65536:
            hdr.append(0x80 | 126)
            hdr.extend(struct.pack("!H", n))
        else:
            hdr.append(0x80 | 127)
            hdr.extend(struct.pack("!Q", n))
        hdr.extend(mask)
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
        self.sock.sendall(bytes(hdr) + masked)

    def _recv_exact(self, k: int) -> bytes:
        out = b""
        while len(out) < k:
            chunk = self.sock.recv(k - len(out))
            if not chunk:
                raise EOFError("CDP WebSocket closed")
            out += chunk
        return out

    def _recv_frame(self) -> dict:
        while True:
            b1, b2 = self._recv_exact(2)
            opcode = b1 & 0x0F
            n = b2 & 0x7F
            if n == 126:
                n = struct.unpack("!H", self._recv_exact(2))[0]
            elif n == 127:
                n = struct.unpack("!Q", self._recv_exact(8))[0]
            if b2 & 0x80:
                mask = self._recv_exact(4)
                raw = bytes(b ^ mask[i % 4] for i, b in enumerate(self._recv_exact(n)))
            else:
                raw = self._recv_exact(n)
            if opcode == 0x09:  # ping -> pong
                continue
            if opcode == 0x01:
                return json.loads(raw.decode())

    def call(self, method: str, params: dict | None = None) -> dict:
        self._id += 1
        cid = self._id
        payload: dict = {"id": cid, "method": method}
        if params:
            payload["params"] = params
        self._send_raw(payload)
        while True:
            msg = self._recv_frame()
            if msg.get("method") == "Runtime.exceptionThrown":
                self.exceptions.append(str(msg.get("params")))
            elif msg.get("method") == "Runtime.consoleAPICalled":
                if msg.get("params", {}).get("type") == "error":
                    self.exceptions.append(f"console.error: {msg.get('params')}")
            elif msg.get("id") == cid:
                if "error" in msg:
                    raise RuntimeError(f"CDP {method} failed: {msg['error']}")
                return msg.get("result", {})

    def close(self) -> None:
        self.sock.close()


def _launch_cdp(chromium: str, tmp_prof: str) -> tuple[subprocess.Popen, _CdpClient]:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    dbg_port = s.getsockname()[1]
    s.close()

    proc = subprocess.Popen(
        [
            chromium,
            "--headless",
            "--no-sandbox",
            "--disable-gpu",
            "--disable-dev-shm-usage",
            "--disable-extensions",
            "--disable-background-networking",
            f"--user-data-dir={tmp_prof}",
            f"--remote-debugging-port={dbg_port}",
            "about:blank",
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    ws_url = None
    for _ in range(50):
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{dbg_port}/json/list", timeout=1) as resp:
                pages = json.loads(resp.read().decode("utf-8"))
                for p in pages:
                    if p.get("type") == "page" and p.get("webSocketDebuggerUrl"):
                        ws_url = p["webSocketDebuggerUrl"]
                        break
                if ws_url:
                    break
        except Exception:
            time.sleep(0.12)
    if not ws_url:
        proc.kill()
        raise RuntimeError("Chromium CDP endpoint did not start")
    cdp = _CdpClient(ws_url)
    cdp.call("Page.enable")
    cdp.call("Runtime.enable")
    return proc, cdp


def _check_viewport(
    cdp: _CdpClient,
    url: str,
    width: int,
    height: int,
    label: str,
    screenshot_out: Path | None = None,
    dpr: float = 1.0,
) -> None:
    cdp.exceptions.clear()
    cdp.call(
        "Emulation.setDeviceMetricsOverride",
        {"width": width, "height": height, "deviceScaleFactor": dpr, "mobile": width < 600},
    )
    cdp.call("Page.navigate", {"url": url})

    # Wait until portfolioBody & benchBody are populated
    metrics = None
    expr = (
        "JSON.stringify({"
        "ready: document.readyState,"
        "title: document.title,"
        "h1: document.querySelector('h1')?.textContent || '',"
        "wasm: document.getElementById('kpiWasm')?.textContent || '',"
        "sw: document.documentElement.scrollWidth,"
        "iw: window.innerWidth,"
        "rows: document.querySelectorAll('#portfolioBody tr').length,"
        "benchRows: document.querySelectorAll('#benchBody tr').length,"
        "alphaUsdc: document.querySelector('#portfolioBody tr:first-child td:nth-child(2)')?.textContent || '',"
        "stressEvm: document.querySelector('#benchBody tr:last-child td:nth-child(4)')?.textContent || '',"
        "guardVisible: document.getElementById('guardBanner')?.classList.contains('visible') || false,"
        "badge: document.getElementById('statusBadge')?.textContent || ''"
        "})"
    )
    for _ in range(40):
        time.sleep(0.1)
        res = cdp.call("Runtime.evaluate", {"expression": expr, "returnByValue": True})
        val = res.get("result", {}).get("value")
        if val:
            m = json.loads(val)
            if m["rows"] == 4 and m["benchRows"] == 4:
                metrics = m
                break
    assert metrics is not None, f"[{label}] Timed out waiting for workbench DOM to render (last={val!r}, exc={cdp.exceptions})"
    assert not cdp.exceptions, f"[{label}] Browser console/runtime errors: {cdp.exceptions}"
    assert "1.2.0" in metrics["h1"], f"[{label}] Unexpected H1: {metrics['h1']}"
    assert "24,518 B" in metrics["wasm"], f"[{label}] Unexpected WASM KPI: {metrics['wasm']}"
    assert metrics["stressEvm"] == "16,645,399", f"[{label}] Unexpected Stress EVM gas: {metrics['stressEvm']}"
    assert metrics["sw"] <= metrics["iw"] + 2, f"[{label}] Horizontal overflow: scrollWidth={metrics['sw']} > innerWidth={metrics['iw']}"

    if "oracleBandGuard" in url:
        assert metrics["guardVisible"] is True, f"[{label}] Guard banner not visible"
        assert metrics["alphaUsdc"] == "25,000.00", f"[{label}] Rollback Alpha USDC should be 25,000.00, got {metrics['alphaUsdc']}"
    elif "institutionalMesh" in url:
        assert metrics["guardVisible"] is False, f"[{label}] Guard banner should be hidden"
        assert metrics["alphaUsdc"] == "20,350.00", f"[{label}] Settled Alpha USDC should be 20,350.00, got {metrics['alphaUsdc']}"

    if screenshot_out is not None:
        screenshot_out.parent.mkdir(parents=True, exist_ok=True)
        shot = cdp.call("Page.captureScreenshot", {"format": "png"})
        raw_png = base64.b64decode(shot["data"])
        screenshot_out.write_bytes(raw_png)
        assert len(raw_png) > 15_000, f"[{label}] Screenshot unexpectedly small ({len(raw_png)} B)"

    print(
        f"[chromium-e2e] {label} ({width}x{height}): OK scrollWidth={metrics['sw']}<={metrics['iw']} "
        f"alphaUsdc={metrics['alphaUsdc']} rows={metrics['rows']} badge='{metrics['badge']}'"
    )


def _rasterize_svg_chart(cdp: _CdpClient, tmp_dir: Path) -> None:
    svg_path = ASSETS_DIR / "gas-comparison-chart.svg"
    png_path = ASSETS_DIR / "gas-comparison-chart.png"
    if not svg_path.exists():
        return
    html_p = tmp_dir / "chart.html"
    html_p.write_text(
        "<!doctype html><html><body style='margin:0;background:#0b1120;overflow:hidden;'>"
        + svg_path.read_text(encoding="utf-8")
        + "</body></html>",
        encoding="utf-8",
    )
    cdp.call(
        "Emulation.setDeviceMetricsOverride",
        {"width": 1120, "height": 560, "deviceScaleFactor": 2, "mobile": False},
    )
    cdp.call("Page.navigate", {"url": html_p.as_uri()})
    time.sleep(0.35)
    shot = cdp.call("Page.captureScreenshot", {"format": "png"})
    raw_png = base64.b64decode(shot["data"])
    png_path.write_bytes(raw_png)
    assert len(raw_png) > 20_000
    print(f"[chromium-e2e] Rasterized 2x Retina chart: {png_path.relative_to(ROOT)} ({len(raw_png):,} B)")


def _refresh_sha256sums() -> None:
    import hashlib

    sums_path = ROOT / "SHA256SUMS.txt"
    if not sums_path.exists():
        return
    updated: list[str] = []
    for raw_line in sums_path.read_text(encoding="utf-8").splitlines():
        s = raw_line.strip()
        if not s:
            continue
        parts = s.split(None, 1)
        if len(parts) != 2:
            updated.append(s)
            continue
        rel_p = parts[1].lstrip("*")
        target_f = ROOT / rel_p
        digest = hashlib.sha256(target_f.read_bytes()).hexdigest() if target_f.exists() else parts[0].lower()
        updated.append(f"{digest}  {rel_p}")
    sums_path.write_text("\n".join(updated) + "\n", encoding="utf-8", newline="\n")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--capture-assets", action="store_true", help="Also regenerate docs/assets/*.png screenshots & chart")
    ap.add_argument("--rasterize-chart-only", action="store_true", help="Re-rasterize docs/assets/gas-comparison-chart.png from SVG")
    args = ap.parse_args()

    chromium = find_chromium()
    if not chromium:
        if os.environ.get("REQUIRE_CHROMIUM", "0") == "1":
            raise SystemExit("Chromium not found but REQUIRE_CHROMIUM=1")
        print("[chromium-e2e] Chromium not installed; skipping headless E2E")
        return 0

    if args.rasterize_chart_only:
        with tempfile.TemporaryDirectory(prefix="sc_cdp_") as tmp_dir:
            proc, cdp = _launch_cdp(chromium, tmp_dir)
            try:
                _rasterize_svg_chart(cdp, Path(tmp_dir))
            finally:
                cdp.close()
                proc.terminate()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()
        _refresh_sha256sums()
        return 0

    httpd, port, bind_host = _start_server(WEB_DIR)
    with tempfile.TemporaryDirectory(prefix="sc_cdp_") as tmp_dir:
        proc, cdp = _launch_cdp(chromium, tmp_dir)
        try:
            base = f"http://{bind_host}:{port}/index.html"
            _check_viewport(
                cdp,
                f"{base}?scenario=institutionalMesh&desks=4",
                1440,
                980,
                "desktop-scenario1",
                ASSETS_DIR / "workbench-institutional-mesh.png" if args.capture_assets else None,
            )
            _check_viewport(
                cdp,
                f"{base}?scenario=oracleBandGuard&desks=4",
                1440,
                980,
                "desktop-scenario2",
                ASSETS_DIR / "workbench-fail-closed-guard.png" if args.capture_assets else None,
            )
            _check_viewport(cdp, f"{base}?scenario=marginShortfallGuard&desks=4", 768, 1024, "tablet-scenario3")
            _check_viewport(cdp, f"{base}?scenario=robinhoodUsdgMesh&desks=4", 390, 844, "mobile-scenario4")
            if args.capture_assets:
                _rasterize_svg_chart(cdp, Path(tmp_dir))
        finally:
            cdp.close()
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
            httpd.shutdown()
            httpd.server_close()

    if args.capture_assets:
        _refresh_sha256sums()
    print("[chromium-e2e] ALL 3 VIEWPORTS & 4 SCENARIOS PASSED")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
