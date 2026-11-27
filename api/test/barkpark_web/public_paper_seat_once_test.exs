defmodule BarkparkWeb.PublicPaperSeatOnceTest do
  @moduledoc """
  task-8574bb40259a788a: `/papers/<slug>` read the Default seat twice, once in
  `PaperRevisionHeaders` and once in the reader's mount, each a
  `DefaultScopeCache` read. An expiry or invalidate between the two split
  `x-barkpark-paper-revision` from the body. The plug now resolves the seat
  once and hands it to the dead render through `conn.assigns`.

  The gap is staged at `[:phoenix, :live_view, :mount, :start]`, which fires
  after the plug pipeline and before `mount/3`: the handler busts the cache
  once a seat move has happened that the cache has not seen.
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

    handler = "seat-once-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      :telemetry.detach(handler)
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

    %{
      handler: handler,
      a: a,
      pa: pa,
      b: b,
      pb: pb,
      ds: ds,
      slug: "dsc-#{System.unique_integer([:positive])}"
    }
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

  # Bust the cache between the plug and the reader's mount, once.
  defp bust_before_mount!(handler) do
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler,
        [:phoenix, :live_view, :mount, :start],
        fn _event, _measure, meta, _config ->
          if meta.socket.view == BarkparkWeb.BulldocsLive and
               not Phoenix.LiveView.connected?(meta.socket) do
            DefaultScopeCache.invalidate()
            send(test_pid, :busted_before_mount)
          end
        end,
        nil
      )
  end

  test "a cache bust between the plug and the reader leaves the header naming the body's paper",
       %{conn: conn} = c do
    rev_a = paper!(c, c.a, c.pa, "Seat A words")
    rev_b = paper!(c, c.b, c.pb, "Seat B words")

    Application.put_env(:barkpark, :tenancy_default_scope_cache_ttl_ms, 60_000)
    DefaultScopeCache.invalidate()
    assert Tenancy.get_default_workspace().id == c.a.id
    move_seat_silently!(c.a, c.b)
    bust_before_mount!(c.handler)

    conn = get(conn, "/papers/#{c.slug}")
    body = html_response(conn, 200)
    assert_received :busted_before_mount
    [rev] = get_resp_header(conn, @rev)

    shown = if body =~ "Seat A words", do: rev_a, else: rev_b

    assert rev == shown,
           "header names #{if rev == rev_a, do: "A", else: "B"}, body shows the other"
  end

  test "control: with no bust, the cached seat names both", %{conn: conn} = c do
    rev_a = paper!(c, c.a, c.pa, "Seat A words")
    _ = paper!(c, c.b, c.pb, "Seat B words")

    Application.put_env(:barkpark, :tenancy_default_scope_cache_ttl_ms, 60_000)
    DefaultScopeCache.invalidate()
    assert Tenancy.get_default_workspace().id == c.a.id
    move_seat_silently!(c.a, c.b)

    conn = get(conn, "/papers/#{c.slug}")
    assert html_response(conn, 200) =~ "Seat A words"
    assert get_resp_header(conn, @rev) == [rev_a]
  end
end
