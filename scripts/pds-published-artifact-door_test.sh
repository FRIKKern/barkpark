#!/usr/bin/env bash
#
# Selftest for scripts/pds-published-artifact-door.sh — drives the REAL door
# against a synthetic git repository built here, so every arm is hermetic: no
# network, no registry, no dependence on this repo's own history.
#
# WHY A SYNTHETIC REPO RATHER THAN REPLAY. Replay over barkpark's real history
# proves the door reproduces known verdicts, and that evidence lives in the PR.
# It cannot prove the door CAN GO GREEN on a tree where the defect is absent,
# because main is red today. A fixture can flip one field and ask.
#
# THE ARMS ARE TWO-SIDED BY CONSTRUCTION. Every hatch arm has a MUTATION twin
# that removes the hatch and demands the same tree REFUSE — a hatch that skips
# everything is indistinguishable from a hatch that works, unless you show the
# thing it was hiding.
#
set -uo pipefail

DOOR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pds-published-artifact-door.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0; arms=0
ok()  { arms=$((arms+1)); printf '  ok   %s\n' "$1"; }
bad() { arms=$((arms+1)); fails=$((fails+1)); printf '  FAIL %s\n     %s\n' "$1" "$2"; }

FIX="$TMP/repo"; mkdir -p "$FIX"; cd "$FIX" || exit 2
git init -q .
git config user.email t@t
git config user.name t
mkdir -p js/packages js/.changeset
pkg() { mkdir -p "js/packages/$1"; printf '%s\n' "$2" > "js/packages/$1/package.json"; }
commit() { git add -A >/dev/null 2>&1; git commit -qm "$1" >/dev/null 2>&1; }

printf '{"ignore":[]}\n' > js/.changeset/config.json
# holdr and holdr_twin are IDENTICAL but for the version literal. That pairing is
# the probe for the placeholder hatch: both gain a subpath in the same commit, so
# if only holdr skips, the skip is keyed on the LITERAL and on nothing else.
pkg react '{"name":"@barkpark/react","version":"1.0.0","exports":{".":"x"}}'
pkg secret '{"name":"@barkpark/secret","version":"9.9.9","private":true,"exports":{".":"x"}}'
pkg holdr '{"name":"@barkpark/holdr","version":"0.0.0-placeholder","exports":{".":"x"}}'
pkg holdr_twin '{"name":"@barkpark/holdr-twin","version":"3.0.0","exports":{".":"x"}}'
pkg unscoped '{"name":"create-thing","version":"2.0.0","exports":{".":"x"}}'
commit v1
BASE="$(git rev-parse HEAD)"

# The defect: subpaths added with every version literal UNCHANGED, so R stays at
# v1 for all four and only the hatches decide who is checked.
pkg react '{"name":"@barkpark/react","version":"1.0.0","exports":{".":"x","./client":"y"}}'
pkg secret '{"name":"@barkpark/secret","version":"9.9.9","private":true,"exports":{".":"x","./added":"y"}}'
pkg holdr '{"name":"@barkpark/holdr","version":"0.0.0-placeholder","exports":{".":"x","./added":"y"}}'
pkg holdr_twin '{"name":"@barkpark/holdr-twin","version":"3.0.0","exports":{".":"x","./added":"y"}}'
commit "add subpaths, no bumps"
DIRTY="$(git rev-parse HEAD)"

echo "pds-published-artifact-door_test — hermetic fixture"

out="$(bash "$DOOR" "$DIRTY" 2>&1)"; rc=$?
if [ "$rc" = "1" ]; then ok "IT CAN RED: a subpath added after R is REFUSED (rc 1)"; else bad "can red" "rc=$rc want 1"; fi
if grep -q <<<"$out" './client'; then ok "the refusal NAMES ./client — an unnamed refusal is not actionable"; else bad "names subpath" "refusal did not name ./client"; fi
if grep -q <<<"$out" 'secret.*SKIP private:true'; then ok "HATCH private:true SKIPs a package that would otherwise REFUSE"; else bad "hatch private" "secret was not skipped as private"; fi
if grep -q <<<"$out" 'holdr.*SKIP version literal is 0.0.0-placeholder'; then ok "PROBE: the placeholder LITERAL alone produces the skip"; else bad "hatch placeholder" "holdr was not skipped on its literal"; fi
if grep -q <<<"$out" 'create-thing'; then ok "AN UNSCOPED PACKAGE IS NAMED BY ITS package.json, never by scope plus dir"; else bad "unscoped" "create-thing never appeared — a scope-builder stops checking it silently"; fi

out="$(bash "$DOOR" "$BASE" 2>&1)"; rc=$?
if [ "$rc" = "0" ]; then ok "IT CAN GREEN: the tree without the added subpath PASSes (rc 0)"; else bad "can green" "rc=$rc want 0 — a door that cannot pass refuses everything"; fi
if grep -q <<<"$out" 'REFUSALS 0' && grep -q <<<"$out" 'VERDICT: PASS'; then ok "the exit code descends: REFUSALS 0 => VERDICT PASS"; else bad "exit descends" "green run did not print REFUSALS 0 + VERDICT: PASS"; fi
if grep -q <<<"$out" 'RELEASE DEBT'; then ok "RELEASE DEBT is printed on a run that still exits 0 — a column, not a verdict"; else bad "debt reported" "debt section missing on a green run"; fi
if grep -q <<<"$out" 'reads the exports MAP only'; then ok "THE BLIND SPOT IS PRINTED: exports MAP only, behaviour-only changes pass"; else bad "blind spot printed" "the run did not print the blind-spot sentence"; fi
if grep -q <<<"$out" 'SKIP-WITH-REASON'; then ok "THE ENHANCEMENT ARM PRINTS SKIP-WITH-REASON on a GREEN run"; else bad "enhancement arm" "the optional byte arm did not print SKIP-WITH-REASON"; fi

# MUTATION: remove private:true and the SAME package must be checked and refuse.
# The version literal is left ALONE, or R would move onto the mutation commit and
# the package would pass for a reason that has nothing to do with the hatch.
pkg secret '{"name":"@barkpark/secret","version":"9.9.9","exports":{".":"x","./added":"y"}}'
commit "mutation: drop private"
out="$(bash "$DOOR" HEAD 2>&1)"
if grep -q <<<"$out" 'secret.*REFUSE'; then ok "MUTATION: the SAME package without private:true is CHECKED and REFUSES"; else bad "hatch private mutation" "dropping private:true did not make secret refuse"; fi
git reset -q --hard "$DIRTY"

# THE PAIRED PROBE: holdr and holdr-twin differ in the version LITERAL and in
# nothing else — same shape, same added subpath, same R. Only the placeholder is
# skipped, which is what proves the hatch keys on the literal rather than on the
# package identity or on absence from a registry.
out="$(bash "$DOOR" "$DIRTY" 2>&1)"
if grep -q <<<"$out" 'holdr-twin.*REFUSE'; then ok "PAIRED PROBE: the twin at a NON-placeholder literal is CHECKED and REFUSES — the hatch keys on the LITERAL, not the package identity"; else bad "hatch placeholder twin" "holdr-twin at 3.0.0 was not checked"; fi

# HATCH .changeset ignore, and its mutation twin.
#
# These two arms assert on the REACT ROW, never on the whole-tree exit code. The
# fixture deliberately holds a second refusing package (holdr-twin), so a global
# rc conflates "react was hatched" with "nothing else refuses" — and an arm that
# cannot tell those apart is not testing the hatch.
printf '{"ignore":["@barkpark/react"]}\n' > js/.changeset/config.json
commit "ignore react"
out="$(bash "$DOOR" HEAD 2>&1)"
if grep -qE '@barkpark/react .*SKIP \.changeset ignore' <<<"$out"; then ok "HATCH .changeset ignore SKIPs the package that would otherwise REFUSE"; else bad "hatch ignore" "react was not skipped on the ignore list"; fi
printf '{"ignore":[]}\n' > js/.changeset/config.json
commit "mutation: empty the ignore list"
out="$(bash "$DOOR" HEAD 2>&1)"
if grep -qE '@barkpark/react .*REFUSE' <<<"$out"; then ok "MUTATION: emptying the ignore list REFUSES the same package on the same tree"; else bad "hatch ignore mutation" "react did not refuse after emptying ignore"; fi
git reset -q --hard "$DIRTY"

# A genuine release must be structurally silent, not silent by exception. Again
# scoped to the react row: the rest of the fixture is still deliberately red.
pkg react '{"name":"@barkpark/react","version":"2.0.0","exports":{".":"x","./client":"y"}}'
commit "release: bump literal"
out="$(bash "$DOOR" HEAD 2>&1)"
if grep -qE '@barkpark/react .*2\.0\.0 .*PASS' <<<"$out"; then ok "A RELEASE IS STRUCTURALLY SILENT: bumping the literal moves R onto itself"; else bad "release silent" "react still refuses after a real release bump — a door that fires on a release will be weakened"; fi
git reset -q --hard "$DIRTY"

# READER FAILURES ARE NAMED, NEVER CLASSIFIED (task-4dba2e52ea7c1b04). A
# package.json blob that EXISTS but fails to parse must ERROR — it must never
# silently read as "field absent" and get treated as public/not-private. Before
# this fix, json_field's `except Exception: sys.exit(0)` made an unparseable
# private:true package's `priv` read as empty, which is indistinguishable from
# a genuinely absent field: the package would be CHECKED (and could PASS or
# REFUSE) instead of the ERROR a reader failure demands.
mkdir -p js/packages/unreadable
printf 'not valid json {{{\n' > js/packages/unreadable/package.json
commit "add a package.json that exists but does not parse"
out="$(bash "$DOOR" HEAD 2>&1)"; rc=$?
if grep -q <<<"$out" 'unreadable.*ERROR unreadable package.json'; then
  ok "READER FAILURE: a package.json that exists but fails to parse is an ERROR row, never a silent classification"
else
  bad "reader failure named" "unreadable/package.json did not produce an ERROR row: $out"
fi
if [ "$rc" = "2" ]; then ok "READER FAILURE: an ERROR row takes the whole door to VERDICT ERROR (rc 2)"; else bad "reader failure verdict" "rc=$rc want 2 — a reader failure must never look like a clean or merely-refusing tree"; fi
git reset -q --hard "$DIRTY"

# SHALLOW HISTORY IS REFUSED, NOT PASSED (elixir-nightly run 33717527961).
#
# The nightly checked out at actions/checkout's default fetch-depth: 1. resolve_r
# walks git log comparing each commit to its PARENT; on a truncated history the
# parent does not resolve, R collapses onto the boundary commit — HEAD — and
# exports(R) == exports(HEAD) for every package. The door printed VERDICT: PASS
# on a tree that REFUSES with real history: a vacuous pass whose output is
# byte-plausible.
#
# THE ARM IS TWO-SIDED. The SAME fixture at the SAME sha is cloned twice: once
# shallow (must ERROR, rc 2, naming the cause) and once with full history (must
# still REFUSE, rc 1, naming ./client). Without the control, a guard that errored
# on every clone would pass this arm just as happily.
SHALLOW="$TMP/shallow"; FULLCLONE="$TMP/fullclone"
git clone -q --depth 1 "file://$FIX" "$SHALLOW" 2>/dev/null
git clone -q "file://$FIX" "$FULLCLONE" 2>/dev/null
if [ -d "$SHALLOW/.git" ] && [ "$(git -C "$SHALLOW" rev-parse --is-shallow-repository)" = "true" ]; then
  ok "FIXTURE: the --depth 1 clone really is shallow (an arm over a full clone would be vacuous)"
else
  bad "shallow fixture" "the --depth 1 clone is not shallow — the arm below would prove nothing"
fi
out="$(cd "$SHALLOW" && bash "$DOOR" HEAD 2>&1)"; rc=$?
if [ "$rc" = "2" ]; then ok "SHALLOW: the door exits 2 (measured nothing) instead of descending to a PASS it cannot support"; else bad "shallow rc" "rc=$rc want 2 — on fetch-depth: 1 R collapses onto HEAD and every package passes vacuously"; fi
if grep -qF 'ERROR: shallow history — R cannot be derived; fetch-depth: 0 required' <<<"$out"; then ok "SHALLOW: the refusal NAMES the cause and the remedy — a failed read is never byte-identical to a PASS"; else bad "shallow line" "the run did not print the shallow ERROR line: $out"; fi
if grep -q <<<"$out" 'VERDICT: ERROR' && ! grep -q <<<"$out" 'VERDICT: PASS'; then ok "SHALLOW: the verdict is ERROR and no PASS is printed anywhere in the run"; else bad "shallow verdict" "the shallow run did not verdict ERROR: $out"; fi
out="$(cd "$FULLCLONE" && bash "$DOOR" HEAD 2>&1)"; rc=$?
if [ "$rc" = "1" ]; then ok "CONTROL: the SAME fixture sha with FULL history still REFUSES (rc 1) — the guard keys on shallowness, not on being a clone"; else bad "shallow control" "rc=$rc want 1 — the full clone of the same tree must behave exactly as before"; fi
if grep -q <<<"$out" './client'; then ok "CONTROL: the full-history clone still NAMES ./client"; else bad "shallow control names" "the full clone refusal did not name ./client: $out"; fi

if grep -nE '\b(curl|wget|npm|pnpm|yarn|nc|ping)\b' "$DOOR" | grep -vE '^[0-9]+:[[:space:]]*#' | grep -q .; then
  bad "offline" "a network command appears outside a comment in the shipped door"
else
  ok "NO NETWORK COMMAND IS INVOKED ANYWHERE IN THIS FILE"
fi

bash "$DOOR" definitely-not-a-ref >/dev/null 2>&1; rc=$?
if [ "$rc" = "2" ]; then ok "a bad ref exits 2 (measured nothing) rather than passing"; else bad "bad ref" "rc=$rc want 2 — an unresolvable ref must not look like a clean tree"; fi

echo
if [ "$fails" -eq 0 ]; then echo "SELFTEST PASS: $arms arms"; exit 0; fi
echo "SELFTEST FAIL: $fails of $arms arms"; exit 1
