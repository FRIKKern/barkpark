#!/usr/bin/env bash
# TEMPORARY PLANT — task-2f62b64c32be3780 c2. Removed in the next commit.
# Under `set -o pipefail`, find(1) outruns the 64KB pipe and head(1) closes it,
# so this assignment takes the PRODUCER's status: 141, not a verdict.
set -euo pipefail
first=$(find / -type f | head -1)
echo "$first"
