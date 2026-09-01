defmodule BarkparkWeb.FinderWorkspaceScopeTest.SpyIndxRetriever do
  @moduledoc """
  A stand-in for the registered `"indx"` retriever
  (`Barkpark.Plugins.Indx.Retriever`) that RECORDS the fact it was reached.

  The finder's search call asked for `engine: "indx"` and was SILENTLY
  downgraded to Postgres by `QueryPipeline`'s D3-b gate — a non-postgres engine
  with no binary `:workspace_id` in opts cannot prove tenant scope, so the gate
  substitutes `DocumentsRetriever`. Threading the workspace key therefore LIFTS
  that gate, and a naive tenancy fix flips this public surface onto Indx as a
  side effect — onto a candidate pool `Indx.Retriever`'s own comment calls "NOT
  tenant-scoped", hydrated with no perspective filter. This spy is how that
  flip is detected: reached = the engine changed.
  """
  @behaviour Barkpark.Search.Retriever

  @impl true
  def search(_scope, _parsed, _config, opts) do
    case Application.get_env(:barkpark, :finder_engine_spy_pid) do
      pid when is_pid(pid) -> send(pid, {:indx_retriever_called, opts})
      _ -> :ok
    end

    {[], 0, %{}}
  end
end

defmodule BarkparkWeb.FinderWorkspaceScopeTest do
  @moduledoc """
  The public `/finder` is mounted FLAT on the public root — `pipe_through
  [:browser, :paper_reader_csp]`, `live_session :finder` with no `on_mount`, no
  token, no LiveScope — so nothing upstream of it resolves a tenant. Its BY-ID
  twin (`Content.get_public_document/3`) pins its read to the seeded Default
  workspace and fails closed when there is none, and the module's own moduledoc
  claims that same fence. Its five LIST reads carried no workspace key at all.

  WHY A PLAIN TWO-TENANT FIXTURE PROVES NOTHING HERE. With no scope opts,
  `Content.resolve_read_dataset_id/2` resolves the seeded Default project's
  dataset row and the dataset leg then does the fencing — another workspace's
  `production` is a DIFFERENT dataset row, so its documents fall out for
  reasons that have nothing to do with tenancy. A test built on that greens
  BEFORE any fix.

  THE FIXTURE THEREFORE USES THE CALLER-CONTROLLED FAIL-OPEN PATH. `?dataset=`
  is caller-supplied and only shape-validated by `sanitize_dataset/1`. On a
  dataset slug NO project owns a `datasets` row for, `resolve_read_dataset_id/2`
  returns nil and every read degrades to the bare `d.dataset == ^dataset`
  STRING filter — at which point the workspace key is the ONLY thing left
  between the public finder and every tenant on the box. That is the shape
  seeded below: two workspaces, both holding a published public-visibility
  document whose `dataset` STRING is the same and whose `dataset_id` is NULL.

  Every test carries a POSITIVE control from the Default workspace — a refute
  read off an empty page is not a fence.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content
  alias Barkpark.Repo
  alias BarkparkWeb.FinderWorkspaceScopeTest.SpyIndxRetriever

  @home_type "finderhome"
  @away_type "finderaway"
  @dataset "shadowfinder"
  @token "zzqfindertoken"

  setup do
    {default_ws, default_project} = Barkpark.TenancyFixtures.ensure_default_scope!()
    home_scope = [workspace_id: default_ws.id, project_id: default_project.id]

    ws_b = Barkpark.TenancyFixtures.create_workspace!()
    project_b = Barkpark.TenancyFixtures.create_project!(ws_b)
    away_scope = [workspace_id: ws_b.id, project_id: project_b.id]

    upsert_public_schema!(@home_type, home_scope)
    upsert_public_schema!(@away_type, away_scope)

    uid = System.unique_integer([:positive])
    home_id = "finder-home-#{uid}"
    away_id = "finder-away-#{uid}"
    home_title = "#{@token} home #{uid}"
    away_title = "#{@token} away #{uid}"

    publish_doc!(@home_type, home_id, home_title, home_scope)
    publish_doc!(@away_type, away_id, away_title, away_scope)

    # Collapse the dataset leg for BOTH tenants. The write path dual-writes a
    # `datasets` row per project and stamps its id; dropping those rows and the
    # stamps leaves the bare `dataset` STRING, which is exactly the state a
    # caller-supplied `?dataset=` slug no project owns produces on a read — and
    # the pre-W2 legacy/backfill population looks the same. Now nothing but the
    # workspace key separates the two tenants.
    collapse_dataset_leg!(@dataset)

    %{
      home_id: home_id,
      away_id: away_id,
      home_title: home_title,
      away_title: away_title
    }
  end

  defp upsert_public_schema!(name, scope) do
    {:ok, _} =
      Content.upsert_schema(
        %{"name" => name, "title" => name, "visibility" => "public", "fields" => []},
        @dataset,
        scope
      )
  end

  defp publish_doc!(type, doc_id, title, scope) do
    {:ok, _} =
      Content.create_document(
        type,
        %{"doc_id" => doc_id, "title" => title, "content" => %{}},
        @dataset,
        scope
      )

    {:ok, doc} = Content.publish_document(doc_id, type, @dataset, scope)
    doc
  end

  defp collapse_dataset_leg!(dataset) do
    Repo.query!("UPDATE documents SET dataset_id = NULL WHERE dataset = $1", [dataset])
    Repo.query!("UPDATE schema_definitions SET dataset_id = NULL WHERE dataset = $1", [dataset])
    Repo.query!("DELETE FROM datasets WHERE slug = $1", [dataset])
    :ok
  end

  defp finder_path(query \\ nil) do
    case query do
      nil -> "/finder?dataset=#{@dataset}"
      q -> "/finder?dataset=#{@dataset}&q=#{URI.encode_www_form(q)}"
    end
  end

  describe "cross-workspace reads" do
    test "SECURITY: a workspace-B document is NOT a hit in the anonymous finder search",
         %{conn: conn, home_title: home_title, away_title: away_title} do
      # `?q=` on the URL, not a form event: `handle_params/3` owns the search on
      # the dead render AND the connected one, so this is the same read a
      # crawler, a bookmark and a typed keystroke all take.
      {:ok, _view, html} = live(conn, finder_path(@token))

      # PERMIT DIRECTION FIRST — the Default workspace's own public document is
      # still served, so the refutes cannot pass on an empty result page.
      assert html =~ home_title

      refute html =~ away_title,
             "CROSS-WORKSPACE LEAK: a workspace-B document was a hit in the public finder"

      refute html =~ @away_type,
             "CROSS-WORKSPACE LEAK: a workspace-B TYPE NAME rendered beside a public finder hit"
    end

    test "SECURITY: a workspace-B document is NOT in the anonymous finder graph payload",
         %{conn: conn, home_id: home_id, away_id: away_id, away_title: away_title} do
      {:ok, view, _html} = live(conn, finder_path())
      html = render_async(view, 5_000)

      # PERMIT DIRECTION FIRST — the corpus landed and carries the Default
      # workspace's node, so the refutes are read against a real payload.
      assert html =~ home_id

      refute html =~ away_id,
             "CROSS-WORKSPACE LEAK: a workspace-B doc id is in the public finder's graph payload"

      refute html =~ away_title,
             "CROSS-WORKSPACE LEAK: a workspace-B title is in the public finder's graph payload"

      refute html =~ @away_type,
             "CROSS-WORKSPACE LEAK: a workspace-B TYPE NAME is in the public finder's graph payload"
    end
  end

  describe "search engine" do
    setup do
      previous = Application.get_env(:barkpark, :search_retrievers, %{})
      Application.put_env(:barkpark, :finder_engine_spy_pid, self())

      Application.put_env(
        :barkpark,
        :search_retrievers,
        Map.put(previous, "indx", SpyIndxRetriever)
      )

      on_exit(fn ->
        Application.put_env(:barkpark, :search_retrievers, previous)
        Application.delete_env(:barkpark, :finder_engine_spy_pid)
      end)

      :ok
    end

    test "the finder's search read stays pinned to the POSTGRES engine — closing the tenancy hole must not flip it to Indx",
         %{conn: conn, home_title: home_title} do
      {:ok, _view, html} = live(conn, finder_path(@token))

      refute_received {:indx_retriever_called, _opts},
                      "the public finder's search reached the INDX retriever — " <>
                        "supplying :workspace_id lifted QueryPipeline's D3-b gate and " <>
                        "silently changed the engine on a public surface"

      # PERMIT DIRECTION, same run: the Postgres retriever actually answered and
      # the Default workspace's document is a hit. The spy returns zero hits, so
      # this also fails on a flip — the refute above is not read off a page that
      # never searched.
      assert html =~ home_title
    end
  end
end
