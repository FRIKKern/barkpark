defmodule BarkparkWeb.BulldocsLiveAutocompleteTest do
  @moduledoc """
  Positive public-reader coverage for the inline wikilink and tag autocomplete
  contract. The mounted, authorized reader performs the real search events,
  then saves the exact PortableDoc nodes produced by choosing those results and
  proves the marks survive a fresh mount. A foreign workspace supplies negative
  controls so a green result cannot hide a tenant-wide discovery leak.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.{Auth, Content}
  @dataset "production"

  setup %{conn: conn} do
    previous_canvas = System.get_env("BARKPARK_PAPER_CANVAS")
    System.put_env("BARKPARK_PAPER_CANVAS", "1")

    on_exit(fn ->
      if previous_canvas,
        do: System.put_env("BARKPARK_PAPER_CANVAS", previous_canvas),
        else: System.delete_env("BARKPARK_PAPER_CANVAS")
    end)

    suffix = System.unique_integer([:positive])
    ws = create_workspace!("reader-autocomplete-#{suffix}")
    project = create_project!(ws)
    foreign_ws = create_workspace!("reader-autocomplete-foreign-#{suffix}")
    foreign_project = create_project!(foreign_ws)

    editor_slug = "reader-autocomplete-editor-#{suffix}"
    candidate_slug = "reader-autocomplete-candidate-#{suffix}"
    candidate_title = "Reader Autocomplete Candidate #{suffix}"
    candidate_tag = "reader-autocomplete-tag-#{suffix}"
    foreign_slug = "reader-autocomplete-foreign-paper-#{suffix}"
    foreign_title = "Reader Autocomplete Foreign #{suffix}"
    foreign_tag = "reader-autocomplete-foreign-tag-#{suffix}"

    seed_paper!(ws, project, editor_slug, "Reader autocomplete editor #{suffix}", nil)
    seed_paper!(ws, project, candidate_slug, candidate_title, candidate_tag)
    seed_paper!(foreign_ws, foreign_project, foreign_slug, foreign_title, foreign_tag)

    raw = "reader-autocomplete-writer-#{suffix}"

    {:ok, _token} =
      Auth.create_token(raw, "reader autocomplete writer", @dataset, ["read", "write"], ws.id)

    %{
      conn: Plug.Test.init_test_session(conn, %{"api_token" => raw}),
      raw: raw,
      ws: ws,
      project: project,
      editor_slug: editor_slug,
      candidate_slug: candidate_slug,
      candidate_title: candidate_title,
      candidate_tag: candidate_tag,
      foreign_slug: foreign_slug,
      foreign_title: foreign_title,
      foreign_tag: foreign_tag
    }
  end

  test "authorized searches choose scoped wikilink and tag marks that persist after reload",
       ctx do
    path = paper_path(ctx.ws, ctx.project, ctx.editor_slug)
    candidate_slug = ctx.candidate_slug
    candidate_title = ctx.candidate_title
    {:ok, view, _html} = live(ctx.conn, path)
    render_click(view, "paper-toggle-edit", %{})

    render_hook(view, "paper-wikilink-search", %{"query" => "Reader Autocomplete"})
    assert_reply(view, %{results: wikilinks})

    picked_wikilink =
      Enum.find(wikilinks, &(&1.id == candidate_slug and &1.title == candidate_title))

    assert %{id: ^candidate_slug, title: ^candidate_title, type: "paper"} = picked_wikilink
    refute Enum.any?(wikilinks, &(&1.id == ctx.foreign_slug or &1.title == ctx.foreign_title))

    render_hook(view, "paper-tag-search", %{"query" => "reader-autocomplete-tag"})
    assert_reply(view, %{results: tags})

    picked_tag = Enum.find(tags, &(&1 == ctx.candidate_tag))
    assert picked_tag == ctx.candidate_tag
    refute ctx.foreign_tag in tags

    selected_content = [
      %{"type" => "text", "value" => "Selected "},
      %{
        "type" => "wikilink",
        "target" => picked_wikilink.title,
        "docId" => picked_wikilink.id,
        "children" => [%{"type" => "text", "value" => picked_wikilink.title}]
      },
      %{"type" => "text", "value" => " "},
      %{"type" => "tag", "name" => picked_tag},
      %{"type" => "text", "value" => " "}
    ]

    render_hook(view, "paper-ops", %{
      "request_id" => Ecto.UUID.generate(),
      "if_rev" => socket_of(view).assigns.paper_rev,
      "ops" => [
        %{
          "op" => "patch-block",
          "id" => "body",
          "patch" => %{"content" => selected_content}
        }
      ]
    })

    assert stored_body(ctx) == selected_content

    reloaded_conn = Plug.Test.init_test_session(recycle(ctx.conn), %{"api_token" => ctx.raw})
    {:ok, reloaded, _html} = live(reloaded_conn, path)
    render_click(reloaded, "paper-toggle-edit", %{})

    assert Enum.find(socket_of(reloaded).assigns.edit_blocks, &(&1["id"] == "body"))["content"] ==
             selected_content
  end

  defp seed_paper!(ws, project, slug, title, tag) do
    labels =
      case tag do
        nil -> %{}
        name -> Barkpark.LabelFixtures.with_named_labels(%{}, @dataset, [name, "#{name}-support"])
      end

    attrs =
      Map.merge(
        %{
          "slug" => slug,
          "title" => title,
          "workspace_id" => ws.id,
          "project_id" => project.id,
          "blocks" => [
            %{"id" => "heading", "type" => "heading", "level" => 1, "text" => title},
            %{
              "id" => "body",
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => "Original body"}]
            }
          ]
        },
        labels
      )

    assert {:ok, _paper} = Content.upsert_paper(Barkpark.LabelFixtures.paper_attrs(attrs))
  end

  defp stored_body(ctx) do
    ctx.editor_slug
    |> Content.get_paper(@dataset, workspace_id: ctx.ws.id, project_id: ctx.project.id)
    |> get_in([Access.key!(:content), "blocks"])
    |> Enum.find(&(&1["id"] == "body"))
    |> Map.fetch!("content")
  end

  defp paper_path(ws, project, slug), do: "/w/#{ws.slug}/p/#{project.slug}/papers/#{slug}"
  defp socket_of(view), do: :sys.get_state(view.pid).socket
end
