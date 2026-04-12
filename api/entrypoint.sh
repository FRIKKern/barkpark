#!/bin/sh
set -e

# Run migrations
bin/sanity_api eval "SanityApi.Release.migrate()"

# Run seeds (idempotent — uses ON CONFLICT DO NOTHING)
bin/sanity_api eval "SanityApi.Release.seed()"

# Start the server
exec bin/sanity_api start
