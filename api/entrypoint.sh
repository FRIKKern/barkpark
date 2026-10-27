#!/bin/sh
set -e

# An image is pinned to one release, so the update check is off unless the
# operator sets BARKPARK_SELF_UPDATE_CHECK=on. The update runner stays off
# unless BARKPARK_SELF_UPDATE_APPLY=1, and an image has no checkout to apply to.
: "${BARKPARK_SELF_UPDATE_CHECK:=off}"
export BARKPARK_SELF_UPDATE_CHECK

# The image runs as uid 10001. A volume created by an older, root-run image
# keeps root ownership, so say how to fix it instead of failing on first upload.
if [ ! -w /app/uploads ]; then
  echo "entrypoint: /app/uploads is not writable by uid $(id -u)." >&2
  echo "entrypoint: give the volume to uid 10001, for example:" >&2
  echo "entrypoint:   docker run --rm -u 0 -v <volume>:/app/uploads <image> chown -R 10001:10001 /app/uploads" >&2
  exit 1
fi

# Run migrations
bin/barkpark eval "Barkpark.Release.migrate()"

# Run seeds (idempotent — uses ON CONFLICT DO NOTHING)
bin/barkpark eval "Barkpark.Release.seed()"

# Start the server
exec bin/barkpark start
