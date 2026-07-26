#!/usr/bin/env bash
# scrub.sh <file> — redact known secret shapes; scrubbed content to stdout.
#
# Portable bash 3.2 / BSD sed (macOS) and GNU sed (Linux) both work here.
# NOTE: sed operates line-by-line, so it cannot match a pattern that spans
# multiple lines (e.g. a PEM private key body). The BEGIN/END PRIVATE KEY
# block is therefore redacted separately with perl -0pe (slurp mode) BEFORE
# the single-line sed passes run. If perl is unavailable, this step is
# skipped with a loud warning to stderr — never fail silently on a secret.
set -euo pipefail
[ $# -eq 1 ] || { echo "usage: scrub.sh <file>" >&2; exit 2; }
[ -f "$1" ] || { echo "scrub.sh: no such file: $1" >&2; exit 2; }

redact_multiline_keys() {
  if command -v perl >/dev/null 2>&1; then
    perl -0pe 's/-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----/[REDACTED-PRIVATE-KEY]/gs'
  else
    echo "scrub.sh: WARNING: perl not found — multiline PRIVATE KEY blocks were NOT scrubbed. Inspect output manually before sharing." >&2
    cat
  fi
}

redact_multiline_keys < "$1" | sed -E \
  -e 's/bp_(admin|ingest|read|write)_[A-Za-z0-9_-]+/[REDACTED-BP-TOKEN]/g' \
  -e 's/(Bearer )[A-Za-z0-9._~+\/=-]+/\1[REDACTED]/g' \
  -e 's/(BARKPARK_[A-Z_]*TOKEN["'\'' ]*[:=][" '\'']*)[^"'\'' ,}]+/\1[REDACTED]/g' \
  -e 's/gh[pousr]_[A-Za-z0-9]{20,}/[REDACTED-GH-TOKEN]/g' \
  -e 's/github_pat_[A-Za-z0-9_]{20,}/[REDACTED-GH-TOKEN]/g' \
  -e 's/sk-ant-[A-Za-z0-9_-]{20,}/[REDACTED-ANTHROPIC-KEY]/g' \
  -e 's/sk-[A-Za-z0-9]{20,}/[REDACTED-API-KEY]/g' \
  -e 's/AKIA[0-9A-Z]{16}/[REDACTED-AWS-KEY]/g' \
  -e 's/(AWS_SECRET_ACCESS_KEY["'\'' ]*[:=][" '\'']*)[^"'\'' ,}]+/\1[REDACTED-AWS-SECRET]/g' \
  -e 's/(AWS_SESSION_TOKEN["'\'' ]*[:=][" '\'']*)[^"'\'' ,}]+/\1[REDACTED-AWS-SECRET]/g'
