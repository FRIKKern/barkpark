defmodule BarkparkWeb.Studio.StudioSessionBirthTemplateTest do
  @moduledoc """
  spd-bl-session-birth-template — a Studio-created session opens onto a canvas
  with somewhere to type.

  The writer's `maybe_apply_paper_template` matches "paper" ONLY, while
  `Content.blocks_type?/1` whitelists ["paper", "session"] — so the desk's
  generic `%{"blocks" => []}` seed persisted for a session as an untemplated
  EMPTY LIST. `read_blocks` returns it as-is, `setup_paper_view` takes the
  block branch (`paper_block_mode: true`), and the human got a pane in block
  mode with ZERO canvas runs: a second, different blank from the one wave 17
  fixed (named out of wave-17 scope by charter D221).

  The fix seeds ONE empty paragraph (`id: "session-body"`) at the Studio seam
  (`Shared.seed_new_doc_content/1`) — the same "somewhere to type" the paper
  template's `tpl-body` provides, without inventing a session template in
  core. The proof is the task's own bar: open a Studio-created session and
  assert a canvas run exists — read back from the STORE, not only the DOM.

  The paper birth is pinned UNCHANGED by contrast: papers keep the explicit
  empty list, because that list is precisely the signal `Template.maybe_seed`
  reads to apply the real paper template (D219) — a paragraph seeded there
  would bypass the locked title template.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content

  @dataset "production"

  setup do
    prev = System.get_env("BARKPARK_PAPER_CANVAS")
    System.put_env("BARKPARK_PAPER_CANVAS", "1")

    on_exit(fn ->
      case prev do
        nil -> System.delete_env("BARKPARK_PAPER_CANVAS")
        v -> System.put_env("BARKPARK_PAPER_CANVAS", v)
      end
    end)

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "session",
          "title" => "Sessions",
          "icon" => "clock",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    :ok
  end

  test "a Studio-born session carries one canvas run and opens onto it", %{conn: conn} do
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio"))

    # The Studio's own create path (Fields.new_document -> the
    # seed_new_doc_content seam), driven as the event the "+" button fires.
    # The session doclist pane nests under the plugin/…Rest tier whose node id
    # is dataset-random, so the event is sent to the view directly — same
    # handler, same seam, no hand-rolled fixture.
    html = render_click(view, "new-document", %{"type" => "session"})

    refute html =~ "Failed to create"

    # THE STORE IS THE PROOF: the persisted birth carries exactly the seeded
    # empty paragraph — a canvas run to type into, not an untemplated [].
    created =
      "session"
      |> Content.list_documents(@dataset, perspective: :raw)
      |> Enum.find(&Content.draft?(&1.doc_id))

    assert created, "expected the created session draft row to exist"

    session_blocks = created.content["blocks"]

    assert match?([%{"id" => "session-body", "type" => "paragraph"}], session_blocks),
           """
           A Studio-born session must carry ONE seeded paragraph run.

           An empty blocks list here is the measured defect: block mode with
           zero canvas runs — a blank pane with nothing to click and nowhere
           to type (spd-bl-session-birth-template).

           got: #{inspect(created.content["blocks"])}
           """

    [run] = session_blocks

    assert run["content"] == [], "the seeded run is EMPTY — a place to type, not content"

    # …and OPENING it (the reserved open/type/id segment the desk itself
    # uses) renders a real block editor over that run — not a block-mode pane
    # with zero canvas runs.
    pub_id = Content.published_id(created.doc_id)

    {:ok, _view2, opened} =
      live(conn, scoped_studio("/d/#{@dataset}/studio/open/session/#{pub_id}"))

    assert opened =~ ~s(data-test-id="studio-paper-block-editor")
    assert opened =~ "session-body"
  end

  test "the paper birth seed is UNCHANGED — still the explicit empty list the template reads",
       %{conn: conn} do
    # Contrast control: seeding a paragraph for papers would bypass the D219
    # template (locked tpl-title + tpl-body). This arm makes the session
    # clause unable to over-match.
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

    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper"))

    view
    |> element(~s(button.pane-add-btn[phx-click="new-document"][phx-value-type="paper"]))
    |> render_click()

    created =
      "paper"
      |> Content.list_documents(@dataset, perspective: :raw)
      |> Enum.find(&Content.draft?(&1.doc_id))

    assert created
    blocks = created.content["blocks"]

    assert Enum.any?(blocks, &(&1["id"] == "tpl-title")),
           "the paper template must still fire — got #{inspect(blocks)}"

    refute Enum.any?(blocks, &(&1["id"] == "session-body")),
           "the session seed leaked into the paper birth"
  end
end
