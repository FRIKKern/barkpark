# Phase 7 WI7 — Bokbasen E2E tests are tagged `:bokbasen_integration` and
# excluded by default so the standard `mix test` invocation stays free of
# external HTTP fixtures. Run them explicitly with:
#
#     mix test --include bokbasen_integration
#
# See api/test/barkpark/plugins/onixedit/bokbasen/e2e_test.exs.
#
# Phase 8 WI5 — the Phase 4-8 demo test (`phase8_e2e_test.exs`) USED to be
# tagged `:phase8_demo`, with its WI3/WI4 assertion blocks behind
# `:requires_wi3` / `:requires_wi4`, "until WI6 close-out flips the
# includes". WI6 closed and nothing ever flipped them, so for months the
# three describes issued no signal at all and silently rotted red. All
# three tags are GONE as of the phase8 unpark: the demo now runs in the
# default `mix test` lane like any other test. Do not re-park a test
# behind a tag no CI step includes — a test that cannot run cannot fail.
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
# wbqs-api-vacuous-tests — the generated-thumb-rendition test needs a real
# `vips` binary on PATH to produce a rendition. Tagged `:requires_vips` so a
# box without libvips gets a visible ExUnit skip instead of the test quietly
# passing. Run explicitly on a machine that has vips installed:
#
#     mix test --include requires_vips
#
ExUnit.start(
  exclude: [
    :bokbasen_integration,
    :flaky,
    :boot_test,
    :plugin_routes,
    :requires_vips,
    # The `tsc --noEmit` check on priv/plugin_types.d.ts needs a TypeScript
    # compiler. Tagged `:requires_node` and excluded for the same reason as
    # `:requires_vips` above: a box without one gets a VISIBLE skip instead of
    # the test quietly passing. It used to run everywhere and take a
    # `find_executable -> nil -> :ok` arm, so deleting plugin_types.d.ts
    # outright kept it green. Run explicitly:
    #
    #     mix test --include requires_node
    #
    :requires_node,
    # Live IdP interop (needs the Keycloak container) — scripts/idp-interop.sh
    :idp_interop,
    # Real-binary Studio-chat E2E (spawns the actual `claude` CLI: ~$0.43 +
    # ~40s per run, needs OAuth login). Opt-in via scripts/claude-chat-e2e.sh —
    # NEVER in the default lane or CI. See
    # test/barkpark_web/studio/claude_chat_real_binary_test.exs (charter D20).
    :real_binary,
    # The claim-forward LIVE probe (task-adaae4196cffa86f): it reaches a REAL
    # instance's `/v1/tasks/prime` derived-ready head over HTTP, so it needs a
    # network and a credential and can never run in the default lane. Point it
    # at an instance and opt in:
    #
    #     BARKPARK_LIVE_URL=https://guerrilla.barkpark.cloud \
    #     BARKPARK_LIVE_TOKEN=<a read token> \
    #     mix test --include live_probe \
    #       test/barkpark/tasks/board/claim_forward_live_probe_test.exs
    #
    # Mirrors the TUI half's `-tags liveprobe` build tag.
    :live_probe
  ]
)

# NODE-GLOBAL LEAK PROBE — the PER-MODULE arm (task-086261728f14c078).
#
# The after_suite arm below says a key leaked. It cannot say WHICH module leaked
# it, and finding that out cost a full diagnosis on 2026-09-20: run 35509163543
# printed `value left behind: :one_shot` and the writer turned out to be
# `Barkpark.OneShot.boot!/0`, called by `Mix.Tasks.Barkpark.Preview.Backfill`
# and `Mix.Tasks.Barkpark.Workspace.ProvisionSchemas` — two frames below any
# test source, so no static reader of api/test could see it.
#
# A formatter gets `:module_finished` for every module, so it can. APPENDED to
# whatever is already configured (`mix test --formatter …` must keep working);
# it never replaces the CLI formatter.
ExUnit.configure(
  formatters: ExUnit.configuration()[:formatters] ++ [Barkpark.BootModeLeakFormatter]
)

# NODE-GLOBAL LEAK PROBE — the RUNTIME arm (task-086261728f14c078).
#
# `scripts/test-env-leak-gate.sh` is a STATIC reader. Its rule is "an on_exit
# restoring this key exists in the module", and its own moduledoc says so: a
# green from it means "a restore is WRITTEN", never "a restore RAN". That is
# not a tightening away — elixir-nightly 35323296944 (2026-09-18) reddened two
# assertions in application_boot_mode_test.exs with `left: :one_shot` while the
# writer module had a correct, present, matching `on_exit`. The gate was green
# and RIGHT to be green; the leak was still live. A static reader cannot close
# that, so something must run.
#
# This is the cheap half of that something: at the END of the suite, a
# node-global key that no test claims to own must be in its pristine state. It
# costs one function call per run and it cannot be vacuous — the pristine value
# is asserted below, not read from the tree.
#
# WHAT IT DOES NOT CATCH, stated rather than left to be discovered: a write that
# is restored before the suite ends but AFTER some other module read it. That is
# the transient the 09-18 nightly actually drew, and it is caught at the SOURCE
# instead — `Barkpark.BootModeSandbox` restores synchronously in a `try … after`
# and then re-reads the key, so a restore that does not land reds the writer's
# own test. The two arms are complementary: the sandbox catches it in the
# module that caused it, this catches anything that escaped the whole run.
ExUnit.after_suite(fn _results ->
  case Barkpark.BootModeSandbox.current() do
    :error ->
      :ok

    {:ok, mode} ->
      IO.puts(:stderr, """

      ================================================================
      NODE-GLOBAL LEAK: :barkpark, :boot_mode outlived the whole suite
      ================================================================

        value left behind: #{inspect(mode)}

      This key is ONE value for the WHOLE NODE. Whatever set it did not put it
      back, and in a run where the ExUnit shuffle puts a reader after the writer
      that reader fails an assertion about code it does not touch.

      Every write must go through `Barkpark.BootModeSandbox` (api/test/support),
      which restores in a `try … after` and asserts the restore landed.
      ================================================================
      """)

      # Non-zero exit, not just a shout: a detector that only prints is read as
      # decoration and scrolls past in 60k lines of CI log.
      System.at_exit(fn _ -> exit({:shutdown, 1}) end)
  end
end)

# ── chat_bridge fixture (Connectors D54) ───────────────────────────────────
#
# WHY THIS IS HERE AND NOT IN A MIGRATION.
#
# `chat_bridge.connector_installs` is owned by the CONNECTORS BRIDGE — a
# standalone Node service (`connectors/`) that creates its own schema and DDL at
# boot. Charter D28 forbids an Ecto migration for it: two owners of one table is
# how you get a silent drift. So the Elixir test DB has never had the table, and
# `Barkpark.Connectors.Install` (`@schema_prefix "chat_bridge"`) would raise
# `ERROR 42P01 (undefined_table)` on the first read. That — not any GRANT — is
# the actual blocker (D54: prod's Repo role OWNS chat_bridge, and CI's Postgres
# is a superuser).
#
# THROUGH `Repo`, NOT A RAW POSTGREX CONN. Whoever executes the CREATE becomes
# the schema's OWNER. Running it through the Repo makes the TEST role the owner,
# so no GRANT is ever needed here. A raw Postgrex connection with hardcoded
# superuser credentials would re-introduce exactly the creator≠reader split this
# avoids. It also must run BEFORE `Sandbox.mode(:manual)` — after that, DDL would
# be trapped inside a per-test transaction and rolled back. The sandbox rolls
# back across a non-`public` prefix fine, so tests stay isolated.
#
# ⚠️ DDL CROSS-REFERENCE — this is a SECOND source of truth.
# The statement below TRANSCRIBES `connectors/src/db/schema.ts`
# (`CREATE_CONNECTOR_INSTALLS_SQL` + `ADD_CHAT_TOKEN_REF_SQL`), which carries a
# comment pointing back at this block. That file HAS ALREADY DRIFTED once —
# `ADD_CHAT_TOKEN_REF_SQL` exists precisely because `CREATE TABLE IF NOT EXISTS`
# was a no-op against the older four-column table. If you change one, change the
# other. `test/barkpark/connectors/install_schema_test.exs` pins the exact column
# set the catalog reads, so a drift reds the Elixir suite instead of 500ing
# Studio in production.
Barkpark.Repo.query!("CREATE SCHEMA IF NOT EXISTS chat_bridge")

Barkpark.Repo.query!("""
CREATE TABLE IF NOT EXISTS chat_bridge.connector_installs (
  provider       text NOT NULL,
  install_key    text NOT NULL,
  workspace_id   text NOT NULL,
  credential_ref text,
  chat_token_ref text,
  created_at     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (provider, install_key)
)
""")

# Idempotent forward path for a test DB created before chat_token_ref existed —
# `CREATE TABLE IF NOT EXISTS` is a NO-OP against an existing table, so the new
# column would otherwise never appear. Mirrors the bridge's ADD_CHAT_TOKEN_REF_SQL.
Barkpark.Repo.query!("""
ALTER TABLE chat_bridge.connector_installs
  ADD COLUMN IF NOT EXISTS chat_token_ref text
""")

Ecto.Adapters.SQL.Sandbox.mode(Barkpark.Repo, :manual)
