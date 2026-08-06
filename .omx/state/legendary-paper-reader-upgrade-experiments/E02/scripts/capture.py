#!/usr/bin/env python3
"""Capture the revision-pinned Round-1 reader baseline without writes."""

from __future__ import annotations

import base64
import hashlib
import json
import os
import socket
import struct
import subprocess
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RAW = ROOT / "raw"
OUT = ROOT / "outputs"
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
BASE = "https://guerrilla.barkpark.cloud"
PAPERS = [
    ("CCH29", "cloud-console-hardening-wave-29-2026-08-03", "18768b0a14c2eead927181c4a0e37c18", "known_bad"),
    ("PDS45", "pds-wave-45-2026-08-03", "b992fd8aaa028b0dab30a8da76f077fd", "known_bad"),
    ("CCH28", "cloud-console-hardening-wave-28-2026-08-03", "49c1534d9fb76d0d9adc7b97f25ec471", "known_bad"),
    ("PDS44", "pds-wave-44-2026-08-03", "8bbd5d874a1b697f1e4e437c473f8e52", "known_good_by_dimension"),
]


def canonical(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode()


def sha(data):
    return hashlib.sha256(data).hexdigest()


def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": "barkpark-legendary-e02/1"})
    with urllib.request.urlopen(req, timeout=30) as response:
        return response.status, dict(response.headers), response.read()


def text_of(value):
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        return "".join(text_of(v) for v in value)
    if isinstance(value, dict):
        return value.get("text", "") + value.get("value", "") + text_of(value.get("content", [])) + text_of(value.get("children", [])) + text_of(value.get("items", []))
    return ""


def count_source(blocks):
    types = {}
    empty_paragraphs = 0
    table_headers = 0
    table_rows = 0
    callouts = 0
    marked_nodes = 0
    headings = []
    ids = []
    for block in blocks:
        kind = block.get("type", "missing")
        types[kind] = types.get(kind, 0) + 1
        ids.append(block.get("id"))
        if kind == "paragraph" and not text_of(block).strip():
            empty_paragraphs += 1
        if kind == "heading":
            headings.append(block.get("level"))
        if kind == "table":
            header = block.get("header", block.get("head", []))
            table_headers += len(header) if isinstance(header, list) else 0
            rows = block.get("rows", block.get("body", []))
            table_rows += len(rows) if isinstance(rows, list) else 0
        if kind == "callout":
            callouts += 1
        stack = [block]
        while stack:
            node = stack.pop()
            if isinstance(node, dict):
                marks = node.get("marks")
                if isinstance(marks, list) and marks:
                    marked_nodes += 1
                stack.extend(node.values())
            elif isinstance(node, list):
                stack.extend(node)
    return {
        "blocks": len(blocks), "types": types, "ids_unique_nonblank": len(ids) == len(set(ids)) and all(ids),
        "empty_paragraphs": empty_paragraphs, "table_headers": table_headers, "table_rows": table_rows,
        "callouts": callouts, "marked_nodes": marked_nodes, "heading_levels": headings,
    }


class CDP:
    def __init__(self, url):
        from urllib.parse import urlparse
        parsed = urlparse(url)
        self.sock = socket.create_connection((parsed.hostname, parsed.port or 80), timeout=10)
        key = base64.b64encode(os.urandom(16)).decode()
        target = parsed.path + (("?" + parsed.query) if parsed.query else "")
        request = (f"GET {target} HTTP/1.1\r\nHost: {parsed.hostname}:{parsed.port}\r\n"
                   f"Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n")
        self.sock.sendall(request.encode())
        response = b""
        while b"\r\n\r\n" not in response:
            response += self.sock.recv(4096)
        if b" 101 " not in response.split(b"\r\n", 1)[0]:
            raise RuntimeError(response[:200])
        self.next_id = 0

    def _send(self, payload):
        data = json.dumps(payload, separators=(",", ":")).encode()
        mask = os.urandom(4)
        header = bytearray([0x81])
        n = len(data)
        if n < 126:
            header.append(0x80 | n)
        elif n < 65536:
            header.append(0x80 | 126); header.extend(struct.pack("!H", n))
        else:
            header.append(0x80 | 127); header.extend(struct.pack("!Q", n))
        header.extend(mask)
        self.sock.sendall(bytes(header) + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))

    def _recv(self):
        first = self.sock.recv(2)
        if len(first) < 2:
            raise EOFError("websocket closed")
        opcode, n = first[0] & 0x0F, first[1] & 0x7F
        if n == 126:
            n = struct.unpack("!H", self.sock.recv(2))[0]
        elif n == 127:
            n = struct.unpack("!Q", self.sock.recv(8))[0]
        data = b""
        while len(data) < n:
            data += self.sock.recv(n - len(data))
        if opcode == 8:
            raise EOFError("websocket close frame")
        return json.loads(data)

    def call(self, method, params=None):
        self.next_id += 1
        request_id = self.next_id
        self._send({"id": request_id, "method": method, "params": params or {}})
        while True:
            message = self._recv()
            if message.get("id") == request_id:
                if "error" in message:
                    raise RuntimeError(message["error"])
                return message.get("result", {})


def browser_probe(url, width, slug):
    port_sock = socket.socket(); port_sock.bind(("127.0.0.1", 0)); port = port_sock.getsockname()[1]; port_sock.close()
    profile = ROOT / "tmp" / f"chrome-{width}-{slug}"
    profile.mkdir(parents=True, exist_ok=True)
    proc = subprocess.Popen([CHROME, "--headless=new", "--disable-gpu", "--no-first-run", "--no-default-browser-check",
                             f"--user-data-dir={profile}", f"--remote-debugging-port={port}", "about:blank"],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        listing = None
        for _ in range(100):
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{port}/json", timeout=1) as res:
                    listing = json.load(res)
                if listing:
                    break
            except Exception:
                time.sleep(0.05)
        if not listing:
            raise RuntimeError("Chrome DevTools endpoint unavailable")
        page = next(item for item in listing if item.get("type") == "page")
        cdp = CDP(page["webSocketDebuggerUrl"])
        cdp.call("Runtime.enable")
        cdp.call("Page.enable")
        cdp.call("Emulation.setDeviceMetricsOverride", {"width": width, "height": 900, "deviceScaleFactor": 1, "mobile": True})
        navigation_attempts = []
        href = ""
        navigation = {}
        for attempt in range(3):
            navigation = cdp.call("Page.navigate", {"url": url}) if attempt == 0 else cdp.call("Page.reload", {"ignoreCache": True})
            for _ in range(160):
                state = cdp.call("Runtime.evaluate", {"expression": "document.readyState", "returnByValue": True})["result"].get("value")
                href = cdp.call("Runtime.evaluate", {"expression": "location.href", "returnByValue": True})["result"].get("value")
                if state == "complete" and href == url: break
                time.sleep(0.05)
            title = cdp.call("Runtime.evaluate", {"expression": "document.title", "returnByValue": True})["result"].get("value")
            navigation_attempts.append({"attempt": attempt + 1, "title": title})
            if not str(title).startswith("500"):
                break
        if href != url:
            raise RuntimeError(f"navigation did not commit: {navigation!r}; current={href!r}")
        expression = r"""(() => {
          const q = s => Array.from(document.querySelectorAll(s));
          const rect = e => { const r=e.getBoundingClientRect(); return {left:r.left,right:r.right,width:r.width}; };
          const tabbables=q('a[href],button,input,select,textarea,[tabindex]').filter(e => !e.disabled && e.tabIndex >= 0);
          return {url:location.href,title:document.title,viewport:{innerWidth,clientWidth:document.documentElement.clientWidth},
            document:{scrollWidth:document.documentElement.scrollWidth,scrollHeight:document.documentElement.scrollHeight},
            landmarks:{main:q('main').length,article:q('article').length,h1:q('h1').length,lang:document.documentElement.lang},
            blockIds:q('[data-block-id]').map(e=>e.getAttribute('data-block-id')),
            tables:q('table').map(t=>({role:t.getAttribute('role'),caption:t.querySelectorAll('caption').length,
              headers:t.querySelectorAll('th').length,scopedHeaders:t.querySelectorAll('th[scope]').length,rect:rect(t),parentOverflow:getComputedStyle(t.parentElement).overflowX})),
            callouts:q('.bp-callout,[data-callout],aside').map(e=>({role:e.getAttribute('role'),label:e.getAttribute('aria-label'),tag:e.tagName})),
            semanticMarks:{strong:q('strong,b').length,code:q('code').length,em:q('em').length},
            tabbableCount:tabbables.length,active:{tag:document.activeElement.tagName,id:document.activeElement.id},
            bodyDataRev:document.querySelector('article')?.getAttribute('data-rev') || document.querySelector('[data-paper-rev]')?.getAttribute('data-paper-rev') || null,
            horizontalOverflow:document.documentElement.scrollWidth > document.documentElement.clientWidth};
        })()"""
        value = cdp.call("Runtime.evaluate", {"expression": expression, "returnByValue": True})["result"]["value"]
        focus_order = []
        for _ in range(min(value["tabbableCount"], 12)):
            cdp.call("Input.dispatchKeyEvent", {"type": "keyDown", "key": "Tab", "code": "Tab", "windowsVirtualKeyCode": 9})
            cdp.call("Input.dispatchKeyEvent", {"type": "keyUp", "key": "Tab", "code": "Tab", "windowsVirtualKeyCode": 9})
            active = cdp.call("Runtime.evaluate", {"expression": "({tag:document.activeElement.tagName,id:document.activeElement.id,text:(document.activeElement.innerText||document.activeElement.getAttribute('aria-label')||'').slice(0,80),focusVisible:document.activeElement.matches(':focus-visible'),outline:getComputedStyle(document.activeElement).outlineStyle})", "returnByValue": True})["result"]["value"]
            focus_order.append(active)
        ax = cdp.call("Accessibility.getFullAXTree")
        roles = {}
        for node in ax.get("nodes", []):
            role = (node.get("role") or {}).get("value")
            if role: roles[role] = roles.get(role, 0) + 1
        value["keyboard_focus_order"] = focus_order
        value["ax_roles"] = roles
        value["navigation_attempts"] = navigation_attempts
        return value
    finally:
        proc.terminate()
        try: proc.wait(timeout=5)
        except subprocess.TimeoutExpired: proc.kill()


def main():
    started = time.perf_counter()
    RAW.mkdir(parents=True, exist_ok=True); OUT.mkdir(parents=True, exist_ok=True)
    manifest = {"schema_version": "legendary-reader-baseline-captures/v1", "base_url": BASE, "papers": [], "captured_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    scores = []
    for short, slug, expected_rev, control in PAPERS:
        paper_dir = RAW / short
        paper_dir.mkdir(parents=True, exist_ok=True)
        record = {"short_id": short, "slug": slug, "expected_rev": expected_rev, "control": control, "captures": {}}
        for surface, suffix in (("source", "/source"), ("public", ""), ("email", "/email")):
            status, headers, body = fetch(f"{BASE}/papers/{slug}{suffix}")
            ext = "json" if surface == "source" else "html"
            path = paper_dir / f"{surface}.{ext}"
            path.write_bytes(body)
            record["captures"][surface] = {"path": str(path.relative_to(ROOT)), "status": status, "content_type": headers.get("Content-Type"), "bytes": len(body), "sha256": sha(body)}
        cli = subprocess.run(["bp", "-s", "guerrilla", "paper", "view", slug, "-o", "json"], capture_output=True, check=True)
        cli_path = paper_dir / "cli.json"; cli_path.write_bytes(cli.stdout)
        record["captures"]["cli"] = {"path": str(cli_path.relative_to(ROOT)), "bytes": len(cli.stdout), "sha256": sha(cli.stdout)}
        source = json.loads((paper_dir / "source.json").read_bytes())
        cli_doc = json.loads(cli.stdout)
        blocks = source["source"]["blocks"]
        record["observed_rev"] = source.get("_rev")
        record["source_metrics"] = count_source(blocks)
        record["canonical_block_sha256"] = sha(canonical(blocks))
        record["cli_canonical_block_sha256"] = sha(canonical(cli_doc.get("blocks", cli_doc.get("body", {}).get("blocks", []))))
        record["pin_match"] = record["observed_rev"] == expected_rev and cli_doc.get("_rev") == expected_rev
        record["projection_match"] = record["canonical_block_sha256"] == record["cli_canonical_block_sha256"]
        record["browser"] = {}
        for surface in ("public", "email"):
            record["browser"][surface] = {}
            for width in (320, 390):
                record["browser"][surface][str(width)] = browser_probe(f"{BASE}/papers/{slug}{'' if surface == 'public' else '/email'}", width, f"{short}-{surface}")
        manifest["papers"].append(record)
        scores.append({"paper": short, "pin": record["pin_match"], "projection": record["projection_match"], "source": record["source_metrics"], "browser": record["browser"]})
    (OUT / "capture-manifest.json").write_bytes(canonical(manifest) + b"\n")
    (OUT / "baseline-observations.json").write_bytes(canonical({"papers": scores}) + b"\n")
    elapsed = time.perf_counter() - started
    (OUT / "timing.json").write_bytes(canonical({"capture_seconds": round(elapsed, 6), "papers": 4, "browser_cells": 16}) + b"\n")


if __name__ == "__main__":
    main()
