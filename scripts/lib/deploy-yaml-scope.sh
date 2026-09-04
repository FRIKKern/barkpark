#!/usr/bin/env bash
#
# lib/deploy-yaml-scope.sh — the ONE way this repo answers "which lines of a
# workflow file belong to job X / to step Y of job X".
#
# WHY A LIB, AND WHY A REAL PARSE
# -------------------------------
# scripts/check-deploy-smoke.sh (extract_cp_smoke, extract_instance_smoke,
# extract_job_lines) and scripts/check-deployyml-filters.sh (extract_regexes)
# each carried a hand-rolled copy of the SAME awk rule:
#
#     /^  [a-zA-Z0-9_-]+:/   # "a job starts here"
#
# Four copies of one boundary, and the boundary is a lie: it matches TEXT, so it
# cannot tell a job key from an identical-looking line inside a string. The
# reachable, VALID-YAML defeat is not the heredoc the follow-up row names (a
# 2-space body inside a `run: |` nested at 8 spaces is not parseable YAML, and
# both scripts already red on that via assert_parseable_yaml). It is the reverse:
# a TOP-LEVEL block scalar — `run-name: |` is the obvious one, and GitHub
# accepts it — whose body is indented two spaces:
#
#     run-name: |
#       control-plane: not a job, just a string
#             - name: Smoke test
#               run: |
#                 curl .../v1/auth/login ... 401 ...
#
# That is valid YAML, executes nothing, and every awk copy above reads it as the
# control-plane job's Smoke test step. Placed after the real `jobs:` mapping it
# lets the deploy workflow answer its own gate with a string literal — the exact
# disarm class check-deploy-smoke.sh exists to stop, re-opened one indent level
# up. A parser cannot be fooled by it: a scalar's CONTENT is never a node.
#
# So the boundary is computed from yaml.compose()'s node marks, and the lines are
# emitted VERBATIM from the file, so every downstream assertion stays the string
# scan it was. This adds no CI dependency: both callers already require
# python3 + PyYAML (assert_parseable_yaml, extract_changes_step) and refuse to
# certify anything without it.
#
# FAIL-CLOSED CONTRACT
#   0  the span was computed; the lines are on stdout (possibly EMPTY — an empty
#      span means the job or step is ABSENT, which is the caller's ruling to make
#      and is exactly how the incumbent extractors behaved).
#   2  HARNESS-UNAVAILABLE: no python3, or no PyYAML. Nothing on stdout.
#   3  the file does not parse as YAML. Nothing on stdout.
# Never a silent empty set from a broken harness: 2 and 3 print to stderr.

# _deploy_yaml_scope_py — the extractor, materialised into a variable first: a
# heredoc cannot be fed to a command substitution that closes on the same line.
_deploy_yaml_scope_py() {
  cat <<'PY'
import sys

try:
    import yaml
except ImportError:
    sys.stderr.write("PyYAML not importable\n")
    sys.exit(2)

path = sys.argv[1]
want_job = sys.argv[2]
want_step = sys.argv[3] if len(sys.argv) > 3 else None

with open(path, "rb") as fh:
    lines = fh.read().decode("utf-8", "replace").splitlines()

try:
    with open(path, "rb") as fh:
        root = yaml.compose(fh)
except Exception as exc:
    sys.stderr.write(" ".join(str(exc).split()) + "\n")
    sys.exit(3)

if root is None or not isinstance(root, yaml.nodes.MappingNode):
    sys.stderr.write("the workflow root is not a mapping\n")
    sys.exit(3)


def pairs(node):
    return node.value if isinstance(node, yaml.nodes.MappingNode) else []


def find(node, key):
    for k, v in pairs(node):
        if getattr(k, "value", None) == key:
            return k, v
    return None, None


# The span of a mapping entry, in FILE lines: from its key's line to the line
# before the next sibling key (or the end of the enclosing node). Deriving the
# end from the next sibling — rather than trusting end_mark, which PyYAML often
# parks on the following token — keeps trailing comments with the entry they
# follow, which is what the incumbent awk did.
def entry_span(parent, key_node, value_node):
    start = key_node.start_mark.line
    end = None
    seen = False
    for k, _v in pairs(parent):
        if seen:
            end = k.start_mark.line
            break
        if k is key_node:
            seen = True
    if end is None:
        end = value_node.end_mark.line
    return start, end


jobs_key, jobs_node = find(root, "jobs")
if jobs_node is None:
    sys.stderr.write("no 'jobs:' mapping in %s\n" % path)
    sys.exit(3)

job_key, job_node = find(jobs_node, want_job)
if job_node is None:
    sys.exit(0)  # absent job: empty span, the caller rules on it

j_start, j_end = entry_span(jobs_node, job_key, job_node)
# The last job in the mapping: bound it by the end of `jobs:` itself, never EOF.
_, root_jobs_end = entry_span(root, jobs_key, jobs_node)
j_end = min(j_end, root_jobs_end)

if want_step is None:
    out = lines[j_start:j_end]
else:
    _sk, steps_node = find(job_node, "steps")
    if steps_node is None or not isinstance(steps_node, yaml.nodes.SequenceNode):
        sys.exit(0)
    items = steps_node.value
    out = []
    for i, item in enumerate(items):
        _nk, name_node = find(item, "name")
        name = getattr(name_node, "value", None)
        if name is None or want_step not in name:
            continue
        s = item.start_mark.line
        e = items[i + 1].start_mark.line if i + 1 < len(items) else j_end
        out = lines[s:min(e, j_end)]
        break

while out and not out[-1].strip():
    out.pop()
sys.stdout.write("".join(l + "\n" for l in out))
PY
}

# deploy_yaml_job_lines <yml> <job> — every line of that job, verbatim.
deploy_yaml_job_lines() {
  _deploy_yaml_scope_run "$1" "$2"
}

# deploy_yaml_step_lines <yml> <job> <name-substring> — every line of the step of
# that job whose `name` CONTAINS the substring, verbatim. A step without a name
# is never matched, and a later step always closes the previous one, so an
# unnamed trailing step can never be absorbed into the one before it.
deploy_yaml_step_lines() {
  _deploy_yaml_scope_run "$1" "$2" "$3"
}

_deploy_yaml_scope_run() {
  local yml="$1"

  if ! command -v python3 >/dev/null 2>&1; then
    echo "HARNESS-UNAVAILABLE[deploy-yaml-scope]: python3 not on PATH — the job/step boundary cannot be computed." >&2
    echo "This is NOT a verdict on the workflow, and NOT a pass. Install python3 + PyYAML and re-run." >&2
    return 2
  fi

  local probe rc=0
  probe="$(_deploy_yaml_scope_py)"
  printf '%s\n' "$probe" | python3 - "$@" || rc=$?

  if [ "$rc" -eq 2 ]; then
    echo "HARNESS-UNAVAILABLE[deploy-yaml-scope]: PyYAML not importable — the job/step boundary cannot be computed." >&2
    echo "This is NOT a verdict on the workflow, and NOT a pass. pip install pyyaml and re-run." >&2
  elif [ "$rc" -eq 3 ]; then
    echo "UNPARSEABLE[deploy-yaml-scope]: $yml does not parse as YAML — no job boundary exists to compute." >&2
  fi
  return "$rc"
}
