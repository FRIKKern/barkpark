#!/usr/bin/env bash
# render.test.sh: a fixture repo's day pages render the expected README News block.
# Finished days only: the day dated "today" and a day without groups never show, and only
# the newest --days finished days do. Hermetic: mktemp fixture, no git, no gh, no network.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/docs/news"

day() { # day <date> <json-or-empty>
  {
    echo "<!-- doc-tier: human | canonical-for: news-$1 | budget: 3000tok -->"
    [ -n "$2" ] && echo "<!-- news-day: $2 -->"
    echo "# The day $1"
  } >"$T/docs/news/$1.md"
}
day 2026-11-13 '{"summary": "Oldest finished day.", "groups": [{"label": "Old", "text": "falls off", "prs": [1]}]}'
day 2026-11-14 '{"summary": "Saturday.", "groups": [{"label": "Desk", "text": "dialogs ask first", "prs": [10, 11]}]}'
day 2026-11-15 '{"summary": "A quiet Sunday."}'
day 2026-11-16 '{"summary": "Today so far.", "groups": [{"label": "Now", "text": "not finished", "prs": [99]}]}'
day 2026-11-12 ''
echo "# Feature article, not a day page" >"$T/docs/news/2026-11-14-feature.md"
day 2026-11-11 '{"summary": "Friday.", "groups": [{"label": "Papers", "text": "find and replace", "prs": [5]}, {"label": "Sheets", "text": "charts", "prs": [6]}]}'

printf '# Fixture\n\n## News\n\n<!-- news:start -->\nstale text\n<!-- news:end -->\n\n## After\n' >"$T/README.md"

python3 "$HERE/render.py" "$T" --repo OWNER/fixture --today 2026-11-16 --days 2 >/dev/null

cat >"$T/expected.md" <<'EOF'
# Fixture

## News

<!-- news:start -->
**Saturday 14 November.** Saturday. [The full day](docs/news/2026-11-14.md)
- **Desk:** dialogs ask first ([#10](https://github.com/OWNER/fixture/pull/10), [#11](https://github.com/OWNER/fixture/pull/11))

**Friday 13 November.** Oldest finished day. [The full day](docs/news/2026-11-13.md)
- **Old:** falls off ([#1](https://github.com/OWNER/fixture/pull/1))
<!-- news:end -->

## After
EOF
if ! diff -u "$T/expected.md" "$T/README.md"; then
  echo "FAIL: rendered block differs from the expected one" >&2
  exit 1
fi

# Idempotent: a second run changes nothing, and --check agrees.
python3 "$HERE/render.py" "$T" --repo OWNER/fixture --today 2026-11-16 --days 2 --check >/dev/null || {
  echo "FAIL: --check says a freshly rendered README would change" >&2
  exit 1
}

# A malformed news-day line is refused (exit 2), never rendered around.
echo '<!-- news-day: {"summary": ""} -->' >>"$T/docs/news/2026-11-14.md"
sed -i.bak '2d' "$T/docs/news/2026-11-14.md"
rc=0
python3 "$HERE/render.py" "$T" --repo OWNER/fixture --today 2026-11-16 --check >/dev/null 2>&1 || rc=$?
if [ "$rc" -ne 2 ]; then
  echo "FAIL: an empty summary exited $rc, want 2" >&2
  exit 1
fi

echo "PASS render.test.sh: finished days only, newest 2, idempotent, malformed refused"
