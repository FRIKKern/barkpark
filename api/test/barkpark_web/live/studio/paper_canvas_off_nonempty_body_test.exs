defmodule BarkparkWeb.Studio.PaperCanvasOffNonEmptyBodyTest do
  @moduledoc """
  THE FLAG-OFF BODY MUST NEVER RENDER ZERO CHARACTERS (spd-canvas-off-nonempty-guard).

  Wave 19 DECIDED not to build a named state on the `BARKPARK_PAPER_CANVAS=0`
  arm, on the ground that the arm is not a production screen (charter D256):
  the variable is set nowhere in this repo's deploy surface, and
  `paper_canvas_enabled?/0` reads `nil` as TRUE. This file is what makes that
  decision FALSIFIABLE instead of merely asserted — it reds the moment an
  operator (or a future host template) turns the canvas off and thereby
  promotes the opt-out arm to a screen a human looks at.

  THE MEASUREMENT. A block-backed document persisted with `blocks: []` is the
  general case: `Projection.read_blocks/1` returns a LIST, so
  `paper_block_mode` is true and the never-blank notice at
  `components.ex`'s `blank_body?/1` arm is structurally unreachable for it. At
  flag ON the body region carries the wave-18 named sentence plus the Add-block
  form. At flag OFF `show_editor` is false, the pane renders the streamed
  `<article phx-update="stream">` with no stream children, and the body region
  renders ZERO visible characters — and the shell loses its `aria-label` on top,
  so the surface is nameless to a screen reader as well as wordless on screen.

  Both flag values are measured in the SAME file and the count is asserted at
  both, so "non-zero" can never be satisfied by chrome leaking into the region:
  the region is `main[data-test-id="studio-paper-shell"]` — the body arm and
  nothing else; the header, the badge, the action bar and the metadata sidebar
  are all its siblings, outside it.

  AS MEASURED ON THIS FIXTURE: before the fix, flag=1 rendered 496 visible
  characters and flag=0 rendered 0. After it, flag=1 is unchanged at 496 and
  flag=0 renders 100.

  The flag is pinned per charter D233 through
  `BarkparkWeb.PaperEditorTestHelpers.pin_paper_canvas!/1` — the repo's single
  get_env/put_env/on_exit-delete_env idiom — under `async: false`.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BarkparkWeb.PaperEditorTestHelpers, only: [pin_paper_canvas!: 1, seed_paper_schema!: 0]

  alias Barkpark.Content

  @dataset "production"
  @slug "spd-canvas-off-empty-paper"

  setup do
    seed_paper_schema!()
    :ok
  end

  # FIXTURE LAW: the document must carry a `blocks` key holding an EMPTY LIST.
  #
  # Two shapes are NOT this fixture and would each measure a different arm:
  #   * NO `blocks` key at all — the w19 fossil, which routes to
  #     `blank_body?/1`'s never-blank notice.
  #   * The BIRTH TEMPLATE — `Content.create_document/3` injects a locked
  #     `tpl-title` heading plus a `tpl-body` paragraph even when the caller
  #     passes `"blocks" => []`, so the created row is a TWO-block document.
  #
  # And `upsert_paper/1` cannot make one either: the publish wall refuses an
  # empty body outright ("This paper has a title but no content yet"). So the
  # row is created and then written down to `blocks: []` directly — which is
  # the state a document reaches in production the ordinary way, by an author
  # deleting the last block.
  defp seed_empty_block_paper! do
    {:ok, created} =
      Content.create_document(
        "paper",
        %{"_id" => @slug, "title" => "Empty Body Paper", "blocks" => []},
        @dataset
      )

    doc =
      created
      |> Ecto.Changeset.change(content: %{"rev" => 0, "blocks" => []})
      |> Barkpark.Repo.update!()

    assert %{"blocks" => []} = doc.content,
           "FIXTURE LAW: the guard measures a blocks-LIST document that is EMPTY, " <>
             "got #{inspect(doc.content)}"

    doc
  end

  # The seeded row is draft-only, so its resolved id carries the storage prefix.
  @doc_id "drafts.#{@slug}"

  defp open_paper(conn) do
    live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@doc_id}"))
  end

  # The document BODY REGION only: `main[data-test-id="studio-paper-shell"]`
  # holds the sentinel plus whichever body arm the cond picked, and NOTHING
  # else — the document header, the type badge, the action bar and the metadata
  # sidebar are all its siblings, outside it. Measuring the panel instead would
  # keep the count comfortably non-zero forever and the guard would be a
  # decoration.
  #
  # It is deliberately NOT scoped to `article`: only the streamed / notice /
  # legacy arms render an `<article>`; the editor arm renders a `<div
  # class="bp-paper-editor">`, so an `article`-scoped count reads 0 on the
  # canvas path and the flag-ON control would be measuring nothing.
  defp body_text(view) do
    view
    |> element(~s(main[data-test-id="studio-paper-shell"]))
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp shell_aria_label(view) do
    view
    |> element(~s(main[data-test-id="studio-paper-shell"]))
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s(main[data-test-id="studio-paper-shell"]))
    |> LazyHTML.attribute("aria-label")
  end

  describe "canvas ON (the mainline default) — the control" do
    setup do
      pin_paper_canvas!("1")
      seed_empty_block_paper!()
      :ok
    end

    test "an empty-blocks document says so, in words, and the shell is named", %{conn: conn} do
      {:ok, view, _html} = open_paper(conn)

      text = body_text(view)

      assert String.length(text) > 0,
             "flag ON body region rendered zero characters — the control arm is broken, " <>
               "so the flag-OFF assertion below would prove nothing"

      assert text =~ "has no body blocks yet"

      assert shell_aria_label(view) != [],
             "flag ON shell has no accessible name"
    end
  end

  describe "canvas OFF (BARKPARK_PAPER_CANVAS=0) — the guard" do
    setup do
      pin_paper_canvas!("0")
      seed_empty_block_paper!()
      :ok
    end

    # THE TRIPWIRE. If this ever reds again, someone has made the opt-out arm
    # wordless — and the moment anyone exports BARKPARK_PAPER_CANVAS=0 on a live
    # host, that wordlessness is a production screen.
    test "the body region renders NON-ZERO visible characters", %{conn: conn} do
      {:ok, view, _html} = open_paper(conn)

      text = body_text(view)

      assert String.length(text) > 0,
             "the flag-OFF body region rendered ZERO visible characters for a blocks-list " <>
               "document — an author who opens this paper is shown nothing at all and is " <>
               "given no way forward. Region text was: #{inspect(text)}"

      # And the characters are the RIGHT ones: the sentence names WHICH document
      # is empty and WHERE the way forward is. Without this a stray glyph of
      # chrome leaking into the region would satisfy the count above.
      assert text =~ "has no body blocks yet"
      assert text =~ @doc_id
      assert text =~ "Choose Edit above to add one."
    end

    # Criterion 3: the shell's accessible name. A wordless region that is also
    # nameless is invisible twice over.
    test "the shell keeps an accessible name", %{conn: conn} do
      {:ok, view, _html} = open_paper(conn)

      labels = shell_aria_label(view)

      assert labels != [],
             "the flag-OFF paper shell carries NO aria-label — the surface is unnamed to a " <>
               "screen reader, so a wordless body has nothing announcing it either"

      assert [label] = labels
      assert String.trim(label) != "", "the flag-OFF shell's aria-label is blank"
    end
  end
end
