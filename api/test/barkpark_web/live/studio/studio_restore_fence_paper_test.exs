defmodule BarkparkWeb.Studio.StudioRestoreFencePaperTest do
  @moduledoc """
  task-5b74471e6a2d6de8, in paper view: history's Restore names the rev of the
  paper the page shows (`History.seen_rev/1`), so a write the page showed does
  not refuse the next press.

  The button named `editor_doc.rev`, the row from the last pane rebuild. A
  paper's own ops and the frames the page paints re-read `paper_doc` only, so
  the first press after any write, the person's own typing included, was
  refused; the second went through.

  The other writer is this test process writing through `Barkpark.Content`.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias BarkparkWeb.EditorPost

  @dataset "production"
  @moved "The document changed since you loaded it"

  setup %{conn: conn} do
    previous = System.get_env("BARKPARK_PAPER_CANVAS")
    System.put_env("BARKPARK_PAPER_CANVAS", "1")

    on_exit(fn ->
      if previous,
        do: System.put_env("BARKPARK_PAPER_CANVAS", previous),
        else: System.delete_env("BARKPARK_PAPER_CANVAS")
    end)

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "paper",
          "title" => "Papers",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            %{"name" => "body", "type" => "richText"}
          ]
        },
        @dataset
      )

    slug = "rfence-paper-#{System.unique_integer([:positive])}"
    write(slug, "Body one")
    write(slug, "Body two")

    raw = "rfence-paper-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "rfence-paper", @dataset, ~w(read write admin), ws_id)

    {:ok, conn: Plug.Test.init_test_session(conn, %{"api_token" => raw}), slug: slug}
  end

  # Someone else saves the whole paper.
  defp write(slug, body) do
    {:ok, paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: slug,
          dataset: @dataset,
          title: "Fence paper",
          blocks: [
            %{"id" => "b-head", "type" => "heading", "text" => "Fence paper", "level" => 1},
            paragraph("b-body", body),
            paragraph("b-extra", "Spare block")
          ]
        })
      )

    paper
  end

  defp paragraph(id, value),
    do: %{"id" => id, "type" => "paragraph", "content" => text(value)}

  defp patch_body(value),
    do: %{"op" => "patch-block", "id" => "b-body", "patch" => %{"content" => text(value)}}

  defp text(value), do: [%{"type" => "text", "value" => value}]

  defp open(c) do
    {:ok, view, _html} = live(c.conn, scoped_studio("/d/#{@dataset}/studio/paper/#{c.slug}"))
    render_async(view, 5_000)

    if has_element?(view, "[data-test-id='paper-edit-toggle']"),
      do: view |> element("[data-test-id='paper-edit-toggle']") |> render_click()

    assert socket_assigns(view).editor_view == :paper, "fixture: the page is in paper view"
    view
  end

  defp socket_assigns(view), do: :sys.get_state(view.pid).socket.assigns
  defp flash(view), do: socket_assigns(view).flash

  # The stored paper's row, and the row a restore compares (draft first).
  defp stored(c), do: Content.get_paper(c.slug, @dataset)

  defp current(c) do
    {doc, _draft?, _published?} = Content.fetch_doc_with_draft("paper", c.slug, @dataset)
    doc
  end

  defp body_text(doc) do
    doc.content["blocks"]
    |> Enum.find(&(&1["id"] == "b-body"))
    |> get_in(["content", Access.at(0), "value"])
  end

  # The history dialog's Restore of the paper's first revision ("Body one").
  defp dialog_values(view, c) do
    first = c.slug |> Content.list_revisions("paper", @dataset, limit: 200) |> List.last()
    render_click(view, "show-history", %{})

    [el] =
      view
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query(~s(#history-list button[phx-value-id="#{first.id}"]))
      |> Enum.to_list()

    for key <- ~w(id if_rev if_absent),
        [value] <- [LazyHTML.attribute(el, "phx-value-#{key}")],
        into: %{},
        do: {key, value}
  end

  defp press(view, params), do: EditorPost.press(view, "restore-revision", params)

  defp assert_restored(view, c) do
    refute flash(view)["error"], "the first press after a write the page showed was refused"
    assert flash(view)["info"] =~ "Restored from history"
    assert body_text(current(c)) == "Body one"
  end

  test "the person's own edit, then Restore: restored on the first press", c do
    view = open(c)
    request_id = Ecto.UUID.generate()

    render_hook(
      view,
      "paper-op",
      Map.merge(patch_body("Body mine"), %{
        "request_id" => request_id,
        "if_rev" => socket_assigns(view).paper_rev
      })
    )

    assert_reply(view, %{saved: true, request_id: ^request_id})
    assert body_text(stored(c)) == "Body mine", "fixture: the own edit was written"

    press(view, dialog_values(view, c))
    assert_restored(view, c)
  end

  test "someone else's block edit the page painted, then Restore: restores", c do
    view = open(c)
    rev = socket_assigns(view).paper_rev
    op = patch_body("Body three")
    {:ok, _} = Content.apply_paper_block_op(c.slug, op, @dataset, if_rev: rev)
    render(view)

    assert socket_assigns(view).paper_rev == stored(c).content["rev"],
           "fixture: the page took the edit's frame"

    press(view, dialog_values(view, c))
    assert_restored(view, c)
  end

  test "someone else's whole-paper save the page painted, then Restore: restores", c do
    view = open(c)
    write(c.slug, "Body three")
    render(view)

    assert socket_assigns(view).paper_rev == stored(c).content["rev"],
           "fixture: the page took the save's frame"

    press(view, dialog_values(view, c))
    assert_restored(view, c)
  end

  test "pressed after someone else saved: refused, the newer words stay", c do
    view = open(c)
    pressed = dialog_values(view, c)
    assert pressed["if_rev"] == current(c).rev

    after_write = write(c.slug, "Body three")
    press(view, pressed)

    assert flash(view)["error"] =~ @moved
    assert current(c).rev == after_write.rev, "the late restore wrote over the newer words"
    assert body_text(current(c)) == "Body three"
  end
end
