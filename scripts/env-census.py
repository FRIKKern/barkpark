#!/usr/bin/env python3
"""env-census — derive the env-var census from Elixir sources and diff it against compose.

Self-host-blessing epic, wave 1 / S1 (charter decisions D14, D15, D24).

Why this exists
---------------
The compose install passed 10 of ~105 env names the api actually reads, and the
gap was invisible because every prior count was a hand-written number in a doc.
The Definition of Done for the passthrough allowlist is therefore SCRIPT-DERIVED,
never a literal quoted from a paper (D14): re-run this, read the number it prints.

Contract (D15)
--------------
1. Census is DERIVED, never hand-listed: every ``System.get_env/fetch_env!`` in a
   root's ``config/runtime.exs`` + ``lib/**`` is a census member.
2. FAIL CLOSED: any call site whose argument is not a double-quoted literal must
   have a hand-declared resolution keyed by (file, argument-expression-as-written).
   An undeclared dynamic site EXITS NON-ZERO naming file, line and argument --
   that is the script's own mutation proof, and it is what stops the census from
   quietly going stale when someone adds a computed read.
3. Compose diff is SCOPED PER ENVIRONMENT LIST, not whole-file: root
   ``docker-compose.yml`` service ``api``, ``cloud/docker-compose.yml`` anchor
   ``x-control-plane``. Whole-file matching false-positives on the ``postfix``
   sidecar's DKIM/MAIL vars, which no Elixir ever reads.
4. Names read by code but absent from that list FAIL, unless they are on the
   EXEMPT table -- which carries a dated reason per entry.
5. Duplicate keys inside one environment list are REFUSED: compose silently keeps
   the last one, so a duplicate is an edit that looks applied and is not.
6. Bare passthrough only. ``- NAME=${NAME:-default}`` converts "unset" into "set
   to something", which is a DIFFERENT server-side meaning. On the five secrets
   and on the BARKPARK_PLUGINS kill switch that is a HARD FAIL (D24); elsewhere
   it is a WARN unless the name is on the DEFAULTS_OK allowlist.
7. ENV-shadow assertion: an ``ENV NAME=`` line in ``api/Dockerfile`` that names a
   census member makes the var permanently "set" inside the image, so compose
   passthrough of an unset shell var cannot reach the code and a boot-time
   presence check passes on a baked placeholder. Allowlisted names carry a dated
   reason, same rule as EXEMPT.

Stdlib only, on purpose: this runs in CI with no pip step.

Usage
-----
    python3 scripts/env-census.py --root cloud
    python3 scripts/env-census.py --root api
    python3 scripts/env-census.py --root both --no-compose   # census only
    python3 scripts/env-census.py --tree /some/checkout --root api
"""

import argparse
import os
import re
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# ─────────────────────────────────────────────────────────────────────────────
# Call-site extraction
# ─────────────────────────────────────────────────────────────────────────────

# Matches System.get_env( / System.fetch_env( / System.fetch_env!( and captures
# everything up to the first comma or close paren -- the FIRST argument as written.
CALL_RE = re.compile(r"System\.(?:get_env|fetch_env!?)\(([^,)]*)")
LITERAL_RE = re.compile(r'^"([A-Za-z_][A-Za-z0-9_]*)"$')


def scan_sources(files):
    """Return (literals: set[str], dynamic: list[(path, lineno, argexpr, rawline)])."""
    literals, dynamic = set(), []
    for path in files:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for lineno, line in enumerate(fh, 1):
                stripped = line.strip()
                if stripped.startswith("#"):
                    continue  # a commented-out call is not a read
                for m in CALL_RE.finditer(line):
                    arg = m.group(1).strip()
                    lit = LITERAL_RE.match(arg)
                    if lit:
                        literals.add(lit.group(1))
                    else:
                        dynamic.append((path, lineno, arg, stripped))
    return literals, dynamic


# ─────────────────────────────────────────────────────────────────────────────
# Hand-declared resolutions for dynamic sites.
# Key: (repo-relative path, argument-expression-as-written).
# Line-number-free ON PURPOSE -- line numbers shift, this survives refactors and
# still fails closed when a NEW dynamic site appears.
# ─────────────────────────────────────────────────────────────────────────────
RESOLUTIONS = {
    ("api/config/runtime.exs", "env_name"): dict(
        why="for-comprehension over a literal 3-tuple list (CycleFleet release capture)",
        names=[
            "BARKPARK_RELEASE_CAPTURE_TOKEN",
            "BARKPARK_RELEASE_CAPTURE_BP_PATH",
            "BARKPARK_DEPLOYMENT_DIGEST",
            # second for-comprehension over the same variable name (runtime.exs
            # ~602, platform operator allowlists). It was written
            # `env_name |> System.get_env("")`, which the census keyed as arg '""'
            # and could not attribute; rewritten to System.get_env(env_name, "")
            # so it lands here (2026-09-03).
            "BARKPARK_OPERATOR_EMAILS",
            "BARKPARK_OPERATOR_TOKEN_IDS",
        ],
    ),
    ("api/config/runtime.exs", "name"): dict(
        why="require_s3 closure; the 4 call sites pass string literals (S3 media backend)",
        names=[
            "BARKPARK_S3_ENDPOINT",
            "BARKPARK_S3_BUCKET",
            "BARKPARK_S3_ACCESS_KEY_ID",
            "BARKPARK_S3_SECRET_ACCESS_KEY",
        ],
    ),
    ("api/config/runtime.exs", "env_var"): dict(
        why="Enum.reduce over a literal keyword list (ticket rate limits)",
        names=[
            "BARKPARK_TICKET_RATE_CREATE",
            "BARKPARK_TICKET_RATE_MESSAGE",
            "BARKPARK_TICKET_RATE_ATTACHMENT",
        ],
    ),
    ("api/lib/barkpark/build_info.ex", "name"): dict(
        why="compile-time `env` closure; callers pass literals (build metadata)",
        names="CALLERS",  # resolved by scanning the closure's own call sites
    ),
    ("api/lib/barkpark/plugins/github/settings.ex", "@intake_workspace_env"): dict(
        why="module attribute, single literal binding in the same module",
        names=["BARKPARK_GITHUB_INTAKE_WORKSPACE_ID"],
    ),
    ("api/lib/barkpark/sites/deploy_runner.ex", "name"): dict(
        why="env_or_nil/1 helper; callers pass literals (site deploy runner)",
        names="CALLERS",
    ),
    # EXEMPT site. Keyed on the EXACT source text of the argument -- the empty
    # string -- so a future `System.get_env(something)` on this same line is a
    # different key and still fails closed.
    ("api/lib/barkpark_web/studio/tmux_console.ex", ""): dict(
        why="EXEMPT: bare System.get_env() reads the WHOLE environment to seed a "
        "tmux child process; it names no variable, so it contributes no census "
        "member (2026-08-08)",
        names=[],
    ),
}

# Closures whose members are found by grepping the closure name's call sites.
CALLER_PATTERNS = {
    "api/lib/barkpark/build_info.ex": r'\benv\.\("([A-Z_][A-Z0-9_]*)"\)',
    "api/lib/barkpark/sites/deploy_runner.ex": r'\benv_or_nil\("([A-Z_][A-Z0-9_]*)"\)',
}

# ─────────────────────────────────────────────────────────────────────────────
# Exempt list -- read by code, legitimately NOT passed through compose.
# Every entry carries a DATED reason. An unexplained absence is a FAILURE.
# ─────────────────────────────────────────────────────────────────────────────
EXEMPT = {
    "PATH": "OS-provided; the container image supplies it (2026-08-08)",
    "HOME": "OS-provided (2026-08-08)",
    "USER": "OS-provided (2026-08-08)",
    "TERM": "OS/tty-provided (2026-08-08)",
    "SHELL": "OS-provided (2026-08-08)",
    "PWD": "OS-provided (2026-08-08)",
    "BARKPARK_HOME": "CLI/TUI-side var; the server container never sets it (2026-08-08)",
    "BARKPARK_ENV": "dev/test-only selector; prod containers are prod by construction (2026-08-08)",
    "BARKPARK_DEV_DATABASE": "dev-only convenience for the local Postgres name (2026-08-08)",
    "MIX_ENV": "baked into the release at build time; not a runtime knob (2026-08-08)",
    "RELEASE_NODE": "set by the OTP release boot scripts (2026-08-08)",
    "RELEASE_COOKIE": "set by the OTP release boot scripts (2026-08-08)",
    "PHX_SERVER": "set by the Dockerfile/release; not an operator knob (2026-08-08)",
    # Build/deploy internals — the D15 ratified baseline, reason "not an
    # operator knob": read by build_info.ex / sites/deploy_runner.ex for build
    # metadata and the site-build lock path, set by build tooling, never by a
    # compose operator.
    "TMPDIR": "OS/build-tooling temp dir; deploy_runner lock-path fallback, not an operator knob (2026-08-08)",
    "BARKPARK_BUILD_GATE_LOCK": "site-build lock path override for deploy tooling; not an operator knob (2026-08-08)",
    "BARKPARK_BUILD_VERSION": "build-metadata bake for docker/tarball builds; not an operator knob (2026-08-08)",
    "BARKPARK_BUILD_COMMIT": "build-metadata bake for docker/tarball builds; not an operator knob (2026-08-08)",
    "BARKPARK_BUILD_DATE": "build-metadata bake for docker/tarball builds; not an operator knob (2026-08-08)",
    "CI": "CI-only (2026-08-08)",
    "GITHUB_ACTIONS": "CI-only (2026-08-08)",
    "GITHUB_TOKEN": "CI-only (2026-08-08)",
}

# ─────────────────────────────────────────────────────────────────────────────
# `:-` default policy (D24).
# HARD_FAIL: a default here changes what "unset" MEANS on a security boundary.
#   - the five secrets: a default boots a box on a value nobody chose.
#   - BARKPARK_PLUGINS: the kill switch. `${BARKPARK_PLUGINS:-}` sets it to the
#     empty string, which is "load NO plugins", not "load the default set".
# ─────────────────────────────────────────────────────────────────────────────
HARD_FAIL_DEFAULTS = {
    "SECRET_KEY_BASE",
    "BARKPARK_CLOAK_KEY",
    "BARKPARK_KEK",
    "PREVIEW_JWT_SECRET",
    "BARKPARK_RELEASE_CAPTURE_HMAC_SECRET",
    "BARKPARK_PLUGINS",
}

# Names where a compose-side `:-` default is a DECLARED, reviewed choice: the
# value is non-secret, and "unset" and "the default" mean the same thing.
DEFAULTS_OK = {
    "DATABASE_URL": "points at the bundled db service; override for external PG (2026-08-08)",
    "PORT": "the container's own listen port, not an operator secret (2026-08-08)",
    "POOL_SIZE": "Ecto pool size; runtime.exs has the same default (2026-08-08)",
    "OAUTH_BASE_URL": "public callback base; the compose default is the real one (2026-08-08)",
    "SMTP_HOST": "the bundled postfix sidecar's compose hostname (2026-08-08)",
    "SMTP_PORT": "submission port 587 (2026-08-08)",
    "SMTP_VERIFY_PEER": "false for the in-network hop to the postfix sidecar (2026-08-08)",
    "MAIL_FROM_ADDRESS": "non-secret display value (2026-08-08)",
    "MAIL_FROM_NAME": "non-secret display value (2026-08-08)",
    "TRUSTED_PROXY_PEERS": "must track the pinned subnet's .1 gateway (2026-08-08)",
    "PHX_HOST": "self-host default; S1a converts this to a :? require (2026-08-08)",
    "BARKPARK_SEED_PROFILE": "compose deliberately defaults to `clean` (the app-side "
    "default is `demo`, too heavy for a self-host first boot) — reviewed choice, "
    "S1a (2026-08-08)",
}

# ─────────────────────────────────────────────────────────────────────────────
# Dockerfile ENV-shadow allowlist (D15 assertion 4). Anything else that both
# appears as `ENV NAME=` in api/Dockerfile AND is a census member is a FAILURE:
# the baked value makes the var permanently set inside the image, so an unset
# shell var never reaches the code and a presence check passes on a placeholder.
# ─────────────────────────────────────────────────────────────────────────────
DOCKERFILE_ENV_OK = {
    "MIX_ENV": "build-stage only; the release is compiled prod by construction (2026-08-08)",
    "BARKPARK_SKIP_IMAGE": "build-stage ARG passthrough, never read at runtime (2026-08-08)",
    "PHX_SERVER": "image self-description: this image IS the server (2026-08-08)",
    "PORT": "the port the image listens on; compose publishes the same one and no "
            "secret is involved (2026-08-08)",
}


def resolve_dynamic(root_dir, dynamic):
    """Return (resolved_names, undeclared_sites)."""
    resolved, undeclared = set(), []
    for path, lineno, arg, raw in dynamic:
        rel = os.path.relpath(path, root_dir).replace(os.sep, "/")
        key = (rel, arg)
        entry = RESOLUTIONS.get(key)
        if entry is None:
            undeclared.append((rel, lineno, arg, raw))
            continue
        names = entry["names"]
        if names == "CALLERS":
            pat = CALLER_PATTERNS.get(rel)
            if not pat:
                undeclared.append((rel, lineno, arg, "CALLERS declared but no pattern"))
                continue
            with open(path, "r", encoding="utf-8", errors="replace") as fh:
                found = set(re.findall(pat, fh.read()))
            if not found:
                undeclared.append((rel, lineno, arg, "CALLERS pattern matched nothing"))
                continue
            resolved |= found
        else:
            resolved |= set(names)
    return resolved, undeclared


# ─────────────────────────────────────────────────────────────────────────────
# Compose environment-block extraction (indentation scanner, no YAML dep)
# ─────────────────────────────────────────────────────────────────────────────

def compose_env_block(path, anchor_re):
    """Names in the `environment:` list under the block matching anchor_re.

    Returns (bare: set[str], defaulted: dict[name -> rhs], duplicates: list[(name, lineno)]).
    Duplicates are reported because compose silently keeps the LAST occurrence --
    an edit to the first one looks applied and does nothing.
    """
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        lines = fh.read().splitlines()

    anchor = re.compile(anchor_re)
    start = None
    for i, line in enumerate(lines):
        if anchor.match(line):
            start = i
            break
    if start is None:
        raise SystemExit(f"FAIL: anchor {anchor_re!r} not found in {path}")

    anchor_indent = len(lines[start]) - len(lines[start].lstrip())

    env_at = None
    for i in range(start + 1, len(lines)):
        line = lines[i]
        if not line.strip() or line.strip().startswith("#"):
            continue
        indent = len(line) - len(line.lstrip())
        if indent <= anchor_indent:
            break  # left the block without finding environment:
        if line.strip() == "environment:":
            env_at = i
            break
    if env_at is None:
        raise SystemExit(f"FAIL: no environment: block under {anchor_re!r} in {path}")

    env_indent = len(lines[env_at]) - len(lines[env_at].lstrip())
    bare, defaulted, duplicates = set(), {}, []
    seen = {}
    for offset, line in enumerate(lines[env_at + 1:], env_at + 2):
        if not line.strip():
            continue
        indent = len(line) - len(line.lstrip())
        if indent <= env_indent and not line.strip().startswith("#"):
            break
        s = line.strip()
        if s.startswith("#"):
            continue
        if not s.startswith("- "):
            continue
        item = s[2:].strip()
        if "=" in item:
            name, rhs = item.split("=", 1)
            name = name.strip()
            defaulted[name] = rhs
        else:
            name = item
            bare.add(name)
        if name in seen:
            duplicates.append((name, seen[name], offset))
        else:
            seen[name] = offset
    return bare, defaulted, duplicates


def dockerfile_env_names(path):
    """Return [(name, lineno)] for every `ENV NAME=` line in a Dockerfile."""
    out = []
    if not os.path.isfile(path):
        return out
    pat = re.compile(r"^\s*ENV\s+([A-Za-z_][A-Za-z0-9_]*)=")
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for lineno, line in enumerate(fh, 1):
            m = pat.match(line)
            if m:
                out.append((m.group(1), lineno))
    return out


ROOTS = {
    "api": dict(
        sources=["api/config/runtime.exs", "api/lib"],
        compose="docker-compose.yml",
        anchor=r"^  api:\s*$",
        label="root docker-compose.yml service `api`",
        dockerfile="api/Dockerfile",
    ),
    "cloud": dict(
        sources=["cloud/config/runtime.exs", "cloud/lib"],
        compose="cloud/docker-compose.yml",
        anchor=r"^x-control-plane:",
        label="cloud/docker-compose.yml `x-control-plane` anchor",
        dockerfile=None,
    ),
}


def collect_files(root_dir, sources):
    out = []
    for s in sources:
        p = os.path.join(root_dir, s)
        if os.path.isfile(p):
            out.append(p)
        elif os.path.isdir(p):
            for dirpath, _dirs, names in os.walk(p):
                for n in sorted(names):
                    if n.endswith((".ex", ".exs")):
                        out.append(os.path.join(dirpath, n))
        else:
            raise SystemExit(f"FAIL: source path missing: {p}")
    return sorted(out)


def audit_root(tree, name, skip_compose):
    """Run one root's census + compose diff. Returns 0 on pass, 1 on failure."""
    cfg = ROOTS[name]
    rc = 0

    files = collect_files(tree, cfg["sources"])
    literals, dynamic = scan_sources(files)
    resolved, undeclared = resolve_dynamic(tree, dynamic)

    print(f"══ root: {name} ══ ({len(files)} source files scanned)")
    print(f"  literal call sites .......... {len(literals)} unique names")
    print(f"  dynamic call sites .......... {len(dynamic)} ({len(undeclared)} UNDECLARED)")
    print(f"  names recovered from those .. {len(resolved)}")

    if undeclared:
        rc = 1
        print("  ✗ FAIL-CLOSED: undeclared dynamic System.get_env/fetch_env site(s):")
        for rel, lineno, arg, raw in undeclared:
            print(f"      {rel}:{lineno}  arg={arg!r}")
            print(f"        {raw[:110]}")
        print("    Declare each in RESOLUTIONS (file, arg-expression) with the "
              "names it can read, or mark it exempt with a dated reason.")

    census = literals | resolved
    print(f"  CENSUS (canonical denominator) = {len(census)}")

    if skip_compose:
        print()
        return rc

    compose_path = os.path.join(tree, cfg["compose"])
    bare, defaulted, duplicates = compose_env_block(compose_path, cfg["anchor"])
    passed = bare | set(defaulted)
    print(f"  compose ({cfg['label']}): {len(passed)} passed "
          f"({len(bare)} bare, {len(defaulted)} with =rhs)")

    if duplicates:
        rc = 1
        print(f"  ✗ DUPLICATE key(s) in one environment list ({len(duplicates)}) — "
              "compose keeps the LAST, so the first edit is a silent no-op:")
        for dup, first, second in duplicates:
            print(f"      - {dup}: first at {cfg['compose']}:{first}, again at :{second}")

    missing = sorted(n for n in census - passed if n not in EXEMPT)
    exempted = sorted(n for n in census - passed if n in EXEMPT)
    extra = sorted(passed - census)

    print(f"  exempt-and-absent ........... {len(exempted)}")
    print(f"  MISSING from compose ........ {len(missing)}")
    if missing:
        rc = 1
        for n in missing:
            print(f"      - {n}")
    print(f"  ARITHMETIC: census {len(census)} = passed-and-read "
          f"{len(census & passed)} + exempt-absent {len(exempted)} + missing {len(missing)}")
    assert len(census) == len(census & passed) + len(exempted) + len(missing)
    if extra:
        print(f"  passed but never read (check for typos/rename): {len(extra)}")
        for n in extra:
            print(f"      ~ {n}")

    # Bare-passthrough law (D24): a `:-` default is a semantic change, and on a
    # secret or on the plugin kill switch it is a hard failure.
    hard = sorted(n for n, rhs in defaulted.items()
                  if ":-" in rhs and n in HARD_FAIL_DEFAULTS)
    warn = sorted(n for n, rhs in defaulted.items()
                  if ":-" in rhs and n in census
                  and n not in HARD_FAIL_DEFAULTS and n not in DEFAULTS_OK)
    if hard:
        rc = 1
        print(f"  ✗ `:-` DEFAULT ON A SECRET / KILL SWITCH ({len(hard)}) — "
              "this boots a box on a value nobody chose:")
        for n in hard:
            print(f"      - {n}={defaulted[n]}")
    if warn:
        print(f"  WARN `:-` default on a read knob, not on DEFAULTS_OK ({len(warn)}): "
              + ", ".join(warn))

    # ENV-shadow assertion.
    if cfg["dockerfile"]:
        shadows = [(n, ln) for n, ln in dockerfile_env_names(os.path.join(tree, cfg["dockerfile"]))
                   if n in census and n not in DOCKERFILE_ENV_OK]
        if shadows:
            rc = 1
            print(f"  ✗ Dockerfile ENV SHADOW ({len(shadows)}) in {cfg['dockerfile']} — "
                  "a baked value makes the var permanently set in the image, so "
                  "compose passthrough of an unset shell var never reaches the code:")
            for n, ln in shadows:
                print(f"      - {cfg['dockerfile']}:{ln}  ENV {n}=…")

    print()
    return rc


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--tree", default=REPO_ROOT,
                    help="checkout root holding api/ and cloud/ (default: this repo)")
    ap.add_argument("--root", choices=["api", "cloud", "both"], default="both")
    ap.add_argument("--no-compose", action="store_true", help="census only, skip compose diff")
    args = ap.parse_args()

    roots = ["api", "cloud"] if args.root == "both" else [args.root]
    rc = 0
    for name in roots:
        rc |= audit_root(args.tree, name, args.no_compose)

    print("RESULT:", "PASS" if rc == 0 else "FAIL")
    return rc


if __name__ == "__main__":
    sys.exit(main())
