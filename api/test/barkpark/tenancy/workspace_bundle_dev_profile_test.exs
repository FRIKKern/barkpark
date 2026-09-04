defmodule Barkpark.Tenancy.WorkspaceBundleDevProfileTest do
  @moduledoc """
  The profile-aware, dataset-granular export gate (PDS-D3/D7 · D27/D28/D29/D31).

  Every proof here is MECHANICAL and adversarial: the secret scan reads the RAW
  tar bytes (not the manifest's own summary of itself), the skip-not-post-filter
  proof reads the QUERIES the export actually issued, and every deny assertion
  is paired with a `:full`-profile positive control so a vacuous green — a
  refute that passes because the row was never seeded — is impossible.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.QueryCounter

  import Barkpark.TenancyFixtures

  alias Barkpark.Repo
  alias Barkpark.Tenancy.WorkspaceBundle
  alias Barkpark.Tenancy.WorkspaceBundle.{Archive, Catalog, ExportScopeError}

  # ── PDS-D31: the deny is a SKIP, not a post-filter ───────────────────────────

  describe "profile :dev denies at COPY time (PDS-D31)" do
    test "a webhook secret, an api_token hash, a scoped secret and a ticket are ZERO-hit in the RAW bundle bytes, and the denied tables are absent from the manifest" do
      f = seed_dev_fixture!()

      {:ok, dev} = WorkspaceBundle.export(f.ws.id, profile: :dev)
      {manifest, _dumps} = Archive.unpack(dev)

      # Positive control FIRST: the full-fidelity bundle really does carry all
      # four, so the refutes below cannot pass vacuously.
      {:ok, full} = WorkspaceBundle.export(f.ws.id)

      for marker <- [f.webhook_secret, f.token_hash, f.secret_marker, f.ticket_marker] do
        assert full =~ marker,
               "positive control failed: #{marker} is not in the FULL bundle either"

        refute dev =~ marker, "#{marker} leaked into the dev bundle's raw bytes"
      end

      names = MapSet.new(manifest["tables"], & &1["name"])

      for denied <- Catalog.dev_deny_tables() do
        refute MapSet.member?(names, denied),
               "denied table #{denied} is a member of the dev manifest"
      end

      # …and everything that SHOULD travel still does (no over-deny).
      for copied <- Catalog.dev_copy_tables() do
        assert MapSet.member?(names, copied), "copy-classified #{copied} is missing"
      end

      assert MapSet.size(names) == length(Catalog.dev_copy_tables())
      assert manifest["profile"] == "dev"
    end

    test "a denied table is never QUERIED — no COPY is issued for it (the memory-peak proof, not just a filtered manifest)" do
      f = seed_dev_fixture!()

      {_bundle, queries} =
        capture_queries(fn -> WorkspaceBundle.export(f.ws.id, profile: :dev) end)

      # `Enum.uniq` because `capture_queries` is TELEMETRY-based and the
      # streamed producer emits one query event PER FETCH — a fat table issues
      # the SAME `COPY (…)` string once per chunk. Uniquing collapses those
      # back to one event per TABLE, which is the quantity this proof is about.
      #
      # This stays a strict `==`, never a `>=`: the whole content of the
      # PDS-D31 skip-not-post-filter proof is that a denied table is never
      # queried AT ALL, and `>=` would pass for an export that copied every
      # table and filtered afterwards — exactly the build this test exists to
      # catch.
      copies = queries |> Enum.filter(&String.starts_with?(&1, "COPY (")) |> Enum.uniq()
      assert length(copies) == length(Catalog.dev_copy_tables())

      # Sampled across all three deny classes: secret store, size class, PII.
      for denied <- ~w(api_tokens webhooks secrets mutation_events revisions audit_events
                       search_intel_events) do
        assert denied in Catalog.dev_deny_tables()

        refute Enum.any?(queries, &String.contains?(&1, denied)),
               "#{denied} was touched by a query during a dev export — the deny must skip the " <>
                 "table BEFORE the COPY loop, never filter its bytes afterwards"
      end

      # The full profile is the foil: there, every one of them IS copied.
      {_bundle, full_queries} = capture_queries(fn -> WorkspaceBundle.export(f.ws.id) end)

      full_copies = Enum.filter(full_queries, &String.starts_with?(&1, "COPY ("))

      for denied <- ~w(api_tokens webhooks secrets mutation_events revisions) do
        assert Enum.any?(full_copies, &String.contains?(&1, denied)),
               "foil failed: the FULL profile must still COPY #{denied}"
      end
    end
  end

  # ── PDS-D28 + D27: the type-deny is read explicitly, and it CASCADES ─────────

  describe "documents type-deny (PDS-D28) and its cascade (PDS-D27)" do
    test "dev_action/1 FLATTENS the deny to a bare :copy — only dev_doc_type_deny/0 carries it" do
      # This is the trap the exporter must not fall into: an exporter driven off
      # dev_action/1 alone sees a correct-looking :copy for documents and ships
      # every ticket.
      assert Catalog.dev_action("documents") == :copy
      assert Catalog.dev_doc_type_deny() == ["ticket"]
    end

    test "a seeded ticket AND its content_edges / plugin_doc_state children are absent from the dev bundle; the full bundle carries all three" do
      f = seed_dev_fixture!()

      {:ok, full} = WorkspaceBundle.export(f.ws.id)
      {_fm, full_dumps} = Archive.unpack(full)

      # Positive control: the full profile carries the ticket, both edges (the
      # ticket is the TO endpoint of one and the FROM endpoint of the other) and
      # the plugin_doc_state row.
      assert full_dumps["documents"] =~ f.ticket_marker
      assert full_dumps["content_edges"] =~ f.ticket_id
      assert full_dumps["task_edges"] =~ f.ticket_id
      assert full_dumps["plugin_doc_state"] =~ f.plugin_state_marker

      {:ok, dev} = WorkspaceBundle.export(f.ws.id, profile: :dev)
      {_dm, dev_dumps} = Archive.unpack(dev)

      refute dev_dumps["documents"] =~ f.ticket_marker
      # THE CASCADE: without it these children travel as FK-violating orphans
      # carrying the denied conversation's graph.
      refute dev_dumps["content_edges"] =~ f.ticket_id
      refute dev_dumps["task_edges"] =~ f.ticket_id
      refute dev_dumps["plugin_doc_state"] =~ f.plugin_state_marker

      # No over-cascade: the ordinary doc, its ordinary edge and its own
      # plugin_doc_state row all still travel.
      assert dev_dumps["documents"] =~ f.post_marker
      assert dev_dumps["content_edges"] =~ f.plain_edge_id
      assert dev_dumps["plugin_doc_state"] =~ f.plain_plugin_state_marker
    end

    test "the E3 doc-keyed semi-join cascades too — a denied ticket's authoring_exemption never travels" do
      f = seed_dev_fixture!()

      {:ok, full} = WorkspaceBundle.export(f.ws.id)
      {_m, full_dumps} = Archive.unpack(full)
      assert full_dumps["authoring_exemptions"] =~ f.ticket_doc_id

      {:ok, dev} = WorkspaceBundle.export(f.ws.id, profile: :dev)
      {_m, dev_dumps} = Archive.unpack(dev)

      refute dev_dumps["authoring_exemptions"] =~ f.ticket_doc_id
      assert dev_dumps["authoring_exemptions"] =~ f.post_doc_id
    end
  end

  # ── PDS-D29: the dataset arbiter ────────────────────────────────────────────

  describe "dataset arbiter (PDS-D29)" do
    test "resolves datasets->projects->workspace, so a slug a SIBLING workspace also owns still resolves — dataset_slugs_for/1 would have selected the empty set" do
      f = seed_dev_fixture!()

      # The live trap, reproduced: a sibling workspace owns the same slug, so the
      # project-qualified helper drops it entirely.
      sibling = create_workspace!(unique("wssib"))
      sibling_proj = create_project!(sibling, unique("projsib"))
      insert_dataset!(sibling_proj.id, f.alpha)

      refute f.alpha in WorkspaceBundle.dataset_slugs_for(f.ws.id),
             "fixture invalid: the slug must be shared to reproduce the trap"

      {:ok, bundle} = WorkspaceBundle.export(f.ws.id, dataset: f.alpha)
      {manifest, dumps} = Archive.unpack(bundle)

      # Resolved by identity, not by the slug set: alpha's documents travel…
      assert dumps["documents"] =~ f.post_marker
      refute dumps["documents"] =~ f.beta_marker
      assert manifest["dataset"] == f.alpha

      # …while the bare-slug E3 members stay fail-CLOSED on the shared slug.
      assert manifest["dataset_slugs"] == []
      refute dumps["preview_token_jti"] =~ f.jti_alpha
    end

    test "an unknown slug and an AMBIGUOUS slug both raise a named ExportScopeError, never a silent pick" do
      f = seed_dev_fixture!()

      err =
        assert_raise ExportScopeError, fn ->
          WorkspaceBundle.export(f.ws.id, dataset: "no-such-dataset-#{f.tag}")
        end

      assert err.code == "dataset_not_found"

      # TWO projects of the SAME workspace owning the slug — a workspace-scoped
      # resolve has no defensible pick (a dataset slug is unique only per project).
      second_proj = create_project!(f.ws, unique("proj2"))
      insert_dataset!(second_proj.id, f.alpha)

      err =
        assert_raise ExportScopeError, fn ->
          WorkspaceBundle.export(f.ws.id, dataset: f.alpha)
        end

      assert err.code == "ambiguous_dataset_slug"
      assert Exception.message(err) =~ f.alpha
    end

    test "sibling-dataset exclusion: Group-A narrows to the target, the TRIAD roots ship narrowed, Group-C travels workspace-whole" do
      f = seed_dev_fixture!()

      {:ok, bundle} = WorkspaceBundle.export(f.ws.id, dataset: f.alpha)
      {manifest, dumps} = Archive.unpack(bundle)

      members = Map.new(manifest["tables"], &{&1["name"], &1})

      # Group-A (documents, media_files, …) — only the target dataset's rows.
      assert dumps["documents"] =~ f.post_marker
      refute dumps["documents"] =~ f.beta_marker

      # The triad: the workspace row, its OWNING project, the target dataset row.
      assert members["workspaces"]["row_count"] == 1
      assert members["projects"]["row_count"] == 1
      assert members["datasets"]["row_count"] == 1
      assert dumps["datasets"] =~ f.alpha
      refute dumps["datasets"] =~ f.beta

      # Group-C has no dataset grain to narrow on and travels workspace-whole —
      # deliberate (PDS-D7): the import loads with member FK constraints
      # dropped (re-added NOT VALID — task-7889645a51769a36), so a dangling
      # child lands as a recoverable orphan rather than aborting.
      assert dumps["content_edges"] =~ f.beta_edge_id
    end

    test "Group-A narrows on the CANONICAL dataset_id, never the `dataset` string mirror" do
      f = seed_dev_fixture!()

      # A beta document whose denormalized `dataset` string was rewritten to the
      # target slug while dataset_id still points at beta. Keying on the mirror
      # would pull it into alpha's bundle.
      Repo.query!("UPDATE documents SET dataset = $1 WHERE id = $2::text::uuid", [
        f.alpha,
        f.mirror_doc_id
      ])

      {:ok, bundle} = WorkspaceBundle.export(f.ws.id, dataset: f.alpha)
      {_manifest, dumps} = Archive.unpack(bundle)

      refute dumps["documents"] =~ f.mirror_marker
      assert dumps["documents"] =~ f.post_marker
    end

    test "E3 dataset-keyed members INTERSECT dataset_slugs_for/1 with the target — the sibling slug's rows never travel" do
      f = seed_dev_fixture!()

      # Both slugs are exclusive to this workspace here, so both are in the
      # project-qualified set; the intersection is what narrows to one.
      assert f.alpha in WorkspaceBundle.dataset_slugs_for(f.ws.id)
      assert f.beta in WorkspaceBundle.dataset_slugs_for(f.ws.id)

      {:ok, bundle} = WorkspaceBundle.export(f.ws.id, dataset: f.alpha)
      {manifest, dumps} = Archive.unpack(bundle)

      assert manifest["dataset_slugs"] == [f.alpha]
      assert dumps["preview_token_jti"] =~ f.jti_alpha
      refute dumps["preview_token_jti"] =~ f.jti_beta
    end

    test "profile and dataset COMPOSE — a dev bundle at dataset grain is both scrubbed and narrowed" do
      f = seed_dev_fixture!()

      {:ok, bundle} = WorkspaceBundle.export(f.ws.id, profile: :dev, dataset: f.alpha)
      {manifest, dumps} = Archive.unpack(bundle)

      assert manifest["profile"] == "dev"
      assert manifest["dataset"] == f.alpha
      assert dumps["documents"] =~ f.post_marker
      refute dumps["documents"] =~ f.beta_marker
      refute dumps["documents"] =~ f.ticket_marker

      # PDS-D215: this file's moduledoc promises every deny assertion is paired
      # with a `:full`-profile positive control, and this was the one raw
      # `refute` on a bundle value without one — a green here would have been
      # indistinguishable from a fixture that never seeded the secret at all.
      {:ok, full} = WorkspaceBundle.export(f.ws.id)

      assert full =~ f.webhook_secret,
             "positive control failed: the webhook secret is not in the FULL bundle either"

      refute bundle =~ f.webhook_secret
    end
  end

  # ── PDS-D3: additive manifest, unchanged import contract ────────────────────

  describe "manifest stays bp-export-v1 (PDS-D3)" do
    test "format is byte-identical, the new keys are ADDITIVE, and the existing import path accepts a dev bundle unchanged" do
      f = seed_dev_fixture!()

      {:ok, bundle} =
        WorkspaceBundle.export(f.ws.id,
          profile: :dev,
          dataset: f.alpha,
          source_server: "https://guerrilla.barkpark.cloud"
        )

      {manifest, _dumps} = Archive.unpack(bundle)

      assert manifest["format"] == "bp-export-v1"
      assert manifest["grain"] == "workspace"
      assert manifest["profile"] == "dev"
      assert manifest["dataset"] == f.alpha
      assert manifest["source_workspace"] == f.ws.slug
      assert manifest["source_dataset"] == f.alpha
      assert manifest["source_server"] == "https://guerrilla.barkpark.cloud"

      # Every pre-existing key still present and unchanged in meaning.
      for key <- ~w(format grain workspace_id workspace_slug exported_at dataset_slugs tables) do
        assert Map.has_key?(manifest, key)
      end

      # The import engine reads the manifest it always read — a dev bundle is
      # just a manifest with fewer members, so merge-convergence works untouched.
      assert {:ok, stats} = WorkspaceBundle.import_bundle(bundle, mode: :merge)
      assert stats.total_rows > 0
      assert Map.keys(stats.tables) |> Enum.sort() != []

      refute Map.has_key?(stats.tables, "api_tokens")
    end

    test "an unknown profile raises a named error rather than silently falling back to the full, secret-carrying bundle" do
      f = seed_dev_fixture!()

      err =
        assert_raise ExportScopeError, fn ->
          WorkspaceBundle.export(f.ws.id, profile: :staging)
        end

      assert err.code == "invalid_profile"

      # String forms are accepted (a controller passes a query param straight
      # through) — but only the two real ones.
      assert {:ok, _} = WorkspaceBundle.export(f.ws.id, profile: "dev")
      assert {:ok, _} = WorkspaceBundle.export(f.ws.id, profile: "full")
    end
  end

  # ── The permanent tripwire: the full path did not move ──────────────────────

  describe "the full-fidelity path is byte-identical (the tripwire)" do
    test "omitting every opt is EXACTLY profile: :full — dump for dump, manifest key for manifest key" do
      f = seed_dev_fixture!()

      {:ok, b0} = WorkspaceBundle.export(f.ws.id)
      {:ok, b1} = WorkspaceBundle.export(f.ws.id, profile: :full)

      {m0, d0} = Archive.unpack(b0)
      {m1, d1} = Archive.unpack(b1)

      # The bytes: every table's dump identical, member for member.
      assert d0 == d1

      # The manifest: identical but for the wall-clock stamp, which differs
      # between ANY two exports and is not part of the contract.
      assert Map.delete(m0, "exported_at") == Map.delete(m1, "exported_at")

      # And the additive keys carry the honest default.
      assert m0["profile"] == "full"
      assert m0["dataset"] == nil
      assert m0["source_server"] == nil
    end

    test "an explicit dataset does NOT change the full profile's table set — only its row scope" do
      f = seed_dev_fixture!()

      {:ok, whole} = WorkspaceBundle.export(f.ws.id)
      {:ok, scoped} = WorkspaceBundle.export(f.ws.id, dataset: f.alpha)

      {mw, _} = Archive.unpack(whole)
      {ms, _} = Archive.unpack(scoped)

      names = fn m -> m["tables"] |> Enum.map(& &1["name"]) |> Enum.sort() end
      assert names.(mw) == names.(ms)

      whole_docs = Enum.find(mw["tables"], &(&1["name"] == "documents"))["row_count"]
      scoped_docs = Enum.find(ms["tables"], &(&1["name"] == "documents"))["row_count"]
      assert scoped_docs > 0 and scoped_docs < whole_docs
    end
  end

  # ── fixture + helpers ───────────────────────────────────────────────────────

  # One workspace spanning every axis under test: two datasets (alpha/beta), a
  # denied-type ticket with children on all three cascade paths, a mirror-drifted
  # document, bare-slug E3 rows in both datasets, and one row in each of the
  # three deny classes (credential store / size class / PII).
  defp seed_dev_fixture! do
    tag = System.unique_integer([:positive])
    ws = create_workspace!(unique("wsdev"))
    proj = create_project!(ws, unique("projdev"))

    alpha = "alpha-#{tag}"
    beta = "beta-#{tag}"

    post_marker = "POST-ALPHA-#{tag}"
    beta_marker = "POST-BETA-#{tag}"
    mirror_marker = "MIRROR-BETA-#{tag}"
    ticket_marker = "TICKET-PII-#{tag}"

    {:ok, post} =
      create_document_in!(
        ws,
        proj,
        "post",
        %{"doc_id" => "post-#{tag}", "title" => post_marker},
        alpha
      )

    {:ok, ticket} =
      create_document_in!(
        ws,
        proj,
        "ticket",
        %{"doc_id" => "tkt-#{tag}", "title" => ticket_marker},
        alpha
      )

    {:ok, beta_doc} =
      create_document_in!(
        ws,
        proj,
        "post",
        %{"doc_id" => "beta-#{tag}", "title" => beta_marker},
        beta
      )

    {:ok, beta_doc2} =
      create_document_in!(
        ws,
        proj,
        "note",
        %{"doc_id" => "beta2-#{tag}", "title" => "beta sibling #{tag}"},
        beta
      )

    {:ok, mirror_doc} =
      create_document_in!(
        ws,
        proj,
        "post",
        %{"doc_id" => "mirror-#{tag}", "title" => mirror_marker},
        beta
      )

    # Fixture invariant: the Group-A narrowing is only meaningful if the
    # canonical column is actually stamped.
    assert scalar(
             "SELECT count(*) FROM documents WHERE id = $1::text::uuid AND dataset_id IS NOT NULL",
             [
               post.id
             ]
           ) == 1

    # The cascade surfaces: the ticket as edge TARGET, as edge SOURCE, and as a
    # plugin_doc_state owner. Plus an ordinary edge that must survive the cascade.
    insert_content_edge!(post.id, ticket.id)
    plain_edge_id = insert_content_edge!(post.id, beta_doc.id)
    beta_edge_id = insert_content_edge!(beta_doc.id, beta_doc2.id)
    insert_task_edge!(ticket.id, post.id)

    plugin_state_marker = "PLUGIN-TICKET-#{tag}"
    plain_plugin_state_marker = "PLUGIN-POST-#{tag}"
    insert_plugin_doc_state!(ticket.id, "k-#{tag}", plugin_state_marker)
    insert_plugin_doc_state!(post.id, "k-#{tag}", plain_plugin_state_marker)

    # E3 doc-keyed: one exemption per document, so the semi-join cascade is
    # observable in both directions.
    insert_exemption!(ticket.doc_id, alpha, "ticket")
    insert_exemption!(post.doc_id, alpha, "post")

    # E3 dataset-keyed: bare-slug rows in both datasets.
    jti_alpha = "JTI-ALPHA-#{tag}"
    jti_beta = "JTI-BETA-#{tag}"
    insert_preview_jti!(jti_alpha, alpha)
    insert_preview_jti!(jti_beta, beta)

    # The three deny classes, each with a distinctive plaintext marker the raw
    # byte scan looks for.
    webhook_secret = "WEBHOOK-SIGNING-SECRET-#{tag}"
    token_hash = "APITOKENHASH#{tag}"
    # `secrets.value` is Cloak-encrypted bytea (its COPY text is hex), so the
    # scannable marker rides the plaintext `name` column — the deny is
    # table-level either way: the whole row never travels.
    secret_marker = "RUNSECRET-NAME-#{tag}"

    Repo.query!(
      "INSERT INTO webhooks (id, workspace_id, name, url, dataset, secret, inserted_at, updated_at) " <>
        "VALUES (gen_random_uuid(), $1::text::uuid, $2, 'https://example.test/hook', $3, $4, now(), now())",
      [ws.id, "hook-#{tag}", alpha, webhook_secret]
    )

    Repo.query!(
      "INSERT INTO api_tokens (id, workspace_id, token_hash, label, dataset, inserted_at, updated_at) " <>
        "VALUES (gen_random_uuid(), $1::text::uuid, $2, $3, $4, now(), now())",
      [ws.id, token_hash, "tok-#{tag}", alpha]
    )

    Repo.query!(
      "INSERT INTO secrets (id, workspace_id, name, value, updated_at) " <>
        "VALUES (gen_random_uuid(), $1::text::uuid, $2, $3, now())",
      [ws.id, secret_marker, "run-secret-value-#{tag}"]
    )

    %{
      tag: tag,
      ws: ws,
      proj: proj,
      alpha: alpha,
      beta: beta,
      post_marker: post_marker,
      post_doc_id: post.doc_id,
      beta_marker: beta_marker,
      mirror_marker: mirror_marker,
      mirror_doc_id: mirror_doc.id,
      ticket_marker: ticket_marker,
      ticket_id: ticket.id,
      ticket_doc_id: ticket.doc_id,
      plain_edge_id: plain_edge_id,
      beta_edge_id: beta_edge_id,
      plugin_state_marker: plugin_state_marker,
      plain_plugin_state_marker: plain_plugin_state_marker,
      jti_alpha: jti_alpha,
      jti_beta: jti_beta,
      webhook_secret: webhook_secret,
      token_hash: token_hash,
      secret_marker: secret_marker
    }
  end

  # Collect every SQL statement THIS measurement issues while `fun` runs — the
  # only way to prove a table was never QUERIED (a manifest can only prove it
  # was never PACKED, which a post-filter would also satisfy).
  #
  # LINEAGE-SCOPED, via the shared `Barkpark.QueryCounter`: an absence claim
  # over a node-global capture is the most fragile shape there is — ANY
  # background process touching the table inside the window refutes it. The
  # capture now sees only this test process, anything it spawned, and any pid
  # it named with `own/1`. See `Barkpark.QueryCounterTest`.
  defp capture_queries(fun) do
    QueryCounter.sql(fun)
  end


  defp insert_dataset!(project_id, slug) do
    Repo.query!(
      "INSERT INTO datasets (id, project_id, slug, name, inserted_at, updated_at) " <>
        "VALUES (gen_random_uuid(), $1::text::uuid, $2, $2, now(), now())",
      [project_id, slug]
    )
  end

  defp insert_content_edge!(from_id, to_id) do
    %{rows: [[id]]} =
      Repo.query!(
        "INSERT INTO content_edges (id, from_id, to_id, kind, inserted_at, updated_at) " <>
          "VALUES (gen_random_uuid(), $1::text::uuid, $2::text::uuid, 'ref', now(), now()) " <>
          "RETURNING id::text",
        [from_id, to_id]
      )

    id
  end

  defp insert_task_edge!(from_id, to_id) do
    Repo.query!(
      "INSERT INTO task_edges (id, from_id, to_id, kind, inserted_at) " <>
        "VALUES (gen_random_uuid(), $1::text::uuid, $2::text::uuid, 'blocks', now())",
      [from_id, to_id]
    )
  end

  defp insert_plugin_doc_state!(doc_uuid, key, value) do
    Repo.query!(
      "INSERT INTO plugin_doc_state (plugin_name, doc_id, key, value, updated_at) " <>
        "VALUES ('pdstest', $1::text::uuid, $2, $3, now())",
      [doc_uuid, key, value]
    )
  end

  defp insert_exemption!(doc_id, dataset, type) do
    Repo.query!(
      "INSERT INTO authoring_exemptions (doc_id, dataset, type, exempted_at) " <>
        "VALUES ($1, $2, $3, now()) ON CONFLICT (doc_id, dataset) DO NOTHING",
      [doc_id, dataset, type]
    )
  end

  defp insert_preview_jti!(jti, dataset) do
    Repo.query!(
      "INSERT INTO preview_token_jti (jti, dataset, issued_at, expires_at) " <>
        "VALUES ($1, $2, now(), now() + interval '1 hour')",
      [jti, dataset]
    )
  end

  defp scalar(sql, params), do: Repo.query!(sql, params).rows |> hd() |> hd()

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
