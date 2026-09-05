"""Read a bp response so a REFUSAL cannot be mistaken for an empty result.

THE DEFECT THIS CLOSES. `rows = d.get("docs") or d.get("tasks") or []` is the
right idiom for a real document with a missing field and EXACTLY wrong for a
failed read, and the two are indistinguishable at the call site. bp's refusal
envelope carries no `docs` key AT ALL:

    $ bp task ls --parent task-3f1fe755ed53738e --limit 5 -o json
    {"error":{"code":"usage","message":"unknown flag --parent for task ls"},"ok":false}
    exit=2

so the `or` swallows it and yields the same [] a genuinely childless parent
yields. Two specimens in one day reported 0 children for parents carrying 35,
142 and 345.

bp IS NOT AT FAULT and must not be "fixed": it emits THREE independent refusal
signals -- `ok:false`, a typed `error.code`, and a distinct non-zero exit (2
usage, 4 not_found). The reader threw all three away. (The opposite half of the
disease -- a producer that signals nothing -- is `bp search`, which prints a
manifest failure on stderr and still exits 0; that is the sibling row
`spd-bl-bp-search-exits-zero-while-failing` and is NOT fixed here.)

THE RULE: check the SHAPE before the CONTENT.

    from bp_read import bp_json, rows
    d = bp_json(["bp", "task", "ls", "--limit", "5", "-o", "json"])
    n = len(rows(d, "docs", "tasks"))     # a true 0 here MEANS zero

`rows()` refuses to apply the key fallback to a payload that never passed
`ensure_ok`, so the two halves cannot drift apart.
"""

from __future__ import annotations

import json
import subprocess
from typing import Any, Iterable, Sequence

__all__ = ["BpRefused", "ensure_ok", "bp_json", "rows"]


class BpRefused(Exception):
    """bp declined the read. Raised INSTEAD of returning a plausible zero."""

    def __init__(self, code: str, message: str, *, exit_code: int | None = None,
                 argv: Sequence[str] | None = None, payload: Any = None) -> None:
        self.code = code
        self.message = message
        self.exit_code = exit_code
        self.argv = list(argv) if argv else []
        self.payload = payload
        where = " ".join(self.argv) if self.argv else "bp"
        tail = "" if exit_code is None else f" (exit {exit_code})"
        super().__init__(f"bp refused `{where}`{tail}: {code}: {message}")


def ensure_ok(payload: Any, *, exit_code: int | None = None,
              argv: Sequence[str] | None = None) -> dict:
    """Return `payload` only if it is a bp SUCCESS envelope; else raise.

    Three signals, checked independently, because each one alone is defeatable:
    a non-zero exit is lost by a pipeline, `ok:false` is lost by a reader that
    only looks at `error`, and `error` is lost by a reader that only looks at
    `ok`. Any one of them firing is a refusal.
    """
    if exit_code is not None and exit_code != 0:
        code, message = "exit", f"bp exited {exit_code}"
        if isinstance(payload, dict) and isinstance(payload.get("error"), dict):
            code = str(payload["error"].get("code") or code)
            message = str(payload["error"].get("message") or message)
        raise BpRefused(code, message, exit_code=exit_code, argv=argv, payload=payload)
    if not isinstance(payload, dict):
        raise BpRefused("shape", f"expected a JSON object, got {type(payload).__name__}",
                        exit_code=exit_code, argv=argv, payload=payload)
    if payload.get("ok", True) is False or "error" in payload:
        err = payload.get("error")
        if isinstance(err, dict):
            code = str(err.get("code") or "error")
            message = str(err.get("message") or err)
        else:
            code, message = "error", str(err if err is not None else "ok:false")
        raise BpRefused(code, message, exit_code=exit_code, argv=argv, payload=payload)
    return payload


def bp_json(argv: Sequence[str], *, input_text: str | None = None) -> dict:
    """Run bp and return its parsed SUCCESS envelope, or raise BpRefused.

    Captures stdout and stderr separately and NEVER pipes bp into a parser --
    a pipeline discards bp's exit status, which is the one signal a malformed
    body cannot fake.
    """
    argv = list(argv)
    proc = subprocess.run(argv, capture_output=True, text=True, input=input_text)
    body = proc.stdout.strip()
    if not body:
        raise BpRefused("empty", f"bp printed nothing; stderr: {proc.stderr.strip()[:400]}",
                        exit_code=proc.returncode, argv=argv)
    try:
        payload = json.loads(body)
    except json.JSONDecodeError as exc:
        raise BpRefused("unparseable", f"{exc}; first 200 bytes: {body[:200]}",
                        exit_code=proc.returncode, argv=argv) from exc
    return ensure_ok(payload, exit_code=proc.returncode, argv=argv)


def rows(payload: dict, *keys: str, require: bool = True) -> list:
    """Apply the `docs`/`tasks` key fallback -- but ONLY to a checked payload.

    `require=True` (the default) refuses a payload in which NONE of `keys` is
    present. That absence is the fingerprint of a refusal that slipped past a
    caller who forgot `ensure_ok`: a genuinely empty result carries the key
    with an empty list, a refusal carries no such key at all.
    """
    ensure_ok(payload)
    keys = keys or ("docs", "tasks")
    for key in keys:
        value = payload.get(key)
        if isinstance(value, list):
            return value
    if require:
        raise BpRefused("shape",
                        "none of %s is present -- a real empty result carries the key with []"
                        % ", ".join(repr(k) for k in keys),
                        payload=payload)
    return []


def counts(payload: dict, *keys: str) -> int:
    """len(rows(...)) -- so a 0 printed by a caller is always an EARNED zero."""
    return len(rows(payload, *keys))
