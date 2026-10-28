#!/usr/bin/env bash
# release-migrations.sh <from-ref> <to-ref> — the "Migrations" section of a
# release's notes, as Markdown on stdout.
#
# Lists every file added under api/priv/repo/migrations between the two refs
# and marks each one expand or contract. The mark is mechanical and reads only
# the `up` or `change` body (a `def down` block is skipped):
#   contract  the body drops or renames a table or column, or sets NOT NULL
#             (Ecto: drop/drop_if_exists table, remove, remove_if_exists,
#             rename, modify ... null: false, and inside alter table an add
#             with null: false and no default; SQL: DROP TABLE, DROP COLUMN,
#             RENAME, SET NOT NULL)
#   expand    anything else
# A contract line is printed beside the file so the person blessing the release
# can check it. docs/ops/PROD_OPS.md says why the split matters: old and new code
# share the new schema during a blue/green swap.
#
# Called by scripts/release-curator-draft.sh. Run it by hand for a release:
#   bash scripts/release-migrations.sh v0.2.27 v0.2.28
#
# Exits 2 when either ref does not resolve. bash 3.2 compatible.
set -uo pipefail

from="${1:-}"
to="${2:-}"
[ -n "$from" ] && [ -n "$to" ] || { echo "usage: release-migrations.sh <from-ref> <to-ref>" >&2; exit 2; }
DIR="api/priv/repo/migrations"

git rev-parse --verify --quiet "$from^{commit}" >/dev/null || { echo "release-migrations: $from does not resolve" >&2; exit 2; }
git rev-parse --verify --quiet "$to^{commit}" >/dev/null || { echo "release-migrations: $to does not resolve" >&2; exit 2; }

added="$(git diff --diff-filter=A --name-only "$from" "$to" -- "$DIR" | grep -E '\.exs$' || true)"

printf '### Migrations\n\n'
if [ -z "$added" ]; then
  printf 'No new files under `%s`.\n' "$DIR"
  exit 0
fi

count="$(printf '%s\n' "$added" | wc -l | tr -d ' ')"
printf '%s new file(s) under `%s`. The mark is mechanical: **contract** when the up or change body drops or renames a table or column or sets NOT NULL, **expand** otherwise. Check each contract line before you publish.\n\n' "$count" "$DIR"

CONTRACT_RE='(^|[^_a-z])(drop(_if_exists)?[[:space:]]*\(?[[:space:]]*table\(|remove(_if_exists)?[[:space:]]+:|rename[[:space:]]*\(?[[:space:]]*table\(|modify[[:space:]]*\(?.*null:[[:space:]]*false)|DROP[[:space:]]+TABLE|DROP[[:space:]]+COLUMN|[[:space:]]RENAME[[:space:]]|SET[[:space:]]+NOT[[:space:]]+NULL'

printf '%s\n' "$added" | while IFS= read -r f; do
  # Body without any `def down` block: from `  def down` (not the one-line
  # `def down, do:` form) to the next line that is exactly `  end`.
  # The `from:` half of a reversible modify names the OLD shape, so it is cut
  # before matching. Inside `alter table(...)`, an `add ... null: false` with no
  # `default:` is also contract: code from the previous release inserts rows
  # without that column.
  hit="$(git show "$to:$f" | awk '
    /^  def down([ (]|$)/ && !/, do:/ { skip = 1; next }
    skip && /^  end[[:space:]]*$/ { skip = 0; next }
    skip { next }
    /^[[:space:]]*#/ { next }
    /alter[[:space:]]*\(?[[:space:]]*table\(/ { alter = 1 }
    /create(_if_not_exists)?[[:space:]]*\(?[[:space:]]*table\(/ { alter = 0 }
    {
      line = $0
      sub(/from:[[:space:]]*\{[^}]*\}/, "", line)
      tag = ""
      if (alter && line ~ /(^|[^_a-z])add(_if_not_exists)?[[:space:]]*\(?[[:space:]]*:/ && line ~ /null:[[:space:]]*false/ && line !~ /default:/) tag = "ALTER-NOT-NULL "
      print NR ": " tag line
    }' | grep -E "$CONTRACT_RE|: ALTER-NOT-NULL " | head -1 | sed -E 's/^([0-9]+): (ALTER-NOT-NULL )? */\1: /' | cut -c1-140)"
  name="$(basename "$f")"
  if [ -n "$hit" ]; then
    printf -- '- `%s`: contract (line %s)\n' "$name" "$(printf '%s' "$hit" | sed -E 's/^([0-9]+): (.*)$/\1, `\2`/')"
  else
    printf -- '- `%s`: expand\n' "$name"
  fi
done
