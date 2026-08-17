#!/usr/bin/env bash
# leakage-audit.sh — did the cold agent stay cold? Audit a run transcript for
# reads that leak warm context. (ledger: pe-w7-cold-harness leakage row)
#
#   bash tooling/paper-excellence/harness/leakage-audit.sh <transcript.jsonl>
#   bash tooling/paper-excellence/harness/leakage-audit.sh --selftest
#
# The coldness protocol (spawn-cold.sh) fences the ENVIRONMENT; this audit
# fences BEHAVIOUR. A cold agent authoring a premium paper should read only:
#
#   * the published guide it was pointed at (paper-authoring-excellence), and
#   * the reference papers THAT GUIDE itself sanctions — the slugs the guide
#     demonstrates reading (its /papers/<slug> mentions and its `bp paper view`
#     / `bp doc get` / `bp paper pull <slug>` examples). The allowlist is
#     DERIVED FROM THE LIVE GUIDE TEXT at run time, never hard-coded — so when
#     the guide changes which examples it teaches, the audit follows.
#   * verb-only reads with no slug: `bp capabilities` and `bp doc ls tag` (the
#     tag registry the wall demands) are always sanctioned.
#
# Anything else is leakage. Two failure classes:
#
#   HARD FAIL (regardless of slug):  `bp search …`  or  `bp task …`
#     — a cold author does not query the ledger or full-text index; those are
#       the warm-agent tells this epic hunts. Their mere presence fails.
#   LEAK:  a slug-bearing read (`bp paper view/pull <slug>`, `bp doc get
#     <type> <slug>`) whose slug is NOT in {guide slug} ∪ {guide-derived
#     allowlist}.
#
# Writes are never leakage: `bp paper new/push`, `bp bulldocs publish`,
# `bp media upload` are how the agent PRODUCES the paper.
#
# --selftest proves the audit can lose: it runs against a built-in leaky
# transcript (must fail) and a built-in clean one (must pass). An audit that
# cannot fail is not an audit.
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUIDE_SLUG="${GUIDE_SLUG:-paper-authoring-excellence}"
BP="${BP:-bp}"

audit() {  # audit <transcript> <guide-text-file>
  TRANSCRIPT="$1" GUIDE_TEXT="$2" python3 - "$GUIDE_SLUG" <<'PY'
import json, os, re, sys

guide_slug = sys.argv[1]
transcript = os.environ["TRANSCRIPT"]
guide_text = open(os.environ["GUIDE_TEXT"], encoding="utf-8", errors="replace").read()

SLUG = r"[a-z][a-z0-9]*(?:-[a-z0-9]+){1,}"

# --- allowlist DERIVED from the live guide -------------------------------
allow = {guide_slug}
# slugs the guide points a reader at: /papers/<slug> and the read examples.
for m in re.finditer(r"/papers/(" + SLUG + r")", guide_text):
    allow.add(m.group(1))
for m in re.finditer(r"bp\s+paper\s+(?:view|pull)\s+(" + SLUG + r")", guide_text):
    allow.add(m.group(1))
for m in re.finditer(r"bp\s+doc\s+get\s+\w+\s+(" + SLUG + r")", guide_text):
    allow.add(m.group(1))
# the scaffold example `bp paper new my-paper` names a WRITE target, not a read.

# --- every shell command the agent ran, pulled from the stream -----------
cmds = []
def walk(o):
    if isinstance(o, dict):
        # a Bash tool_use carries {"name":"Bash","input":{"command":"…"}}
        if o.get("name") == "Bash" and isinstance(o.get("input"), dict):
            c = o["input"].get("command")
            if isinstance(c, str):
                cmds.append(c)
        for v in o.values():
            walk(v)
    elif isinstance(o, list):
        for v in o:
            walk(v)

with open(transcript, encoding="utf-8", errors="replace") as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            walk(json.loads(line))
        except json.JSONDecodeError:
            # a non-JSON line is itself suspicious, but never a false PASS:
            # scan its text for bp calls too.
            cmds.append(line)

failures = []
bp_reads = []

# A bp invocation may be bare (`bp …`, PATH) or path-prefixed (`/x/.bin/bp …`,
# `./bp …`) — the cold prompt hands the agent the binary's ABSOLUTE path, so an
# audit gated on bare `bp ` alone would miss every call and pass vacuously.
BP_CALL = re.compile(r"(?:^|[^\w.-])(?:\S*/)?bp\s+([a-z-]+)(?:\s+([a-z-]+))?(.*)$")

def split_parts(cmd):
    for part in re.split(r"&&|\|\||;|\|", cmd):
        yield part.strip()

# D50 sanctions "the agent's OWN created slug(s)" — the M3 read-back is a rubric
# REQUIREMENT, so a slug this transcript itself creates/pushes is sanctioned for
# reads. (Pushing onto a foreign existing slug is refused by the rev guard and
# the wall; it cannot launder a warm slug into the allowlist in practice, and
# any such write would be visible in the transcript regardless.)
own_slugs = set()
for cmd in cmds:
    for part in split_parts(cmd):
        m = BP_CALL.search(part)
        if m and m.group(1) == "paper" and (m.group(2) or "") in ("new", "push"):
            sm = re.search(SLUG, m.group(3) or "")
            if sm:
                own_slugs.add(sm.group(0))
allow |= own_slugs

# split compound commands so `x && bp search y` is still caught.
for cmd in cmds:
    for part in split_parts(cmd):
        m = BP_CALL.search(part)
        if not m:
            continue
        verb, sub, rest = m.group(1), (m.group(2) or ""), (m.group(3) or "")
        # HARD FAIL verbs — warm-agent tells.
        if verb in ("search", "task"):
            failures.append("HARD FAIL — `bp %s%s` (a cold author never queries the ledger/index): %s"
                            % (verb, (" " + sub) if sub else "", part))
            continue
        # slug-bearing reads.
        slug = None
        if verb == "paper" and sub in ("view", "pull"):
            sm = re.search(SLUG, rest)
            slug = sm.group(0) if sm else None
        elif verb == "doc" and sub == "get":
            sm = re.search(r"\w+\s+(" + SLUG + r")", rest)
            slug = sm.group(1) if sm else None
        if slug is not None:
            bp_reads.append((slug, part))
            if slug not in allow:
                failures.append("LEAK — read of un-sanctioned slug `%s`: %s" % (slug, part))

print("leakage-audit: guide-derived allowlist (%d): %s" % (len(allow), ", ".join(sorted(allow))))
print("leakage-audit: own created/pushed slug(s) sanctioned (%d): %s"
      % (len(own_slugs), ", ".join(sorted(own_slugs)) or "(none)"))
print("leakage-audit: slug-bearing reads seen (%d): %s"
      % (len(bp_reads), ", ".join(sorted({s for s, _ in bp_reads})) or "(none)"))
if failures:
    print("leakage-audit: FAIL — %d finding(s):" % len(failures))
    for f in failures:
        print("  " + f)
    sys.exit(1)
print("leakage-audit: PASS — every read is sanctioned; no bp search / bp task")
PY
}

if [ "${1:-}" = "--selftest" ]; then
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  # A guide text the derivation can read: it sanctions two example slugs.
  cat > "$TMP/guide.txt" <<'EOF'
The paper renders live at /papers/paper-excellence-wave-2026-08-17.
For a render-only example see bp paper view eight-minute-erasure.
EOF
  # CLEAN: reads only the sanctioned slugs + capabilities + doc ls tag.
  cat > "$TMP/clean.jsonl" <<'EOF'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"bp capabilities -o json"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"bp paper view paper-authoring-excellence"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"bp doc ls tag && bp paper view eight-minute-erasure"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"bp paper push my-paper"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"bp paper pull my-paper"}}]}}
EOF
  # LEAKY: a bp search, a read of an un-sanctioned slug, and the same two
  # smuggled through the binary's ABSOLUTE path (the cold prompt hands the
  # agent that path, so path-prefixed calls are the likely spelling).
  cat > "$TMP/leaky.jsonl" <<'EOF'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"bp search wave 6 grade"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"bp doc get paper heggemsnes-act -o json"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"/tmp/harness/.bin/bp task ready"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"/tmp/harness/.bin/bp paper view paper-excellence-wave-7-2026-08-17"}}]}}
EOF
  echo "== selftest: CLEAN transcript should PASS =="
  audit "$TMP/clean.jsonl" "$TMP/guide.txt"; CLEAN_RC=0
  echo "== selftest: LEAKY transcript should FAIL with all 4 findings =="
  set +e
  LEAKY_OUT="$(audit "$TMP/leaky.jsonl" "$TMP/guide.txt")"
  LEAKY_RC=$?
  set -e
  echo "$LEAKY_OUT"
  if [ "$LEAKY_RC" -eq 0 ]; then
    echo "leakage-audit: SELFTEST FAIL — the leaky transcript was not caught" >&2
    exit 1
  fi
  # All four must be caught INDIVIDUALLY — two bare, two path-prefixed — or a
  # spelling class is invisible and the audit passes vacuously on it.
  if ! printf '%s' "$LEAKY_OUT" | grep -q "FAIL — 4 finding"; then
    echo "leakage-audit: SELFTEST FAIL — expected exactly 4 findings (2 bare + 2 path-prefixed); a spelling class slipped" >&2
    exit 1
  fi
  echo "leakage-audit: SELFTEST PASS — clean passes (incl. own-slug read-back), leaky fails on all 4 (incl. path-prefixed bp)"
  exit 0
fi

TRANSCRIPT="${1:?usage: leakage-audit.sh <transcript.jsonl> | --selftest}"
[ -f "$TRANSCRIPT" ] || { echo "leakage-audit: no transcript at $TRANSCRIPT" >&2; exit 2; }

# Pull the live guide text — the allowlist is derived from it, never committed.
GUIDE_TEXT="$(mktemp)"
trap 'rm -f "$GUIDE_TEXT"' EXIT
"$BP" paper view "$GUIDE_SLUG" > "$GUIDE_TEXT" 2>/dev/null || {
  echo "leakage-audit: FAIL — could not fetch the live guide ($GUIDE_SLUG) to derive the allowlist" >&2
  exit 2
}

audit "$TRANSCRIPT" "$GUIDE_TEXT"
