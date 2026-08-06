#!/usr/bin/env python3
"""Capture real anonymous public/Studio/email browser evidence without writes."""

from __future__ import annotations

import base64
import hashlib
import json
import os
import socket
import struct
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RAW = ROOT / "raw"
OUT = ROOT / "outputs"
SCREEN = RAW / "screenshots"
BASE = "https://guerrilla.barkpark.cloud"
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
EXPECTED_MANIFEST = "docs/cli/fixtures/full-manifest.json"
PAPERS = [
    ("CCH29", "cloud-console-hardening-wave-29-2026-08-03", "18768b0a14c2eead927181c4a0e37c18", 252),
    ("PDS45", "pds-wave-45-2026-08-03", "b992fd8aaa028b0dab30a8da76f077fd", 227),
    ("CCH28", "cloud-console-hardening-wave-28-2026-08-03", "49c1534d9fb76d0d9adc7b97f25ec471", 237),
    ("PDS44", "pds-wave-44-2026-08-03", "8bbd5d874a1b697f1e4e437c473f8e52", 99),
]
PROFILES = {
    "desktop": {"width": 1440, "height": 900, "device_scale_factor": 1, "mobile": False},
    "390": {"width": 390, "height": 844, "device_scale_factor": 1, "mobile": True},
    "320": {"width": 320, "height": 720, "device_scale_factor": 1, "mobile": True},
    "reflow200": {"width": 640, "height": 900, "device_scale_factor": 2, "mobile": False},
}


def canonical(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode()


def sha(data):
    return hashlib.sha256(data).hexdigest()


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(canonical(value) + b"\n")


def fetch(url):
    request = urllib.request.Request(url, headers={"User-Agent": "barkpark-restart-e02/1"})
    try:
        response = urllib.request.urlopen(request, timeout=45)
    except urllib.error.HTTPError as exc:
        response = exc
    body = response.read()
    safe = {}
    for name in ("Content-Type", "Content-Length", "Cache-Control", "ETag", "Last-Modified", "Vary", "X-Request-ID", "Location"):
        if response.headers.get(name):
            safe[name.lower()] = response.headers.get(name)
    return response.status, safe, body, response.geturl()


class CDP:
    def __init__(self, url):
        from urllib.parse import urlparse
        parsed = urlparse(url)
        self.sock = socket.create_connection((parsed.hostname, parsed.port or 80), timeout=15)
        key = base64.b64encode(os.urandom(16)).decode()
        target = parsed.path + (("?" + parsed.query) if parsed.query else "")
        request = (
            f"GET {target} HTTP/1.1\r\nHost: {parsed.hostname}:{parsed.port}\r\n"
            f"Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n\r\n"
        )
        self.sock.sendall(request.encode())
        response = b""
        while b"\r\n\r\n" not in response:
            response += self.sock.recv(4096)
        if b" 101 " not in response.split(b"\r\n", 1)[0]:
            raise RuntimeError("CDP websocket upgrade failed")
        self.next_id = 0

    def send(self, payload):
        data = json.dumps(payload, separators=(",", ":")).encode()
        mask = os.urandom(4)
        header = bytearray([0x81])
        length = len(data)
        if length < 126:
            header.append(0x80 | length)
        elif length < 65536:
            header.append(0x80 | 126)
            header.extend(struct.pack("!H", length))
        else:
            header.append(0x80 | 127)
            header.extend(struct.pack("!Q", length))
        header.extend(mask)
        self.sock.sendall(bytes(header) + bytes(byte ^ mask[i % 4] for i, byte in enumerate(data)))

    def receive(self):
        first = self.sock.recv(2)
        if len(first) < 2:
            raise EOFError("CDP websocket closed")
        opcode, length = first[0] & 0x0F, first[1] & 0x7F
        if length == 126:
            length = struct.unpack("!H", self.sock.recv(2))[0]
        elif length == 127:
            length = struct.unpack("!Q", self.sock.recv(8))[0]
        data = b""
        while len(data) < length:
            data += self.sock.recv(length - len(data))
        if opcode == 8:
            raise EOFError("CDP close frame")
        return json.loads(data)

    def call(self, method, params=None):
        self.next_id += 1
        request_id = self.next_id
        self.send({"id": request_id, "method": method, "params": params or {}})
        while True:
            message = self.receive()
            if message.get("id") == request_id:
                if "error" in message:
                    raise RuntimeError(message["error"])
                return message.get("result", {})


JS_PROBE = r"""(() => {
  const q = s => Array.from(document.querySelectorAll(s));
  const visible = e => { const r=e.getBoundingClientRect(), s=getComputedStyle(e); return s.visibility !== 'hidden' && s.display !== 'none' && r.width > 0 && r.height > 0; };
  const box = e => { const r=e.getBoundingClientRect(); return {left:r.left,top:r.top,right:r.right,bottom:r.bottom,width:r.width,height:r.height}; };
  const controls=q('a[href],button,input,select,textarea,[tabindex]').filter(e => visible(e) && !e.disabled && e.tabIndex >= 0);
  const controlBoxes=controls.map((e,i)=>({i,tag:e.tagName,id:e.id||null,label:(e.innerText||e.getAttribute('aria-label')||'').trim().slice(0,100),tabIndex:e.tabIndex,box:box(e)}));
  const overlaps=[];
  for(let i=0;i<controlBoxes.length;i++) for(let j=i+1;j<controlBoxes.length;j++) {
    const a=controlBoxes[i].box,b=controlBoxes[j].box;
    const w=Math.min(a.right,b.right)-Math.max(a.left,b.left),h=Math.min(a.bottom,b.bottom)-Math.max(a.top,b.top);
    if(w>4 && h>4) overlaps.push({a:i,b:j,width:w,height:h});
  }
  return {
    url:location.href,title:document.title,readyState:document.readyState,
    viewport:{innerWidth,clientWidth:document.documentElement.clientWidth,visualWidth:window.visualViewport?.width||innerWidth,devicePixelRatio},
    document:{scrollWidth:document.documentElement.scrollWidth,scrollHeight:document.documentElement.scrollHeight},
    horizontalOverflow:document.documentElement.scrollWidth > document.documentElement.clientWidth + 1,
    landmarks:{main:q('main').length,article:q('article').length,h1:q('h1').length,lang:document.documentElement.lang},
    blockIds:q('[data-block-id]').map(e=>e.getAttribute('data-block-id')),
    headings:q('h1,h2,h3,h4,h5,h6').map(e=>({level:Number(e.tagName.slice(1)),text:(e.innerText||'').trim().slice(0,160)})),
    tables:q('table').map(t=>({role:t.getAttribute('role'),caption:t.querySelectorAll('caption').length,headers:t.querySelectorAll('th').length,scopedHeaders:t.querySelectorAll('th[scope]').length,box:box(t),parentOverflow:getComputedStyle(t.parentElement).overflowX})),
    callouts:q('.bp-callout,[data-callout],aside').map(e=>({role:e.getAttribute('role'),label:e.getAttribute('aria-label'),tag:e.tagName})),
    semanticMarks:{strong:q('strong,b').length,code:q('code').length,em:q('em').length},
    controlCount:controls.length,controlBoxes,controlOverlaps:overlaps,
    positiveTabindex:q('[tabindex]').filter(e=>Number(e.getAttribute('tabindex'))>0).length,
    bodyText:(document.body?.innerText||'').replace(/\s+/g,' ').trim(),
    paperRev:document.querySelector('article')?.getAttribute('data-rev') || document.querySelector('[data-paper-rev]')?.getAttribute('data-paper-rev') || null,
    authGate:/\/login(?:\?|$)/.test(location.pathname+location.search),
    liveSocket:q('[data-phx-session]').length
  };
})()"""


def browser_probe(url, profile_name, surface, short):
    profile = PROFILES[profile_name]
    port_socket = socket.socket()
    port_socket.bind(("127.0.0.1", 0))
    port = port_socket.getsockname()[1]
    port_socket.close()
    user_dir = Path(tempfile.mkdtemp(prefix=f"barkpark-e02-{short}-{surface}-{profile_name}-", dir="/private/tmp"))
    process = subprocess.Popen([
        CHROME, "--headless=new", "--disable-gpu", "--no-first-run", "--no-default-browser-check",
        "--disable-background-networking", f"--user-data-dir={user_dir}", f"--remote-debugging-port={port}", "about:blank",
    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        listing = None
        for _ in range(160):
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{port}/json", timeout=1) as response:
                    listing = json.load(response)
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
        cdp.call("Network.enable")
        cdp.call("Emulation.setDeviceMetricsOverride", {
            "width": profile["width"], "height": profile["height"],
            "deviceScaleFactor": profile["device_scale_factor"], "mobile": profile["mobile"],
        })
        cdp.call("Page.navigate", {"url": url})
        for _ in range(240):
            state = cdp.call("Runtime.evaluate", {"expression": "document.readyState", "returnByValue": True})["result"].get("value")
            if state == "complete":
                break
            time.sleep(0.05)
        time.sleep(0.4)
        value = cdp.call("Runtime.evaluate", {"expression": JS_PROBE, "returnByValue": True})["result"]["value"]
        focus_order = []
        for _ in range(min(value["controlCount"], 24)):
            cdp.call("Input.dispatchKeyEvent", {"type": "keyDown", "key": "Tab", "code": "Tab", "windowsVirtualKeyCode": 9})
            cdp.call("Input.dispatchKeyEvent", {"type": "keyUp", "key": "Tab", "code": "Tab", "windowsVirtualKeyCode": 9})
            active = cdp.call("Runtime.evaluate", {"expression": "({tag:document.activeElement.tagName,id:document.activeElement.id||null,label:(document.activeElement.innerText||document.activeElement.getAttribute('aria-label')||'').trim().slice(0,100),focusVisible:document.activeElement.matches(':focus-visible'),outline:getComputedStyle(document.activeElement).outlineStyle})", "returnByValue": True})["result"]["value"]
            focus_order.append(active)
        ax = cdp.call("Accessibility.getFullAXTree")
        roles = {}
        for node in ax.get("nodes", []):
            role = (node.get("role") or {}).get("value")
            if role:
                roles[role] = roles.get(role, 0) + 1
        cookies = cdp.call("Network.getAllCookies").get("cookies", [])
        value["focusOrder"] = focus_order
        value["axRoleCountsObservationOnly"] = roles
        value["sessionCookieMetadata"] = [{"name": c["name"], "secure": c.get("secure"), "httpOnly": c.get("httpOnly"), "sameSite": c.get("sameSite")} for c in cookies]
        value["requestedUrl"] = url
        value["profile"] = profile
        shot = cdp.call("Page.captureScreenshot", {"format": "png", "captureBeyondViewport": False})["data"]
        shot_path = SCREEN / short / surface / f"{profile_name}.png"
        shot_path.parent.mkdir(parents=True, exist_ok=True)
        shot_path.write_bytes(base64.b64decode(shot))
        value["screenshot"] = {"path": str(shot_path.relative_to(ROOT)), "sha256": sha(shot_path.read_bytes()), "bytes": shot_path.stat().st_size}
        return value
    finally:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
        subprocess.run(["trash", str(user_dir)], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def main():
    started = time.perf_counter()
    if os.environ.get("BARKPARK_MANIFEST") != EXPECTED_MANIFEST:
        raise SystemExit(f"BARKPARK_MANIFEST must equal {EXPECTED_MANIFEST}")
    if not Path(CHROME).is_file():
        raise SystemExit("Google Chrome executable unavailable")
    manifest = {
        "schema_version": "legendary-restart-e02-capture/v1",
        "assignment_id": "restart-experiment-02", "round": "baseline", "base_url": BASE,
        "manifest_override": EXPECTED_MANIFEST, "bp_server": "guerrilla", "profiles": PROFILES, "papers": [],
    }
    for short, slug, expected_rev, expected_blocks in PAPERS:
        paper_dir = RAW / short
        paper_dir.mkdir(parents=True, exist_ok=True)
        record = {"short_id": short, "slug": slug, "expected_rev": expected_rev, "expected_blocks": expected_blocks, "http": {}, "browser": {}}
        paths = {
            "source": f"/papers/{slug}/source", "public": f"/papers/{slug}", "email": f"/papers/{slug}/email",
            "studio": f"/w/default/p/default/d/production/studio/production/paper/{slug}",
        }
        for surface, path in paths.items():
            status, headers, body, final_url = fetch(BASE + path)
            if surface == "studio":
                raw_path = paper_dir / "studio-response-metadata.json"
                write_json(raw_path, {"body_persisted": False, "reason": "Login HTML may contain session-bound CSRF material; only its hash and safe metadata are retained.", "body_sha256": sha(body), "bytes": len(body)})
            else:
                suffix = "json" if surface == "source" else "html"
                raw_path = paper_dir / f"{surface}.{suffix}"
                raw_path.write_bytes(body)
            record["http"][surface] = {"requested_url": BASE + path, "final_url": final_url, "status": status, "safe_headers": headers, "bytes": len(body), "sha256": sha(body), "path": str(raw_path.relative_to(ROOT)), "body_persisted": surface != "studio"}
        cli = subprocess.run(["bp", "-s", "guerrilla", "paper", "view", slug, "-o", "json"], capture_output=True, check=True)
        cli_path = paper_dir / "cli.json"
        cli_path.write_bytes(cli.stdout)
        source = json.loads((paper_dir / "source.json").read_bytes())
        cli_doc = json.loads(cli.stdout)
        record["cli"] = {"path": str(cli_path.relative_to(ROOT)), "bytes": len(cli.stdout), "sha256": sha(cli.stdout), "observed_rev": cli_doc.get("_rev")}
        record["observed_rev"] = source.get("_rev")
        record["source_block_count"] = len(source["source"]["blocks"])
        record["source_blocks_sha256"] = sha(canonical(source["source"]["blocks"]))
        record["cli_blocks_sha256"] = sha(canonical(cli_doc.get("blocks", [])))
        record["pin_match"] = record["observed_rev"] == expected_rev and cli_doc.get("_rev") == expected_rev
        record["block_count_match"] = record["source_block_count"] == expected_blocks
        record["projection_match"] = record["source_blocks_sha256"] == record["cli_blocks_sha256"]
        for surface in ("public", "email", "studio"):
            record["browser"][surface] = {}
            target = BASE + paths[surface]
            for profile_name in PROFILES:
                record["browser"][surface][profile_name] = browser_probe(target, profile_name, surface, short)
        manifest["papers"].append(record)
    write_json(OUT / "raw-capture-manifest.json", manifest)
    redacted = json.loads(canonical(manifest))
    for paper in redacted["papers"]:
        for surface in paper["browser"].values():
            for cell in surface.values():
                cell["sessionCookieMetadata"] = [{**cookie, "value": "NOT_CAPTURED"} for cookie in cell["sessionCookieMetadata"]]
    write_json(OUT / "redacted-capture-manifest.json", redacted)
    write_json(OUT / "timing.json", {"capture_seconds": round(time.perf_counter() - started, 6), "browser_cells": 48, "http_fetches": 16, "cli_reads": 4})


if __name__ == "__main__":
    main()
