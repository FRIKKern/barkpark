defmodule BarkparkWeb.Studio.StudioLivePaperWayOutTest do
  @moduledoc """
  THE WAY OUT HAS TO GET YOU OUT (spd-w19, charter D257/D258).

  Wave 18 gave a resolved-but-unrenderable document a named state with two ways
  out. Neither of them worked, and this file is the binary for both — driven
  through a real `live/2` mount on the real fossil shape (content with NO
  `blocks` key), never through the component in isolation.

    1. THE REPAIR BUTTON. `paper-add-block` DID land (the paper gained a
       paragraph, the footer said "Auto-saved") but the pane never left the
       notice: `paper_pane_op/2` re-assigned `paper_doc` and nothing else, so
       `paper_block_mode` stayed false and the notice re-rendered over a
       document that now had a body. Worse, the write mints `body_html`, so on
       that re-render `html_backed_body` flipped true, the repair button
       VANISHED, and the reason text flipped to a sentence that was FALSE about
       the document ("stored as saved HTML … the body cannot be started from
       here"). The assertion is therefore the SWAP — notice absent AND the block
       editor present in the same re-render — not merely that the wording moved.

    2. THE WAY BACK. The emitted href was `/d/production/studio/paper`, a path
       that exists only under the `/w/:ws/p/:proj` scope: `route_info/4`
       returned `:error` and a real request 404'd. Proven here as a ROUTE (a
       router lookup plus a real request), never as a string equality against
       the same `Paths` call the component makes — that assertion would have
       been green the whole time this link was broken.

  Both arms are proven at BOTH values of `BARKPARK_PAPER_CANVAS`, because the
  fix has two halves and the flag hides one of them: with the canvas ON the
  always-editable editor renders off `paper_doc`, so the mode re-derive alone
  looks sufficient; with it OFF (`show_editor` false) the pane renders the
  streamed `<article phx-update="stream">`, and a mode flip WITHOUT the stream
  fill paints that article with zero children — a NEW blank. The flag is pinned
  per charter D233 (`async: false` + `on_exit` restore).
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content
  alias BarkparkWeb.Studio.StudioLive.Paths

  @dataset "production"
  @fossil "spd-w19-way-out-fossil"

  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "paper",
          "title" => "Papers",
          "icon" => "file-text",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    :ok
  end

  # The REAL fossil shape (D237): content with NO `blocks` key at all, asserted
  # at the seam so this file can never go vacuous the way spd-w18's arm 2 did.
  defp seed_fossil! do
    {:ok, doc} =
      Content.create_document(
        "paper",
        %{"doc_id" => @fossil, "title" => "Untitled", "content" => %{"rev" => 0}},
        @dataset
      )

    refute Map.has_key?(doc.content, "blocks"),
           "FIXTURE LAW (D237): the fossil must carry NO blocks key, got #{inspect(doc.content)}"

    doc
  end

  defp pin_canvas!(value) do
    previous = System.get_env("BARKPARK_PAPER_CANVAS")
    System.put_env("BARKPARK_PAPER_CANVAS", value)

    on_exit(fn ->
      case previous do
        nil -> System.delete_env("BARKPARK_PAPER_CANVAS")
        restore -> System.put_env("BARKPARK_PAPER_CANVAS", restore)
      end
    end)
  end

  defp open_fossil(conn) do
    live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@fossil}"))
  end

  # The document body region only — so "renders nothing" is measured on the
  # surface the author looks at, not on the whole shell (whose chrome would keep
  # any character count comfortably non-zero forever).
  defp body_text(view) do
    view
    |> element(~s(main[data-test-id="studio-paper-shell"]))
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("article")
    |> LazyHTML.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  describe "the repair button opens the editor (canvas ON — the mainline default)" do
    setup do
      pin_canvas!("1")
      seed_fossil!()
      :ok
    end

    test "pressing it SWAPS the screen: the notice goes, the block editor arrives",
         %{conn: conn} do
      {:ok, view, html} = open_fossil(conn)

      # BEFORE: the named state, and no editor.
      assert html =~ ~s(data-test-id="paper-unrenderable-notice")
      assert html =~ ~s(data-test-id="paper-unrenderable-start-body")
      assert html =~ ~s(phx-value-if_rev="0")
      refute html =~ ~s(data-test-id="studio-paper-block-editor")

      after_html =
        view
        |> element(~s([data-test-id="paper-unrenderable-start-body"]))
        |> render_click()

      # AFTER, in the SAME re-render: the way out got us out.
      refute after_html =~ ~s(data-test-id="paper-unrenderable-notice"),
             "the notice survived its own repair — the way out did not get the author out"

      assert after_html =~ ~s(data-test-id="studio-paper-block-editor"),
             "the repair minted a block list but the editor never opened"

      # The write really landed (this was never the broken half, and asserting it
      # keeps the swap above from being explained away as a failed write).
      # The fossil is draft-only, so its resolved id carries the storage prefix.
      assert %{content: %{"blocks" => [_ | _] = blocks}} =
               Content.get_paper("drafts.#{@fossil}", @dataset)

      assert Enum.any?(blocks, &(&1["type"] == "paragraph"))
    end

    test "the reason text cannot flip to the HTML-backed sentence as a side effect",
         %{conn: conn} do
      {:ok, view, _html} = open_fossil(conn)

      after_html =
        view
        |> element(~s([data-test-id="paper-unrenderable-start-body"]))
        |> render_click()

      # The pre-fix build kept the notice and re-worded it — the write mints
      # `body_html`, so `html_backed_body` flipped true on the very next render
      # and the pane told the author the body "was stored as saved HTML", about a
      # document that had gained a real block list milliseconds earlier.
      refute after_html =~ "will not silently convert stored HTML into",
             "the notice re-rendered with a sentence that is false about this document"

      refute after_html =~ ~s(data-test-id="paper-unrenderable-notice")
    end

    test "the repair is not replayable behind a vanished button — there is no second empty paragraph",
         %{conn: conn} do
      {:ok, view, _html} = open_fossil(conn)

      view
      |> element(~s([data-test-id="paper-unrenderable-start-body"]))
      |> render_click()

      # The control is GONE from the DOM (the editor replaced it), so the stage-C
      # replay the pre-fix build allowed has no button to press.
      assert_raise ArgumentError, fn ->
        view
        |> element(~s([data-test-id="paper-unrenderable-start-body"]))
        |> render_click()
      end
    end
  end

  describe "the repair button opens the editor (canvas OFF — the opt-out path)" do
    setup do
      pin_canvas!("0")
      seed_fossil!()
      :ok
    end

    # THE RESIDUAL THE ASSIGN-ONLY FIX WOULD HAVE SHIPPED. With the canvas off
    # `show_editor` is false, so the repaired document renders the STREAMED
    # article. Flipping `paper_block_mode` without filling `:paper_blocks` paints
    # that article with ZERO children — a new blank of exactly the class this wave
    # outlaws. So the measurement is the stream's children.
    #
    # MEASURED HONESTLY, because the obvious metric lies here: the block the
    # repair mints is an EMPTY paragraph, so the body region's visible-glyph count
    # is 0 at this flag value BY DESIGN (an empty paragraph is a caret target, not
    # a message). Glyph count therefore cannot tell "no stream children" from "one
    # empty block"; the child count and the article's own markup can, and the
    # user-visible way forward — the OFF path's Edit toggle, which only renders
    # for a block-backed paper — is asserted on top.
    test "the repaired body renders real stream children, never an empty stream article",
         %{conn: conn} do
      {:ok, view, html} = open_fossil(conn)

      assert html =~ ~s(data-test-id="paper-unrenderable-notice")
      # Pre-repair the body region is the NOTICE (wave 18's fix — an unrenderable
      # document is never silent), so the pre/post contrast is notice → blocks.
      assert body_text(view) =~ "cannot render the body of this paper"

      after_html =
        view
        |> element(~s([data-test-id="paper-unrenderable-start-body"]))
        |> render_click()

      refute after_html =~ ~s(data-test-id="paper-unrenderable-notice")

      article_id = "paper-body-drafts.#{@fossil}"

      refute after_html =~ ~r/<article id="#{Regex.escape(article_id)}"[^>]*>\s*<\/article>/,
             "the repaired document renders an EMPTY stream article — a NEW blank"

      children =
        view
        # Attribute form, not `#id`: a draft-only slug carries dots, which a CSS
        # id selector would read as class separators.
        |> element(~s(article[id="#{article_id}"]))
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("[data-block-id]")

      assert Enum.count(children) >= 1,
             "the stream was never filled — the mode flipped over an empty container"

      # And the author can act on it: the opt-out path's Edit toggle renders only
      # for a block-backed paper, so its presence is the way forward being real.
      assert after_html =~ ~s(data-test-id="paper-edit-toggle")
    end
  end

  describe "the way back is a real route, for both viewer grammars" do
    setup do
      pin_canvas!("1")
      seed_fossil!()
      :ok
    end

    test "the scoped viewer's link resolves in the router AND answers 200", %{conn: conn} do
      {:ok, _view, html} = open_fossil(conn)

      [href] =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s(a[data-test-id="paper-unrenderable-back"]))
        |> LazyHTML.attribute("href")

      # A ROUTE, not a plausible string — and asserted FIRST, so a regression in
      # the scope thread reds the ROUTE, not a string comparison. `:error` is what
      # the shipped `/d/production/studio/paper` returned here.
      route = Phoenix.Router.route_info(BarkparkWeb.Router, "GET", href, "localhost")

      refute route == :error,
             "the notice's way back is not a route this router serves: #{href}"

      # The 200 comes BEFORE the shape assertions on purpose: it is the assertion
      # a regression in the scope thread must red, and it cannot be satisfied by
      # any string that merely looks like a path.
      assert conn |> get(href) |> Map.fetch!(:status) == 200,
             "the notice's way back does not answer 200: #{href}"

      assert %{
               route: "/w/:workspace_slug/p/:project_slug/d/:dataset/studio/*path",
               log_module: BarkparkWeb.Studio.StudioLive,
               path_params: %{"dataset" => @dataset, "path" => ["paper"]}
             } = route

      assert href == scoped_studio("/d/#{@dataset}/studio/paper"),
             "the notice's way back must carry the viewer's own scope"
    end

    test "the flat grammar the component falls back to is routable too", %{conn: conn} do
      flat = Paths.flat_root(@dataset) <> "/paper"

      refute Phoenix.Router.route_info(BarkparkWeb.Router, "GET", flat, "localhost") == :error,
             "the flat fallback must be a real route: #{flat}"

      # The flat surface rides the P3 flat→scoped funnel, so its honest answer is
      # a 302 into the scoped canonical — which is itself a 200 (above). The
      # unroutable `/d/:dataset/studio/paper` this replaced answered neither.
      flat_conn = get(conn, flat)
      assert flat_conn.status == 302
      assert Phoenix.ConnTest.redirected_to(flat_conn) =~ "/d/#{@dataset}/studio"
    end

    # The fallback grammar, guarded where it is actually reachable: rendered
    # through the component with NO scope (the attr's default). This is the half
    # of the fix the threaded call site would otherwise hide — the emitted href
    # must be routable at BOTH ends of the attr, never the `/d/…` form that is
    # only a route under `/w/:ws/p/:proj`.
    test "with no scope at all the emitted href is still a route" do
      html =
        render_component(&BarkparkWeb.Studio.StudioLive.Components.studio_paper_view/1, %{
          paper_doc: %Barkpark.Content.Document{
            doc_id: @fossil,
            type: "paper",
            title: "Untitled",
            status: "draft",
            content: %{"rev" => 0}
          },
          paper_rev: 0,
          paper_html: "",
          paper_block_mode: false,
          paper_edit_mode: false,
          dataset: @dataset,
          streams: %{paper_blocks: []}
        })

      [href] =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s(a[data-test-id="paper-unrenderable-back"]))
        |> LazyHTML.attribute("href")

      assert href == Paths.flat_root(@dataset) <> "/paper"

      refute Phoenix.Router.route_info(BarkparkWeb.Router, "GET", href, "localhost") == :error,
             "the unscoped fallback must still be a route: #{href}"
    end

    test "the unscoped /d/… spelling the notice used to emit is genuinely unroutable" do
      assert Phoenix.Router.route_info(
               BarkparkWeb.Router,
               "GET",
               "/d/#{@dataset}/studio/paper",
               "localhost"
             ) == :error
    end
  end
end
