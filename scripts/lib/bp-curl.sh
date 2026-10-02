#!/usr/bin/env bash
# bp-curl.sh — curl against the Barkpark API with the 429 handled ONCE, here.
#
# THE DEFECT THIS CLOSES (task-ca8fffa7ca885413, split from task-b4b421aac4e9d55d).
# Every shell/CI curl consumer of the BP API treated HTTP 429 as a hard failure.
# Two shapes, kept apart because they take different remedies:
#
#   class B  code="$(curl ... -w '%{http_code}')"   the status REACHES a branch,
#            no branch is 429-shaped — remedy: add the branch (here, once).
#   class C  body="$(curl -s ...)" / curl -sf ...    the status is DISCARDED before
#            any branch exists — a 429 branch is unreachable until the status is
#            captured FIRST. `-f` collapses every status into exit 22.
#
# THE INVARIANT, copied from cloud/priv/static/__preview__/seal-predicate.mjs
# (RATE_LIMIT_* there; BP_CURL_* here):
#   * the wait comes FROM THE RESPONSE — `error.details.retry_after` in the body
#     (what Errors.to_envelope puts there, THREE levels deep) read first, then the
#     Retry-After header — never a hardcoded sleep. Absent/unparseable = 1s.
#   * a wait longer than BP_CURL_MAX_WAIT_S is NOT slept out: the pulse plugin
#     answers Retry-After: 3600 on a spent daily cap — that is a quota, not a blip.
#   * bounded by an attempt cap (BP_CURL_ATTEMPTS, first try included) AND a
#     total-wait ceiling (BP_CURL_MAX_TOTAL_WAIT_S) across one call.
#   * on give-up the stderr line is `BP-CURL-RATE-LIMITED`, distinct from a
#     transport failure — backpressure is not a fault.
# Harness: scripts/lib/bp-curl.test.sh (fake 429-then-200 server retried, fake
# 500 not, the header VALUE proven to be the one slept — a hardcoded sleep reds).
#
# Usage (source it; the two verbs invoke `curl` by NAME so a harness can stub it):
#     . "$(dirname "$0")/lib/bp-curl.sh"             # from scripts/foo.sh
#     . "$(dirname "$0")/../lib/bp-curl.sh"          # from scripts/lib/… or scripts/x/foo.sh
#
#   code="$(bp_curl_code -sS -m 20 -o "$out" -X POST "$URL" -H ... 2>/dev/null || echo 000)"
#       class-B drop-in: prints the FINAL http_code (after any 429 backoff) on
#       stdout. Transport failure prints NOTHING and returns curl's rc, so the
#       `|| echo 000` idiom yields a clean 000 (curl -w alone prints 000 AND
#       fails, which made that idiom print 000000 — a latent double).
#
#   body="$(bp_curl_body -sS -m 20 "$URL" -H ...)" || rc=$?
#       class-C drop-in for `curl -s`/`curl -sf`: the status is captured before
#       anything else; a 2xx puts the body on stdout and returns 0; any other
#       status puts NOTHING on stdout, names the status on stderr and returns 22
#       (curl -f's own code, so `if curl -sf ...` converts 1:1). 429 is backed
#       off first, exactly like bp_curl_code.
#
# The helper OWNS -w, -D and -f: a caller passing any of them gets a distinct
# `CANNOT` line and exit 64 (they would either double the status on stdout or
# hide it). Callers keep their own -o, -s, -m/--max-time, -X, -H, -d, --data-*.

BP_CURL_ATTEMPTS="${BP_CURL_ATTEMPTS:-4}"                 # total tries, first included
BP_CURL_DEFAULT_WAIT_S="${BP_CURL_DEFAULT_WAIT_S:-1}"     # the plugs' floor when no value is sent
BP_CURL_MAX_WAIT_S="${BP_CURL_MAX_WAIT_S:-5}"             # a longer ask is a quota, not a blip
BP_CURL_MAX_TOTAL_WAIT_S="${BP_CURL_MAX_TOTAL_WAIT_S:-10}" # one call never pauses longer

bp_curl__say() { printf 'bp-curl: %s\n' "$*" >&2; }

# Refuse the flags this helper owns. Returns 64 with a CANNOT line, else 0.
bp_curl__refuse_args() {
  local a
  for a in "$@"; do
    case "$a" in
      -w|--write-out|--write-out=*|-D|--dump-header|--dump-header=*|-f|--fail|--fail-with-body)
        bp_curl__say "CANNOT run: the caller passed '$a', a flag bp_curl owns (it captures the status with -w/-D itself, and -f would hide it)"
        return 64 ;;
      --*) : ;;
      -[A-Za-z]*)
        case "$a" in
          *[A-Za-z]=*) : ;;  # not a flag cluster
          *) case "$a" in
               *f*|*w*|*D*)
                 if [[ "$a" =~ ^-[A-Za-z]+$ ]]; then
                   bp_curl__say "CANNOT run: the caller passed '$a', a flag cluster carrying f/w/D which bp_curl owns"
                   return 64
                 fi ;;
             esac ;;
        esac ;;
    esac
  done
  return 0
}

# Read the retry_after the server SENT: body `"retry_after": N` (string or
# number) first, then the last Retry-After header. Prints an integer or nothing.
bp_curl__retry_after() { # $1 body file, $2 header file
  local v=""
  if [ -f "$1" ]; then
    v="$(awk 'match($0,/"retry_after"[[:space:]]*:[[:space:]]*"?[0-9]+/){s=substr($0,RSTART,RLENGTH);gsub(/[^0-9]/,"",s);print s;exit}' "$1" 2>/dev/null)"
  fi
  if [ -z "$v" ] && [ -f "$2" ]; then
    v="$(awk 'tolower($1)=="retry-after:"{x=$2;gsub(/\r/,"",x);v=x} END{if(v!="")print v}' "$2" 2>/dev/null)"
  fi
  case "$v" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s' "$v"
}

# The one curl, with the bounded 429 loop. Sets BP_CURL_CODE, BP_CURL_RC,
# BP_CURL_BODY_FILE (the file the final body landed in) and BP_CURL_TMP.
# The body ALWAYS lands in the helper's own file first — a caller's `-o /dev/null`
# would otherwise make the envelope's retry_after unreadable — and is copied to
# the caller's -o target after every attempt, so the caller sees what curl would
# have written.
bp_curl__run() {
  local a prev="" dest="" url="" args=() skip=0
  for a in "$@"; do
    if [ "$skip" = 1 ]; then dest="$a"; skip=0; continue; fi
    case "$a" in
      -o|--output) skip=1; continue ;;
      --output=*) dest="${a#--output=}"; continue ;;
      http://*|https://*) url="$a" ;;
    esac
    args+=("$a")
  done
  BP_CURL_TMP="$(mktemp -d "${TMPDIR:-/tmp}/bp-curl.XXXXXX")" || { bp_curl__say "CANNOT run: mktemp failed"; return 64; }
  local hdr="$BP_CURL_TMP/hdr" body="$BP_CURL_TMP/body"
  BP_CURL_BODY_FILE="$body"
  local attempt=1 waited=0 code rc asked wait src giveup=""
  while :; do
    : > "$hdr"
    rc=0
    : > "$body"
    code="$(command curl -D "$hdr" -w '%{http_code}' -o "$body" ${args[@]+"${args[@]}"})" || rc=$?
    [ -n "$dest" ] && cp "$body" "$dest" 2>/dev/null
    if [ "$rc" != 0 ]; then BP_CURL_CODE=""; BP_CURL_RC="$rc"; return 0; fi
    [ "$code" = "429" ] || break
    asked="$(bp_curl__retry_after "$body" "$hdr")"
    if [ -n "$asked" ]; then wait="$asked"; src="the server asked for it"; else wait="$BP_CURL_DEFAULT_WAIT_S"; src="no retry_after given, using our default"; fi
    if [ "$wait" -gt "$BP_CURL_MAX_WAIT_S" ]; then
      giveup="the server asked for ${wait}s, longer than this program will ever wait on your behalf (${BP_CURL_MAX_WAIT_S}s), so the 429 is reported unslept"; break
    fi
    if [ "$attempt" -ge "$BP_CURL_ATTEMPTS" ]; then
      giveup="the attempt cap of ${BP_CURL_ATTEMPTS} is spent (waited ${waited}s in total)"; break
    fi
    if [ $((waited + wait)) -gt "$BP_CURL_MAX_TOTAL_WAIT_S" ]; then
      giveup="a further ${wait}s would exceed the ${BP_CURL_MAX_TOTAL_WAIT_S}s total-wait budget for one call (already waited ${waited}s)"; break
    fi
    bp_curl__say "rate limited (429) on ${url:-<url>} — BACKPRESSURE, not a fault; waiting ${wait}s (${src}) and retrying (attempt ${attempt} of ${BP_CURL_ATTEMPTS})"
    sleep "$wait"
    waited=$((waited + wait)); attempt=$((attempt + 1))
  done
  if [ "$code" = "429" ]; then
    bp_curl__say "BP-CURL-RATE-LIMITED: the server is rate limiting this client on ${url:-<url>} — HTTP 429${asked:+ retry_after=$asked}, and ${giveup}"
  fi
  BP_CURL_CODE="$code"; BP_CURL_RC=0
  return 0
}

# bp_curl_code <curl args…> -> final http_code on stdout (nothing + curl's rc on transport failure)
bp_curl_code() {
  bp_curl__refuse_args "$@" || return $?
  BP_CURL_TMP=""
  bp_curl__run "$@" || { rm -rf "${BP_CURL_TMP:-}"; return $?; }
  rm -rf "$BP_CURL_TMP"
  if [ "$BP_CURL_RC" != 0 ]; then return "$BP_CURL_RC"; fi
  printf '%s' "$BP_CURL_CODE"
}

# bp_curl_body <curl args…> -> body on stdout + 0 on 2xx; 22 + a named status on stderr otherwise
bp_curl_body() {
  bp_curl__refuse_args "$@" || return $?
  BP_CURL_TMP=""
  bp_curl__run "$@" || { rm -rf "${BP_CURL_TMP:-}"; return $?; }
  local rc="$BP_CURL_RC" code="$BP_CURL_CODE" body="$BP_CURL_BODY_FILE"
  if [ "$rc" != 0 ]; then rm -rf "$BP_CURL_TMP"; return "$rc"; fi
  case "$code" in
    2??) [ -f "$body" ] && cat "$body"; rm -rf "$BP_CURL_TMP"; return 0 ;;
    *) bp_curl__say "HTTP ${code:-<none>} from the server (body withheld from stdout; the status is the verdict)"
       rm -rf "$BP_CURL_TMP"; return 22 ;;
  esac
}
