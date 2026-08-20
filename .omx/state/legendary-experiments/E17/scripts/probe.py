#!/usr/bin/env python3
"""Run real-surface availability attempts without proxy-passing any failure."""

from __future__ import annotations

import hashlib
import json
import os
import subprocess
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

from common import CANDIDATE_ID, ROOT, SURFACES, load_capsules, physical_hash, target_slug, write_json

RAW = ROOT / "attempts" / "raw"


def http_attempt(url: str, *, bearer: bool = False) -> dict[str, Any]:
    headers = {"User-Agent": "barkpark-e17-real-reader-gate/1"}
    if bearer and os.environ.get("BARKPARK_TOKEN"):
        headers["Authorization"] = f"Bearer {os.environ['BARKPARK_TOKEN']}"
    request = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            body = response.read()
            return {
                "body_bytes": len(body),
                "body_sha256": hashlib.sha256(body).hexdigest(),
                "content_type": response.headers.get("Content-Type"),
                "final_url": response.geturl(),
                "http_status": response.status,
            }
    except urllib.error.HTTPError as error:
        body = error.read()
        return {
            "body_bytes": len(body),
            "body_sha256": hashlib.sha256(body).hexdigest(),
            "content_type": error.headers.get("Content-Type"),
            "final_url": error.geturl(),
            "http_status": error.code,
        }
    except Exception as error:  # availability evidence must survive transport failure
        return {"transport_error": f"{type(error).__name__}: {error}"}


def command_attempt(command: list[str], *, stdin: str | None = None, timeout: int = 30) -> dict[str, Any]:
    try:
        completed = subprocess.run(
            command,
            input=stdin,
            text=True,
            capture_output=True,
            timeout=timeout,
            check=False,
        )
        stdout = completed.stdout.encode()
        stderr = completed.stderr.encode()
        return {
            "exit_code": completed.returncode,
            "stdout_bytes": len(stdout),
            "stdout_sha256": hashlib.sha256(stdout).hexdigest(),
            "stderr_bytes": len(stderr),
            "stderr_sha256": hashlib.sha256(stderr).hexdigest(),
            "diagnostic": (completed.stderr or completed.stdout)[:1000],
        }
    except Exception as error:
        return {"command_error": f"{type(error).__name__}: {error}"}


def tui_preflight() -> dict[str, Any]:
    return command_attempt(["script", "-q", "/dev/null", "bp"], stdin="q", timeout=30)


def mail_preflight() -> dict[str, Any]:
    present = Path("/System/Applications/Mail.app").is_dir()
    running = command_attempt(["osascript", "-e", 'application "Mail" is running'])
    return {"mail_app_present": present, "mail_app_running_probe": running}


def main() -> None:
    RAW.mkdir(parents=True, exist_ok=True)
    capsules = sorted(load_capsules(), key=lambda row: row["fixture_id"])
    base_url = os.environ.get("BARKPARK_URL", "https://guerrilla.barkpark.cloud").rstrip("/")
    shared_tui = tui_preflight()
    shared_mail = mail_preflight()
    started = time.perf_counter()
    rows: list[dict[str, Any]] = []

    for capsule in capsules:
        fixture_id = capsule["fixture_id"]
        slug = target_slug(fixture_id)
        for surface in SURFACES:
            if surface == "authenticated_studio":
                target = f"{base_url}/w/default/p/default/d/production/studio/production/paper/{slug}"
                observation = http_attempt(target, bearer=True)
                block = "AUTHENTICATED_SESSION_UNAVAILABLE_AND_CANDIDATE_NOT_DEPLOYED"
            elif surface == "public_reader":
                target = f"{base_url}/papers/{slug}"
                observation = http_attempt(target)
                block = "NO_DEPLOYED_E16_PROVENANCE_MARKER"
            elif surface == "tui":
                target = f"bp interactive TUI target={slug}"
                observation = shared_tui
                block = "TUI_SCHEMA_LOAD_FAILED_BEFORE_CANDIDATE_SELECTION"
            elif surface == "real_client_email":
                target = f"{base_url}/papers/{slug}/email"
                observation = {"endpoint": http_attempt(target), "real_client": shared_mail}
                block = "CANDIDATE_EMAIL_ENDPOINT_UNAVAILABLE_NO_MESSAGE_IMPORTED"
            else:
                target = f"bp paper view {slug} --width 40"
                observation = command_attempt(["bp", "paper", "view", slug, "--width", "40"])
                block = "CLI_REPORTS_CANDIDATE_SLUG_ABSENT"

            raw = {
                "schema_version": "legendary-e17-real-surface-attempt/v1",
                "candidate_id": CANDIDATE_ID,
                "candidate_source_sha256": capsule["source_sha256"],
                "fixture_id": fixture_id,
                "surface": surface,
                "target": target,
                "observation": observation,
                "candidate_materialized": False,
                "accepted_capture": False,
                "capture_sha256": None,
                "block_reason": block,
                "evidence_boundary": "REAL_SURFACE_ATTEMPT_ONLY_NOT_A_CAPTURE",
            }
            path = RAW / surface / f"{fixture_id}.json"
            write_json(path, raw)
            rows.append({
                "fixture_id": fixture_id,
                "surface": surface,
                "raw_path": str(path.relative_to(ROOT)),
                "attempt_sha256": physical_hash(path),
            })

    write_json(ROOT / "attempt-index.json", {
        "schema_version": "legendary-e17-attempt-index/v1",
        "candidate_id": CANDIDATE_ID,
        "attempt_count": len(rows),
        "capture_count": 0,
        "rows": rows,
    })
    write_json(ROOT / "timing-probe.json", {
        "schema_version": "legendary-e17-probe-timing/v1",
        "attempt_count": len(rows),
        "elapsed_seconds": round(time.perf_counter() - started, 6),
        "excluded_from_deterministic_hashes": True,
    })
    print(f"E17 PROBE COMPLETE attempts={len(rows)} captures=0 verdict=BLOCKED")


if __name__ == "__main__":
    main()
