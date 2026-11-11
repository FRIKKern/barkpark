#!/usr/bin/env bash
# Tests for scripts/ci-apt-dns-fallback.sh. No network, no sudo: the resolver
# file is a temp file and the probe host is one that never resolves.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
fails=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want [$3] got [$2]"; fails=$((fails + 1)); fi; }
run() { APT_DNS_SUDO= APT_DNS_RESOLV_CONF="$conf" APT_DNS_PROBE_HOST=never-resolves.invalid bash "$here/ci-apt-dns-fallback.sh" "$@" >/dev/null 2>&1; }

conf="$(mktemp)"
printf 'nameserver 168.63.129.16\nsearch x.internal\n' >"$conf"

run; check "exits 0 when the lookup fails" "$?" "0"
check "public resolvers come first" "$(sed -n '1,2p' "$conf" | tr '\n' ' ')" "nameserver 1.1.1.1 nameserver 8.8.8.8 "
check "the runner's own resolver is kept" "$(grep -c '^nameserver 168.63.129.16$' "$conf")" "1"
check "the search line is kept" "$(grep -c '^search x.internal$' "$conf")" "1"

before="$(cat "$conf")"
run --force; check "exits 0 when forced" "$?" "0"
check "a second call writes nothing more" "$(cat "$conf")" "$before"

printf 'nameserver 1.1.1.1 # already here\n' >"$conf"
run --force; check "a 1.1.1.1 line with a trailing comment counts as present" "$(grep -c '1\.1\.1\.1' "$conf")" "1"

printf 'nameserver\t168.63.129.16\ndomain x.internal\n' >"$conf"
run --force
check "a tab-separated nameserver line is kept" "$(grep -c '168.63.129.16' "$conf")" "1"
check "a domain line is kept" "$(grep -c '^domain x.internal$' "$conf")" "1"

conf="/nonexistent-dir/resolv.conf"
run --force; check "exits 0 when the file cannot be written" "$?" "0"

[ "$fails" = 0 ] && echo "ci-apt-dns-fallback.test: all passed" || { echo "ci-apt-dns-fallback.test: $fails failed"; exit 1; }
