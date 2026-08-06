#!/usr/bin/env python3
"""Deterministic hostile-reader attack over restart candidates E04/E05/E06."""

from __future__ import annotations

import email
import hashlib
import json
import re
import subprocess
import sys
import tarfile
import time
from collections import Counter
from email import policy
from html import escape
from pathlib import Path

E08 = Path(__file__).resolve().parents[1]
ROOT = E08.parent
CHROME = Path("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
FIXTURES = ("CCH28", "CCH29", "PDS44", "PDS45")
CANDIDATES = ("E04", "E05", "E06")
VIEWPORTS = (("desktop", 1280, 800, 1), ("390", 390, 844, 1), ("320", 320, 700, 1), ("reflow-200", 1280, 800, 2))


def canonical(value):
    return json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n"


def dump(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(canonical(value))


def dump_compact(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":")) + "\n")


def load(path):
    return json.loads(path.read_text())


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def render_nodes(nodes):
    out = []
    for node in nodes:
        kind = node.get("type")
        ident = escape(str(node.get("id", "")), quote=True)
        if kind == "heading":
            level = min(6, max(1, int(node.get("level", 2))))
            out.append(f'<h{level} id="{ident}">{escape(str(node.get("text", "")))}</h{level}>')
        elif kind == "paragraph":
            out.append(f'<p id="{ident}">{escape(flat_text(node.get("content", [])))}</p>')
        elif kind == "callout":
            out.append(f'<aside id="{ident}" role="note" data-tone="{escape(str(node.get("tone", "info")))}">{escape(flat_text(node.get("content", [])))}</aside>')
        elif kind == "list":
            tag = "ol" if node.get("ordered") else "ul"
            items = "".join(f"<li>{escape(flat_text(item))}</li>" for item in node.get("items", []))
            out.append(f'<{tag} id="{ident}">{items}</{tag}>')
        elif kind == "table":
            head = "".join(f'<th scope="col">{escape(flat_text(c))}</th>' for c in node.get("head", []))
            rows = "".join("<tr>" + "".join(f"<td>{escape(flat_text(c))}</td>" for c in row) + "</tr>" for row in node.get("rows", []))
            out.append(f'<div class="table-scroll" tabindex="0"><table id="{ident}"><thead><tr>{head}</tr></thead><tbody>{rows}</tbody></table></div>')
    return "<!doctype html><html><head><meta charset=utf-8></head><body><main>" + "".join(out) + "</main></body></html>"


def flat_text(value):
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        return "".join(flat_text(x) for x in value)
    if isinstance(value, dict):
        if "value" in value:
            return str(value["value"])
        if "text" in value:
            return str(value["text"])
        return "".join(flat_text(v) for v in value.values() if isinstance(v, (list, dict)))
    return ""


def artifact(candidate, surface, fixture):
    base = ROOT / candidate
    if candidate == "E04":
        row = load(base / "evidence/run-1/adapters" / surface / f"{fixture}.json")
        return render_nodes(row["projection"]["blocks"]), "PROXY_HARNESS_FROM_CANDIDATE_JSON", None
    if candidate == "E05":
        d = base / "generated/adapters" / fixture
        if surface == "public":
            return (d / "public.html").read_text(), "CANDIDATE_STATIC_ARTIFACT", None
        raw = (d / "email.eml").read_bytes()
    else:
        d = base / "generated/adapters"
        if surface == "public":
            return (d / "public" / f"{fixture}.html").read_text(), "CANDIDATE_STATIC_ARTIFACT", None
        raw = (d / "email" / f"{fixture}.eml").read_bytes()
    msg = email.message_from_bytes(raw, policy=policy.default)
    html_part = msg.get_body(preferencelist=("html",))
    return (html_part.get_content() if html_part else ""), "LOCAL_MIME_HTML_PART_NOT_DELIVERED", msg


def browser_probe(html, label, width, height, zoom):
    style = f"<style>html{{zoom:{zoom};}} body{{overflow-wrap:anywhere;}} img,table{{max-width:100%;}}</style>"
    script = """<script>(()=>{const q=s=>document.querySelectorAll(s).length;const fs=[...document.querySelectorAll('a[href],button,input,select,textarea,[tabindex]')].filter(e=>!e.disabled&&e.tabIndex>=0);const r={clientWidth:document.documentElement.clientWidth,scrollWidth:document.documentElement.scrollWidth,overflow:document.documentElement.scrollWidth>document.documentElement.clientWidth+1,headings:q('h1,h2,h3,h4,h5,h6'),tables:q('table'),scopedHeaders:q('th[scope]'),callouts:q('aside[role=note],[role=status],[role=alert]'),marks:q('mark,strong,em,code'),landmarks:q('main,nav,header,footer,aside'),focusables:fs.length,focusOrder:fs.slice(0,50).map(e=>e.id||e.tagName.toLowerCase()+':'+e.tabIndex)};const p=document.createElement('pre');p.id='attack-result';p.textContent=JSON.stringify(r);document.body.appendChild(p)})()</script>"""
    wrapped = html.replace("</head>", style + "</head>") if "</head>" in html.lower() else style + html
    wrapped = re.sub(r"</body\s*>", script + "</body>", wrapped, flags=re.I) if re.search(r"</body\s*>", wrapped, re.I) else wrapped + script
    probe_dir = E08 / "runtime"
    probe_dir.mkdir(parents=True, exist_ok=True)
    page = probe_dir / "probe.html"
    page.write_text(wrapped)
    cmd = [str(CHROME), "--headless", "--incognito", "--no-sandbox", "--disable-gpu", "--disable-extensions", "--disable-sync", "--disable-background-networking", "--disable-component-update", "--metrics-recording-only", "--safebrowsing-disable-auto-update", "--no-first-run", "--no-default-browser-check", "--virtual-time-budget=1000", f"--window-size={width},{height}", "--dump-dom", page.resolve().as_uri()]
    try:
        cp = subprocess.run(cmd, capture_output=True, text=True, timeout=8)
    except subprocess.TimeoutExpired:
        return {"label": label, "status": "BLOCKED", "reason": "local Chrome timed out after 8 seconds"}
    match = re.search(r'<pre id="attack-result">(.*?)</pre>', cp.stdout, re.S)
    if cp.returncode or not match:
        return {"label": label, "status": "BLOCKED", "reason": f"chrome rc={cp.returncode}; result={bool(match)}"}
    from html import unescape
    data = json.loads(unescape(match.group(1)))
    data.update({"label": label, "status": "FAIL" if data["overflow"] else "PASS", "width": width, "height": height, "zoom": zoom, "reader_kind": "local_headless_chrome"})
    return data


def mime_probe(msg):
    if msg is None:
        return {"status": "BLOCKED", "reason": "candidate exposes JSON adapter, not RFC message"}
    plain = msg.get_body(preferencelist=("plain",))
    htmlp = msg.get_body(preferencelist=("html",))
    required = {k: bool(msg.get(k)) for k in ("From", "To", "Subject", "Message-ID", "MIME-Version")}
    ok = msg.get_content_type() == "multipart/alternative" and bool(plain) and bool(htmlp) and all(required.values())
    return {"status": "PASS" if ok else "FAIL", "content_type": msg.get_content_type(), "plain": bool(plain), "html": bool(htmlp), "required_headers": required}


def static_semantic_probe(html):
    counts = {
        "headings": len(re.findall(r"<h[1-6]\b", html, re.I)),
        "tables": len(re.findall(r"<table\b", html, re.I)),
        "scoped_headers": len(re.findall(r"<th\b[^>]*\bscope\s*=", html, re.I)),
        "callouts": len(re.findall(r"<(?:aside\b[^>]*\brole\s*=\s*[\"']note|[^>]+\brole\s*=\s*[\"'](?:status|alert))", html, re.I)),
        "landmarks": len(re.findall(r"<(?:main|nav|header|footer|aside)\b", html, re.I)),
        "marks": len(re.findall(r"<(?:mark|strong|em|code)\b", html, re.I)),
        "focusables": len(re.findall(r"<(?:a\b[^>]*\bhref|button\b|input\b|select\b|textarea\b|[^>]+\btabindex\s*=)", html, re.I)),
    }
    table_ok = counts["tables"] == 0 or counts["scoped_headers"] >= counts["tables"]
    return {"status": "PASS" if table_ok else "FAIL", "evidence_kind": "STATIC_DOM_PROXY_NOT_AT", **counts}


def build():
    started = time.perf_counter_ns()
    assignment = load(E08 / "assignment.json")
    seal = load(ROOT / "baseline-seal/contract.json")
    rows = []
    for candidate in CANDIDATES:
        for surface in ("public", "email"):
            for fixture in FIXTURES:
                html, evidence_kind, msg = artifact(candidate, surface, fixture)
                rows.append({"candidate": candidate, "surface": surface, "fixture": fixture, "viewport": "static", **static_semantic_probe(html)})
                if fixture == "CCH28":
                    for name, width, height, zoom in VIEWPORTS:
                        probe = browser_probe(html, f"{candidate}-{surface}-{fixture}-{name}", width, height, zoom)
                        rows.append({"candidate": candidate, "surface": surface, "fixture": fixture, "viewport": name, "evidence_kind": evidence_kind, **probe})
                if surface == "email":
                    rows.append({"candidate": candidate, "surface": "email_mime", "fixture": fixture, "viewport": "n/a", "evidence_kind": evidence_kind, **mime_probe(msg)})
        for fixture in FIXTURES:
            rows.extend([
                {"candidate": candidate, "surface": "studio", "fixture": fixture, "axis": "authenticated_render_session_expiry_reconnect", "status": "BLOCKED", "evidence_kind": "REAL_READER_UNAVAILABLE", "reason": "no safe authenticated Studio session; static adapter is not proxy-passed"},
                {"candidate": candidate, "surface": "email", "fixture": fixture, "axis": "delivered_mail_clients", "status": "BLOCKED", "evidence_kind": "REAL_READER_UNAVAILABLE", "reason": "no delivery account or real mail client receipt"},
                {"candidate": candidate, "surface": "assistive_technology", "fixture": fixture, "axis": "screen_reader_reading_order", "status": "BLOCKED", "evidence_kind": "REAL_READER_UNAVAILABLE", "reason": "no real AT session; DOM semantics are proxy evidence only"},
                {"candidate": candidate, "surface": "cache", "fixture": fixture, "axis": "freshness_reconnect", "status": "BLOCKED", "evidence_kind": "REAL_READER_UNAVAILABLE", "reason": "isolated artifact has no deployed cache/reconnect lifecycle"},
            ])
    # DOM table/callout/landmark/focus probes are observations, not AT passes.
    browser = [r for r in rows if r.get("reader_kind") == "local_headless_chrome"]
    for r in browser:
        if r["status"] == "PASS" and (r["tables"] > r["scopedHeaders"] and r["tables"] > 0):
            r["semantic_warning"] = "table without scoped header"
            r["status"] = "FAIL"
    counts = dict(Counter(r["status"] for r in rows))
    candidate_outcomes = []
    for candidate in CANDIDATES:
        cr = [r for r in rows if r["candidate"] == candidate]
        cc = dict(Counter(r["status"] for r in cr))
        candidate_outcomes.append({"candidate": candidate, "counts": cc, "verdict": "REJECT", "reason": "zero-threshold gate has FAIL/BLOCKED cells"})
    report = {
        "schema_version": "legendary-paper-restart-e08-attack-matrix/v1",
        "assignment_id": assignment["assignment_id"],
        "round": "attack",
        "reader_truth": {"local_headless_chrome": "real browser engine over isolated candidate/static/proxy artifacts; CCH28 representative at every width", "static_dom": "all four fixtures checked for semantic carriers", "real_studio_email_at": "unavailable cells remain BLOCKED"},
        "rows": rows,
        "counts": counts,
    }
    dump(E08 / "reports/attack-matrix.json", report)
    dump(E08 / "reports/candidate-scorecards.json", {"round": "attack", "candidates": candidate_outcomes})
    inputs = {}
    for p in [ROOT / "baseline-seal/contract.json"] + [ROOT / c / "result.json" for c in CANDIDATES]:
        inputs[str(p.relative_to(ROOT))] = sha(p)
    dump(E08 / "reports/input-hashes.json", inputs)
    elapsed = time.perf_counter_ns() - started
    return report, candidate_outcomes, elapsed


def credential_scan():
    patterns = [re.compile(x, re.I) for x in (r"bearer\s+[a-z0-9._-]{12,}", r"api[_-]?key\s*[:=]", r"password\s*[:=]", r"-----BEGIN .*PRIVATE KEY-----")]
    hits = []
    scanned = []
    excluded = {E08 / "scripts/attack.py", E08 / "reports/credential-scan.json", E08 / "reports/credential-scan-false-positive-attempt.json", E08 / "evidence.tar.gz"}
    for p in sorted(E08.rglob("*")):
        if p.is_file() and "runtime/" not in str(p.relative_to(E08)) and p not in excluded:
            scanned.append(p)
            text = p.read_text(errors="ignore")
            for pattern in patterns:
                if pattern.search(text):
                    hits.append({"path": str(p.relative_to(E08)), "pattern": pattern.pattern})
    dump(E08 / "reports/credential-scan.json", {"status": "PASS" if not hits else "FAIL", "hits": hits, "files_scanned": len(scanned), "excluded_self_referential_files": sorted(str(p.relative_to(E08)) for p in excluded)})
    return hits


def main():
    report, outcomes, elapsed = build()
    semantic = sha(E08 / "reports/attack-matrix.json")
    run_no = int(sys.argv[1]) if len(sys.argv) > 1 else 1
    dump(E08 / f"reports/replay-{run_no}.json", {"run": run_no, "semantic_sha256": semantic, "counts": report["counts"]})
    if run_no == 2:
        r1 = load(E08 / "reports/replay-1.json")
        dump(E08 / "reports/reproducibility.json", {"status": "PASS" if r1["semantic_sha256"] == semantic else "FAIL", "run_1": r1["semantic_sha256"], "run_2": semantic})
        dump(E08 / "reports/timing.json", {"run_2_wall_nanoseconds": elapsed, "measurement": "local hostile browser and static reader probes"})
        hits = credential_scan()
        result = {
            "schema_version": "legendary-paper-restart-experiment-result/v1",
            "assignment_id": "restart-experiment-08",
            "assignment_uuid": "ef4bc3aa-adbe-487a-813a-87ba2b27e142",
            "epic_task_id": "task-a768c69e659add58",
            "wave_id": "legendary-paper-reader-upgrade-wave-2026-08-06-restart",
            "wave_revision": "8a94f6db-1be6-4bbf-ba49-7f3aeed0e737",
            "round": "attack",
            "status": "completed",
            "candidate_selected": False,
            "candidate_outcomes": outcomes,
            "counts": report["counts"],
            "hard_threshold": "zero overflow and zero semantic loss; every declared real reader exercised",
            "typed_verdict": "REJECT_ALL_CANDIDATES_BLOCKED_OR_FAILED",
            "observations": ["Local Chrome exercised public and decoded email HTML at desktop, 390, 320, and 200%-equivalent zoom.", "DOM semantics, focus order, MIME structure, and overflow were measured; these are not real AT, delivered-mail, authenticated Studio, cache, expiry, or reconnect evidence.", "Every candidate has hard FAIL or BLOCKED cells."],
            "preference": "None recorded; Attack does not select a format.",
            "credential_scan": "PASS" if not hits else "FAIL",
            "reproducibility": load(E08 / "reports/reproducibility.json")["status"],
            "evidence": "evidence.tar.gz"
        }
        dump_compact(E08 / "result.json", result)
        members = [p for p in sorted(E08.rglob("*")) if p.is_file() and p.name != "evidence.tar.gz" and "runtime/chrome-profile" not in str(p)]
        with tarfile.open(E08 / "evidence.tar.gz", "w:gz", format=tarfile.PAX_FORMAT) as tf:
            for p in members:
                info = tf.gettarinfo(str(p), arcname=str(p.relative_to(E08)))
                info.mtime = 0
                with p.open("rb") as fh:
                    tf.addfile(info, fh)
        result = load(E08 / "result.json")
        result["artifact_set_sha256"] = sha(E08 / "evidence.tar.gz")
        dump_compact(E08 / "result.json", result)
    print(canonical({"round": "attack", "run": run_no, "counts": report["counts"], "semantic_sha256": semantic}), end="")


if __name__ == "__main__":
    main()
