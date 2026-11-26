defmodule BarkparkWeb.PublicPaperDefaultSeatCacheTest do
  @moduledoc """
  task-d2af427518739052: `/papers/<slug>` reads the Default workspace from two
  sources. The reader goes through `Tenancy.get_default_workspace/0`
  (`DefaultScopeCache`, 60 s TTL), and `PaperRevisionHeaders` joins
  `workspaces.is_default` live. When the seat moves and the cache still holds
  the old seat, the body and the revision header name different papers.

  The cache can hold the old seat after a move: the bundle import's
  `settle_default_seat!/2` invalidates INSIDE its transaction, so a concurrent
  read repopulates the cache from the still-committed old seat (the hazard the
  cache's moduledoc names for `delete_workspace/1`); and writes outside
  `Tenancy` are bounded only by the TTL. This test arms the cache, warms it,
  and moves the seat without invalidating, the state either path leaves.
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Repo
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.{DefaultScopeCache, Workspace}

  @rev "x-barkpark-paper-revision"

  setup do
    previous = Application.get_env(:barkpark, :tenancy_default_scope_cache_ttl_ms)

    on_exit(fn ->
      DefaultScopeCache.invalidate()

      case previous do
        nil -> Application.delete_env(:barkpark, :tenancy_default_scope_cache_ttl_ms)
        value -> Application.put_env(:barkpark, :tenancy_default_scope_cache_ttl_ms, value)
      end
    end)

    {a, pa} = Barkpark.TenancyFixtures.ensure_default_scope!()
    b = Barkpark.TenancyFixtures.create_workspace!()
    {:ok, pb} = Tenancy.create_project_with_dataset(b, %{name: "dsc-p"})
    ds = Content.paper_default_dataset()

    for {ws, p} <- [{a, pa}, {b, pb}] do
      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => "paper",
            "title" => "Papers",
            "visibility" => "public",
            "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
          },
          ds,
          workspace_id: ws.id,
          project_id: p.id
        )
    end

    Barkpark.LabelFixtures.register_tags!(ds)
    %{a: a, pa: pa, b: b, pb: pb, ds: ds, slug: "dsc-#{System.unique_integer([:positive])}"}
  end

  defp paper!(c, ws, p, text) do
    {:ok, doc} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          "slug" => c.slug,
          "title" => "T",
          "dataset" => c.ds,
          "workspace_id" => ws.id,
          "project_id" => p.id,
          "blocks" => [
            %{"id" => "h-1", "type" => "heading", "text" => "Title"},
            %{
              "id" => "b-1",
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => text}]
            }
          ]
        })
      )

    # A fixture paper carries no released revision; name its current one so
    # the header tells the two papers apart.
    doc = Repo.reload!(doc)

    {1, _} =
      Repo.update_all(from(d in Document, where: d.id == ^doc.id),
        set: [released_revision_id: doc.current_revision_id]
      )

    doc.current_revision_id
  end

  # The seat moves A -> B with no invalidate: what a read inside the import's
  # transaction, or a write outside `Tenancy`, leaves in the cache.
  defp move_seat_silently!(from, to) do
    {1, _} =
      Repo.update_all(from(w in Workspace, where: w.id == ^from.id), set: [is_default: false])

    {1, _} = Repo.update_all(from(w in Workspace, where: w.id == ^to.id), set: [is_default: true])
  end

  test "after a seat move the cache has not seen, the header names the paper the body shows",
       %{conn: conn} = c do
    rev_a = paper!(c, c.a, c.pa, "Seat A words")
    rev_b = paper!(c, c.b, c.pb, "Seat B words")

    Application.put_env(:barkpark, :tenancy_default_scope_cache_ttl_ms, 60_000)
    DefaultScopeCache.invalidate()
    assert Tenancy.get_default_workspace().id == c.a.id

    move_seat_silently!(c.a, c.b)
    assert Tenancy.get_default_workspace().id == c.a.id, "the cache still holds seat A"

    conn = get(conn, "/papers/#{c.slug}")
    body = html_response(conn, 200)
    [rev] = get_resp_header(conn, @rev)

    shown = if body =~ "Seat A words", do: rev_a, else: rev_b
    assert rev == shown
    assert rev in [rev_a, rev_b]
  end

  test "control: with the cache busted after the move, both name seat B", %{conn: conn} = c do
    _ = paper!(c, c.a, c.pa, "Seat A words")
    rev_b = paper!(c, c.b, c.pb, "Seat B words")

    Application.put_env(:barkpark, :tenancy_default_scope_cache_ttl_ms, 60_000)
    DefaultScopeCache.invalidate()
    move_seat_silently!(c.a, c.b)
    DefaultScopeCache.invalidate()

    conn = get(conn, "/papers/#{c.slug}")
    assert html_response(conn, 200) =~ "Seat B words"
    assert get_resp_header(conn, @rev) == [rev_b]
  end
end
