#!/usr/bin/env bash
# cloud-format-check.sh — run cloud/'s format gate under THE ELIXIR THE GATE
# PINS, not the one that happens to be on PATH.
#
# ─────────────────────────────────────────────────────────────────────────────
#  WHY THIS EXISTS (task-417026dfc4826971)
# ─────────────────────────────────────────────────────────────────────────────
#  PR #17482 sat at 3/4 with a RED "Cloud control-plane (compile + format)" job
#  while `mix format --check-formatted` in the PR's own worktree exited 0 on the
#  SAME head sha. Cause: .github/workflows/cloud.yml pins Elixir 1.18.1; the
#  fleet's Macs run 1.19.5, and the two formatters disagree.
#
#  MEASURED 2026-09-10, the exact byte that cost that cycle
#  (cloud/test/barkpark_cloud/registry_name_claim_select_census_test.exs:351,
#  fixed by d3f0f5995) — a 99-column line, one over the 98 default:
#
#      assert {:not, _, [{:is_nil, _, [field]}]} = Extract.select_value(source(), :has_admin_token),
#             """
#             ...
#             """
#
#    Elixir 1.19.5  --check-formatted  exit 0   ← what the dev sees
#    Elixir 1.18.1  --check-formatted  exit 1   ← what the gate sees
#
#  So a green local `mix format --check-formatted` IS NOT THIS GATE. Worse and
#  silently: a local `mix format` REWRITES gate-correct bytes into gate-red
#  ones, so the next dev's reflex "fix" re-reds a green gate.
#
#  THE PIN IS NOT THE ENFORCEMENT. .tool-versions says elixir 1.18.4-otp-27;
#  cloud.yml says 1.18.1; this Mac's PATH says 1.19.5. Three numbers, and
#  nothing on a dev box reconciles them, because there is no asdf/mise here.
#  A declaration nothing checks is a comment. This script is the check: it
#  OBTAINS the pinned Elixir and runs the gate's own command under it.
#
#  ONE SOURCE OF TRUTH FOR THE EXPECTED VERSION: it is READ OUT of
#  .github/workflows/cloud.yml's `compile:` job matrix, never restated here.
#  A second declaration is a second thing to drift, and drift between the pin
#  and the gate is the defect this file exists to stop. If the shape ever
#  changes this REFUSES (exit 5) rather than guessing — a wrong expectation is
#  worse than none, because it reds people who are on the CORRECT toolchain.
#
# ─────────────────────────────────────────────────────────────────────────────
#  USAGE
# ─────────────────────────────────────────────────────────────────────────────
#    make cloud-format-check                       # the way you should call it
#    bash scripts/cloud-format-check.sh            # same thing
#    bash scripts/cloud-format-check.sh --selftest # prove each refusal can fire
#
#  EXIT CODES — the whole point of the file. A FAILED READ MUST NEVER LOOK LIKE
#  A PASS, and a REFUSAL must never look like a VERDICT:
#    0  formatted, under the Elixir the gate pins
#    1  GENUINELY UNFORMATTED under the gate's Elixir — the only code that is a
#       claim about the code
#    3  CANNOT OBTAIN the pinned Elixir (no mise, no asdf, download failed, or
#       the obtained build will not run on this OTP) — no claim made
#    4  cloud/deps not fetched — .formatter.exs uses import_deps, so the
#       formatter cannot even parse its own config — no claim made
#    5  the pinned version could not be read out of cloud.yml — no claim made
#    6  the formatter DID NOT RUN (no mix, a wrapper refused it, or an exit code
#       that is neither 0 nor 1) — no claim made
#
#  Codes 3/4/5/6 are REFUSALS and say so in words. Nothing downstream may read
#  them as "the tree is unformatted". THE INVARIANT: exit 1 is emitted only when
#  `mix format --check-formatted` RAN under the pinned Elixir and returned 1.
set -uo pipefail

ROOT="${CLOUD_FORMAT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
WORKFLOW="${CLOUD_FORMAT_WORKFLOW:-$ROOT/.github/workflows/cloud.yml}"
CLOUD_DIR="${CLOUD_FORMAT_CLOUD_DIR:-$ROOT/cloud}"
CACHE="${BARKPARK_ELIXIR_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/barkpark/elixir}"

say() { printf '%s\n' "$*"; }

# ── the expected version, read out of the gate that will judge you ───────────
# Scoped to the `compile:` job (the one that runs the Format check step) so a
# matrix elsewhere in the file — e.g. `test:` — cannot answer for it.
read_expected() {
  awk '
    /^  compile:/            { in_job = 1; next }
    in_job && /^  [a-z_-]+:/ { in_job = 0 }
    in_job && /elixir: \[/   { if (match($0, /"[0-9][^"]*"/)) { print substr($0, RSTART+1, RLENGTH-2); exit } }
  ' "$1" 2>/dev/null
}

elixir_version_of() { # bin-dir-or-empty -> "1.18.1"
  local prefix="$1"
  if [ -n "$prefix" ]; then
    PATH="$prefix:$PATH" "$prefix/elixir" --version 2>/dev/null \
      | sed -n 's/^Elixir \([0-9][0-9.]*\).*/\1/p' | head -1
  else
    elixir --version 2>/dev/null | sed -n 's/^Elixir \([0-9][0-9.]*\).*/\1/p' | head -1
  fi
}

otp_major() {
  erl -noshell -eval 'io:format("~s",[erlang:system_info(otp_release)]),halt().' 2>/dev/null \
    | sed 's/[^0-9].*//'
}

# ── obtain the pinned Elixir. Prints the bin dir on stdout, or nothing. ──────
# Order: already-on-PATH > mise > asdf > cached download > fresh download.
# The download is the honest fallback on a box with no version manager (this
# describes the whole Mac fleet): elixir-lang/elixir ships precompiled release
# zips, which are plain BEAM bytecode and run on a NEWER OTP than they were
# built against — VERIFIED below rather than assumed, because "it downloaded"
# is not "it runs".
obtain() {
  local want="$1" d p
  if command -v mise >/dev/null 2>&1; then
    if mise install "elixir@$want" >/dev/null 2>&1; then
      p="$(mise where "elixir@$want" 2>/dev/null)"
      [ -n "$p" ] && [ -x "$p/bin/elixir" ] && { printf '%s' "$p/bin"; return 0; }
    fi
  fi
  if command -v asdf >/dev/null 2>&1; then
    asdf install elixir "$want" >/dev/null 2>&1
    p="$(asdf where elixir "$want" 2>/dev/null)"
    [ -n "$p" ] && [ -x "$p/bin/elixir" ] && { printf '%s' "$p/bin"; return 0; }
  fi

  d="$CACHE/$want"
  if [ -x "$d/bin/elixir" ]; then printf '%s' "$d/bin"; return 0; fi
  command -v curl >/dev/null 2>&1 || return 1
  command -v unzip >/dev/null 2>&1 || return 1

  # Try the OTP-flavoured assets from this box's OTP downward. 1.18 predates
  # OTP 28, so on an OTP 28 box the otp-27 build is the one that exists.
  local otp start n zip
  otp="$(otp_major)"; [ -n "$otp" ] || otp=27
  mkdir -p "$d" || return 1
  zip="$d/.download.zip"
  for n in $(seq "$otp" -1 25); do
    if curl -fsSL --retry 2 --max-time 300 \
        -o "$zip" \
        "https://github.com/elixir-lang/elixir/releases/download/v$want/elixir-otp-$n.zip" 2>/dev/null; then
      if unzip -q -o "$zip" -d "$d" 2>/dev/null; then
        rm -f "$zip"
        chmod +x "$d"/bin/* 2>/dev/null
        [ -x "$d/bin/elixir" ] && { printf '%s' "$d/bin"; return 0; }
      fi
    fi
  done
  rm -f "$zip"
  return 1
}

run_check() {
  if [ ! -f "$WORKFLOW" ]; then
    say "!! CLOUD FORMAT CHECK REFUSED (exit 5): no workflow at $WORKFLOW,"
    say "   so the Elixir version the Cloud gate pins cannot be read."
    say "   NO CLAIM is being made about formatting."
    return 5
  fi
  local EXPECTED RUNNING BIN GOT
  EXPECTED="$(read_expected "$WORKFLOW")"
  if [ -z "$EXPECTED" ]; then
    say "!! CLOUD FORMAT CHECK REFUSED (exit 5): could not read the compile job's pinned"
    say "   elixir version out of ${WORKFLOW#"$ROOT"/}. The job's matrix shape changed."
    say "   Fix this reader rather than restating a version here — a second declaration is"
    say "   a second thing to drift, and a wrong expectation reds people who are CORRECT."
    say "   NO CLAIM is being made about formatting."
    return 5
  fi

  RUNNING="$(elixir_version_of "")"
  say ">> gate pins   Elixir $EXPECTED   (read from ${WORKFLOW#"$ROOT"/}, compile job matrix)"
  say ">> on PATH     Elixir ${RUNNING:-<none>}"

  if [ -n "$RUNNING" ] && [ "$RUNNING" = "$EXPECTED" ]; then
    BIN=""
    say ">> versions agree — running the gate's command directly."
  else
    say ""
    say "!! VERSION MISMATCH — this is the whole reason this script exists."
    say "   The gate formats with Elixir $EXPECTED. Your PATH has ${RUNNING:-nothing}."
    say "   The 1.18 and 1.19 formatters DISAGREE (measured: a 99-column"
    say "   \`assert pat = call(),\` with a trailing message is CLEAN under 1.19.5 and"
    say "   RED under 1.18.1). So a green local \`mix format --check-formatted\` is NOT"
    say "   this gate, and a local \`mix format\` will REWRITE gate-correct bytes into"
    say "   gate-red ones. Obtaining Elixir $EXPECTED to get a real answer..."
    BIN="$(obtain "$EXPECTED")"
    if [ -z "$BIN" ] || [ ! -x "$BIN/elixir" ]; then
      say ""
      say "!! CANNOT OBTAIN THE PINNED ELIXIR (exit 3) — a REFUSAL, not a verdict."
      say "   the gate: Elixir $EXPECTED   (${WORKFLOW#"$ROOT"/}, compile job)"
      say "   this box: Elixir ${RUNNING:-<none>}"
      say "   Tried, in order: mise ($( command -v mise >/dev/null 2>&1 && echo present || echo absent))," \
          "asdf ($( command -v asdf >/dev/null 2>&1 && echo present || echo absent)),"
      say "   and the precompiled release zip under $CACHE/$EXPECTED."
      say ""
      say "   Do NOT run \`mix format\` on the strength of this run. Reformatting under"
      say "   ${RUNNING:-your Elixir} rewrites files the gate considers CLEAN."
      say "   NO CLAIM is being made about formatting."
      return 3
    fi
    GOT="$(elixir_version_of "$BIN")"
    if [ "$GOT" != "$EXPECTED" ]; then
      say ""
      say "!! CANNOT OBTAIN THE PINNED ELIXIR (exit 3) — a REFUSAL, not a verdict."
      say "   Obtained a toolchain at $BIN but it reports Elixir ${GOT:-<it would not run>},"
      say "   not the pinned $EXPECTED. A precompiled build can fail to start on this OTP"
      say "   (\`erl\` here is OTP $(otp_major)); that is a failed READ, never a format verdict."
      say "   NO CLAIM is being made about formatting."
      return 3
    fi
    say ">> obtained    Elixir $GOT at $BIN"
  fi

  if [ ! -d "$CLOUD_DIR/deps" ] || [ -z "$(ls -A "$CLOUD_DIR/deps" 2>/dev/null)" ]; then
    say ""
    say "!! CLOUD FORMAT CHECK REFUSED (exit 4): DEPS NOT FETCHED — a REFUSAL, not a verdict."
    say "   $CLOUD_DIR/deps is missing or empty."
    say "   cloud/.formatter.exs uses \`import_deps: [:ecto, :ecto_sql]\`, so the formatter"
    say "   needs deps to parse its own config. Without them it dies with 'Unknown"
    say "   dependency :ecto given to :import_deps' and a NON-ZERO exit that is"
    say "   indistinguishable from unformatted code at the exit-code level."
    say "   Run: (cd $CLOUD_DIR && mix deps.get)"
    say "   NO CLAIM is being made about formatting."
    return 4
  fi
  say ">> deps        resolved in ${CLOUD_DIR#"$ROOT"/}/deps"

  # MIX_HOME IS DELIBERATELY LEFT ALONE. A fresh MIX_HOME forces `mix local.hex`,
  # and the hex archive that Elixir $EXPECTED fetches is compiled for ITS OTP —
  # on an OTP 28 box that archive fails to load ("please re-compile this module
  # with an Erlang/OTP 28 compiler"), which would refuse for a reason that has
  # nothing to do with formatting. The box's own ~/.mix hex loads fine, and
  # `mix format --check-formatted` writes nothing to it.
  local MIXBIN out rc refused
  if [ -n "$BIN" ]; then MIXBIN="$BIN/mix"; else MIXBIN="$(command -v mix 2>/dev/null)"; fi
  if [ -z "$MIXBIN" ] || [ ! -x "$MIXBIN" ]; then
    say ""
    say "!! CANNOT READ FORMATTING (exit 6): no runnable \`mix\`, so the formatter never ran."
    say "   NO CLAIM is being made about formatting."
    return 6
  fi

  # BP_ALLOW_FORMAT satisfies the fleet's compile-slot shim (~/.local/bin/mix),
  # which refuses `mix format` under the wrong Elixir. Its condition is MET here,
  # not bypassed: the version was proved against the gate's own matrix above, and
  # --check-formatted writes nothing.
  if [ -n "$BIN" ]; then
    out="$(cd "$CLOUD_DIR" && PATH="$BIN:$PATH" BP_ALLOW_FORMAT=1 "$MIXBIN" format --check-formatted 2>&1)"
  else
    out="$(cd "$CLOUD_DIR" && BP_ALLOW_FORMAT=1 "$MIXBIN" format --check-formatted 2>&1)"
  fi
  rc=$?

  # A REFUSAL IS NOT A VERDICT. Belt and braces: only 0 and 1 are verdicts, AND
  # a wrapper may refuse with 1, so its vocabulary routes to 6 as well.
  refused=""
  case "$rc" in 0 | 1) ;; *) refused="exit code $rc is neither 0 nor 1" ;; esac
  # NO `printf … | grep -q` HERE. `grep -q` exits on its first match and closes
  # the pipe; under pipefail the printf then dies of SIGPIPE (141) and the
  # PIPELINE reports 141, so a MATCH reads as no-match — and $out is a mix
  # format diff, i.e. exactly the large payload that makes it fire. Pure-bash
  # pattern match instead: no pipe, no subprocess, no size dependence.
  case "$out" in
    *REFUSED* | *UNCHECKED*) refused="the \`mix\` invoked refused to run the formatter" ;;
  esac
  if [ -n "$refused" ]; then
    say ""
    say "!! CANNOT READ FORMATTING (exit 6): $refused — the formatter DID NOT RUN."
    say "   This is a REFUSAL, not a verdict. It is NOT 'unformatted'. What $MIXBIN said:"
    printf '%s\n' "$out" | sed 's/^/     | /'
    say "   NO CLAIM is being made about formatting."
    return 6
  fi

  say ""
  if [ "$rc" -eq 0 ]; then
    [ -n "$out" ] && say "$out"
    say "CLOUD FORMAT OK — cloud/ is formatted under Elixir $EXPECTED, which is the version"
    say "the 'Cloud control-plane (compile + format)' job runs. THIS is the gate's answer."
    return 0
  fi
  say "$out"
  say ""
  say "!! CLOUD UNFORMATTED (exit 1) — a real verdict, under the gate's Elixir $EXPECTED"
  say "   (your PATH has ${RUNNING:-<none>}; the two formatters disagree, which is why this"
  say "   reds while a plain \`mix format --check-formatted\` in cloud/ may not)."
  say ""
  say "   FIX IT UNDER $EXPECTED, NOT UNDER YOUR PATH ELIXIR:"
  if [ -n "$BIN" ]; then
    say "     (cd ${CLOUD_DIR#"$ROOT"/} && PATH=\"$BIN:\$PATH\" BP_ALLOW_FORMAT=1 mix format)"
  else
    say "     (cd ${CLOUD_DIR#"$ROOT"/} && BP_ALLOW_FORMAT=1 mix format)"
  fi
  say "   Running plain \`mix format\` under ${RUNNING:-your Elixir} will UNDO this fix on the"
  say "   next pass and re-red the gate."
  return 1
}

if [ "${1:-}" != "--selftest" ]; then
  run_check
  exit $?
fi

# ─────────────────────────────────────────────────────────────────────────────
#  --selftest: PROVE EACH REFUSAL CAN FIRE, AND NAME ITSELF
# ─────────────────────────────────────────────────────────────────────────────
#  A guard that separates causes is worthless if it cannot demonstrate the
#  separation. Each case drives a temp tree into one state and asserts BOTH the
#  exit code AND that the message names that cause and no other.
fails=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
SELF="${BASH_SOURCE[0]}"

check() { # name want yes no rc out
  local name="$1" want="$2" yes="$3" no="$4" rc="$5" out="$6"
  if [ "$rc" -ne "$want" ]; then
    say "  FAIL  $name — expected exit $want, got $rc"; fails=$((fails + 1)); return
  fi
  # Pure-bash substring match, not `printf … | grep -q` — see the note in
  # run_check: grep -q + pipefail turns a MATCH into 141 on a large payload,
  # which would make this assertion silently invert under exactly the outputs
  # it is here to police.
  case "$out" in
    *"$yes"*) ;;
    *) say "  FAIL  $name — exit $rc was right but the message never says '$yes'"; fails=$((fails + 1)); return ;;
  esac
  if [ -n "$no" ]; then
    case "$out" in
      *"$no"*) say "  FAIL  $name — the message ALSO says '$no', so the causes are not separated"; fails=$((fails + 1)); return ;;
    esac
  fi
  say "  ok    $name (exit $rc, names '$yes')"
}

say "=== cloud-format-check selftest: every refusal must fire, and name only itself ==="

# 1. NO WORKFLOW — refuse rather than guess a version.
mkdir -p "$tmp/no-wf/cloud/deps"; : > "$tmp/no-wf/cloud/deps/keep"
out="$(CLOUD_FORMAT_ROOT="$tmp/no-wf" CLOUD_FORMAT_WORKFLOW="$tmp/no-wf/nope.yml" bash "$SELF" 2>&1)"; rc=$?
check "a missing workflow REFUSES rather than guessing a version" 5 "exit 5" "UNFORMATTED" "$rc" "$out"

# 2. A MATRIX IN A DIFFERENT JOB MUST NOT ANSWER FOR compile:.
mkdir -p "$tmp/bad-wf/cloud/deps" "$tmp/bad-wf/.github/workflows"; : > "$tmp/bad-wf/cloud/deps/keep"
printf 'jobs:\n  compile:\n    name: Cloud\n  test:\n    strategy:\n      matrix:\n        elixir: ["9.9.9"]\n' \
  > "$tmp/bad-wf/.github/workflows/cloud.yml"
out="$(CLOUD_FORMAT_ROOT="$tmp/bad-wf" CLOUD_FORMAT_WORKFLOW="$tmp/bad-wf/.github/workflows/cloud.yml" bash "$SELF" 2>&1)"; rc=$?
check "the test job's matrix must not answer for the compile job" 5 "exit 5" "UNFORMATTED" "$rc" "$out"

# 3. AN UNOBTAINABLE PIN REFUSES AS ITSELF. No 0.0.1 exists anywhere, and the
#    download loop 404s on every asset, so this exercises the real fallback.
mkdir -p "$tmp/wrong/cloud/deps" "$tmp/wrong/.github/workflows"; : > "$tmp/wrong/cloud/deps/keep"
printf 'jobs:\n  compile:\n    strategy:\n      matrix:\n        elixir: ["0.0.1"]\n' \
  > "$tmp/wrong/.github/workflows/cloud.yml"
out="$(BARKPARK_ELIXIR_CACHE="$tmp/cache" CLOUD_FORMAT_ROOT="$tmp/wrong" \
  CLOUD_FORMAT_WORKFLOW="$tmp/wrong/.github/workflows/cloud.yml" bash "$SELF" 2>&1)"; rc=$?
check "an unobtainable pin REFUSES and is never reported as unformatted" 3 "CANNOT OBTAIN" "UNFORMATTED" "$rc" "$out"
check "and it says NO CLAIM, so nothing downstream reads it as a verdict" 3 "NO CLAIM" "" "$rc" "$out"
check "and it forbids the reflex 'fix' that would red a currently-green gate" 3 "Do NOT run" "" "$rc" "$out"

# 4. DEPS NOT FETCHED — pin matches PATH so the version branch is skipped.
running="$(elixir_version_of "")"
if [ -n "$running" ]; then
  mkdir -p "$tmp/nodeps/cloud" "$tmp/nodeps/.github/workflows"
  printf 'jobs:\n  compile:\n    strategy:\n      matrix:\n        elixir: ["%s"]\n' "$running" \
    > "$tmp/nodeps/.github/workflows/cloud.yml"
  out="$(CLOUD_FORMAT_ROOT="$tmp/nodeps" CLOUD_FORMAT_WORKFLOW="$tmp/nodeps/.github/workflows/cloud.yml" bash "$SELF" 2>&1)"; rc=$?
  check "unfetched deps REFUSE as themselves, not as a format failure" 4 "DEPS NOT FETCHED" "UNFORMATTED" "$rc" "$out"
  check "and the import_deps trap is named so the next reader does not re-derive it" 4 "import_deps" "" "$rc" "$out"
else
  say "  skip  deps-refusal case — no elixir on PATH to match an expectation against"
fi

# 5. A WRAPPER REFUSAL IS NOT A VERDICT. A fake `mix` speaks the box shim's
#    refusal with everything else correct. It must print CANNOT READ, exit 6,
#    and must NOT contain the word UNFORMATTED anywhere.
if [ -n "$running" ]; then
  mkdir -p "$tmp/refuse/cloud/deps" "$tmp/refuse/.github/workflows" "$tmp/refuse/bin"
  : > "$tmp/refuse/cloud/deps/keep"
  printf 'jobs:\n  compile:\n    strategy:\n      matrix:\n        elixir: ["%s"]\n' "$running" \
    > "$tmp/refuse/.github/workflows/cloud.yml"
  cat > "$tmp/refuse/bin/mix" <<'FAKE'
#!/usr/bin/env bash
echo "mix format is REFUSED on this box: local Elixir != the one CI and prod use." >&2
echo "UNCHECKED: this refusal is exit 2 — a toolchain refusal, never a formatting verdict." >&2
exit 2
FAKE
  chmod +x "$tmp/refuse/bin/mix"
  out="$(PATH="$tmp/refuse/bin:$PATH" CLOUD_FORMAT_ROOT="$tmp/refuse" \
    CLOUD_FORMAT_WORKFLOW="$tmp/refuse/.github/workflows/cloud.yml" bash "$SELF" 2>&1)"; rc=$?
  check "a wrapper REFUSAL refuses as itself and is NEVER reported as unformatted" 6 "CANNOT READ" "UNFORMATTED" "$rc" "$out"
  check "and it quotes the wrapper's own words so the reader can see WHO refused" 6 "REFUSED on this box" "" "$rc" "$out"
else
  say "  skip  wrapper-refusal case — no elixir on PATH to pin an expectation to"
fi

# 6. THE READER ACTUALLY READS THE REAL WORKFLOW. If this returns empty on the
#    committed file, every case above is testing a straw man.
if [ -f "$WORKFLOW" ]; then
  real="$(read_expected "$WORKFLOW")"
  if [ -n "$real" ]; then
    say "  ok    the reader resolves the REAL cloud.yml compile-job pin: Elixir $real"
  else
    say "  FAIL  the reader returns EMPTY on the committed ${WORKFLOW#"$ROOT"/} — every case above is a straw man"
    fails=$((fails + 1))
  fi
else
  say "  skip  real-workflow read — $WORKFLOW not present"
fi

say ""
if [ "$fails" -eq 0 ]; then
  say "SELFTEST OK — each cause refuses with its own exit code and names only itself."
  exit 0
fi
say "SELFTEST FAILED — $fails case(s) did not separate their cause." >&2
exit 1
