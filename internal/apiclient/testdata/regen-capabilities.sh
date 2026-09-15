#!/usr/bin/env bash
# Regenerate internal/apiclient/testdata/capabilities.json — the committed
# capabilities manifest the path-drift gate (manifest_path_drift_test.go) reads.
#
#   internal/apiclient/testdata/regen-capabilities.sh
#
# WHY THIS SCRIPT EXISTS. The fixture is a SECOND COPY of the server's route
# table. A second copy with no mechanical way to refresh is exactly the defect
# the gate is meant to cure, rebuilt one layer down: it rots, someone "fixes"
# the gate by editing the fixture to match the Go literal, and the gate is then
# asserting the Go code against itself. The refresh must be one command that
# nobody has to remember the shape of. It is this one.
#
# HOW TO USE IT. Run it whenever the drift gate reds because the SERVER moved
# (a route renamed, a command added) — never to silence a red caused by the Go
# side. Commit the regenerated fixture as its own change, with the manifest
# etag in the commit message.
#
# CONFIG. Server + token are read, in order, from:
#   1. $BARKPARK_API_URL / $BARKPARK_TOKEN
#   2. ~/.config/barkpark/config.json  (.server / .token — what `bp` itself uses)
# The token is used for the request ONLY. It is never written to the fixture.
#
# WHY NOT `bp capabilities -o json`? bp renders a LEGEND-COMPACTED manifest
# (commands as positional arrays, no `http` key at all), so it cannot source a
# path_template gate. The wire body from GET /v1/capabilities carries
# http.method + http.path_template per command. Measured 2026-09-15:
# `bp capabilities -o json | jq '.commands[0].http'` errors with
# "Cannot index array with string \"http\"".
#
# ADMIN TIER IS REQUIRED. /v1/capabilities is tier-projected (existence hiding):
# an anonymous caller saw 22 commands where the admin manifest carried 212 on
# 2026-09-15. A fixture captured at a lower tier would silently drop the routes
# the gate is supposed to police, and the gate would go vacuous while staying
# green. The script refuses anything but auth_tier "admin".

set -euo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
out="$here/capabilities.json"
cfg="${HOME}/.config/barkpark/config.json"

server="${BARKPARK_API_URL:-}"
token="${BARKPARK_TOKEN:-}"
if [ -z "$server" ] && [ -r "$cfg" ]; then server="$(jq -r '.server // empty' "$cfg")"; fi
if [ -z "$token" ]  && [ -r "$cfg" ]; then token="$(jq -r '.token  // empty' "$cfg")"; fi

if [ -z "$server" ]; then echo "regen-capabilities: no server (set BARKPARK_API_URL or configure $cfg)" >&2; exit 2; fi
if [ -z "$token"  ]; then echo "regen-capabilities: no token (set BARKPARK_TOKEN or configure $cfg)"  >&2; exit 2; fi

server="${server%/}"
tmp="$(mktemp -t bp-caps)"
trap 'rm -f "$tmp"' EXIT

curl -fsS -H "Authorization: Bearer ${token}" "${server}/v1/capabilities" -o "$tmp"

tier="$(jq -r '.auth_tier // "?"' "$tmp")"
n="$(jq -r '.commands | length' "$tmp")"
withhttp="$(jq -r '[.commands[] | select(.http.path_template != null)] | length' "$tmp")"

# Three refusals, each guarding a way this fixture could land LOOKING fine and
# measuring nothing.
[ "$tier" = "admin" ] || { echo "regen-capabilities: auth_tier is '$tier', not 'admin' — tier-projected manifest would under-report routes" >&2; exit 3; }
[ "$n" -ge 100 ]      || { echo "regen-capabilities: only $n commands — not a live surface" >&2; exit 3; }
[ "$withhttp" -ge 100 ] || { echo "regen-capabilities: only $withhttp commands carry http.path_template — wrong representation (legend-compacted?)" >&2; exit 3; }

captured="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
etag="$(jq -r '.etag // ""' "$tmp")"

# The fixture header. JSON carries no comments, so provenance rides a root
# `_fixture` key: where it came from, when, and the command that refreshes it.
# manifest_path_drift_test.go ASSERTS this key is present and populated, so the
# provenance cannot be dropped by a careless hand-edit.
# SLIMMED, deliberately. The gate reads id + noun + verb + http.method +
# http.path_template and nothing else; the full wire body is ~243KB of summaries
# and flag descriptions that would make every refresh an unreviewable diff. The
# slim is done HERE, mechanically, so it is not a hand step that can be done
# differently next time. Commands with no `http` key are DROPPED and the drop is
# counted in the header, so a representation change that strips `http` shows up
# as a number rather than as silence.
jq --arg captured "$captured" --arg server "$server" --arg tier "$tier" --arg etag "$etag" '
  {
    "_fixture": {
      "what": "GET /v1/capabilities, verbatim wire body (admin tier).",
      "source": $server,
      "captured_at": $captured,
      "server_etag": $etag,
      "regenerate": "internal/apiclient/testdata/regen-capabilities.sh",
      "read_by": "internal/apiclient/manifest_path_drift_test.go",
      "do_not": "Do NOT hand-edit to make the drift gate green. A red means the Go literals and the server disagree; fix whichever is wrong and re-run this script.",
      "slimmed_to": ["id", "noun", "verb", "http.method", "http.path_template"],
      "commands_on_wire": ($n | tonumber),
      "commands_kept": ([.commands[] | select(.http.path_template != null)] | length)
    },
    "manifest_version": .manifest_version,
    "auth_tier": .auth_tier,
    "etag": .etag,
    "generated_at": .generated_at,
    "server": .server,
    "commands": [
      .commands[]
      | select(.http.path_template != null)
      | {id, noun, verb, http: {method: .http.method, path_template: .http.path_template}}
      | if (.id == null) then del(.id) else . end
    ]
  }
' --arg n "$n" "$tmp" > "$out"

echo "wrote $out"
echo "  tier=$tier commands=$n with_path_template=$withhttp etag=$etag captured_at=$captured"
