defmodule BarkparkWeb.Studio.SharedPaperWriteCapableBodyHtmlSanitizeTest do
  @moduledoc """
  arpss-studio-legacy-body-html-sanitize-asymmetry — Studio's read-only
  `raw(@paper_html)` arm served the raw stored `body_html` to a WRITE-CAPABLE
  socket, while `Content.Papers.reader_source/3` sanitizes that same field for
  every caller it serves.

  THE SHAPE — an ASYMMETRY, not a hole in either path. One stored field,
  `content["body_html"]`, has two readers. The bulldocs reader
  (`Content.Papers.reader_source/3`) runs `HtmlSanitizer.sanitize/1` on it
  unconditionally, with no principal test. The Studio reader
  (`Shared.Paper.reader_paper_html/2`) ran the sanitizer only on the
  write-DENIED branch — via `reader_source/3` — and handed the write-capable
  branch the stored bytes verbatim into `raw/1`. Whichever reader a poisoned
  row reaches first therefore decided whether script executed.

  WHY A WRITE-CAPABLE SOCKET IS NOT SELF-EVIDENTLY SAFE. `write_denied?/1`
  answers "which SOURCE may this socket see" (an author sees their own
  unredacted document). It does not answer "are these bytes safe to `raw/1`".
  And the write-capable population is not only authenticated authors:
  `Shared.Paper`'s own clamp comment conceded that "a principal-LESS socket on
  the open public-demo desk is write-capable BY DESIGN, so nothing here narrows
  it". That desk is what this file mounts — `:public_demo_studio` is `true` in
  `config/test.exs` — so the socket here is anonymous AND write-capable, which
  is the residual arm the mount clamp deliberately left open.

  WHY THE STORE-TIME CHOKEPOINT DOES NOT COVER IT. `Content.Writer` scrubs
  `content["body_html"]` on create and upsert, so a write made today is clean.
  That chokepoint landed in #2340 (2026-07-10) and does not reach backwards,
  which is why `Plugs.PaperReaderCsp` names "a pre-sanitizer poisoned row" as
  the thing it exists to catch — and that plug is path-gated to the
  `…/papers/:slug` readers, which Studio is not. So on this arm the store-time
  pass was the ONLY layer. Every fixture below plants its bytes with a direct
  `Repo.update!`, which is exactly that pre-chokepoint population.

  `async: false` — the paper-canvas flag is process-global.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.{Content, Repo}
  alias BarkparkWeb.Studio.StudioLive.Shared

  # ITS OWN DATASET, for the reason the sibling anon-share file records: schema
  # lookup and the tag registry are dataset-scoped and shared on "production",
  # so a foreign global `paper` schema could decide this file's verdict. A
  # dataset no other file names cannot be raced on the shared test database.
  @dataset "wcap-body-html-#{System.unique_integer([:positive])}"

  # A stored cache no renderer of ours would emit today: a script, an
  # event-handler attribute, and one paragraph of real prose. The sanitizer
  # keeps the prose and drops the rest — so a green here is a CLAMP, not a
  # blanking, and the prose assertion is what proves that.
  @poisoned ~s|<p id="readable">Readable prose</p><script>alert('leak')</script><img src="x" onerror="alert('handler')">|

  # The same shape, one revision later — the body a `:paper_updated` broadcast
  # announces (the THIRD `:paper_html` feed, which re-assigns after mount).
  @poisoned_v2 ~s|<p id="readable">Second version</p><script>alert('leak2')</script>|

  setup do
    prev_canvas = System.get_env("BARKPARK_PAPER_CANVAS")

    # An HTML-only paper renders the read-only raw arm under both settings;
    # pinning the default keeps the arm this file is about the one that runs.
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

  # An HTML-only (legacy) paper whose STORED cache carries the poisoned bytes.
  # Written through the normal upsert first (so every other content key is what
  # production carries), then the cache is planted directly — the write path
  # sanitizes, and the whole point is a row that predates that layer.
  defp create_html_paper!(ws, proj, slug, body_html) do
    {:ok, paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          "slug" => slug,
          "title" => "Legacy HTML paper",
          "dataset" => @dataset,
          "body_html" => "<p id=\"readable\">Readable prose</p>",
          "workspace_id" => ws.id,
          "project_id" => proj.id
        })
      )

    plant_body_html!(paper, body_html)
  end

  defp plant_body_html!(paper, body_html) do
    paper
    |> Ecto.Changeset.change(content: Map.put(paper.content, "body_html", body_html))
    |> Repo.update!()
  end

  defp open_paper!(conn, slug) do
    {:ok, view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{slug}"))
    {view, html}
  end

  # ANTI-VACUITY GUARD 1 — the socket really is on the WRITE-CAPABLE branch.
  # Without this the test could pass through the pre-existing write-DENIED
  # clamp (which already sanitizes via `reader_source/3`) and prove nothing
  # about the arm this fix changes. Reading the live socket and asserting the
  # branch predicate directly is the only check that cannot drift.
  defp assert_write_capable!(view) do
    socket = :sys.get_state(view.pid).socket

    refute Shared.write_denied?(socket),
           """
           this fixture must land on the WRITE-CAPABLE branch of
           reader_paper_html/2 — a write-DENIED socket is served by
           reader_source/3, which already sanitized before this fix, so a green
           here would be vacuous. Check :public_demo_studio in config/test.exs.
           """

    :ok
  end

  # ANTI-VACUITY GUARD 2 — the read-only raw arm is the one rendering, not an
  # earlier cond branch (no slug / editor / block mode). Keyed on the ARM, not
  # the id: an `<article>` whose tag CLOSES right after `data-rev` is the
  # read-only raw arm; the streamed block arm carries `phx-update="stream"` and
  # the never-blank arm carries the `paper-body-unrenderable-` id.
  defp assert_readonly_article!(rendered, slug) do
    articles = rendered |> then(&Regex.scan(~r/<article[^>]*>/, &1)) |> List.flatten()

    assert Enum.any?(
             articles,
             &(&1 =~ ~r/^<article id="paper-body-(?!unrenderable-)[^"]+" data-rev="\d+">$/)
           ),
           """
           expected the READ-ONLY raw arm (the fixture's document is #{slug}).
           `paper-body-unrenderable-…` is the clamp refusing, a tag carrying
           phx-update="stream" is block mode, `paper-body` bare is "no paper".
           articles rendered: #{inspect(articles)}
           """

    :ok
  end

  describe "a write-capable Studio socket on a legacy HTML-only paper" do
    test "does not render stored script into the raw arm", %{ws: ws, proj: proj, conn: conn} do
      slug = "wcap-poisoned-#{System.unique_integer([:positive])}"
      paper = create_html_paper!(ws, proj, slug, @poisoned)

      {view, html} = open_paper!(conn, paper.doc_id)

      assert_write_capable!(view)
      assert_readonly_article!(html, paper.doc_id)

      # The prose survives — this is a scrub, not a blanking ...
      assert html =~ "Readable prose"
      # ... and neither executable construct reaches the DOM.
      refute html =~ "alert('leak')"
      refute html =~ "alert('handler')"
      refute html =~ "onerror"
    end

    test "a :paper_updated broadcast cannot re-feed raw bytes after mount", %{
      ws: ws,
      proj: proj,
      conn: conn
    } do
      slug = "wcap-refeed-#{System.unique_integer([:positive])}"
      paper = create_html_paper!(ws, proj, slug, @poisoned)

      {view, _html} = open_paper!(conn, paper.doc_id)
      assert_write_capable!(view)
      pid_before = view.pid

      # The write the broadcast is ANNOUNCING, so the viewer genuinely moves to
      # this body rather than satisfying the test by ignoring the frame.
      _ = plant_body_html!(paper, @poisoned_v2)
      send(view.pid, {:paper_updated, %{html: @poisoned_v2, rev: 999}})

      rendered = render(view)
      assert_readonly_article!(rendered, paper.doc_id)

      # CURRENT: the viewer is on the new version ...
      assert rendered =~ "Second version"
      # ... with the frame's script scrubbed on the way into the assign.
      refute rendered =~ "alert('leak2')"
      # Still the same LiveView: this is a re-assign, not a remount.
      assert view.pid == pid_before
    end
  end
end
