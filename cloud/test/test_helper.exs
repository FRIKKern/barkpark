ExUnit.start()

# ── Which database is this run on? (task-b169445c9f0031b3) ────────────────
# Prints ONE `BARKPARK-CLOUD-TEST-DB:` line naming the database and why it was
# chosen — locally an unset MIX_TEST_PARTITION means a per-checkout database,
# CI stays on `barkpark_cloud_test` via CI=true (config/test.exs) — plus a
# `SCHEMA DRIFT` line naming every version when the database's migrations are
# not this checkout's. Prints only; never fails the suite. The red is
# BarkparkCloud.SharedTestDbTest. Mirrors api/test/test_helper.exs (#20107).
#
# BEFORE `Sandbox.mode(:manual)`, as in api: under manual mode a query from this
# process has no checked-out connection, so every probe would read
# `:unavailable` and the line would name no database.
BarkparkCloud.SharedTestDb.report!(BarkparkCloud.Repo)

Ecto.Adapters.SQL.Sandbox.mode(BarkparkCloud.Repo, :manual)
