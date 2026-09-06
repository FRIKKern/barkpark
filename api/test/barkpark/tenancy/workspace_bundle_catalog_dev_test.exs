defmodule Barkpark.Tenancy.WorkspaceBundleCatalogDevTest do
  @moduledoc """
  The dev-profile partition acceptance gate (PDS charter D4/D5/D8).

  Every proof is MECHANICAL and LIVE-derived — the bundle-reachable set is
  re-computed from the catalog on every run (never a hardcoded table count),
  the fail-closed sentinel is exercised protectively (an injected unknown
  table must RAISE), and the single-column-PK assertion is proven non-vacuous
  by injecting a composite-PK table through the sentinel's test seam.

  This suite covers CLASSIFICATION DATA + SENTINEL only — dev-profile export
  behavior is a separate slice (pds-w1-dev-export). The full-fidelity partition
  (`assert_partition!/1`) has its own gate in workspace_bundle_test.exs.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Repo
  alias Barkpark.Tenancy.WorkspaceBundle.Catalog

  # The live bundle-reachable set: root + E1 + E2 + E3 + allowlist — exactly
  # what the dev sentinel must account for. Re-derived here, never pinned.
  defp reachable do
    ([Catalog.root_table()] ++
       Catalog.live_e1(Repo) ++
       Catalog.live_e2(Repo) ++
       Catalog.live_e3(Repo) ++ Map.keys(Catalog.allowlist()))
    |> Enum.uniq()
    |> Enum.sort()
  end

  describe "dev partition coverage (PDS-D4: deny-by-default)" do
    test "sentinel passes on the clean schema and the partition covers EXACTLY the bundle-reachable set" do
      assert :ok = Catalog.assert_dev_partition!(Repo)

      classified = Catalog.dev_partition() |> Map.keys() |> Enum.sort()
      assert classified == reachable()

      # copy + deny (+ scrub, empty in W1) tile the classified set exactly.
      assert Enum.sort(Catalog.dev_copy_tables() ++ Catalog.dev_deny_tables()) == classified
    end

    test "the charter deny census is :deny, table by table" do
      # Credential / secret stores, PII trails, sync family — named in PDS-D4.
      for table <-
            ~w(api_tokens secrets secrets_audit data_keys access_grants webhooks
               share_links registered_chat_hosts preview_token_jti audit_events
               chat_execution_leases chat_execution_events workspace_memberships
               sync_cursors sync_dead_letters sync_push_conflicts
               sync_push_cursors sync_push_doc_revs) do
        assert Catalog.dev_partition()[table] == :deny,
               "#{table} is charter-denied (PDS-D4) and must never travel in a dev bundle"
      end

      # SIZE denies — also close the ticket-snapshot back door (PDS-D5).
      assert Catalog.dev_partition()["mutation_events"] == :deny
      assert Catalog.dev_partition()["revisions"] == :deny

      # Fail-closed edge verdicts beyond the literal census names:
      #   * audit_export_sinks carries a plaintext `secret` sink column;
      #   * webhook_deliveries is the payload+signature trail of denied webhooks;
      #   * shares is an access-granting registry — copying it would silently
      #     re-open public surfaces on the dev target;
      #   * github_sync_conflicts is sync-family with content-bearing payloads;
      #   * chat_runtime_usage_receipts is a cycle-fleet telemetry FK child;
      #   * search_intel_events carries raw user-typed `query` text plus
      #     `actor_key`/`session_key` identity — per-user behavioral telemetry
      #     ("user PII never copied"); the derived crystals/merge_patterns
      #     aggregates carry no actor identity and stay copy.
      for table <-
            ~w(audit_export_sinks webhook_deliveries shares github_sync_conflicts
               chat_runtime_usage_receipts search_intel_events) do
        assert Catalog.dev_partition()[table] == :deny,
               "#{table} must be denied fail-closed"
      end
    end

    test "every cycle_*/epic_*/sync_* reachable table is denied MECHANICALLY (prefix law, live-derived)" do
      for table <- reachable(), String.match?(table, ~r/^(cycle_|epic_|sync_)/) do
        assert Catalog.dev_partition()[table] == :deny,
               "#{table} matches the fleet/sync deny prefix (PDS-D4) but is not :deny"
      end
    end

    test "the content plane copies: triad roots + content + config" do
      for table <-
            ~w(workspaces projects datasets media_files roles role_permissions
               schema_definitions content_edges task_edges
               paper_events authoring_exemptions search_surface_config
               search_synonyms) do
        assert Catalog.dev_action(table) == :copy,
               "#{table} is dev-relevant content/config and must copy"
      end
    end

    test "RULED 2026-09-02: plugin_doc_state is :deny — an unreviewed opaque payload never travels" do
      # The one classification in this partition that is a RULING rather than a
      # census reading. plugin_doc_state is a (plugin_name, doc_id, key) ->
      # value:map scratch bag with no declared safe-key contract and no reader
      # or writer anywhere in api/lib; @dev_scrub is empty, so :copy would have
      # shipped whatever the first plugin decides to stash in `value`.
      assert Catalog.dev_partition()["plugin_doc_state"] == :deny
      assert Catalog.dev_action("plugin_doc_state") == :deny
      assert "plugin_doc_state" in Catalog.dev_deny_tables()
      refute "plugin_doc_state" in Catalog.dev_copy_tables()

      # …and the deny is NARROW: its bundle-reachable siblings, including the
      # other traveling composite-PK table, are untouched by the ruling.
      for still_copied <- ~w(content_edges task_edges authoring_exemptions paper_events) do
        assert Catalog.dev_action(still_copied) == :copy,
               "#{still_copied} must NOT have been swept up by the plugin_doc_state deny"
      end
    end
  end

  describe "documents type-deny axis (PDS-D5)" do
    test "documents is :copy WITH deny_types carrying type=ticket as consumable data" do
      assert {:copy, deny_types: ["ticket"]} = Catalog.dev_partition()["documents"]
      assert Catalog.dev_doc_type_deny() == ["ticket"]
      # The normalized action for the export loop is still :copy — the type
      # axis rides beside it, not instead of it.
      assert Catalog.dev_action("documents") == :copy
      assert "documents" in Catalog.dev_copy_tables()
    end

    test "dev_action is fail-closed: an unclassified table NEVER copies" do
      assert Catalog.dev_action("zzz_table_nobody_reviewed") == :deny
    end
  end

  describe "fail-closed sentinel (PDS-D4 mirror of assert_partition!/1)" do
    test "an injected UNCLASSIFIED tenant table makes the sentinel RAISE, and dropping it heals" do
      assert :ok = Catalog.assert_dev_partition!(Repo)

      Repo.query!(
        "CREATE TABLE zzz_dev_unclassified (id uuid PRIMARY KEY, workspace_id uuid)",
        []
      )

      assert "zzz_dev_unclassified" in Catalog.live_e1(Repo)

      assert_raise RuntimeError, ~r/unclassified bundle-reachable.*FAILS CLOSED/s, fn ->
        Catalog.assert_dev_partition!(Repo)
      end

      # Clean up so the injected table never leaks into the shared test DB.
      Repo.query!("DROP TABLE zzz_dev_unclassified", [])
      assert :ok = Catalog.assert_dev_partition!(Repo)
    end

    test "a phantom entry (classified but not reachable) RAISES" do
      with_phantom = Map.put(Catalog.dev_partition(), "zzz_dev_phantom", :deny)

      assert_raise RuntimeError, ~r/not.*bundle-reachable/s, fn ->
        Catalog.assert_dev_partition!(Repo, with_phantom)
      end
    end

    test "a malformed classification value RAISES before anything else" do
      malformed = Map.put(Catalog.dev_partition(), "documents", :sort_of_copy)

      assert_raise RuntimeError, ~r/malformed/, fn ->
        Catalog.assert_dev_partition!(Repo, malformed)
      end

      # An empty scrub list is malformed too — scrub-nothing must be :copy.
      empty_scrub = Map.put(Catalog.dev_partition(), "media_files", {:scrub_fields, []})

      assert_raise RuntimeError, ~r/malformed/, fn ->
        Catalog.assert_dev_partition!(Repo, empty_scrub)
      end
    end

    test "the scrub_fields shape is a VALID classification (W1-empty, model-ready)" do
      Repo.query!(
        """
        CREATE TABLE zzz_dev_scrubbed
          (id uuid PRIMARY KEY, workspace_id uuid, api_secret text)
        """,
        []
      )

      with_scrub =
        Map.put(Catalog.dev_partition(), "zzz_dev_scrubbed", {:scrub_fields, ["api_secret"]})

      assert :ok = Catalog.assert_dev_partition!(Repo, with_scrub)

      Repo.query!("DROP TABLE zzz_dev_scrubbed", [])
    end
  end

  describe "single-column-PK assertion (PDS-D8 merge arbiter)" do
    # HONESTY NOTE vs the brief's "94/94 single-column PK": the live census is
    # 94/94 base tables WITH a primary key but only 86/94 single-column —
    # plugin_doc_state (3-col) and authoring_exemptions (2-col). Since the
    # 2026-09-02 ruling denied plugin_doc_state, authoring_exemptions is the
    # only TRAVELING composite, which is what the no-rot test below pins. The
    # merge arbiter is `order_columns` (the FULL pk list), so a reviewed
    # composite is a valid `ON CONFLICT (a, b) DO UPDATE` arbiter; the sentinel
    # stays fail-closed on NO-pk tables and UNreviewed composites.
    defp pk_arity(table) do
      %{rows: [[arity]]} =
        Repo.query!(
          """
          SELECT COALESCE(
            (SELECT array_length(c.conkey, 1)
             FROM pg_constraint c
             JOIN pg_class cl ON cl.oid = c.conrelid
             WHERE c.contype = 'p' AND cl.relname = $1), 0)
          """,
          [table]
        )

      arity
    end

    test "every traveling table has a pk arbiter: single-column unless on the reviewed composite list, live-proven" do
      for table <- Catalog.dev_copy_tables() do
        arity = pk_arity(table)

        assert arity >= 1,
               "#{table} is copy-classified but has NO primary key — " <>
                 "the merge-import ON CONFLICT (pk) DO UPDATE arbiter needs one"

        if table not in Catalog.dev_composite_pk_ok() do
          assert arity == 1,
                 "#{table} is copy-classified with a #{arity}-column PK but is not on " <>
                   "the reviewed composite-PK list — review it or fix the schema"
        end
      end
    end

    test "the reviewed composite-PK list matches live reality exactly (no rot, no padding)" do
      live_composites =
        Catalog.dev_copy_tables()
        |> Enum.filter(&(pk_arity(&1) > 1))
        |> Enum.sort()

      assert live_composites == Enum.sort(Catalog.dev_composite_pk_ok())
    end

    test "PROTECTIVE: a copy-classified table with a COMPOSITE PK makes the sentinel RAISE" do
      Repo.query!(
        """
        CREATE TABLE zzz_dev_composite_pk
          (a uuid, b uuid, workspace_id uuid, PRIMARY KEY (a, b))
        """,
        []
      )

      with_composite =
        Map.put(Catalog.dev_partition(), "zzz_dev_composite_pk", :copy)

      assert_raise RuntimeError, ~r/single-column primary key/, fn ->
        Catalog.assert_dev_partition!(Repo, with_composite)
      end

      # Denied, the same table is fine — the PK law binds traveling tables only.
      with_denied = Map.put(Catalog.dev_partition(), "zzz_dev_composite_pk", :deny)
      assert :ok = Catalog.assert_dev_partition!(Repo, with_denied)

      Repo.query!("DROP TABLE zzz_dev_composite_pk", [])
    end
  end

  describe "full-profile isolation" do
    test "the full-fidelity partition sentinel still passes untouched beside the dev partition" do
      assert :ok = Catalog.assert_partition!(Repo)
    end
  end
end
