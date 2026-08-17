#!/usr/bin/env bash
# leakage-audit.sh — did the cold agent stay cold? Audit a run transcript for
# reads that leak warm context. (ledger: pe-w7-cold-harness leakage row;
# widened by pe-w8-leakage-audit-hardening)
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
# Anything else is leakage. The detected surface (one channel per class):
#
#   hard-fail:   `bp search …` or `bp task …` — a cold author does not query
#                the ledger or full-text index; their mere presence fails.
#   slug-read:   `bp paper view/pull <slug>` / `bp doc get <type> <slug>`
#                whose slug is NOT in {guide slug} ∪ {guide-derived allowlist}
#                ∪ {slugs this transcript itself creates/pushes}.
#   doc-query:   `bp doc query …` — a slug it names is checked against the
#                allowlist; a slug-less or un-parseable query over any type
#                but `tag` is itself a finding (a content read we cannot
#                bound).
#   revision:    `bp doc revision <rev-id>` — full content by revision id;
#                revision ids cannot be mapped to sanctioned slugs, so any
#                use is a finding.
#   graph:       `bp doc backlinks/related/history …` — slug reads, same
#                allowlist rule; no parseable slug is itself a finding.
#   capture:     `bp paper capture <url>` — renders a paper by URL; always a
#                finding.
#   discovery:   `bp doc ls <type>` for any type other than `tag` — slug
#                ENUMERATION composes with the read verbs into a complete
#                warm-read path, so it is its own finding class. Verb-only
#                `bp doc ls tag` stays sanctioned.
#   http:        a non-bp HTTP fetch (curl/wget/xh/aria2c/httpie) in Bash
#                that carries the server host or a /papers/ path.
#   non-bash:    ANY non-Bash tool_use block (WebFetch, Read, …) whose input
#                carries the server host or /papers/.
#   indirection: bp reached through a shell variable — an assignment of a
#                path ending in /bp that is later invoked (`B=/x/bp; $B …`),
#                or any `$VAR paper/doc <read-sub-verb> …` call. The finding
#                keeps its base class plus an indirection note.
#
# CONTRACT — this audit PREFERS FALSE POSITIVES OVER SILENCE. Perfect shell
# parsing is not attempted: a command that merely LOOKS like one of the read
# channels above is reported as a finding, each finding names its line, and
# the operator adjudicates. A missed read fails the epic; a spurious finding
# costs one human glance.
#
# Writes are never leakage: `bp paper new/push`, `bp bulldocs publish`,
# `bp media upload` are how the agent PRODUCES the paper.
#
# --selftest proves the audit can lose: it runs against a built-in leaky
# transcript carrying ONE fixture per channel (must fail, with every channel
# marker present — deleting any single detection reds the selftest) and a
# built-in clean one (must pass). An audit that cannot fail is not an audit.
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUIDE_SLUG="${GUIDE_SLUG:-paper-authoring-excellence}"
SERVER_HOST="${SERVER_HOST:-guerrilla.barkpark.cloud}"
BP="${BP:-bp}"

audit() {  # audit <transcript> <guide-text-file>
  TRANSCRIPT="$1" GUIDE_TEXT="$2" SERVER_HOST="$SERVER_HOST" python3 - "$GUIDE_SLUG" <<'PY'
import json, os, re, sys

guide_slug = sys.argv[1]
transcript = os.environ["TRANSCRIPT"]
host = os.environ.get("SERVER_HOST", "guerrilla.barkpark.cloud")
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

# --- every tool_use the agent ran, pulled from the stream ----------------
cmds = []   # Bash commands
tools = []  # (tool-name, serialized input) for every NON-Bash tool_use
def walk(o):
    if isinstance(o, dict):
        # a tool_use carries {"name":"<tool>","input":{…}} — Bash commands are
        # audited as shell text; EVERY other tool's input is scanned for the
        # server host / /papers/ (WebFetch, Read, … are read channels too).
        name = o.get("name")
        if isinstance(name, str) and "input" in o:
            if name == "Bash" and isinstance(o.get("input"), dict):
                c = o["input"].get("command")
                if isinstance(c, str):
                    cmds.append(c)
            elif name != "Bash":
                try:
                    blob = json.dumps(o.get("input"))
                except Exception:
                    blob = str(o.get("input"))
                tools.append((name, blob))
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
CHANNELS = ["hard-fail", "slug-read", "doc-query", "revision", "graph",
            "capture", "discovery", "http", "non-bash", "indirection"]
counts = {c: 0 for c in CHANNELS}
def add(chan, msg):
    counts[chan] += 1
    failures.append(msg)

# A bp invocation may be bare (`bp …`, PATH) or path-prefixed (`/x/.bin/bp …`,
# `./bp …`) — the cold prompt hands the agent the binary's ABSOLUTE path, so an
# audit gated on bare `bp ` alone would miss every call and pass vacuously.
BP_CALL = re.compile(r"(?:^|[^\w.-])(?:\S*/)?bp\s+([a-z-]+)(?:\s+([a-z-]+))?(.*)$")
# bp reached through a shell variable: `$B paper view x`, `"${B}" doc get …`.
VAR_CALL = re.compile(r"(?:^|[\s\"'])\$\{?([A-Za-z_]\w*)\}?[\"']?\s+([a-z-]+)(?:\s+([a-z-]+))?(.*)$")
# assignment (or alias) of something ending in /bp — the indirection source.
ASSIGN = re.compile(r"(?:^|[\s;])(?:alias\s+|export\s+)?([A-Za-z_]\w*)=[\"']?(?:\S*/)?bp[\"']?(?=\s|;|&|$)")
# a non-bp HTTP client at command position (never the URL scheme itself).
HTTP_TOOL = re.compile(r"(?:^|\s)(?:\S*/)?(?:curl|wget|xh|aria2c|httpie)\b|^\s*(?:\S*/)?https?(?=\s)")
# sub-verbs a $VAR call is treated as bp for, even without a seen assignment.
READ_SUBS = {
    "paper": {"view", "pull", "capture", "new", "push"},
    "doc": {"get", "query", "revision", "backlinks", "related", "history", "ls"},
}

def split_parts(cmd):
    for part in re.split(r"&&|\|\||;|\|", cmd):
        yield part.strip()

# pre-pass: collect shell variables assigned a bp path anywhere in the run.
bp_vars = set()
for cmd in cmds:
    for part in split_parts(cmd):
        for m in ASSIGN.finditer(part):
            bp_vars.add(m.group(1))

def parse_call(part):
    """-> (verb, sub, rest, via-var-or-None) for a bp call, direct or indirect."""
    m = BP_CALL.search(part)
    if m:
        return m.group(1), (m.group(2) or ""), (m.group(3) or ""), None
    m = VAR_CALL.search(part)
    if m:
        var, verb, sub, rest = m.group(1), m.group(2), (m.group(3) or ""), (m.group(4) or "")
        if var in bp_vars or (verb in READ_SUBS and sub in READ_SUBS[verb]):
            return verb, sub, rest, var
    return None

# D50 sanctions "the agent's OWN created slug(s)" — the M3 read-back is a rubric
# REQUIREMENT, so a slug this transcript itself creates/pushes is sanctioned for
# reads. (Pushing onto a foreign existing slug is refused by the rev guard and
# the wall; it cannot launder a warm slug into the allowlist in practice, and
# any such write would be visible in the transcript regardless.)
own_slugs = set()
for cmd in cmds:
    for part in split_parts(cmd):
        pc = parse_call(part)
        if pc and pc[0] == "paper" and pc[1] in ("new", "push"):
            sm = re.search(SLUG, pc[2])
            if sm:
                own_slugs.add(sm.group(0))
allow |= own_slugs

# split compound commands so `x && bp search y` is still caught.
for cmd in cmds:
    for part in split_parts(cmd):
        # non-bp HTTP fetch of the server (checked independently of bp calls).
        if HTTP_TOOL.search(part) and (host in part or "/papers/" in part):
            add("http", "HTTP — non-bp fetch of the server host or a /papers/ path: %s" % part)
        pc = parse_call(part)
        if not pc:
            continue
        verb, sub, rest, via = pc
        tail = (" (via $%s indirection — bp reached through a shell variable)" % via) if via else ""
        chan = "indirection" if via else None
        # HARD FAIL verbs — warm-agent tells.
        if verb in ("search", "task"):
            add(chan or "hard-fail",
                "HARD FAIL — `bp %s%s` (a cold author never queries the ledger/index)%s: %s"
                % (verb, (" " + sub) if sub else "", tail, part))
            continue
        # paper capture — renders a paper by URL; always a read finding.
        if verb == "paper" and sub == "capture":
            add(chan or "capture",
                "CAPTURE — `bp paper capture` renders a paper by URL%s: %s" % (tail, part))
            continue
        # doc ls — slug enumeration of any slug-bearing type; only `tag` is verb-only.
        if verb == "doc" and sub == "ls":
            toks = rest.split()
            ltype = toks[0] if toks else ""
            if ltype != "tag":
                add(chan or "discovery",
                    "DISCOVERY — `bp doc ls %s` enumerates slugs of a slug-bearing type%s: %s"
                    % (ltype or "(all)", tail, part))
            continue
        # doc query — the slugs it names are reads; slug-less over non-tag is a
        # content read we cannot bound (un-parseable filter = finding).
        if verb == "doc" and sub == "query":
            toks = rest.split()
            qtype = toks[0] if toks else ""
            slugs = sorted(set(re.findall(SLUG, rest)))
            if slugs:
                for s in slugs:
                    bp_reads.append((s, part))
                    if s not in allow:
                        add(chan or "doc-query",
                            "QUERY LEAK — `bp doc query` names un-sanctioned slug `%s`%s: %s"
                            % (s, tail, part))
            elif qtype != "tag":
                add(chan or "doc-query",
                    "QUERY — slug-less/un-parseable `bp doc query %s` (treated as a content read)%s: %s"
                    % (qtype or "(none)", tail, part))
            continue
        # doc revision — full content by revision id; unmappable to a slug.
        if verb == "doc" and sub == "revision":
            add(chan or "revision",
                "REVISION — `bp doc revision` reads full content by revision id%s: %s" % (tail, part))
            continue
        # doc backlinks/related/history — slug reads on the graph.
        if verb == "doc" and sub in ("backlinks", "related", "history"):
            sm = re.search(SLUG, rest)
            if sm:
                slug = sm.group(0)
                bp_reads.append((slug, part))
                if slug not in allow:
                    add(chan or "graph",
                        "GRAPH — `bp doc %s` of un-sanctioned slug `%s`%s: %s"
                        % (sub, slug, tail, part))
            else:
                add(chan or "graph",
                    "GRAPH — `bp doc %s` without a parseable slug (treated as a read)%s: %s"
                    % (sub, tail, part))
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
                add(chan or "slug-read",
                    "LEAK — read of un-sanctioned slug `%s`%s: %s" % (slug, tail, part))

# non-Bash tools whose input carries the server host or /papers/.
for name, blob in tools:
    if host in blob or "/papers/" in blob:
        add("non-bash",
            "NON-BASH — tool `%s` input carries the server host or /papers/: %s"
            % (name, blob[:200]))

print("leakage-audit: guide-derived allowlist (%d): %s" % (len(allow), ", ".join(sorted(allow))))
print("leakage-audit: own created/pushed slug(s) sanctioned (%d): %s"
      % (len(own_slugs), ", ".join(sorted(own_slugs)) or "(none)"))
print("leakage-audit: slug-bearing reads seen (%d): %s"
      % (len(bp_reads), ", ".join(sorted({s for s, _ in bp_reads})) or "(none)"))
print("leakage-audit: findings by channel: "
      + " ".join("%s=%d" % (c, counts[c]) for c in CHANNELS))
if failures:
    print("leakage-audit: FAIL — %d finding(s):" % len(failures))
    for f in failures:
        print("  " + f)
    sys.exit(1)
print("leakage-audit: PASS — every read is sanctioned; no ledger/index queries, "
      "no enumeration, no raw-HTTP or non-Bash server reads, no indirected bp")
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
  # CLEAN: reads only the sanctioned slugs + capabilities + doc ls tag, plus a
  # non-Bash tool that never touches the server (must NOT be flagged).
  cat > "$TMP/clean.jsonl" <<'EOF'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"bp capabilities -o json"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"bp paper view paper-authoring-excellence"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"bp doc ls tag && bp paper view eight-minute-erasure"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"bp paper push my-paper"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"bp paper pull my-paper"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/tmp/draft.md","content":"a local draft with no server references"}}]}}
EOF
  # LEAKY: ONE fixture per detection channel — the original four (bp search,
  # doc get, path-prefixed task/view) plus the seven channels proven to slip
  # past the 2-verb audit (doc query slug-filter + un-parseable filter, doc
  # revision, backlinks/related/history, paper capture, doc ls paper, raw curl
  # of the server host, a non-Bash WebFetch, and $VAR-indirected bp).
  cat > "$TMP/leaky.jsonl" <<'EOF'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"bp search wave 6 grade"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"bp doc get paper heggemsnes-act -o json"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"/tmp/harness/.bin/bp task ready"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"/tmp/harness/.bin/bp paper view paper-excellence-wave-7-2026-08-17"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"bp doc query paper --filter 'slug==\"paper-excellence-wave-7-2026-08-17\"'"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"bp doc query paper --filter 'title match \"wave grades\"'"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"bp doc revision 9f0c2a1e -o json"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"bp doc backlinks paper heggemsnes-act"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"bp doc related paper heggemsnes-act"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"bp doc history paper heggemsnes-act"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"bp paper capture https://guerrilla.barkpark.cloud/papers/silent-warm-read"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"bp doc ls paper"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"curl -s https://guerrilla.barkpark.cloud/papers/heggemsnes-act"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"WebFetch","input":{"url":"https://guerrilla.barkpark.cloud/papers/heggemsnes-act","prompt":"summarize"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"B=/tmp/harness/.bin/bp && $B paper view paper-excellence-wave-7-2026-08-17"}}]}}
EOF
  echo "== selftest: CLEAN transcript should PASS =="
  audit "$TMP/clean.jsonl" "$TMP/guide.txt"; CLEAN_RC=0
  echo "== selftest: LEAKY transcript should FAIL with all 15 findings =="
  set +e
  LEAKY_OUT="$(audit "$TMP/leaky.jsonl" "$TMP/guide.txt")"
  LEAKY_RC=$?
  set -e
  echo "$LEAKY_OUT"
  if [ "$LEAKY_RC" -eq 0 ]; then
    echo "leakage-audit: SELFTEST FAIL — the leaky transcript was not caught" >&2
    exit 1
  fi
  # Every fixture must be caught INDIVIDUALLY — the exact count proves no
  # detection was removed without its fixture going dark.
  if ! printf '%s' "$LEAKY_OUT" | grep -q "FAIL — 15 finding"; then
    echo "leakage-audit: SELFTEST FAIL — expected exactly 15 findings (one per channel fixture); a detection was removed or a channel slipped" >&2
    exit 1
  fi
  # And every channel's marker must be present — deleting any single
  # detection reds the selftest even if the count were somehow preserved.
  while IFS= read -r marker; do
    if ! printf '%s' "$LEAKY_OUT" | grep -qF -- "$marker"; then
      echo "leakage-audit: SELFTEST FAIL — channel marker '$marker' missing from the leaky findings (a detection was removed or broke)" >&2
      exit 1
    fi
  done <<'MARKERS'
HARD FAIL
LEAK — read of un-sanctioned slug
QUERY LEAK
un-parseable `bp doc query
doc revision
doc backlinks
doc related
doc history
paper capture
DISCOVERY
HTTP —
NON-BASH
indirection
MARKERS
  echo "leakage-audit: SELFTEST PASS — clean passes (incl. own-slug read-back, verb-only doc ls tag, host-free non-Bash tool); leaky fails on all 15 channels (query/revision/graph/capture/discovery/http/non-bash/indirection incl. path-prefixed + \$VAR-indirected bp)"
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
