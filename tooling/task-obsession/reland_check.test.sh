#!/usr/bin/env bash
# Hermetic test for reland_check.py — fixtures only, no ledger/network.
# Run: bash tooling/task-obsession/reland_check.test.sh   (exit 0 = all green)

set -uo pipefail
cd "$(dirname "$0")"
SCRIPT="reland_check.py"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# A backlog of closed tasks with land digests. "hot.ex" appears in many digests
# → frequency-hot; "shipped.ex" is landed only by task "done-a".
cat > "$tmp/tasks.json" <<'JSON'
{"docs":[
  {"doc_id":"done-a","content":{"lifecycle_status":"done","landed":{"files":["shipped.ex","hot.ex"]}}},
  {"doc_id":"done-b","content":{"lifecycle_status":"done","landed":{"files":["other-b.ex","hot.ex"]}}},
  {"doc_id":"done-c","content":{"lifecycle_status":"done","landed":{"files":["other-c.ex","hot.ex"]}}},
  {"doc_id":"open-x","content":{"lifecycle_status":"open","landed":{"files":["shipped.ex"]}}}
]}
JSON

pass=0 fail=0
findings() { # findings <files-content> [extra args...] -> prints finding count
  printf '%s\n' "$1" > "$tmp/files.txt"
  shift
  python3 "$SCRIPT" --files "$tmp/files.txt" --tasks "$tmp/tasks.json" --hot-frac 0.6 "$@" 2>/dev/null \
    | python3 -c "import json,sys; print(len(json.load(sys.stdin)['findings']))"
}
check() { # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then pass=$((pass+1)); printf 'ok   %-46s (%s)\n' "$1" "$3"
  else fail=$((fail+1)); printf 'FAIL %-46s want %s got %s\n' "$1" "$2" "$3"; fi
}

# hot.ex is in 3/3 digests → hot at 0.6 frac. shipped.ex is in 1/3 → not hot.
check "overlap on a real landed file flags"     1 "$(findings 'shipped.ex')"
check "overlap on ONLY a hot file is silent"    0 "$(findings 'hot.ex')"
check "disjoint files → no findings"            0 "$(findings 'brand-new.ex')"
check "open (non-done) task never flags"        0 "$(findings 'shipped.ex' --pr-task open-x --dep done-a)"
check "dependency-edge suppresses the finding"  0 "$(findings 'shipped.ex' --dep done-a)"
check "self (PR's own task) is suppressed"      0 "$(findings 'shipped.ex' --pr-task done-a)"
check "hot + real file still flags on the real" 1 "$(findings $'shipped.ex\nhot.ex')"

echo "---"; echo "passed: $pass  failed: $fail"
[ "$fail" = 0 ]
