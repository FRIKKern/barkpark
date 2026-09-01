defmodule BarkparkWeb.Studio.StudioLiveNewPaperJourneyTest do
  @moduledoc """
  THE HUMAN PATH, not the API path (spd-w17).

  The owner sat down, clicked "+" in the Papers pane, watched the URL become
  `/studio/paper/paper-XXXX` — and the content pane still read
  "Select a document to edit". Every prior Studio suite drove the CODE
  (`render_click(view, "new-document", …)`, direct `Content.upsert_paper`
  seeds); nobody had ever clicked the DOM button with type `"paper"` and looked
  at what came back. This file is that journey, offline.

  Two arms, because the defect has two faces:

    1. FRESH CREATE — mount the Papers desk, click the pane's "+" button, and
       assert a real editor came back: `paper_block_mode` on, the block-editor
       marker in the DOM, and NOT the empty state. Plus the PERSISTED shape:
       the paper-template seed (locked `tpl-title` with `role: "title"` +
       `tpl-body`, `style: "article"`), which only fires when the create seeds
       an explicit EMPTY block list (D219).

    2. PRE-EXISTING DRAFT-ONLY PAPER — every never-published paper is
       unopenable by URL, not merely freshly-created ones (D228; two such
       fossils sit in production from 2026-07-06 and 2026-07-09). Same
       assertions, reached by navigation instead of by the button.

  spd-w18 ADDS THREE ARMS, and the first of them exists because arm 2 above was
  VACUOUS over the blank it was named after (D237). Arm 2 seeds
  `content: %{"blocks" => []}`, and an explicit empty LIST is exactly the shape
  D219's template seed re-fills — so its "fossil" opens with `tpl-title` +
  `tpl-body` and a real editor. The production fossils carry NO `blocks` key at
  all (`Projection.read_blocks/1` ⇒ nil ⇒ `paper_block_mode` false ⇒
  `show_editor` false), which is the shape that painted the owner's blank. Arm 2
  keeps its name honest (it pins the DRAFT-RESOLUTION fix on a template-seeded
  draft) and arm 3 carries the real shape:

    3. A RESOLVED PAPER WITH NO BLOCK LIST — the pane cannot render it, and it
       must SAY so: a named, announced state carrying the document's own id, its
       real type, a plain reason and at least one keyboard-focusable way out,
       where an empty `<article>` used to be the entire screen.

    4. A LEGACY HTML-ONLY PAPER — the never-blank arm must not swallow it. The
       blank predicate is text-and-visible-element aware, not `== ""`, so a
       `"<p></p>"` body IS named (it paints nothing) while an image-only body is
       NOT (it paints something).

    5. A SESSION IN THE PAPER PANE — the pane is opened by every blocks-doc
       type, so it must stop calling a session a paper: the header badge renders
       the real type and the empty-body sentence names the type + id.

  DELIBERATELY NOT ASSERTED: that `Content.get_blocks_doc(published_id)`
  resolves. It does not, and must not — `create_document` always writes
  `drafts.<id>` (writer.ex), so the published row genuinely does not exist.
  Asserting it would push the fix toward navigating to the `drafts.` id, which
  is the refuted lever (it would break `same_editor_doc?/2` identity, presence,
  the secondary pane and discard). The editor resolving the DRAFT is the fix.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content

  @dataset "production"
  @fossil_slug "spd-w17-fossil-paper"

  defp seed_paper_schema! do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "paper",
          "title" => "Papers",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )
  end

  setup do
    # PIN THE CANVAS FLAG ON, and this is not ceremony — it is why this file
    # passed alone and RED in CI's full suite. `BARKPARK_PAPER_CANVAS` is read
    # from the PROCESS-GLOBAL environment at render time, and four sibling
    # suites deliberately set it to "0" to pin the legacy opt-out path
    # (`paper_editor_test_helpers.ex`, `studio_live_paper_canvas_test.exs`,
    # `paper_canvas_test.exs`, `studio_live_paper_test.exs`). Inheriting a "0"
    # here does NOT re-break the owner's bug — the empty state stays gone — but
    # a block paper then opens into the read-only View pane plus the View⇄Edit
    # toggle, so `studio-paper-block-editor` legitimately does not render until
    # someone clicks Edit. Exactly three assertions failed in CI and it was
    # this, reproduced locally with `BARKPARK_PAPER_CANVAS=0`: 3 tests, 3
    # failures on that one line.
    #
    # The canvas IS the mainline default (D7/D9) — `nil` reads as ON — so this
    # pins the default rather than inventing a mode, mirroring the same
    # prev/put/on_exit idiom the OFF suites use. `async: false` makes the
    # process-global write safe.
    prev = System.get_env("BARKPARK_PAPER_CANVAS")
    System.put_env("BARKPARK_PAPER_CANVAS", "1")

    on_exit(fn ->
      case prev do
        nil -> System.delete_env("BARKPARK_PAPER_CANVAS")
        v -> System.put_env("BARKPARK_PAPER_CANVAS", v)
      end
    end)

    seed_paper_schema!()
    :ok
  end

  # The template seed is the product promise: a brand-new paper is not an empty
  # void, it is a locked title heading plus one empty paragraph to type into.
  defp assert_template_shape!(doc) do
    blocks = doc.content["blocks"]
    assert is_list(blocks), "expected a blocks list, got: #{inspect(doc.content["blocks"])}"

    title =
      Enum.find(blocks, fn b ->
        Map.get(b, "role") == "title" or get_in(b, ["meta", "role"]) == "title"
      end)

    assert title, "expected a role:title block in #{inspect(blocks)}"
    assert title["id"] == "tpl-title"
    assert title["type"] == "heading"
    assert title["locked"] == true or get_in(title, ["meta", "locked"]) == true

    assert Enum.any?(blocks, &(&1["id"] == "tpl-body")),
           "expected the empty tpl-body paragraph to type into, got #{inspect(blocks)}"

    assert doc.content["style"] == "article"
  end

  # The one place the two arms agree: whatever route got us here, the human is
  # looking at a real editor.
  defp assert_real_editor!(view, html) do
    refute html =~ "Select a document to edit"
    assert html =~ ~s(data-test-id="studio-paper-block-editor")

    assert :sys.get_state(view.pid).socket.assigns.paper_block_mode,
           "expected paper_block_mode — the paper opened in the field-form/empty branch instead"

    # …and it does not open by accusing the human of a value it wrote itself.
    # The editor now resolves the DRAFT row, so the sidebar's slug field is
    # seeded from `drafts.paper-…` unless it normalises — and that string
    # fails the slug format check, so a brand-new document greeted its author
    # with a red "Only lowercase letters, numbers, and hyphens" on the one
    # field it had never touched.
    refute html =~ ~s(value="drafts.),
           "the sidebar slug field must show the published id, never the drafts. storage prefix"

    refute html =~ "Only lowercase letters, numbers, and hyphens"
  end

  describe "arm 1 — a human clicks + in the Papers pane" do
    test "the new paper opens in a real editor, seeded with the paper template", %{conn: conn} do
      # The flat /studio/... path 302s since the P3 scoped cutover; mount the
      # canonical scoped form the browser actually lands on.
      {:ok, view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper"))

      # Before the click there is no document selected — the empty state here is
      # CORRECT, and pinning it is what makes its survival after the click a
      # real failure rather than a coincidence. spd-w19 replaced the shrug
      # ("Select a document to edit") with the derived `:nothing_selected` state:
      # drilling to a list and picking nothing is not an error and still does not
      # shout, but it no longer shares its copy with a document that FAILED to open.
      assert html =~ ~s(data-test-id="studio-editor-nothing-selected")

      # SCOPE the selector: the airdrop/access header buttons share the
      # `.pane-add-btn` class, and more than one element carries
      # [phx-click="new-document"] across the desk.
      html =
        view
        |> element(~s(button.pane-add-btn[phx-click="new-document"][phx-value-type="paper"]))
        |> render_click()

      refute html =~ "Failed to create"
      assert_real_editor!(view, html)

      # …and the row that was actually written carries the template.
      created =
        "paper"
        |> Content.list_documents(@dataset, perspective: :raw)
        |> Enum.find(&(&1.doc_id != "drafts.#{@fossil_slug}"))

      assert created, "expected the created paper draft row to exist"
      assert Content.draft?(created.doc_id), "create_document always writes drafts.<id>"
      assert_template_shape!(created)
    end

    # task-a945b98cfd8d941f — THE STORED SHAPE, not the painted text. The desk,
    # the breadcrumb and the tab all render "Untitled" either way (they fall
    # back with `doc.title || "Untitled"`), so asserting page text here would
    # pass with the defect fully present. What the human felt was that
    # "Untitled" is real CONTENT in the block they are about to type in — the
    # caret sat after it and the first keystroke appended
    # ("UntitledHand walk MT4FI4TN"). So this asserts the persisted document.
    test "the seeded title BLOCK is empty — \"Untitled\" is a display fallback, not stored text",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper"))

      view
      |> element(~s(button.pane-add-btn[phx-click="new-document"][phx-value-type="paper"]))
      |> render_click()

      created =
        "paper"
        |> Content.list_documents(@dataset, perspective: :raw)
        |> Enum.find(&(&1.doc_id != "drafts.#{@fossil_slug}"))

      assert created, "expected the created paper draft row to exist"

      title_block =
        Enum.find(created.content["blocks"], &(Map.get(&1, "role") == "title"))

      assert title_block["id"] == "tpl-title"

      assert title_block["text"] == "",
             "a brand-new paper's title block must start EMPTY so typing does not append; got #{inspect(title_block["text"])}"

      # …and the row title is not pre-filled either: `derive_title/2` fills it
      # from the block the moment the author types, and until then every
      # display site supplies the word itself.
      refute created.title == "Untitled",
             "the literal must not be STORED — the display fallbacks own that word"

      # The fallback is real, not assumed: this is the exact expression the
      # desk/breadcrumb/tab use, and it still reads "Untitled".
      assert (created.title || "Untitled") == "Untitled"
    end
  end

  describe "arm 2 — a pre-existing TEMPLATE-SEEDED draft-only paper opened by URL (D228)" do
    setup do
      {:ok, doc} =
        Content.create_document(
          "paper",
          %{"doc_id" => @fossil_slug, "title" => "Untitled", "content" => %{"blocks" => []}},
          @dataset
        )

      # The fossil is genuinely draft-only: no published row exists for it.
      assert doc.doc_id == "drafts.#{@fossil_slug}"
      assert {:error, :not_found} = Content.get_document(@fossil_slug, "paper", @dataset)

      # spd-w18 / D237 — SAY WHAT THIS FIXTURE IS. `%{"blocks" => []}` is an
      # explicit empty LIST, so D219's template seed re-filled it: this document
      # arrives at the pane with `tpl-title` + `tpl-body` and renders the editor.
      # It therefore proves DRAFT RESOLUTION, and it structurally cannot prove
      # anything about the owner's blank — that lives on the no-`blocks`-key
      # shape, pinned in arm 3 below. Asserting the seed here is what keeps the
      # two arms from being confused for each other again.
      {:ok, seeded} = Content.get_document("drafts.#{@fossil_slug}", "paper", @dataset)

      assert is_list(seeded.content["blocks"]) and seeded.content["blocks"] != [],
             "this arm's fixture is template-seeded by D219, NOT the blank shape"

      :ok
    end

    test "it opens in a real editor rather than the empty state", %{conn: conn} do
      {:ok, view, html} =
        live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@fossil_slug}"))

      assert_real_editor!(view, html)

      {:ok, fossil} = Content.get_document("drafts.#{@fossil_slug}", "paper", @dataset)
      assert_template_shape!(fossil)
    end

    # The SECOND door onto the same defect (D220). The backlinks panel jumps to a
    # referencer through the reserved ["open", type, id] segment, which resolved
    # blocks-docs published-only too. Fixing only the desk branch would have left
    # this one silently blank — and no arm above touches it.
    test "the same paper opens through the reserved open/type/id backlink segment", %{conn: conn} do
      {:ok, view, html} =
        live(conn, scoped_studio("/d/#{@dataset}/studio/open/paper/#{@fossil_slug}"))

      assert_real_editor!(view, html)
    end
  end

  # ── spd-w18 ────────────────────────────────────────────────────────────────

  @blank_slug "spd-w18-fossil-blank"
  @legacy_slug "spd-w18-legacy-html"

  # THE REAL FOSSIL SHAPE (D237): content with NO `blocks` key. Proven at the
  # seam rather than assumed — `create_document` stores this content verbatim, so
  # the assertion below is what stops a future refactor from quietly re-seeding a
  # list here and making every test under it vacuous.
  defp seed_blockless!(slug, content) do
    {:ok, doc} =
      Content.create_document(
        "paper",
        %{"doc_id" => slug, "title" => "Untitled", "content" => content},
        @dataset
      )

    refute Map.has_key?(doc.content, "blocks"),
           "FIXTURE LAW (D237): this fossil must carry NO blocks key, got #{inspect(doc.content)}"

    assert is_nil(Barkpark.PortableDoc.Projection.read_blocks(doc.content)),
           "read_blocks must return nil for this shape — that is what blanks the pane"

    doc
  end

  describe "arm 3 — a resolved paper with no block list says so BY NAME (spd-w18)" do
    setup do
      seed_blockless!(@blank_slug, %{"rev" => 0})
      :ok
    end

    test "the pane paints a named, announced state with the id, the type and a way out",
         %{conn: conn} do
      {:ok, _view, html} =
        live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@blank_slug}"))

      # NAMED: a stable test-id, not a shrug.
      assert html =~ ~s(data-test-id="paper-unrenderable-notice")

      # ANNOUNCED: assistive tech is told, the same way doc_conflict_banner/1
      # tells it. Both attributes on the notice element itself.
      [notice] =
        Regex.run(
          ~r/<div[^>]*data-test-id="paper-unrenderable-notice".*?<\/div>\s*<\/article>/s,
          html
        )

      assert notice =~ ~s(role="alert")
      assert notice =~ ~s(aria-live="assertive")

      # IDENTIFIED: the document's own id and its REAL type, machine-readable
      # and in the copy a human reads. The id is the PUBLISHED one — `drafts.` is
      # storage plumbing, and the pane must not quote it back at the author.
      assert notice =~ ~s(data-doc-id="#{@blank_slug}")
      assert notice =~ ~s(data-doc-type="paper")
      assert notice =~ ~s(<code>#{@blank_slug}</code>)
      refute notice =~ "drafts."

      # A WAY OUT, asserted as a COUNT so its absence reds: every recovery
      # control inside the notice carries an href or a phx-click.
      ways = Regex.scan(~r/<(?:a|button)\b[^>]*data-test-id="paper-unrenderable-[a-z-]+"/, notice)

      assert length(ways) >= 1,
             "the named state must offer at least one keyboard-focusable way out, got: #{notice}"

      assert Enum.all?(ways, fn [tag] -> tag =~ "href=" or tag =~ "phx-click=" end),
             "every way out must be a real control (href or phx-click): #{inspect(ways)}"

      # The repair is the one the fossil actually needs, on the one path that
      # can mint the missing list.
      assert notice =~ ~s(phx-click="paper-add-block")
      assert notice =~ ~s(data-test-id="paper-unrenderable-start-body")
    end

    test "the empty <article> that used to BE the whole screen is gone", %{conn: conn} do
      {:ok, _view, html} =
        live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@blank_slug}"))

      # The deployed-DOM fingerprint from the report: the body article opened and
      # closed with nothing in between. The article id carries the RAW resolved
      # slug (a draft-only fossil resolves as `drafts.<id>`).
      #
      # spd-w19 UPDATES the id, and this is an expectation change, not a
      # regression: the never-blank arm shipped sharing `paper-body-<slug>` with
      # the STREAMED block arm, and the repair button crosses exactly that
      # boundary (canvas OFF renders the streamed arm). One node keeping its id
      # while gaining `phx-update="stream"` means the notice is preserved as an
      # untracked child of a stream container — it survives its own repair.
      # `paper-body-unrenderable-<slug>` makes the repair a node replacement.
      article_id = "paper-body-unrenderable-drafts.#{@blank_slug}"

      refute html =~ ~r/<article id="#{Regex.escape(article_id)}" data-rev="0">\s*<\/article>/,
             "the resolved-but-unrenderable body must never render as an empty article"

      # …and it is still ONE article carrying the whole named state, data-rev
      # unchanged.
      assert html =~ ~s(<article id="#{article_id}" data-rev="0">)

      refute html =~ ~s(<article id="paper-body-drafts.#{@blank_slug}"),
             "the notice arm must not share the streamed arm's container id"
    end

    test "the header badge and the notice both name the real type, never a literal",
         %{conn: conn} do
      {:ok, _view, html} =
        live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@blank_slug}"))

      assert html =~ ~s(<span class="badge badge-published">paper</span>)
    end
  end

  describe "arm 4 — a legacy HTML-only paper is NOT swallowed by the never-blank arm" do
    test "a real body_html renders raw, exactly as before, with no notice", %{conn: conn} do
      seed_blockless!(@legacy_slug, %{
        "rev" => 0,
        "body_html" => "<p>Legacy prose that a reader can actually see.</p>"
      })

      {:ok, _view, html} =
        live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@legacy_slug}"))

      assert html =~ "Legacy prose that a reader can actually see."
      refute html =~ ~s(data-test-id="paper-unrenderable-notice")
    end

    test "a body_html that PAINTS nothing (<p></p>) is named — the reason `== \"\"` was refused",
         %{conn: conn} do
      seed_blockless!(@legacy_slug, %{"rev" => 0, "body_html" => "<p></p>\n<div> </div>"})

      {:ok, _view, html} =
        live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@legacy_slug}"))

      assert html =~ ~s(data-test-id="paper-unrenderable-notice"),
             "a non-empty STRING that paints an empty screen is the blank being fixed"
    end

    test "an HTML-backed blank offers NO repair button, because the op layer refuses it",
         %{conn: conn} do
      seed_blockless!(@legacy_slug, %{"rev" => 0, "body_html" => "<p></p>"})

      {:ok, view, html} =
        live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@legacy_slug}"))

      assert html =~ ~s(data-test-id="paper-unrenderable-notice")

      # spd-w18 review: `reject_implicit_html_conversion/1` HALTS a block op on a
      # document that has a body_html string and no block list, so offering
      # "Start the body with a paragraph" here would be a control that cannot do
      # what it says — the owner's complaint in a new costume. The way out is the
      # link, and the reason says why.
      refute html =~ ~s(data-test-id="paper-unrenderable-start-body"),
             "a repair the write layer refuses must not be offered"

      assert html =~ "will not silently convert stored HTML into"
      assert html =~ ~s(data-test-id="paper-unrenderable-back")

      # And the refusal is REAL, not a guess: driving the op this button would
      # have sent halts and leaves the document untouched.
      assert {:error, {:halted, _}} =
               Barkpark.Content.apply_paper_block_op(
                 "drafts.#{@legacy_slug}",
                 %{"op" => "append-block", "block" => %{"id" => "b1", "type" => "paragraph"}},
                 @dataset
               )

      assert render(view) =~ ~s(data-test-id="paper-unrenderable-notice")
    end

    test "a body_html with no text but a visible element is left alone — the predicate is not too wide",
         %{conn: conn} do
      seed_blockless!(@legacy_slug, %{
        "rev" => 0,
        "body_html" => ~s(<figure><img src="/media/x.png" alt="A scan"></figure>)
      })

      {:ok, _view, html} =
        live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@legacy_slug}"))

      assert html =~ ~s(<img src="/media/x.png")

      refute html =~ ~s(data-test-id="paper-unrenderable-notice"),
             "an image-only legacy body is visible; naming it unrenderable would be a NEW blank"
    end
  end

  describe "arm 5 — the paper pane stops calling a session a paper" do
    # Rendered through the component directly: a session's desk route is not the
    # subject here, the pane's own honesty is. Every assign is the shape
    # `setup_paper_view/2` hands it for a blocks-doc.
    defp session_pane_html(content) do
      render_component(&BarkparkWeb.Studio.StudioLive.Components.studio_paper_view/1, %{
        paper_doc: %Barkpark.Content.Document{
          doc_id: "session-2026-07-30-x",
          type: "session",
          title: "A work session",
          status: "draft",
          content: content
        },
        paper_rev: 0,
        paper_html: "",
        paper_block_mode: true,
        paper_edit_mode: false,
        dataset: @dataset,
        streams: %{paper_blocks: []}
      })
    end

    test "the header badge renders the document's real type" do
      html = session_pane_html(%{"blocks" => []})

      assert html =~ ~s(<span class="badge badge-published">session</span>)
      refute html =~ ~s(<span class="badge badge-published">paper</span>)
    end

    test "the empty-body sentence names the type and the id, not \"This paper\"" do
      html = session_pane_html(%{"blocks" => []})

      assert html =~ "This session"
      assert html =~ "session-2026-07-30-x"
      refute html =~ "This paper has no body blocks yet"
    end
  end
end
