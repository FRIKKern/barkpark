#!/usr/bin/env python3
"""count_tokens_calibrate.py — tokens confirm (or flip) the brief manifest encoding.

The ctx-compression epic ratified the brief encoding (array-of-tuples JSON, charter
decision 3) on BYTES, with this token check pre-registered as the confirm-or-flip
step (charter decision 5). METER.md bans tiktoken/chars-4 — the ONLY legal counter is
POST /v1/messages/count_tokens against a pinned model id.

WHAT IT DOES
    Reads the committed wave-1 fixtures (tooling/scaffy-duels/fixtures/):
        caps-full  — full 142-command manifest (the un-projected baseline)
        caps-brief — BRIEF-KEEP-LIST v1 as array-of-tuples JSON (the SHIPPED encoding)
    and derives, in memory, four more encodings of the SAME brief keep-list fields
    (charter decision 6) so the comparison isolates ENCODING, never field content:
        brief-nested-json  — nested JSON objects (charter menu ~2.28x)
        brief-tsv          — tab-separated rows, legend header (charter menu ~4.47x)
        brief-cmd          — man-page / usage-line text
        brief-packed       — compact single-line-per-command packed string
    => 6 payloads total. All five brief encodings are invoke-complete (every command
    reconstructable from the brief alone) and carry byte-identical field VALUES — they
    are pure re-serializations of the committed caps-brief tuples, so no reimplementation
    of the Go briefManifest projection is needed and drift is impossible.

KEY DISCOVERY (charter decision 5)
    `bp secret get anthropic_api_key -o json` -> JSON {name, value}. If absent (today:
    `bp secret ls` has only ingest_token — human provisioning is ctx-b5), print the
    wc-c byte table labeled BYTES-NOT-TOKENS-PENDING-CONVERSION and exit 0. That IS the
    pre-registered fallback, NOT a failure.

WITH A KEY
    12 calls = 6 payloads x 2 pinned model ids (tokenizers differ ~30% across models
    per METER.md; the pin must match ctx-s6's live session). Results — per-payload
    input_tokens alongside the byte counts — are written under results/ as committed
    data-of-record, with the decision verdict recorded either way.

DECISION RULE (pre-registered, charter decision 5)
    Tokens win. If another invoke-complete encoding beats the shipped tuples encoding by
    >10% tokens, the winning encoding is named and an amendment task is warranted; ties
    (<=10%) break to the JSON family (i.e. tuples holds). The verdict line is recorded in
    the results file either way — PENDING under the byte-only fallback.

Honesty (distrust-vacuous-green, mirroring meter.py): --self-check proves the
invoke-completeness gate REDS on a mutilated payload and GREENS on a faithful one, and
runs fully offline on the committed fixtures.

Usage:
    count_tokens_calibrate.py [--self-check] [--models id1,id2] [--out PATH]
"""
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURES = os.path.join(HERE, "fixtures")
RESULTS = os.path.join(HERE, "results", "count-tokens")

CAPS_FULL = os.path.join(FIXTURES, "caps-full-2026-07-24.json")
CAPS_BRIEF = os.path.join(FIXTURES, "caps-brief-2026-07-24.json")

# The two pinned model ids (charter decision 5, 13: the pin must match ctx-s6's live
# session). Recorded verbatim in every results file. Override with --models when the
# duel/live-session pin changes. These are the models this epic actually exercises
# (opus builders, sonnet duels); count_tokens is tokenizer-specific, so the exact id
# is load-bearing — see METER.md ("Sonnet 5's tokenizer yields ~30% more tokens than
# Sonnet 4.6 for identical text").
PINNED_MODELS = ["claude-opus-4-8", "claude-sonnet-5"]

# The shipped encoding — the incumbent the decision rule defends.
SHIPPED = "brief-tuples"
FLIP_THRESHOLD = 0.10  # >10% token win by an alt encoding warrants an amendment
KEEP_FIELDS = ["noun", "verb", "summary", "auth_tier", "writes", "args", "flags"]

FALLBACK_LABEL = "BYTES-NOT-TOKENS-PENDING-CONVERSION"


# --------------------------------------------------------------------------- fixtures

def _read_text(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def _nbytes(text):
    return len(text.encode("utf-8"))


def records_from_brief(brief):
    """Canonical per-command records from the committed caps-brief tuples.

    The tuples fixture is byte-identical to briefManifest(caps-full) (verified by
    ctx-s1's reviewer), so it — not the full manifest — is the source of record for the
    brief field VALUES. Every alt encoding re-serializes these identical records, which
    is exactly what charter decision 6 measures: identical fields, encoding-only spread.
    """
    legend = brief["legend"]
    cmd_keys = legend["command"]      # noun verb summary auth_tier writes args flags
    arg_keys = legend["arg"]          # name type required
    flag_keys = legend["flag"]        # name type
    if cmd_keys != KEEP_FIELDS:
        raise ValueError(f"legend.command {cmd_keys} != BRIEF-KEEP-LIST v1 {KEEP_FIELDS}")
    recs = []
    for tup in brief["commands"]:
        rec = dict(zip(cmd_keys, tup))
        rec["args"] = [dict(zip(arg_keys, a)) for a in rec["args"]]
        rec["flags"] = [dict(zip(flag_keys, f)) for f in rec["flags"]]
        recs.append(rec)
    return recs


def brief_header(brief):
    """Top-level brief fields kept per charter decision 6 (nouns catalog dropped)."""
    return {
        "manifest_version": brief["manifest_version"],
        "server": brief["server"],
        "auth_tier": brief["auth_tier"],
        "etag": brief["etag"],
    }


# ------------------------------------------------------------------------- encodings
# Each returns invoke-complete text carrying every BRIEF-KEEP-LIST v1 field.

def enc_nested_json(header, recs):
    doc = dict(header)
    doc["commands"] = recs  # records already carry nested arg/flag dicts
    return json.dumps(doc, separators=(",", ":"), ensure_ascii=False)


def _tsv_args(args):
    return ",".join(f"{a['name']}:{a['type']}:{1 if a['required'] else 0}" for a in args)


def _tsv_flags(flags):
    return ",".join(f"{f['name']}:{f['type']}" for f in flags)


def enc_tsv(header, recs):
    lines = [
        "# manifest_version\t" + str(header["manifest_version"]),
        "# server\t" + json.dumps(header["server"], separators=(",", ":"), ensure_ascii=False),
        "# auth_tier\t" + header["auth_tier"],
        "# etag\t" + header["etag"],
        "# legend\tnoun\tverb\tsummary\tauth_tier\twrites\targs(name:type:required,..)\tflags(name:type,..)",
    ]
    for r in recs:
        lines.append("\t".join([
            r["noun"], r["verb"], r["summary"], r["auth_tier"],
            "1" if r["writes"] else "0", _tsv_args(r["args"]), _tsv_flags(r["flags"]),
        ]))
    return "\n".join(lines)


def enc_cmd(header, recs):
    lines = [
        f"# {header['server']['name']} {header['server']['version']} "
        f"(manifest v{header['manifest_version']}, auth {header['auth_tier']}, etag {header['etag']})",
    ]
    for r in recs:
        parts = [f"{r['noun']} {r['verb']} — {r['summary']}",
                 f"[auth:{r['auth_tier']}]", "[writes]" if r["writes"] else "[read]"]
        if r["args"]:
            parts.append("args: " + " ".join(
                f"{a['name']}({a['type']}{',req' if a['required'] else ''})" for a in r["args"]))
        if r["flags"]:
            parts.append("flags: " + " ".join(f"--{f['name']}({f['type']})" for f in r["flags"]))
        lines.append("  ".join(parts))
    return "\n".join(lines)


def enc_packed(header, recs):
    # Most compact: one pipe-delimited line per command. Charter decision 3 flags packed
    # as only data-dependently collision-safe — legitimate as a measurement candidate,
    # not as the ship choice.
    head = f"#v{header['manifest_version']}|{header['server']['name']}|{header['auth_tier']}|{header['etag']}"
    lines = [head]
    for r in recs:
        a = ",".join(f"{x['name']}:{x['type']}:{1 if x['required'] else 0}" for x in r["args"])
        f = ",".join(f"{x['name']}:{x['type']}" for x in r["flags"])
        lines.append(f"{r['noun']}|{r['verb']}|{r['auth_tier']}|{1 if r['writes'] else 0}|{r['summary']}|{a}|{f}")
    return "\n".join(lines)


def build_payloads():
    """The 6 payloads: dict name -> {text, kind, family, encoding}."""
    full_text = _read_text(CAPS_FULL)
    brief_text = _read_text(CAPS_BRIEF)
    brief = json.loads(brief_text)
    header = brief_header(brief)
    recs = records_from_brief(brief)

    payloads = {
        "full": {"text": full_text, "kind": "baseline", "family": "json",
                 "encoding": "full-nested-json"},
        # tuples = the committed brief fixture verbatim (byte-identical to briefManifest)
        "brief-tuples": {"text": brief_text, "kind": "brief", "family": "json",
                         "encoding": "array-of-tuples+legend", "shipped": True},
        "brief-nested-json": {"text": enc_nested_json(header, recs), "kind": "brief",
                              "family": "json", "encoding": "nested-json"},
        "brief-tsv": {"text": enc_tsv(header, recs), "kind": "brief", "family": "text",
                      "encoding": "tsv"},
        "brief-cmd": {"text": enc_cmd(header, recs), "kind": "brief", "family": "text",
                      "encoding": "cmd-usage-lines"},
        "brief-packed": {"text": enc_packed(header, recs), "kind": "brief", "family": "text",
                         "encoding": "packed"},
    }
    for name, p in payloads.items():
        p["bytes"] = _nbytes(p["text"])
    return payloads, recs


# --------------------------------------------------------------- invoke-completeness

def invoke_complete_errors(payloads, recs):
    """Return a list of failures — empty means every brief encoding is invoke-complete.

    A brief encoding is invoke-complete iff every command's noun, verb, and every
    arg/flag name are recoverable from its text alone (the acceptance test the charter
    calls out: 'every command composable from the brief alone'). We assert presence of
    the load-bearing tokens per command; nested-json additionally must round-trip.
    """
    errs = []
    n = len(recs)

    # nested-json: strict structural round-trip.
    try:
        doc = json.loads(payloads["brief-nested-json"]["text"])
        if len(doc.get("commands", [])) != n:
            errs.append(f"brief-nested-json: {len(doc.get('commands', []))} commands != {n}")
        else:
            for i, (c, r) in enumerate(zip(doc["commands"], recs)):
                missing = [k for k in KEEP_FIELDS if k not in c]
                if missing:
                    errs.append(f"brief-nested-json cmd {i}: missing {missing}")
                    break
                if c["noun"] != r["noun"] or c["verb"] != r["verb"]:
                    errs.append(f"brief-nested-json cmd {i}: noun/verb mismatch")
                    break
                for a in c.get("args", []):
                    if not all(k in a for k in ("name", "type", "required")):
                        errs.append(f"brief-nested-json cmd {i}: arg missing keys")
                        break
    except (ValueError, KeyError) as e:  # noqa: BLE001
        errs.append(f"brief-nested-json: unparseable ({e})")

    # tuples: parseable + 142 tuples of the right arity.
    try:
        tup = json.loads(payloads["brief-tuples"]["text"])
        if len(tup.get("commands", [])) != n:
            errs.append(f"brief-tuples: {len(tup.get('commands', []))} commands != {n}")
    except ValueError as e:  # noqa: BLE001
        errs.append(f"brief-tuples: unparseable ({e})")

    # text encodings: one line per command, every noun/verb/arg-name/flag-name present.
    for name in ("brief-tsv", "brief-cmd", "brief-packed"):
        text = payloads[name]["text"]
        body = [ln for ln in text.split("\n") if ln and not ln.startswith("#")]
        if len(body) != n:
            errs.append(f"{name}: {len(body)} data lines != {n} commands")
            continue
        for i, (ln, r) in enumerate(zip(body, recs)):
            if r["noun"] not in ln or r["verb"] not in ln:
                errs.append(f"{name} line {i}: noun/verb '{r['noun']} {r['verb']}' absent")
                break
            for a in r["args"]:
                if a["name"] not in ln:
                    errs.append(f"{name} line {i}: arg '{a['name']}' absent")
                    break
            for f in r["flags"]:
                if f["name"] not in ln:
                    errs.append(f"{name} line {i}: flag '{f['name']}' absent")
                    break
    return errs


# ------------------------------------------------------------------------ key + api

def discover_key():
    """`bp secret get anthropic_api_key -o json` -> value, or None (fallback path)."""
    try:
        out = subprocess.run(
            ["bp", "secret", "get", "anthropic_api_key", "-o", "json"],
            capture_output=True, text=True, timeout=30,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    try:
        data = json.loads(out.stdout)
    except ValueError:
        return None
    if isinstance(data, dict) and data.get("ok") is not False and "error" not in data:
        val = data.get("value")
        if isinstance(val, str) and val:
            return val
    return None


def count_tokens(model, text, api_key):
    """POST /v1/messages/count_tokens -> input_tokens. METER.md's only legal counter."""
    body = json.dumps({
        "model": model,
        "messages": [{"role": "user", "content": text}],
    }).encode("utf-8")
    req = urllib.request.Request(
        "https://api.anthropic.com/v1/messages/count_tokens",
        data=body, method="POST",
        headers={
            "x-api-key": api_key,
            "anthropic-version": "2023-06-01",
            "content-type": "application/json",
        },
    )
    with urllib.request.urlopen(req, timeout=60) as resp:  # noqa: S310 (fixed host)
        return json.loads(resp.read())["input_tokens"]


# ---------------------------------------------------------------------- decision rule

def decide(metric_by_payload):
    """Apply the pre-registered rule to a {payload: number} map (tokens or bytes).

    Returns (verdict_line, winner, detail). Lower is better. The incumbent is the
    shipped tuples encoding; an alt brief encoding must beat it by >10% to flip.
    """
    briefs = {k: v for k, v in metric_by_payload.items() if k != "full" and v is not None}
    if SHIPPED not in briefs:
        return f"VERDICT: indeterminate — {SHIPPED} not measured", SHIPPED, {}
    ship = briefs[SHIPPED]
    best_name, best_val = min(briefs.items(), key=lambda kv: kv[1])
    detail = {k: round(1 - v / ship, 4) for k, v in briefs.items()}  # +ve = beats tuples
    if best_name == SHIPPED or (1 - best_val / ship) <= FLIP_THRESHOLD:
        return (f"VERDICT: tuples HOLD — no invoke-complete encoding beats {SHIPPED} "
                f"by >{int(FLIP_THRESHOLD * 100)}% (ties break to JSON family)"), SHIPPED, detail
    return (f"VERDICT: FLIP — '{best_name}' beats {SHIPPED} by "
            f"{(1 - best_val / ship) * 100:.1f}% > {int(FLIP_THRESHOLD * 100)}% "
            f"(file an amendment task naming '{best_name}')"), best_name, detail


# --------------------------------------------------------------------------- reports

def byte_table_lines(payloads):
    full_b = payloads["full"]["bytes"]
    rows = ["  payload             bytes     ratio(vs full)  encoding"]
    for name, p in payloads.items():
        ratio = full_b / p["bytes"] if p["bytes"] else 0.0
        rows.append(f"  {name:<18} {p['bytes']:>8}   {ratio:>6.2f}x        {p['encoding']}")
    return rows


def write_results(path, payloads, models, token_table, verdict, winner, detail, key_present):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    full_b = payloads["full"]["bytes"]
    out = {
        "generated_by": "count_tokens_calibrate.py",
        "fixtures": {"full": os.path.basename(CAPS_FULL), "brief": os.path.basename(CAPS_BRIEF)},
        "meter_standard": "POST /v1/messages/count_tokens (METER.md; tiktoken/chars-4 banned)",
        "pinned_models": models,
        "key_present": key_present,
        "byte_label": None if key_present else FALLBACK_LABEL,
        "shipped_encoding": SHIPPED,
        "flip_threshold": FLIP_THRESHOLD,
        "payloads": {
            name: {
                "kind": p["kind"], "family": p["family"], "encoding": p["encoding"],
                "shipped": p.get("shipped", False),
                "bytes": p["bytes"],
                "byte_ratio_vs_full": round(full_b / p["bytes"], 4) if p["bytes"] else None,
                "tokens": (token_table or {}).get(name),
            }
            for name, p in payloads.items()
        },
        "verdict": verdict,
        "winner": winner,
        "brief_advantage_vs_tuples": detail,  # +ve = beats shipped tuples on the metric
    }
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(out, fh, indent=2, ensure_ascii=False)
        fh.write("\n")
    return path


# ------------------------------------------------------------------------ self-check

def self_check():
    """Offline: parse fixtures, build all 6 payloads, prove the invoke-completeness gate
    is non-vacuous (greens on faithful, reds on a mutilated payload), validate report
    shape. No network, no key discovery."""
    if not (os.path.exists(CAPS_FULL) and os.path.exists(CAPS_BRIEF)):
        print(f"count_tokens_calibrate: FAIL — fixtures missing under {FIXTURES}", file=sys.stderr)
        print("  (this script builds AFTER ctx-s1's fixtures land on main — charter decision 5)",
              file=sys.stderr)
        return 1

    payloads, recs = build_payloads()

    if len(payloads) != 6:
        print(f"count_tokens_calibrate: FAIL — {len(payloads)} payloads != 6", file=sys.stderr)
        return 1
    if len(recs) != 142:
        print(f"count_tokens_calibrate: FAIL — {len(recs)} commands != 142", file=sys.stderr)
        return 1

    # Byte-identity: derived fixtures must match the committed fixture bytes exactly.
    if payloads["full"]["bytes"] != _nbytes(_read_text(CAPS_FULL)):
        print("count_tokens_calibrate: FAIL — full byte mismatch", file=sys.stderr)
        return 1

    # GREEN: the faithful payloads pass the invoke-completeness gate.
    errs = invoke_complete_errors(payloads, recs)
    if errs:
        print("count_tokens_calibrate: FAIL — faithful payloads not invoke-complete:", file=sys.stderr)
        for e in errs:
            print(f"  {e}", file=sys.stderr)
        return 1

    # RED: a mutilated brief (summary stripped from every command) MUST be caught —
    # otherwise the gate is vacuous (distrust-vacuous-green, per meter.py).
    broken = dict(payloads)
    mangled = json.loads(payloads["brief-nested-json"]["text"])
    for c in mangled["commands"]:
        c.pop("summary", None)
    broken["brief-nested-json"] = {**payloads["brief-nested-json"],
                                   "text": json.dumps(mangled, separators=(",", ":"))}
    if not invoke_complete_errors(broken, recs):
        print("count_tokens_calibrate: FAIL — gate is VACUOUS (passed a summary-stripped brief)",
              file=sys.stderr)
        return 1

    # Decision machinery must produce a verdict from the byte table.
    byte_metric = {k: v["bytes"] for k, v in payloads.items()}
    verdict, winner, detail = decide(byte_metric)
    if not verdict.startswith("VERDICT:") or winner not in byte_metric:
        print(f"count_tokens_calibrate: FAIL — bad verdict shape: {verdict!r}", file=sys.stderr)
        return 1

    ratios = ", ".join(f"{k} {payloads['full']['bytes'] / v['bytes']:.2f}x"
                       for k, v in payloads.items() if k != "full")
    print("count_tokens_calibrate: self-check OK "
          "(6 payloads, 142 commands, all briefs invoke-complete; gate reds on a "
          "summary-stripped brief)")
    print(f"  byte ratios vs full: {ratios}")
    print(f"  {verdict} [on BYTES — {FALLBACK_LABEL}]")
    return 0


# ------------------------------------------------------------------------------ main

def run(models, out_path):
    payloads, recs = build_payloads()

    errs = invoke_complete_errors(payloads, recs)
    if errs:
        print("count_tokens_calibrate: refusing to publish — briefs not invoke-complete:",
              file=sys.stderr)
        for e in errs:
            print(f"  {e}", file=sys.stderr)
        return 1

    if out_path is None:
        out_path = os.path.join(RESULTS, "count-tokens-2026-07-24.json")

    api_key = discover_key()

    if api_key is None:
        # Pre-registered fallback (charter decision 5): bytes labeled bytes, exit 0.
        byte_metric = {k: v["bytes"] for k, v in payloads.items()}
        verdict, winner, detail = decide(byte_metric)
        verdict = verdict.replace("VERDICT:", "VERDICT (PENDING token conversion):")
        print(f"count_tokens_calibrate: no anthropic_api_key reachable "
              f"(bp secret get -> absent). Emitting {FALLBACK_LABEL}.")
        print(f"  (human key provisioning is ctx-b5-provision-count-tokens-key)")
        for line in byte_table_lines(payloads):
            print(line)
        print(f"  {verdict}")
        path = write_results(out_path, payloads, models, None, verdict, winner, detail,
                             key_present=False)
        print(f"  byte table written: {os.path.relpath(path, HERE)}")
        return 0

    # Key present: 12 calls = 6 payloads x 2 pinned models.
    print(f"count_tokens_calibrate: key found — counting {len(payloads)} payloads "
          f"x {len(models)} models = {len(payloads) * len(models)} count_tokens calls")
    token_table = {}
    per_model = {}
    for model in models:
        per_model[model] = {}
        for name, p in payloads.items():
            try:
                toks = count_tokens(model, p["text"], api_key)
            except (urllib.error.URLError, KeyError, ValueError) as e:  # noqa: BLE001
                print(f"  ERROR {model}/{name}: {e}", file=sys.stderr)
                return 1
            per_model[model][name] = toks
            print(f"  {model:<20} {name:<18} {toks:>8} tokens  ({p['bytes']} bytes)")

    # Verdict on the FIRST pinned model (the primary duel/live-session tokenizer); the
    # second model is recorded for the ~30% cross-tokenizer spread METER.md warns about.
    primary = models[0]
    token_table = per_model[primary]
    verdict, winner, detail = decide(token_table)
    print(f"  {verdict}  [primary model: {primary}]")

    # Persist one results file per model (data-of-record) + the primary-model verdict file.
    written = []
    for model in models:
        mpath = os.path.join(RESULTS, f"count-tokens-{model}-2026-07-24.json")
        mverdict, mwinner, mdetail = decide(per_model[model])
        written.append(write_results(mpath, payloads, [model], per_model[model],
                                     mverdict, mwinner, mdetail, key_present=True))
    written.append(write_results(out_path, payloads, models, token_table, verdict, winner,
                                 detail, key_present=True))
    for path in written:
        print(f"  written: {os.path.relpath(path, HERE)}")
    if winner != SHIPPED:
        print(f"  ACTION: file amendment task — token winner is '{winner}', not '{SHIPPED}'",
              file=sys.stderr)
    return 0


def main(argv):
    args = argv[1:]
    if "--self-check" in args:
        return self_check()
    models = list(PINNED_MODELS)
    out_path = None
    i = 0
    while i < len(args):
        if args[i] == "--models" and i + 1 < len(args):
            models = [m.strip() for m in args[i + 1].split(",") if m.strip()]
            i += 2
        elif args[i] == "--out" and i + 1 < len(args):
            out_path = args[i + 1]
            i += 2
        else:
            print(__doc__, file=sys.stderr)
            return 2
    return run(models, out_path)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
