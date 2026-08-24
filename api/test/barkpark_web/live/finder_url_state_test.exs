defmodule BarkparkWeb.FinderUrlStateTest do
  @moduledoc """
  `task-043ff7d98883b02b` — three honesty/UX defects on the public `/finder`
  (`live/finder_live.ex`), each pinned here.

  1. **NO URL STATE.** `mount/3` read only `params["dataset"]` and hard-set
     `q: ""`; there was no `handle_params/3` and no `push_patch` anywhere in the
     module. A search was not linkable, not bookmarkable, not back-button
     restorable, and did not survive a reload — `/finder?q=foo` rendered an
     empty finder. `handle_params/3` now owns the search, and the search event
     only patches the URL, so every entry point takes one path.

  2. **DEAD SELF-LINKS.** Every non-`paper` type resolved to `~p"/finder"` — a
     link back to the page the reader is already on. `paper` is the only type
     with a public reader (`live("/papers/:slug")` in router.ex — cited by
     SYMBOL, not by line, because the line anchor rotted), so an
     unlinkable hit now renders as text instead of as a control that does
     nothing.

  3. **INFLATED COUNT.** "N documents" was `length(real_nodes ++ phantom_nodes)`,
     and a phantom is a dangling edge TARGET with no document row behind it —
     while the truncation notice beside it was scrupulously honest, so the
     surface contradicted itself. The document count is now derived from the
     non-phantom nodes; `data-rev` keeps the node total it needs as a change
     token.

  Also pinned: `@hit_limit` is 12 and there is no pagination, so the engine's
  full total is now labelled ("showing 12 of 437 hits") instead of standing
  beside 12 rows unqualified.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content

  defp seed_paper(title) do
    slug = title |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-")

    {:ok, _} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: slug,
          title: title,
          body_html: "<p>about #{title}</p>",
          event_type: "plan-written"
        })
      )

    slug
  end

  describe "1. the URL carries the query" do
    test "/finder?q=… renders its hits SERVER-SIDE, with no client round-trip", %{conn: conn} do
      seed_paper("Urlstate Sentinel Alpha")

      # `get/2`, not `live/2`: the DEAD render. This is the bookmark, the
      # reload, the crawler and the pasted link — all of which produced an empty
      # finder before, because nothing read `q` from the params.
      html = conn |> get("/finder?q=urlstate+sentinel") |> html_response(200)

      assert html =~ "urlstate-sentinel-alpha"
      assert html =~ "hits"
      refute html =~ "type to search"
    end

    test "the connected mount restores the query too, so a reload keeps the page", %{conn: conn} do
      seed_paper("Urlstate Sentinel Bravo")

      {:ok, _view, html} = live(conn, "/finder?q=urlstate+sentinel+bravo")

      assert html =~ "urlstate-sentinel-bravo"
      # The input is repopulated — the reader sees WHAT was searched, not a
      # blank box above the results.
      assert html =~ ~s(value="urlstate sentinel bravo")
    end

    test "typing patches the URL, so the address bar tracks the search", %{conn: conn} do
      seed_paper("Urlstate Sentinel Charlie")

      {:ok, view, _html} = live(conn, "/finder")

      view |> element("form") |> render_change(%{"q" => "urlstate sentinel charlie"})

      assert_patched(view, "/finder?q=urlstate+sentinel+charlie")
    end

    test "clearing the box patches back to the bare path, not to ?q=", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/finder?q=something")

      view |> element("form") |> render_change(%{"q" => "   "})

      assert_patched(view, "/finder")
    end

    test "a non-default dataset survives the patch", %{conn: conn} do
      # The dataset was already a URL param and must not be dropped when the
      # query is pushed — otherwise typing silently moves the reader's corpus.
      {:ok, view, _html} = live(conn, "/finder?dataset=staging")

      view |> element("form") |> render_change(%{"q" => "anything"})

      path = assert_patch(view)
      assert path =~ "dataset=staging"
      assert path =~ "q=anything"
    end
  end

  describe "2. an unlinkable hit is not a link" do
    # A NON-PAPER hit is the whole point, and without one this section is
    # vacuous: `public_href/2`'s `_type` clause is never reached by a corpus of
    # papers, so the pre-fix `~p"/finder"` passed every assertion here. MEASURED
    # — reverting the fix left this describe block green until the fixture below
    # existed. The schema must be PUBLIC or the anonymous finder cannot see it.
    setup do
      {ws, project} = Barkpark.TenancyFixtures.ensure_default_scope!()
      scope = [workspace_id: ws.id, project_id: project.id]

      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => "linkless",
            "title" => "linkless",
            "visibility" => "public",
            "fields" => []
          },
          "production",
          scope
        )

      %{scope: scope}
    end

    defp publish_linkless!(title, scope) do
      doc_id = title |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-")

      {:ok, _} =
        Content.create_document(
          "linkless",
          %{"doc_id" => doc_id, "title" => title, "content" => %{}},
          "production",
          scope
        )

      {:ok, _} = Content.publish_document(doc_id, "linkless", "production", scope)
      doc_id
    end

    test "a paper hit links into the reader", %{conn: conn} do
      seed_paper("Urlstate Sentinel Delta")

      html = conn |> get("/finder?q=urlstate+sentinel+delta") |> html_response(200)

      assert html =~ ~s(href="/papers/urlstate-sentinel-delta")
    end

    test "a type with NO public reader renders as text, not as a link", %{
      conn: conn,
      scope: scope
    } do
      publish_linkless!("Linkless Sentinel Hotel", scope)

      html = conn |> get("/finder?q=linkless+sentinel+hotel") |> html_response(200)

      # The hit is still SHOWN — suppressing it would hide real corpus from the
      # reader. It is just not dressed as something you can open.
      assert html =~ "Linkless Sentinel Hotel"
      assert html =~ ~s(data-test-id="finder-hit-inert")
    end

    test "NOTHING on the page links back to /finder itself", %{conn: conn, scope: scope} do
      # The defect stated as the property it violated: a hit whose href was
      # `~p"/finder"` is indistinguishable from a broken control. With a
      # non-paper hit in the result set, this reds on the old code.
      publish_linkless!("Linkless Sentinel India", scope)

      html = conn |> get("/finder?q=linkless+sentinel+india") |> html_response(200)

      assert html =~ "Linkless Sentinel India"
      refute html =~ ~s(href="/finder")
    end
  end

  describe "3. the document count excludes phantoms" do
    # A REAL phantom, built on purpose — without one this whole section is
    # vacuous, because a phantom-free corpus makes the two numbers coincide and
    # the pre-fix code would pass every assertion below.
    #
    # A phantom is what `graph_payload/2` calls an edge TARGET that no document
    # row backs. `Edges.extract_edges/2` walks a schema's REFERENCE fields, so:
    # a PUBLIC schema (anonymous /finder must be able to see it) carrying a
    # reference field, and one published document whose reference points at an
    # id that does not exist.
    setup do
      {ws, project} = Barkpark.TenancyFixtures.ensure_default_scope!()
      scope = [workspace_id: ws.id, project_id: project.id]

      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => "phantomsrc",
            "title" => "phantomsrc",
            "visibility" => "public",
            "fields" => [%{"name" => "points_at", "type" => "reference", "refType" => nil}]
          },
          "production",
          scope
        )

      %{scope: scope}
    end

    defp publish!(type, doc_id, content, scope) do
      {:ok, _} =
        Content.create_document(
          type,
          %{"doc_id" => doc_id, "title" => doc_id, "content" => content},
          "production",
          scope
        )

      {:ok, doc} = Content.publish_document(doc_id, type, "production", scope)
      doc
    end

    defp counts(conn) do
      {:ok, view, _html} = live(conn, "/finder")
      html = render_async(view, 5_000)

      [documents] = Regex.run(~r/([0-9]+) documents/, html, capture: :all_but_first)
      [rev] = Regex.run(~r/data-rev="([0-9]+)"/, html, capture: :all_but_first)

      {String.to_integer(documents), String.to_integer(rev)}
    end

    test "a dangling reference adds a graph NODE and no DOCUMENT", %{conn: conn, scope: scope} do
      {docs_before, nodes_before} = counts(conn)

      # ONE new document, referencing an id nothing backs. That is +1 real node
      # AND +1 phantom node: the graph total must move by 2, the document total
      # by exactly 1. Before the split both moved by 2, which is the defect.
      publish!(
        "phantomsrc",
        "phantom-source-#{System.unique_integer([:positive])}",
        %{"points_at" => "no-such-document-anywhere-#{System.unique_integer([:positive])}"},
        scope
      )

      {docs_after, nodes_after} = counts(conn)

      assert docs_after - docs_before == 1,
             "the document count moved by #{docs_after - docs_before}; one document was added"

      assert nodes_after - nodes_before == 2,
             "the graph node count moved by #{nodes_after - nodes_before}; " <>
               "one document plus its dangling target were added"

      # The property, stated directly: the human-readable line is strictly
      # smaller than the graph total whenever a phantom exists.
      assert docs_after < nodes_after
    end

    test "a document with a RESOLVING reference adds one node and one document", %{
      conn: conn,
      scope: scope
    } do
      # The control. Without it, "documents < nodes" could be satisfied by any
      # off-by-one rather than by phantom exclusion specifically.
      target = "phantom-target-#{System.unique_integer([:positive])}"
      publish!("phantomsrc", target, %{}, scope)

      {docs_before, nodes_before} = counts(conn)

      publish!(
        "phantomsrc",
        "phantom-linker-#{System.unique_integer([:positive])}",
        %{"points_at" => target},
        scope
      )

      {docs_after, nodes_after} = counts(conn)

      assert docs_after - docs_before == 1
      assert nodes_after - nodes_before == 1
    end
  end

  describe "the hit-limit is labelled" do
    test "under the limit the wording is unchanged — the existing spec pins it", %{conn: conn} do
      seed_paper("Urlstate Sentinel Golf")

      html = conn |> get("/finder?q=urlstate+sentinel+golf") |> html_response(200)

      assert html =~ "1 hits"
      # Scoped to the count line: the bare word "showing" appears in the
      # layout's own inline CSS commentary, so a page-wide refute is vacuous.
      refute html =~ "showing 1 of"
    end

    test "over the limit it says how many of how many", %{conn: conn} do
      # @hit_limit is 12; seed 14 so the engine's total exceeds what renders.
      for i <- 1..14, do: seed_paper("Urlstatelimit Sentinel #{i}")

      html = conn |> get("/finder?q=urlstatelimit+sentinel") |> html_response(200)

      assert html =~ ~r/showing 12 of 1[34] hits/,
             "expected a labelled partial count; got: " <>
               inspect(Regex.run(~r/[^>]*hits/, html))
    end
  end
end
