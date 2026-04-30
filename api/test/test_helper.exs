# Phase 7 WI7 — Bokbasen E2E tests are tagged `:bokbasen_integration` and
# excluded by default so the standard `mix test` invocation stays free of
# external HTTP fixtures. Run them explicitly with:
#
#     mix test --include bokbasen_integration
#
# See api/test/barkpark/plugins/onixedit/bokbasen/e2e_test.exs.
ExUnit.start(exclude: [:bokbasen_integration])
Ecto.Adapters.SQL.Sandbox.mode(Barkpark.Repo, :manual)
