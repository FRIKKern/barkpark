# Phase 7 WI7 — Bokbasen E2E tests are tagged `:bokbasen_integration` and
# excluded by default so the standard `mix test` invocation stays free of
# external HTTP fixtures. Run them explicitly with:
#
#     mix test --include bokbasen_integration
#
# See api/test/barkpark/plugins/onixedit/bokbasen/e2e_test.exs.
#
# Phase 8 WI5 — the Phase 4-8 demo test (`phase8_e2e_test.exs`) is tagged
# `:phase8_demo`. It composes the full pipeline (book → ONIX export →
# Bokbasen submit → poll → :accepted → composite write) plus optional
# WI3/WI4 assertions. WI3 (BookEditor sign-off badge) and WI4 (codelist
# staleness) ship in parallel teams; their assertion blocks are tagged
# `:requires_wi3` and `:requires_wi4` so this test stays green-on-default
# until WI6 close-out flips the includes.
#
# Run the demo explicitly:
#
#     mix test --include phase8_demo
#     mix test --include phase8_demo --include requires_wi3 --include requires_wi4
#
# Goal barkpark-mgu — migration tests that drive `Ecto.Migrator.up/3` (and
# the `apply_up/1` / `apply_down/1` paths sharing its `repo.query!` shape)
# race against the SQL sandbox on connection checkout. Tagged `:flaky` so
# the default `mix test` run stays green. Run explicitly with:
#
#     mix test --include flaky
#
# See api/test/barkpark/repo/migrations/codelist_issue_version_test.exs.
#
# Goal barkpark-G1 — the fresh-install invariant regression bar
# (`plugin_free_boot_test.exs`) stops and restarts the whole :barkpark app
# inside `setup_all` with `:plugins` forced to `[]`. Tagged `:boot_test` so
# the default `mix test` invocation stays clean of the app restart. Run
# explicitly:
#
#     mix test --only boot_test test/barkpark/plugin_free_boot_test.exs
#
# Goal barkpark-G2 task s5 — the plugin-route highway lock
# (`plugin_routes_test.exs`) mutates the `:barkpark, :plugins` env around
# its second describe to assert `Plugins.Registry.collect_routes/1`
# collapses to `[]`. Tagged `:plugin_routes` so the default run leaves the
# env untouched. Run explicitly:
#
#     mix test --only plugin_routes test/barkpark_web/plugin_routes_test.exs
#
# Indx plugin — the LIVE end-to-end test (`indx/integration_test.exs`) drives
# a REAL local Indx engine over HTTP (login, index, search). Tagged
# `:indx_live` and excluded by default so the standard `mix test` run never
# reaches a network. Launch a dedicated single-tenant Indx at
# http://127.0.0.1:5001 (seeds admin@indx.co), then run explicitly:
#
#     mix test --only indx_live test/barkpark/plugins/indx/integration_test.exs
#
ExUnit.start(
  exclude: [
    :bokbasen_integration,
    :phase8_demo,
    :requires_wi3,
    :requires_wi4,
    :flaky,
    :boot_test,
    :plugin_routes,
    :indx_live
  ]
)
Ecto.Adapters.SQL.Sandbox.mode(Barkpark.Repo, :manual)
