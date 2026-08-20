#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BASE_URL=${E03_BASE_URL:-https://guerrilla.barkpark.cloud}
mkdir -p "$ROOT/raw/paper-view" "$ROOT/raw/task-show" "$ROOT/raw/public-reader" "$ROOT/raw/email-proxy" "$ROOT/raw/studio"

python3 - "$ROOT/fixture-manifest.json" <<'PY' > "$ROOT/raw/paper.ids"
import json,sys
for row in json.load(open(sys.argv[1]))["papers"]:
    print(row["id"])
PY
python3 - "$ROOT/fixture-manifest.json" <<'PY' > "$ROOT/raw/task.ids"
import json,sys
for row in json.load(open(sys.argv[1]))["tasks"]:
    print(row["id"])
PY

while IFS= read -r id; do
  set +e
  /usr/bin/time -p -o "$ROOT/raw/paper-view/$id.time" \
    bp paper view "$id" > "$ROOT/raw/paper-view/$id.stdout.txt" 2> "$ROOT/raw/paper-view/$id.stderr.txt"
  rc=$?
  set -e
  printf '%s\n' "$rc" > "$ROOT/raw/paper-view/$id.exit"
  /usr/bin/time -p -o "$ROOT/raw/public-reader/$id.time" \
    curl -sS -L -D "$ROOT/raw/public-reader/$id.headers.txt" -o "$ROOT/raw/public-reader/$id.body.html" \
    -w '%{http_code}\n' "$BASE_URL/papers/$id" > "$ROOT/raw/public-reader/$id.status" 2> "$ROOT/raw/public-reader/$id.stderr.txt" || true
  /usr/bin/time -p -o "$ROOT/raw/email-proxy/$id.time" \
    curl -sS -L -D "$ROOT/raw/email-proxy/$id.headers.txt" -o "$ROOT/raw/email-proxy/$id.body.html" \
    -w '%{http_code}\n' "$BASE_URL/papers/$id/email" > "$ROOT/raw/email-proxy/$id.status" 2> "$ROOT/raw/email-proxy/$id.stderr.txt" || true
done < "$ROOT/raw/paper.ids"

while IFS= read -r id; do
  set +e
  /usr/bin/time -p -o "$ROOT/raw/task-show/$id.time" \
    bp task get "$id" > "$ROOT/raw/task-show/$id.stdout.txt" 2> "$ROOT/raw/task-show/$id.stderr.txt"
  rc=$?
  set -e
  printf '%s\n' "$rc" > "$ROOT/raw/task-show/$id.exit"
done < "$ROOT/raw/task.ids"

# Anonymous Studio probe: a login redirect proves the authenticated content view
# was not exercised. It must remain BLOCKED, never PASS.
/usr/bin/time -p -o "$ROOT/raw/studio/anonymous.time" \
  curl -sS -L -D "$ROOT/raw/studio/anonymous.headers.txt" -o "$ROOT/raw/studio/anonymous.body.html" \
  -w '%{http_code}\n' "$BASE_URL/studio" > "$ROOT/raw/studio/anonymous.status" 2> "$ROOT/raw/studio/anonymous.stderr.txt" || true

printf '%s\n' "$BASE_URL" > "$ROOT/raw/base-url.txt"
