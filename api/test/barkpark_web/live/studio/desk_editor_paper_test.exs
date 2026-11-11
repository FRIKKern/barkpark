defmodule BarkparkWeb.Studio.DeskEditorPaperTest do
  @moduledoc """
  The paper canvas (Freeform track, D01..D22) as the last pane of a desk URL.

  Measured in a browser first (editing-w4 probe): the canvas mounts in the
  desk's editor pane, typing saves and survives a reload, the item Share
  dialog and the slash menu work; these tests pin the mount (D01), a saved
  canvas batch and another session's caret (D11). A wikilink's "Open" (D06)
  and starting a new paper from the desk (D04) are broken in the desk; their
  red tests stay on branch `editing/probe` for the rows that own them.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"

  setup %{conn: conn} do
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
          "name" => "paper",
          "title" => "Papers",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    n = System.unique_integer([:positive])
    src = "w4-desk-src-#{n}"
    target = "w4-desk-tgt-#{n}"

    para = fn id, kids -> %{"id" => id, "type" => "paragraph", "content" => kids} end
    text = fn v -> %{"type" => "text", "value" => v} end

    {:ok, _} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: target,
          dataset: @dataset,
          title: "Glacier almanac #{n}",
          blocks: [para.("t-1", [text.("Moraines and crevasses, measured yearly.")])]
        })
      )

    {:ok, _} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: src,
          dataset: @dataset,
          title: "Harbour crane journal #{n}",
          blocks: [
            para.("p-1", [text.("Hydraulic hoses checked on the gantry.")]),
            para.("p-2", [
              text.("See "),
              %{
                "type" => "wikilink",
                "target" => "Glacier almanac #{n}",
                "children" => [text.("the almanac")]
              }
            ])
          ]
        })
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"

    {:ok, conn: conn, base: base, src: src, target: target}
  end

  defp admin(conn, user \\ nil) do
    raw = "w4-desk-paper-" <> Ecto.UUID.generate()
    ws = Tenancy.get_default_workspace()

    {:ok, _} =
      Auth.create_token(raw, "w4-desk-paper", @dataset, ["read", "write", "admin"], ws.id)

    conn
    |> Plug.Test.init_test_session(%{"api_token" => raw})
    |> then(fn c ->
      if user, do: put_connect_params(c, %{"user_id" => user, "user_name" => user}), else: c
    end)
  end

  defp settle(view), do: render_async(view, 5_000)

  defp open_paper(ctx, conn \\ nil) do
    {:ok, view, _} = live(conn || admin(ctx.conn), "#{ctx.base}/paper;#{ctx.src}")
    settle(view)
    view
  end

  # The stored blocks, polled until `needle` is in them or the time is up.
  defp stored_text(slug, needle, tries \\ 25) do
    {doc, _, _} = Content.fetch_doc_with_draft("paper", slug, @dataset, [])
    text = doc |> Map.get(:content, %{}) |> Map.get("blocks", []) |> inspect()

    cond do
      text =~ needle -> text
      tries <= 0 -> text
      true -> Process.sleep(100) && stored_text(slug, needle, tries - 1)
    end
  end

  test "D01: the paper opens in the canvas as the desk's editor pane", ctx do
    view = open_paper(ctx)

    assert has_element?(view, ~s([data-pane-editing] [phx-hook="BarkparkPaperCanvas"]))
    assert has_element?(view, ~s([data-pane-editing] bp-paper-canvas))
    # The metadata sidebar (D12) comes with it.
    assert has_element?(view, ~s([data-pane-editing] aside[aria-label="Document metadata"]))
  end

  test "a canvas batch from the desk pane is saved", ctx do
    view = open_paper(ctx)
    [_, rev] = Regex.run(~r/data-paper-rev="([^"]+)"/, render(view))

    render_hook(view, "paper-ops", %{
      "request_id" => Ecto.UUID.generate(),
      "if_rev" => rev,
      "ops" => [
        %{
          "op" => "append-block",
          "block" => %{
            "id" => "w4-typed",
            "type" => "paragraph",
            "content" => [%{"type" => "text", "value" => "Typed in the desk pane"}]
          }
        }
      ]
    })

    assert stored_text(ctx.src, "Typed in the desk pane") =~ "Typed in the desk pane"
  end

  test "D11: another session's caret reaches the desk pane", ctx do
    alice = open_paper(ctx, admin(ctx.conn, "w4-caret-alice"))
    bob = open_paper(ctx, admin(build_conn(), "w4-caret-bob"))

    selection = %{
      "anchor" => %{"blockId" => "p-1", "offset" => 0},
      "head" => %{"blockId" => "p-1", "offset" => 4}
    }

    render_hook(alice, "paper-selection", %{"selection" => selection})
    _ = render(bob)
    assert_push_event(bob, "bp:remote-selections", %{list: [caret]}, 5_000)
    assert caret.anchor == selection["anchor"]
  end
end
