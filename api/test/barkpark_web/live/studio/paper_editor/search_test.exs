defmodule BarkparkWeb.Studio.PaperEditor.SearchTest do
  @moduledoc """
  In-Studio paper BLOCK EDITOR — wikilink + tag search handler units.

  Pure handler-unit coverage for `Paper.paper_wikilink_search/2` and
  `Paper.paper_tag_search/2`: a minimal LiveView socket (`bare_socket/1`) is
  driven directly past the handler, asserting blank/oversized queries short-
  circuit, matches return the right shape, and non-matches return `[]`. These
  do NOT mount the editor — they exercise the handler functions directly.

  `bare_socket/1` is section-local. The shared base-paper `setup` from
  `BarkparkWeb.PaperEditorTestHelpers` still runs (each describe layers its own
  candidate fixtures on top) — preserved verbatim from the original module.
  """
  use BarkparkWeb.ConnCase, async: false
  use BarkparkWeb.PaperEditorTestHelpers

  defp bare_socket(dataset) do
    # Build a minimal LiveView socket carrying only the assigns the handler
    # reads: `dataset` (direct) and `current_workspace` / `current_project`
    # (consumed by ScopeHelpers.scope_opts/1 — nil means no tenancy scope).
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        dataset: dataset,
        current_workspace: nil,
        current_project: nil
      }
    }
  end

  # ── paper_wikilink_search handler ────────────────────────────────────────────

  describe "paper_wikilink_search/2 — handler unit" do
    @wikilink_slug "2026-06-24-wikilink-candidate"

    setup do
      {:ok, _} =
        Content.upsert_paper(
          Barkpark.LabelFixtures.paper_attrs(%{
            slug: @wikilink_slug,
            dataset: @dataset,
            blocks: [
              %{
                "id" => "h-1",
                "type" => "heading",
                "text" => "Wikilink Candidate Paper",
                "level" => 1
              },
              # A body block: heading-only papers are hollow and refused by the
              # p-quality-gate hollow gate; this test is about wikilink search.
              %{
                "id" => "p-1",
                "type" => "paragraph",
                "content" => [%{"type" => "text", "value" => "Body."}]
              }
            ]
          })
        )

      :ok
    end

    test "blank query returns empty results without hitting the DB" do
      socket = bare_socket(@dataset)
      assert {:reply, %{results: []}, _socket} = Paper.paper_wikilink_search("", socket)
    end

    test "oversized query (> 100 chars) returns empty results" do
      socket = bare_socket(@dataset)
      long_q = String.duplicate("x", 101)
      assert {:reply, %{results: []}, _socket} = Paper.paper_wikilink_search(long_q, socket)
    end

    test "matching query returns candidate with title, string id, and type 'paper'" do
      socket = bare_socket(@dataset)

      {:reply, %{results: results}, _socket} =
        Paper.paper_wikilink_search("Wikilink", socket)

      assert Enum.any?(results, fn r ->
               r.title == "Wikilink Candidate Paper" and
                 is_binary(r.id) and
                 r.type == "paper"
             end)
    end

    test "non-matching query returns empty list" do
      socket = bare_socket(@dataset)

      {:reply, %{results: results}, _socket} =
        Paper.paper_wikilink_search("zzzzzzzz-nomatch", socket)

      assert results == []
    end
  end

  # ── paper_tag_search handler ──────────────────────────────────────────────────

  describe "paper_tag_search/2 — handler unit" do
    setup do
      # Tags live in `content["tags"]` (JSONB string array). Seed two papers so
      # the DISTINCT unnest has a duplicate to collapse.
      {:ok, _} =
        Content.create_document(
          "paper",
          %{"_id" => "tag-paper-a", "title" => "Tag Paper A", "tags" => ["design", "obsidian"]},
          @dataset
        )

      # Legacy flat-string tags are the shape under test — ride the exemption
      # ledger like prod's pre-wall corpus.
      Barkpark.LabelFixtures.exempt!("tag-paper-a", @dataset)
      {:ok, _} = Content.publish_document("tag-paper-a", "paper", @dataset)

      {:ok, _} =
        Content.create_document(
          "paper",
          %{"_id" => "tag-paper-b", "title" => "Tag Paper B", "tags" => ["design", "draft"]},
          @dataset
        )

      Barkpark.LabelFixtures.exempt!("tag-paper-b", @dataset)
      {:ok, _} = Content.publish_document("tag-paper-b", "paper", @dataset)

      :ok
    end

    test "blank query returns empty results without hitting the DB" do
      socket = bare_socket(@dataset)
      assert {:reply, %{results: []}, _socket} = Paper.paper_tag_search("", socket)
    end

    test "oversized query (> 100 chars) returns empty results" do
      socket = bare_socket(@dataset)
      long_q = String.duplicate("x", 101)
      assert {:reply, %{results: []}, _socket} = Paper.paper_tag_search(long_q, socket)
    end

    test "matching query returns DISTINCT tag-name strings" do
      socket = bare_socket(@dataset)

      {:reply, %{results: results}, _socket} = Paper.paper_tag_search("des", socket)

      assert results == ["design"]
      assert Enum.all?(results, &is_binary/1)
    end

    test "non-matching query returns empty list" do
      socket = bare_socket(@dataset)

      {:reply, %{results: results}, _socket} =
        Paper.paper_tag_search("zzzzzzzz-nomatch", socket)

      assert results == []
    end
  end

  # ── paper_tag_search handler — weighted corpus (D10/D18 close) ─────────────

  describe "paper_tag_search/2 — weighted-tag corpus" do
    setup do
      # A post-wall paper: weighted `{tag, strength, rationale}` entries,
      # published through the REAL wall (registered tags + compliant
      # description via LabelFixtures — the one test-side label spelling).
      content =
        Barkpark.LabelFixtures.with_named_labels(%{}, @dataset, ["weighted-design", "wtextra"])

      {:ok, _} =
        Content.create_document(
          "paper",
          Map.merge(%{"_id" => "tag-paper-w", "title" => "Weighted Tag Candidate"}, content),
          @dataset
        )

      {:ok, _} = Content.publish_document("tag-paper-w", "paper", @dataset)
      :ok
    end

    test "autocomplete returns weighted tag NAMES, not JSON blobs" do
      socket = bare_socket(@dataset)

      {:reply, %{results: results}, _socket} = Paper.paper_tag_search("weighted-des", socket)

      assert results == ["weighted-design"]
      assert Enum.all?(results, &is_binary/1)
    end

    test "rationale text never false-positives the typeahead" do
      # Every LabelFixtures rationale contains "exercises" — the OLD reader
      # unnested raw element text, so this query would have matched the blob.
      socket = bare_socket(@dataset)

      {:reply, %{results: results}, _socket} = Paper.paper_tag_search("exercises", socket)

      assert results == []
    end
  end

  # ── THE TENANT FENCE — both typeahead reads, with a REAL workspace ─────────
  #
  # Every arm above builds its socket with `bare_socket/1`, i.e.
  # `current_workspace: nil`. Both typeahead reads land in the PERMISSIVE
  # `Content.Scope.scope_to_workspace_or_global/3`, whose nil arm returns the
  # query UNTOUCHED — every tenant. So a nil-workspace fixture cannot tell a
  # correctly fenced read from one that returns every workspace's rows:
  # deleting `|> scope_to_workspace_or_global(workspace_id, project_id)` from
  # `Content.Query.search_documents_by_title/5` AND from
  # `search_tags_for_type/5` left 446 tests, 0 failures in this directory and
  # 1883 in test/barkpark/content (task-e3b0f58db8f4b9f3).
  #
  # These two describes are the arms that LOSE when the clause goes.
  #
  # TWO THINGS THE FIXTURE HAS TO GET RIGHT, and both are asserted, not assumed:
  #
  #   1. THE SOCKET CARRIES A REAL WORKSPACE. `assert_scoped!/3` reads the opts
  #      the handler will actually pass to Content — `ScopeHelpers.scope_opts/1`
  #      DROPS the key when the assign is nil — and refuses to continue unless a
  #      binary workspace_id is in them. A nil-workspace socket reproduces the
  #      exact blind spot this test exists to close.
  #
  #   2. THE DATASET CLAUSE MUST NOT DO THE TENANT CLAUSE'S JOB. The guard stack
  #      is dataset -> tenant -> owner -> grants, and `scope_to_dataset/3` filters
  #      `dataset_id == <resolved> OR (dataset_id IS NULL AND dataset == ...)`.
  #      Each project owns its OWN `production` dataset row, so a foreign-tenant
  #      paper written the ordinary way is already excluded by the dataset
  #      sibling and the tenant clause stands between nothing and nothing —
  #      which is how the original blind spot survived. The foreign paper here is
  #      therefore seeded in the LEGACY, pre-W2 shape the dataset clause
  #      deliberately admits: `dataset_id IS NULL`, bare `dataset` string. That
  #      row reaches the tenant clause, and the tenant clause is the only thing
  #      that can turn it away. `assert_reaches_tenant_clause!/1` pins that shape
  #      so this can never quietly become a dataset test again.

  defp scoped_socket(dataset, workspace, project) do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        dataset: dataset,
        current_workspace: workspace,
        current_project: project
      }
    }
  end

  defp assert_scoped!(socket, workspace, project) do
    opts = BarkparkWeb.ScopeHelpers.scope_opts(socket)

    assert is_binary(Keyword.get(opts, :workspace_id)),
           "PRECONDITION FAILED: this socket carries NO workspace_id, so the read " <>
             "takes the permissive scope_to_workspace_or_global/3 nil arm (every " <>
             "tenant) and the cross-tenant assertion below would hold whether or " <>
             "not the tenant clause exists. opts=#{inspect(opts)}"

    assert Keyword.get(opts, :workspace_id) == workspace.id
    assert Keyword.get(opts, :project_id) == project.id
    opts
  end

  # PRECONDITION on the foreign row: it must survive `scope_to_dataset/3`, or
  # the assertion below passes for the wrong reason.
  defp assert_reaches_tenant_clause!(doc_id, foreign_workspace) do
    row =
      Barkpark.Repo.get_by!(Barkpark.Content.Document,
        doc_id: doc_id,
        type: "paper",
        dataset: @dataset
      )

    assert is_nil(row.dataset_id),
           "PRECONDITION FAILED: #{doc_id} carries dataset_id=#{inspect(row.dataset_id)}, " <>
             "so scope_to_dataset/3 already excludes it and the tenant clause is " <>
             "never the thing that decides — this arm would pass with the clause deleted."

    assert row.workspace_id == foreign_workspace.id,
           "PRECONDITION FAILED: #{doc_id} is not in the foreign workspace."

    row
  end

  defp seed_scoped_paper!(workspace, project, doc_id, attrs) do
    scope = [workspace_id: workspace.id, project_id: project.id]

    {:ok, _} =
      Content.create_document("paper", Map.put(attrs, "_id", doc_id), @dataset, scope)

    Barkpark.LabelFixtures.exempt!(doc_id, @dataset)
    {:ok, _} = Content.publish_document(doc_id, "paper", @dataset, scope)
    :ok
  end

  # The legacy pre-W2 row: stamped with a tenant, never backfilled with a
  # dataset_id. `scope_to_dataset/3`'s second arm admits it for ANY tenant by
  # design, which is precisely why the tenant clause behind it is load-bearing.
  defp legacy_dataset_shape!(doc_id) do
    import Ecto.Query, only: [from: 2]

    {n, _} =
      Barkpark.Repo.update_all(
        from(d in Barkpark.Content.Document,
          where: d.doc_id == ^doc_id or d.doc_id == ^("drafts." <> doc_id)
        ),
        set: [dataset_id: nil]
      )

    assert n > 0, "legacy_dataset_shape!/1 matched no row for #{doc_id}"
    :ok
  end

  defp two_tenants! do
    ws_a = Barkpark.TenancyFixtures.create_workspace!()
    proj_a = Barkpark.TenancyFixtures.create_project!(ws_a)
    ws_b = Barkpark.TenancyFixtures.create_workspace!()
    proj_b = Barkpark.TenancyFixtures.create_project!(ws_b)
    %{ws_a: ws_a, proj_a: proj_a, ws_b: ws_b, proj_b: proj_b}
  end

  describe "paper_wikilink_search/2 — cross-workspace fence" do
    setup do
      ctx = two_tenants!()

      # SAME dataset string, SAME title stem, DIFFERENT workspaces.
      seed_scoped_paper!(ctx.ws_a, ctx.proj_a, "fence-wikilink-a", %{
        "title" => "Fencewikilink Alpha Paper"
      })

      seed_scoped_paper!(ctx.ws_b, ctx.proj_b, "fence-wikilink-b", %{
        "title" => "Fencewikilink Beta Paper"
      })

      legacy_dataset_shape!("fence-wikilink-b")
      ctx
    end

    test "a workspace-A socket never sees workspace B's matching paper", ctx do
      socket = scoped_socket(@dataset, ctx.ws_a, ctx.proj_a)
      assert_scoped!(socket, ctx.ws_a, ctx.proj_a)
      assert_reaches_tenant_clause!("fence-wikilink-b", ctx.ws_b)

      {:reply, %{results: results}, _socket} =
        Paper.paper_wikilink_search("Fencewikilink", socket)

      titles = Enum.map(results, & &1.title)

      assert "Fencewikilink Alpha Paper" in titles,
             "the rig never reached the candidate — this arm measures nothing. got: " <>
               inspect(titles)

      refute "Fencewikilink Beta Paper" in titles,
             "CROSS-TENANT LEAK: the [[ typeahead offered workspace B's paper to a " <>
               "workspace-A socket. The tenant clause on " <>
               "Content.Query.search_documents_by_title/5 is gone or inert. got: " <>
               inspect(titles)
    end
  end

  describe "paper_tag_search/2 — cross-workspace fence" do
    setup do
      ctx = two_tenants!()

      seed_scoped_paper!(ctx.ws_a, ctx.proj_a, "fence-tag-a", %{
        "title" => "Fence Tag Host A",
        "tags" => ["fencetag-alpha"]
      })

      seed_scoped_paper!(ctx.ws_b, ctx.proj_b, "fence-tag-b", %{
        "title" => "Fence Tag Host B",
        "tags" => ["fencetag-beta"]
      })

      legacy_dataset_shape!("fence-tag-b")
      ctx
    end

    test "a workspace-A socket never sees a tag that exists only in workspace B", ctx do
      socket = scoped_socket(@dataset, ctx.ws_a, ctx.proj_a)
      assert_scoped!(socket, ctx.ws_a, ctx.proj_a)
      assert_reaches_tenant_clause!("fence-tag-b", ctx.ws_b)

      {:reply, %{results: results}, _socket} =
        Paper.paper_tag_search("fencetag", socket)

      assert "fencetag-alpha" in results,
             "the rig never reached the tag corpus — this arm measures nothing. got: " <>
               inspect(results)

      refute "fencetag-beta" in results,
             "CROSS-TENANT LEAK: the #tag typeahead offered a tag that exists only in " <>
               "workspace B to a workspace-A socket. The tenant clause on " <>
               "Content.Query.search_tags_for_type/5 is gone or inert. got: " <>
               inspect(results)
    end
  end
end
