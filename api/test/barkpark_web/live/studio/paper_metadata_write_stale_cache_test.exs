defmodule BarkparkWeb.Studio.PaperMetadataWriteStaleCacheTest do
  @moduledoc """
  task-0d3b2cd020238663 — a paper write that sends neither `blocks` nor
  `body_html` (a title or metadata patch) used to carry the stored
  `body_html` cache forward unchanged. When that cache came from an older
  renderer, the write's `{:paper_updated, …}` frame carried the old bytes,
  and a write-capable Studio socket editing the paper painted them.

  The fix is on the write: `BlockOps.write_encrypted_blocks_doc/8` re-renders
  the cache from the paper's stored blocks on such a write. The frame is built
  from the committed row, so it carries the fresh render.

  Each fixture plants the stale cache with a direct `Repo.update!`, because
  the write path is what renders the cache and would overwrite the probe. The
  stamp is set to the integer `3`: the renderer's own pre-digest version, i.e.
  a cache from an older renderer, which is the population this task is about.

  `async: false` — the paper-canvas flag is process-global and the Studio
  mount shares the seeded Default scope.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.{Content, Repo}
  alias Barkpark.Content.{Broadcast, Labels}
  alias Barkpark.PortableDoc.Render
  alias BarkparkWeb.Studio.StudioLive.Shared

  @dataset "stale-cache-write-#{System.unique_integer([:positive])}"

  @stale ~s|<p>STALE-CACHE-MARKER from an older renderer</p>|

  setup do
    prev_canvas = System.get_env("BARKPARK_PAPER_CANVAS")
    System.delete_env("BARKPARK_PAPER_CANVAS")

    on_exit(fn ->
      case prev_canvas do
        nil -> System.delete_env("BARKPARK_PAPER_CANVAS")
        v -> System.put_env("BARKPARK_PAPER_CANVAS", v)
      end
    end)

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "paper",
          "title" => "Papers",
          "icon" => "📰",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset,
        workspace_id: ws.id,
        project_id: proj.id
      )

    Barkpark.LabelFixtures.register_tags!(@dataset)

    {:ok, ws: ws, proj: proj}
  end

  defp create_blocks_paper!(ws, proj, slug) do
    {:ok, paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          "slug" => slug,
          "title" => "Blocks paper",
          "dataset" => @dataset,
          "workspace_id" => ws.id,
          "project_id" => proj.id,
          "blocks" => [
            %{
              "id" => "p-current",
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => "Current block prose."}]
            }
          ]
        })
      )

    paper
  end

  # Plant the stale cache on the stored row and prove it from the store.
  defp plant_stale_cache!(slug) do
    paper = Content.get_paper(slug, @dataset)

    paper
    |> Ecto.Changeset.change(
      content:
        paper.content
        |> Map.put("body_html", @stale)
        |> Map.put("body_html_sv", 3)
    )
    |> Repo.update!()

    stored = Content.get_paper(slug, @dataset).content
    assert stored["body_html"] == @stale
    assert is_list(stored["blocks"]) and stored["blocks"] != []
    :ok
  end

  # The HTML the current renderer makes from the paper's stored blocks, with
  # the same options the reader uses (`Papers.cache_provenance/4`).
  defp current_render(slug) do
    paper = Content.get_paper(slug, @dataset)
    content = paper.content

    Render.render_blocks(
      content["blocks"],
      Labels.paper_render_opts(@dataset, content["style"],
        workspace_id: paper.workspace_id,
        project_id: paper.project_id
      )
    )
  end

  # A write that sends neither blocks nor body_html.
  defp metadata_write!(slug) do
    {:ok, _} =
      Content.upsert_paper(%{
        "slug" => slug,
        "dataset" => @dataset,
        "description" => "metadata only, no body sent"
      })

    :ok
  end

  test "the :paper_updated frame for a metadata-only write carries HTML rendered from the current blocks",
       %{ws: ws, proj: proj} do
    slug = "stale-frame-#{System.unique_integer([:positive])}"
    _ = create_blocks_paper!(ws, proj, slug)
    plant_stale_cache!(slug)

    :ok = Phoenix.PubSub.subscribe(Barkpark.PubSub, Broadcast.paper_topic(slug, ws.id, @dataset))

    metadata_write!(slug)

    assert_receive {:paper_updated, %{slug: ^slug, html: html}}, 2_000

    refute html =~ "STALE-CACHE-MARKER",
           "the frame carried the stored cache from an older renderer: #{inspect(html)}"

    assert html =~ "Current block prose."
    assert html == current_render(slug)

    # The stored cache moved with it, stamped by the current renderer.
    stored = Content.get_paper(slug, @dataset).content
    assert stored["body_html"] == html
    assert stored["body_html_sv"] == Render.body_html_render_version()
    assert stored["description"] == "metadata only, no body sent"
  end

  test "a write-capable Studio editing view shows HTML rendered from the current blocks after that write",
       %{ws: ws, proj: proj, conn: conn} do
    slug = "stale-studio-#{System.unique_integer([:positive])}"
    paper = create_blocks_paper!(ws, proj, slug)

    {:ok, view, _html} =
      live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{paper.doc_id}"))

    refute Shared.write_denied?(:sys.get_state(view.pid).socket),
           "this fixture must land on the write-capable arm, which paints the frame's html"

    # Planted after mount, so no mount-time read can heal it first.
    plant_stale_cache!(slug)

    # The write comes from this test process, a second producer, so the
    # Studio socket does not skip it as its own echo.
    metadata_write!(slug)

    rendered = render(view)
    assigns = :sys.get_state(view.pid).socket.assigns

    refute assigns.paper_html =~ "STALE-CACHE-MARKER",
           "Studio painted the stored cache from an older renderer: #{inspect(assigns.paper_html)}"

    refute rendered =~ "STALE-CACHE-MARKER"
    assert assigns.paper_html == Shared.editor_body_html(current_render(slug))
    assert rendered =~ "Current block prose."
  end
end
