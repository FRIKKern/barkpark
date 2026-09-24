defmodule BarkparkWeb.Studio.StudioLivePaperMastersTest do
  @moduledoc """
  Paper masters, editor half (task-3b6e562e916c8ce4), driven end to end through
  the mounted Studio paper editor:

    * SAVE — the boundary toolbar's `paper-save-master` button on a section
      stores it as a `paper_master` document, and the slash picker's carrier
      (`[data-paper-masters]`) lists it on the next render;
    * INSERT — `paper-insert-master` (what the canvas hook pushes when the
      author picks a master in the slash menu) inserts a DETACHED copy through
      the request-identified op path: fresh ids, provenance, internal links
      rewritten, and a retry with the same request id replays instead of
      inserting twice;
    * SCOPE — a master from another workspace is neither listed nor
      insertable.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content
  alias Barkpark.Plugins.Bulldocs.Masters

  @dataset "production"

  @section %{
    "id" => "pm-sec",
    "type" => "section",
    "title" => "Pricing block",
    "blocks" => [
      %{"id" => "pm-sec-h", "type" => "heading", "level" => 2, "text" => "Pricing"},
      %{
        "id" => "pm-sec-p",
        "type" => "paragraph",
        "content" => [
          %{
            "type" => "text",
            "value" => "back to pricing",
            "marks" => [%{"type" => "link", "attrs" => %{"href" => "#pm-sec-h"}}]
          }
        ]
      }
    ]
  }

  setup do
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

    slug = "paper-masters-ui-#{System.unique_integer([:positive])}"

    blocks = [
      %{"id" => "pm-h", "type" => "heading", "level" => 1, "text" => "Masters paper"},
      %{
        "id" => "pm-p",
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => "Intro."}]
      },
      @section
    ]

    {:ok, paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{slug: slug, dataset: @dataset, blocks: blocks})
      )

    %{slug: slug, paper: paper}
  end

  defp open(conn, slug) do
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{slug}"))
    view
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp carrier(html) do
    [_, json] = Regex.run(~r/data-paper-masters="([^"]*)"/, html)
    json |> String.replace("&quot;", "\"") |> Jason.decode!()
  end

  defp blocks(slug), do: Content.paper_blocks(slug, @dataset)

  test "save a section as a master, then insert it from the picker as a detached copy",
       %{conn: conn, slug: slug, paper: paper} do
    view = open(conn, slug)
    html = render(view)

    # The picker carrier renders (the pane may write) and is empty.
    assert carrier(html) == []

    # ── SAVE: the section's boundary toolbar button ──────────────────────────
    view
    |> element(~s([data-edit-block-id="pm-sec"] [data-test-id="paper-save-master"]))
    |> render_click()

    assert [master] = Masters.list_for_paper(paper)
    assert master.content["block_type"] == "section"
    assert master.content["source_block_id"] == "pm-sec"
    master_id = Masters.master_id(master)

    # The picker lists it at once, named by the section's own title.
    assert [
             %{
               "id" => ^master_id,
               "title" => "Pricing block",
               "tier" => "section",
               "block_type" => "section"
             }
           ] = carrier(render(view))

    # ── INSERT: what the canvas hook pushes on a slash-menu master pick ─────
    request_id = Ecto.UUID.generate()
    rev = assigns(view).paper_rev

    insert = %{
      "master_id" => master_id,
      "after_id" => "pm-p",
      "request_id" => request_id,
      "if_rev" => rev
    }

    render_hook(view, "paper-insert-master", insert)
    assert_reply(view, %{saved: true, replayed: false, request_id: ^request_id})

    assert ["pm-h", "pm-p", copy_id, "pm-sec"] = Enum.map(blocks(slug), & &1["id"])
    copy = Enum.at(blocks(slug), 2)
    assert "mst-" <> _ = copy_id
    assert copy["type"] == "section"
    assert copy["master"] == %{"id" => master_id, "rev" => master.rev, "mode" => "detached"}

    # Detached: fresh ids throughout, and the internal link follows the copy.
    [heading, para] = copy["blocks"]
    refute heading["id"] == "pm-sec-h"
    refute para["id"] == "pm-sec-p"
    [text] = para["content"]
    assert hd(text["marks"])["attrs"]["href"] == "#" <> heading["id"]

    # The source section is untouched.
    assert Enum.at(blocks(slug), 3) == @section

    # ── RETRY: the same request id replays, never a second copy ─────────────
    render_hook(view, "paper-insert-master", insert)
    assert_reply(view, %{saved: true, replayed: true, request_id: ^request_id})
    assert length(blocks(slug)) == 4
  end

  test "a master from another workspace is neither listed nor insertable",
       %{conn: conn, slug: slug, paper: paper} do
    other_ws = Barkpark.TenancyFixtures.create_workspace!()
    other_project = Barkpark.TenancyFixtures.create_project!(other_ws)
    foreign_slug = "paper-masters-foreign-#{System.unique_integer([:positive])}"

    {:ok, _foreign_paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: foreign_slug,
          dataset: @dataset,
          blocks: [@section]
        })
        |> Map.merge(%{"workspace_id" => other_ws.id, "project_id" => other_project.id})
      )

    {:ok, foreign} =
      Masters.save_master(foreign_slug, "pm-sec", @dataset,
        workspace_id: other_ws.id,
        project_id: other_project.id
      )

    view = open(conn, slug)
    assert carrier(render(view)) == []

    request_id = Ecto.UUID.generate()

    render_hook(view, "paper-insert-master", %{
      "master_id" => Masters.master_id(foreign),
      "after_id" => "pm-p",
      "request_id" => request_id,
      "if_rev" => assigns(view).paper_rev
    })

    assert_reply(view, %{saved: false, rejected: "master_not_found", request_id: ^request_id})
    assert Enum.map(blocks(slug), & &1["id"]) == ["pm-h", "pm-p", "pm-sec"]
    assert Masters.list_for_paper(paper) == []
  end
end
