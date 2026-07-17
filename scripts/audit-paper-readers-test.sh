#!/usr/bin/env bash
set -euo pipefail

repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/bp-paper-audit-test.XXXXXX")"
trap 'trash "$tmp" >/dev/null 2>&1 || true' EXIT

cat >"$tmp/fake-bp" <<'FAKE_BP'
#!/usr/bin/env bash
if [[ " $* " == *" search query "* ]]; then
  if [[ "${BP_FIXTURE_EMPTY:-}" == "1" ]]; then
    printf '%s\n' '{"documents":[]}'
  else
    printf '%s\n' '{"documents":[{"_id":"blocks-paper"},{"_id":"html-paper"}]}'
  fi
  exit 0
fi
if [[ " $* " == *" paper view "* && " $* " == *" --profile none "* ]]; then
  printf 'readable\n'
  exit 0
fi
exit 9
FAKE_BP

cat >"$tmp/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
out=""
url=""
while (($#)); do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -w|-H) shift 2 ;;
    -L|-sS) shift ;;
    *) url="$1"; shift ;;
  esac
done
if [[ "$url" == */source ]]; then
  if [[ "$url" == *html-paper* ]]; then
    printf '%s' '{"source":{"kind":"html","html":"<p>legacy</p>"}}' >"$out"
  else
    printf '%s' '{"source":{"kind":"blocks","blocks":[]}}' >"$out"
  fi
elif [[ "$url" == */email ]]; then
  printf '%s' '<!doctype html><p>mail</p>' >"$out"
else
  printf '%s' '<!doctype html><p>reader</p>' >"$out"
fi
printf '200'
FAKE_CURL

chmod +x "$tmp/fake-bp" "$tmp/curl"
PATH="$tmp:$PATH" BP_AUDIT_BIN="$tmp/fake-bp" BP_AUDIT_BASE_URL="https://fixture.invalid" \
  "$repo/scripts/audit-paper-readers.sh" >"$tmp/result.json"

jq -e '.ok and .inventory == 2 and .audited == 2 and .passed == 2 and .failed == 0' \
  "$tmp/result.json" >/dev/null

if PATH="$tmp:$PATH" BP_FIXTURE_EMPTY=1 BP_AUDIT_BIN="$tmp/fake-bp" \
  BP_AUDIT_BASE_URL="https://fixture.invalid" \
  "$repo/scripts/audit-paper-readers.sh" >"$tmp/empty-result.json"; then
  printf 'empty paper inventory unexpectedly passed\n' >&2
  exit 1
fi

jq -e '.ok == false and .error == "paper inventory must be a non-empty documents array with string ids"' \
  "$tmp/empty-result.json" >/dev/null
printf 'paper reader audit fixture: PASS\n'
