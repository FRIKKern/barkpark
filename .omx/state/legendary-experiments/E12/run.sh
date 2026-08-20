#!/bin/sh
set -eu

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
cd "$HERE"

start=$(python3 -c 'import time; print(time.time_ns())')
python3 scripts/build.py
first=$(find . -maxdepth 1 -type f -name '*.json' ! -name timing.json -print | LC_ALL=C sort | xargs shasum -a 256)
python3 scripts/build.py
second=$(find . -maxdepth 1 -type f -name '*.json' ! -name timing.json -print | LC_ALL=C sort | xargs shasum -a 256)
[ "$first" = "$second" ]
python3 scripts/verify.py

for injection in missing-preimage fabricated-authority second-run-mutation; do
  set +e
  output=$(python3 scripts/verify.py --inject "$injection" 2>&1)
  status=$?
  set -e
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | grep -F "E12 INJECTION CAUGHT $injection" >/dev/null
done

end=$(python3 -c 'import time; print(time.time_ns())')
elapsed=$(python3 -c "print(round(($end - $start) / 1000000000, 6))")
if [ ! -f timing.json ] || [ "${E12_REFRESH_TIMING:-0}" = 1 ]; then
  python3 - "$elapsed" > timing.json <<'PY'
import json, sys
print(json.dumps({
    "assignment_id": "E12",
    "fixture_count": 36,
    "measurement": "two deterministic builds, positive verification, and three caught failure injections",
    "real_seconds": float(sys.argv[1]),
    "schema_version": "legendary-e12-timing/v1"
}, indent=2, sort_keys=True))
PY
fi
printf 'E12 REPLAY PASS in %ss: explicit REWORK/no-winner verdict preserved\n' "$elapsed"
