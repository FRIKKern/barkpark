#!/bin/sh
set -e

# Run migrations
bin/barkpark eval "Barkpark.Release.migrate()"

# Run seeds (idempotent — uses ON CONFLICT DO NOTHING)
bin/barkpark eval "Barkpark.Release.seed()"

# Start the server
exec bin/barkpark start
