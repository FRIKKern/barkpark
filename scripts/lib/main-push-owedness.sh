#!/usr/bin/env bash
# main-push-owedness.sh — "was this main sha OWED a run of this workflow?"
#
# SOURCED, never executed. It defines three functions and no top-level effects.
#
# WHY IT EXISTS (task-2253e13aba12fbe8, measured 2026-09-20)
#
# Two instruments in this tree look at the same main sha and answer differently
# BY CONSTRUCTION:
#
#   scripts/main-verdict-presence.sh  reads .github/main-push-workflows.txt and
#     already speaks NOT_OWED — but only in the coarse form "CONDITIONAL tier +
#     no run at all = not owed", with NO path matching. Its header (the block
#     beginning "THAT BOUND IS STATED, NOT HIDDEN") explains at length why it
#     declined to write a glob matcher: a SECOND, subtly-wrong copy of GitHub's
#     filter semantics is worse than the coarse rule for ITS question, which is
#     about run EXISTENCE across ~59 workflows.
#
#   scripts/main-gate-watch.sh  read that manifest ZERO times (`grep -c
#     main-push-workflows scripts/main-gate-watch.sh` was 0 on f0c53c340) and
#     knew only WAITING and MISSING. After #19414 stopped it counting its own
#     run as a live reason to WAIT, it began printing `MISSING Console gate`
#     and exiting 1 on 42 of the last 50 main tips — 84% — because
#     .github/workflows/console-harness.yml carries a `paths:` key on its
#     `push:` arm ONLY (added 2026-09-10 under task-7ef9d81ed33d2b9c; the
#     reasoning is written into that file above the key). The `pull_request`
#     arm has no filter, so every PR head still renders `Console gate` and
#     branch protection still evaluates it. THERE IS NO MERGE-SAFETY HOLE — a
#     main push that touched no console path was simply never owed that
#     context — but a scheduled watcher screaming falsely on 84% of tips is how
#     a real red gets ignored.
#
# THE COARSE RULE IS NOT AVAILABLE TO main-gate-watch.sh. Adopting "CONDITIONAL
# + nothing rendered = NOT_OWED" there would make its MISSING arm UNREACHABLE
# for every paths-filtered workflow, silencing the detector whose entire job is
# to notice an unjudged tip. main-gate-watch.sh watches THREE named contexts,
# not 59 workflows, so it can afford the precise question the coarse rule
# refuses: did this commit TOUCH a path the filter watches?
#
# So this file writes the matcher ONCE, as the FIRST copy in the tree, not a
# second. Nothing here duplicates main-verdict-presence.sh: the manifest — the
# one hand-reviewed artefact — stays the single tier list, and both scripts read
# it. If main-verdict-presence.sh ever wants to tighten its CONDITIONAL arm from
# existence to owed-ness, it sources this file rather than growing a copy.
#
# ── THE BOUND, STATED ────────────────────────────────────────────────────────
#
# GitHub evaluates a push event's `paths:` filter against the union of files
# across EVERY commit in the push. `mpo_owed` is told the files of ONE sha (the
# tip), because that is all `repos/<r>/commits/<sha>` can answer. For a
# multi-commit push whose tip touched no watched path but whose earlier commit
# did, GitHub says OWED and this file says NOT_OWED. That direction loses a
# scream, never manufactures one, and it is narrow: a run DID start in that
# case, so the workflow almost always rendered its context and the absence
# never arises. It is not silently absorbed — the caller prints NOT_OWED with
# the reason, so the verdict is auditable on the line where it was made.
#
# ── FAIL CLOSED ──────────────────────────────────────────────────────────────
#
# Every way of not knowing returns UNKNOWN, and every caller must treat UNKNOWN
# as OWED. An unreadable workflow file, an unlisted workflow, a manifest that
# does not mention the path, a missing changed-files list: none of them may buy
# silence. A matcher that fails open converts this repair into the wholesale
# mute it exists to avoid.
#
# FUNCTIONS
#   mpo_workflow_for_context <workflows-dir> <context>
#       Prints the repo-relative path of the workflow file that declares a JOB
#       named exactly <context>, or nothing. DERIVED from the tree — there is no
#       context-to-workflow list anywhere, because such a list goes stale the
#       day a job is renamed and the staleness is invisible.
#
#   mpo_tier <manifest> <workflow-path>
#       Prints ALWAYS, CONDITIONAL, or UNKNOWN.
#
#   mpo_owed <workflows-dir> <manifest> <workflow-path> <changed-files-file>
#       Prints OWED, NOT_OWED, or UNKNOWN. <changed-files-file> holds one
#       repo-relative path per line; pass "" when the file set is unknown.

# ── context -> workflow file, derived from the tree ──────────────────────────
mpo_workflow_for_context() {
  local dir="$1" ctx="$2"
  [ -d "$dir" ] || return 0
  python3 - "$dir" "$ctx" <<'PY' 2>/dev/null
import os, sys
try:
    import yaml
except ImportError:
    sys.exit(0)
d, ctx = sys.argv[1], sys.argv[2]
for n in sorted(os.listdir(d)):
    if not n.endswith((".yml", ".yaml")):
        continue
    try:
        with open(os.path.join(d, n), "r", encoding="utf-8") as fh:
            doc = yaml.safe_load(fh)
    except Exception:
        continue
    if not isinstance(doc, dict):
        continue
    jobs = doc.get("jobs")
    if not isinstance(jobs, dict):
        continue
    for jid, job in jobs.items():
        if isinstance(job, dict) and job.get("name") == ctx:
            sys.stdout.write(".github/workflows/" + n + "\n")
            sys.exit(0)
PY
}

# ── tier, read from the committed manifest (the ONE shared list) ─────────────
mpo_tier() {
  local manifest="$1" wf="$2" path tier
  [ -f "$manifest" ] || { echo "UNKNOWN"; return 0; }
  while IFS="$(printf '\t')" read -r path tier; do
    case "$path" in '#'*|'') continue ;; esac
    if [ "$path" = "$wf" ]; then
      case "$tier" in ALWAYS|CONDITIONAL) echo "$tier"; return 0 ;; esac
    fi
  done < "$manifest"
  echo "UNKNOWN"
}

# ── owed-ness ────────────────────────────────────────────────────────────────
mpo_owed() {
  local dir="$1" manifest="$2" wf="$3" changed="$4" tier out rc

  [ -n "$wf" ] || { echo "UNKNOWN"; return 0; }
  tier="$(mpo_tier "$manifest" "$wf")"
  case "$tier" in
    ALWAYS)      echo "OWED"; return 0 ;;
    CONDITIONAL) ;;
    *)           echo "UNKNOWN"; return 0 ;;
  esac

  # A paths-filtered workflow whose commit file set is unknown is OWED, not
  # silent. UNKNOWN here means "this read has no authority", and no authority
  # may ever be spent buying quiet.
  [ -n "$changed" ] && [ -f "$changed" ] || { echo "UNKNOWN"; return 0; }
  [ -f "$dir/$(basename "$wf")" ] || { echo "UNKNOWN"; return 0; }

  out="$(python3 - "$dir/$(basename "$wf")" "$changed" 2>/dev/null <<'PY'
import re, sys
try:
    import yaml
except ImportError:
    print("UNKNOWN"); sys.exit(0)

wf_path, changed_path = sys.argv[1], sys.argv[2]
try:
    with open(wf_path, "r", encoding="utf-8") as fh:
        doc = yaml.safe_load(fh)
except Exception:
    print("UNKNOWN"); sys.exit(0)
if not isinstance(doc, dict):
    print("UNKNOWN"); sys.exit(0)

# YAML 1.1 resolves a bare `on:` to the boolean True, so a parser that looks
# only for the string key finds NOTHING in every workflow ever written.
on = doc.get("on", doc.get(True))
if isinstance(on, str):
    on = {on: None}
elif isinstance(on, list):
    on = dict((k, None) for k in on)
if not isinstance(on, dict) or "push" not in on:
    print("UNKNOWN"); sys.exit(0)
push = on.get("push") or {}
if not isinstance(push, dict):
    print("UNKNOWN"); sys.exit(0)

paths = push.get("paths")
ignore = push.get("paths-ignore")
if paths is not None and ignore is not None:
    # GitHub rejects both keys on one arm; if we ever see it, we do not guess.
    print("UNKNOWN"); sys.exit(0)
if paths is None and ignore is None:
    print("OWED"); sys.exit(0)

def to_regex(pat):
    """GitHub filter-pattern -> anchored regex.

    ** any chars incl. /   * any chars except /   ? one char except /
    +  one-or-more of the preceding character.  A trailing / means the
    directory and everything under it.
    """
    if pat.endswith("/"):
        pat = pat + "**"
    out, i, n = [], 0, len(pat)
    while i < n:
        c = pat[i]
        if c == "*":
            if i + 1 < n and pat[i + 1] == "*":
                out.append(".*"); i += 2; continue
            out.append("[^/]*"); i += 1; continue
        if c == "?":
            out.append("[^/]"); i += 1; continue
        if c == "+" and out:
            out.append("+"); i += 1; continue
        out.append(re.escape(c)); i += 1
    return re.compile("^" + "".join(out) + "$")

def compile_list(raw):
    """Returns [(negated, regex)] in declaration order, or None if unusable."""
    if not isinstance(raw, list):
        return None
    got = []
    for p in raw:
        if not isinstance(p, str) or not p:
            return None
        neg = p.startswith("!")
        got.append((neg, to_regex(p[1:] if neg else p)))
    return got or None

def selected(f, rules):
    """GitHub evaluates patterns in order; a later ! un-selects."""
    sel = False
    for neg, rx in rules:
        if rx.match(f):
            sel = not neg
    return sel

try:
    with open(changed_path, "r", encoding="utf-8") as fh:
        files = [l.strip() for l in fh if l.strip()]
except Exception:
    print("UNKNOWN"); sys.exit(0)
if not files:
    print("UNKNOWN"); sys.exit(0)

if paths is not None:
    rules = compile_list(paths)
    if rules is None:
        print("UNKNOWN"); sys.exit(0)
    print("OWED" if any(selected(f, rules) for f in files) else "NOT_OWED")
    sys.exit(0)

rules = compile_list(ignore)
if rules is None:
    print("UNKNOWN"); sys.exit(0)
# paths-ignore: the run is owed when at least one file is NOT ignored.
print("OWED" if any(not selected(f, rules) for f in files) else "NOT_OWED")
PY
)"
  rc=$?
  if [ "$rc" -ne 0 ]; then echo "UNKNOWN"; return 0; fi
  case "$out" in
    OWED|NOT_OWED|UNKNOWN) echo "$out" ;;
    *) echo "UNKNOWN" ;;
  esac
}
