defmodule BarkparkWeb.FinderLiveTest do
  @moduledoc """
  The public /finder (search-template W3, the Phoenix framework leg): mounts
  anonymously on the reader layout, carries the graph hook contract the
  Canvas2D renderer ingests, and a search event round-trips into the same
  engine the search channel serves — pure LiveView, zero client search code.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content

  # Papers are the proven public corpus fixture (same helper the reader tests
  # use) — searchable, published, no bespoke schema needed in the test env.
  defp seed_doc(title) do
    slug = title |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-")

    {:ok, _paper} =
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

  test "mounts anonymously with the graph hook contract", %{conn: conn} do
    {:ok, view, html} = live(conn, "/finder")

    assert html =~ "Search everything."
    # The hook div carries the renderer's full wire contract (shell renders
    # instantly; the corpus arrives via start_async and patches data-*).
    assert html =~ ~s(phx-hook="FinderGraph")
    assert html =~ "data-nodes="
    assert html =~ "data-edges="

    # The async corpus lands and the attrs update in place (generous timeout —
    # the derivation walks every schema in the test dataset; the default 100ms
    # flakes on a busy CI runner).
    html = render_async(view, 5_000)
    assert html =~ "data-rev="
  end

  test "a search event returns hits from the engine", %{conn: conn} do
    seed_doc("Finder Sentinel Alpha")

    {:ok, view, _html} = live(conn, "/finder")

    html =
      view
      |> element("form")
      |> render_change(%{"q" => "finder sentinel"})

    # The contract: the engine round-trip surfaces the seeded paper as a hit
    # LINKING INTO the native PortableDoc reader. (The displayed title is
    # whatever the fixture stored — the slug here — so assert the semantics,
    # not the fixture's cosmetics.)
    assert html =~ ~s(href="/papers/finder-sentinel-alpha")
    assert html =~ "1 hits"
  end

  test "an empty query clears hits instead of erroring", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/finder")

    html =
      view
      |> element("form")
      |> render_change(%{"q" => "   "})

    assert html =~ "type to search"
  end

  # ── the graph visibility clamp (task-336d22b7722ea71e) ────────────────────
  #
  # /finder is public by construction (`:browser` pipeline, no on_mount, no
  # token) — its principal is the public internet. `graph_payload/2` used to
  # be a second, hand-copied corpus derivation with NO schema-visibility
  # clamp, so while the search side of the SAME LiveView correctly returned 0
  # hits to an anonymous visitor, the graph payload in the same response
  # carried every private type's name and titles (observed live: anonymous
  # corpus = 1 node, type "vault", visibility private, title present). The
  # derivation now reads through `Content.Schema.visible_schemas/2` — the ONE
  # owner, shared with the flat /v1/graph twin — which defaults to the
  # narrowest view and widens only for a principal that earned it.
  describe "graph visibility clamp" do
    setup do
      {ws, project} = Barkpark.TenancyFixtures.ensure_default_scope!()
      scope = [workspace_id: ws.id, project_id: project.id]

      for {name, vis} <- [{"finderopen", "public"}, {"findervault", "private"}] do
        {:ok, _} =
          Content.upsert_schema(
            %{"name" => name, "title" => name, "visibility" => vis, "fields" => []},
            "production",
            scope
          )
      end

      %{scope: scope}
    end

    defp publish_doc!(type, doc_id, title, scope) do
      {:ok, _} =
        Content.create_document(
          type,
          %{"doc_id" => doc_id, "title" => title, "content" => %{}},
          "production",
          scope
        )

      {:ok, doc} = Content.publish_document(doc_id, type, "production", scope)
      doc
    end

    test "SECURITY: the anonymous graph payload carries ZERO private-visibility nodes — not the type name, not the title, not the id",
         %{conn: conn, scope: scope} do
      uid = System.unique_integer([:positive])
      secret_id = "vault-doc-#{uid}"
      secret_title = "SECRET-FINDER-#{uid}"
      open_id = "open-doc-#{uid}"
      open_title = "OPEN-FINDER-#{uid}"

      publish_doc!("findervault", secret_id, secret_title, scope)
      publish_doc!("finderopen", open_id, open_title, scope)

      # No token, no session — the same anonymous mount the probe used.
      {:ok, view, _html} = live(conn, "/finder")
      html = render_async(view, 5_000)

      # PERMIT DIRECTION FIRST: the corpus landed and carries the public doc,
      # so the refutes below cannot pass vacuously on an empty payload — and
      # the fix demonstrably narrows, it does not blank the graph.
      assert html =~ open_title
      assert html =~ open_id

      # The leak, re-probed: the private-visibility node must be absent from
      # the payload in EVERY attribute — type name, title, AND id.
      refute html =~ secret_title,
             "private-visibility TITLE leaked to an anonymous /finder visitor"

      refute html =~ secret_id,
             "private-visibility doc ID leaked to an anonymous /finder visitor"

      refute html =~ "findervault",
             "private-visibility TYPE NAME leaked to an anonymous /finder visitor"
    end

    test "read-time, not cached: a schema flipped to public appears on the NEXT anonymous mount",
         %{conn: conn, scope: scope} do
      uid = System.unique_integer([:positive])
      doc_id = "flip-doc-#{uid}"
      title = "FLIP-FINDER-#{uid}"
      publish_doc!("findervault", doc_id, title, scope)

      {:ok, view, _html} = live(conn, "/finder")
      refute render_async(view, 5_000) =~ title

      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => "findervault",
            "title" => "findervault",
            "visibility" => "public",
            "fields" => []
          },
          "production",
          scope
        )

      {:ok, view2, _html} = live(conn, "/finder")
      assert render_async(view2, 5_000) =~ title
    end
  end
end
