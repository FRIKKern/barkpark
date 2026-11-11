#!/usr/bin/env bash
# Give a CI runner public DNS resolvers when its own resolver does not answer
# for the Ubuntu archive. Called by the libxml2-utils install in
# .github/workflows/elixir.yml (job mix-test), before the first apt call and
# again after a failed install attempt.
#
# 2026-11-11, 13:51Z on: every `apt-get` on the hosted runners (image
# ubuntu-26.04 20261101.186.1, westus3) answered "Temporary failure resolving
# 'archive.ubuntu.com'" (also azure.archive and security.ubuntu.com) on all
# three attempts, for hours. The Elixir test job went red with zero tests run,
# on main and on every PR; nothing merged (task-dfe49f27e50f16ff).
#
# This changes WHO answers the name lookup, nothing else: the install is still
# retried and still the decision, and the step still reds when xmllint is
# absent. It never exits non-zero, so it cannot red a job by itself.
#
#   scripts/ci-apt-dns-fallback.sh           # only when the lookup fails
#   scripts/ci-apt-dns-fallback.sh --force   # after a failed install attempt
set -u
host="${APT_DNS_PROBE_HOST:-archive.ubuntu.com}"
conf="${APT_DNS_RESOLV_CONF:-/etc/resolv.conf}"
sudo_cmd="${APT_DNS_SUDO-sudo}"

if [ "${1:-}" != "--force" ] && getent hosts "$host" >/dev/null 2>&1; then
  echo "ci-apt-dns-fallback: $host resolves; the runner's resolver is left as it is"
  exit 0
fi
if grep -Eq '^nameserver[[:space:]]+1\.1\.1\.1([[:space:]]|$)' "$conf" 2>/dev/null; then
  echo "ci-apt-dns-fallback: public resolvers are already in $conf"
  exit 0
fi
echo "::warning::the runner's resolver does not answer for $host; this job now also asks 1.1.1.1 and 8.8.8.8"
old="$(grep -E '^(nameserver|search|domain|options)[[:space:]]' "$conf" 2>/dev/null || true)"
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n%s\n' "$old" | $sudo_cmd tee "$conf" >/dev/null ||
  echo "ci-apt-dns-fallback: could not write $conf; the install runs on the runner's resolver"
if getent hosts "$host" >/dev/null 2>&1; then
  echo "ci-apt-dns-fallback: $host resolves now"
else
  echo "ci-apt-dns-fallback: $host still does not resolve"
fi
exit 0
