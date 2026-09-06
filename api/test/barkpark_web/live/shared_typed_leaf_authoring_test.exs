defmodule BarkparkWeb.SharedTypedLeafAuthoringTest do
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures
  import Phoenix.LiveViewTest

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
    ws = create_workspace!("typed-leaf-#{suffix}")
    project = create_project!(ws)
    slug = "typed-leaf-#{suffix}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "paper",
          "title" => "Papers",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset,
        workspace_id: ws.id,
        project_id: project.id
      )

    {:ok, _} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          "slug" => slug,
          "workspace_id" => ws.id,
          "project_id" => project.id,
          "blocks" => fixture_blocks()
        })
      )

    raw = "typed-leaf-writer-#{suffix}"

    {:ok, _token} =
      Auth.create_token(raw, "typed leaf writer", @dataset, ["read", "write"], ws.id)

    %{
      conn: Plug.Test.init_test_session(conn, %{"api_token" => raw}),
      raw: raw,
      ws: ws,
      project: project,
      slug: slug
    }
  end

  test "public and Studio shared forms persist typed values without losing block metadata", ctx do
    public_path = "/w/#{ctx.ws.slug}/p/#{ctx.project.slug}/papers/#{ctx.slug}"
    {:ok, public, _html} = live(ctx.conn, public_path)
    render_click(public, "paper-toggle-edit", %{})

    assert has_element?(public, "#field-number-form-number")
    assert has_element?(public, ~s(#field-number-form-number[phx-update="ignore"]))
    assert has_element?(public, ~s(#field-number-form-number[phx-change="paper-edit-block"]))
    assert has_element?(public, "#blockquote-form-quote")
    assert has_element?(public, "#equation-form-equation")
    assert has_element?(public, "#video-form-video")

    save_form(public, "number", %{
      "label" => "Mass",
      "value" => "4.5",
      "min" => "1",
      "max" => "9",
      "step" => "0.5",
      "unit" => "kg"
    })

    save_form(public, "quote", %{"cite" => "Updated author"})
    save_form(public, "equation", %{"tex" => "x^3", "display" => "true"})

    save_form(public, "video", %{
      "src" => "/media/updated.mp4",
      "poster" => "",
      "loop" => "true",
      "caption-count" => "1",
      "caption-0-lang" => "en-US",
      "caption-0-src" => "/captions/updated.vtt"
    })

    blocks = stored_blocks(ctx)

    assert %{
             "value" => 4.5,
             "min" => 1,
             "max" => 9,
             "step" => 0.5,
             "unit" => "kg",
             "unknown" => "number-meta"
           } = by_id(blocks, "number")

    assert %{"cite" => "Updated author", "content" => quote_content, "unknown" => "quote-meta"} =
             by_id(blocks, "quote")

    assert [%{"type" => "strong"}] = quote_content

    assert %{"tex" => "x^3", "display" => true, "unknown" => "equation-meta"} =
             by_id(blocks, "equation")

    assert %{
             "src" => "/media/updated.mp4",
             "poster" => "",
             "loop" => true,
             "captions" => [
               %{"lang" => "en-US", "src" => "/captions/updated.vtt", "unknown" => "caption-meta"}
             ],
             "unknown" => "video-meta"
           } = by_id(blocks, "video")

    studio_path =
      "/w/#{ctx.ws.slug}/p/#{ctx.project.slug}/d/#{@dataset}/studio/paper/#{ctx.slug}"

    studio_conn = Plug.Test.init_test_session(recycle(ctx.conn), %{"api_token" => ctx.raw})
    {:ok, studio, _html} = live(studio_conn, studio_path)

    studio_html =
      if has_element?(studio, ~s([data-test-id="paper-edit-toggle"])) do
        studio |> element(~s([data-test-id="paper-edit-toggle"])) |> render_click()
      else
        render(studio)
      end

    assert studio_html =~ ~s(id="field-number-form-number")
    assert studio_html =~ ~s(value="4.5")
    assert studio_html =~ ~s(value="Updated author")

    save_form(studio, "equation", %{"tex" => "x^4"})
    assert by_id(stored_blocks(ctx), "equation")["tex"] == "x^4"

    remount_conn = Plug.Test.init_test_session(recycle(ctx.conn), %{"api_token" => ctx.raw})
    {:ok, reloaded, _html} = live(remount_conn, public_path)
    render_click(reloaded, "paper-toggle-edit", %{})
    assert socket_of(reloaded).assigns.edit_blocks == stored_blocks(ctx)
  end

  test "public and Studio reject malformed numeric edits without advancing revision", ctx do
    public_path = "/w/#{ctx.ws.slug}/p/#{ctx.project.slug}/papers/#{ctx.slug}"
    {:ok, public, _html} = live(ctx.conn, public_path)
    render_click(public, "paper-toggle-edit", %{})

    before = stored_paper(ctx)
    request_id = Ecto.UUID.generate()

    render_hook(public, "paper-edit-block", %{
      "block_id" => "number",
      "value" => "not-a-number",
      "if_rev" => socket_of(public).assigns.paper_rev,
      "request_id" => request_id
    })

    assert_reply(public, %{saved: false, request_id: ^request_id})
    assert stored_paper(ctx).rev == before.rev
    assert by_id(stored_blocks(ctx), "number")["value"] == 3

    studio_path =
      "/w/#{ctx.ws.slug}/p/#{ctx.project.slug}/d/#{@dataset}/studio/paper/#{ctx.slug}"

    {:ok, studio, _html} = live(ctx.conn, studio_path)

    if has_element?(studio, ~s([data-test-id="paper-edit-toggle"])) do
      studio |> element(~s([data-test-id="paper-edit-toggle"])) |> render_click()
    end

    before_studio = stored_paper(ctx)
    studio_request_id = Ecto.UUID.generate()

    render_hook(studio, "paper-edit-block", %{
      "block_id" => "number",
      "min" => "20",
      "max" => "2",
      "if_rev" => socket_of(studio).assigns.paper_rev,
      "request_id" => studio_request_id
    })

    assert_reply(studio, %{saved: false, request_id: ^studio_request_id})
    assert render(studio) =~ "Save failed"
    assert stored_paper(ctx).rev == before_studio.rev
    assert by_id(stored_blocks(ctx), "number")["value"] == 3
  end

  test "a schema number field synthesizes, edits, projects, and remounts through Beta" do
    type = "typed_metric_#{System.unique_integer([:positive])}"
    doc_id = "metric-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Metric",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "quantity", "title" => "Quantity", "type" => "number"}
          ],
          "layout" => [
            %{"kind" => "field", "name" => "title"},
            %{"kind" => "field", "name" => "quantity"}
          ]
        },
        @dataset
      )

    {:ok, doc} =
      Content.create_document(
        type,
        %{"doc_id" => doc_id, "title" => "Measured", "quantity" => 7},
        @dataset
      )

    path = scoped_studio("/d/#{@dataset}/studio/#{type}/#{doc.doc_id}")

    {:ok, view, html} = live(build_conn(), path)
    assert html =~ ~s(name="doc[quantity]")

    beta_html = view |> element(~s([data-test-id="editor-mode-beta"])) |> render_click()
    assert beta_html =~ ~s(data-test-id="paper-field-number-editor")

    {:ok, before} = Content.get_document(doc.doc_id, type, @dataset)
    number = Enum.find(before.content["blocks"], &(&1["fieldName"] == "quantity"))
    assert number["type"] == "field-number"

    save_form(view, number["id"], %{"label" => "Quantity", "value" => "8.5"})

    {:ok, saved} = Content.get_document(doc.doc_id, type, @dataset)
    assert saved.content["quantity"] == 8.5

    saved_number = Enum.find(saved.content["blocks"], &(&1["fieldName"] == "quantity"))
    assert saved_number["value"] == 8.5

    {:ok, remounted, classic_html} = live(build_conn(), path)
    assert classic_html =~ ~s(name="doc[quantity]")
    assert classic_html =~ ~s(value="8.5")

    remounted |> element(~s([data-test-id="editor-mode-beta"])) |> render_click()
    assert has_element?(remounted, "#field-number-value-#{number["id"]}[value=\"8.5\"]")
  end

  test "technical forms persist through both hosts and reject stale collection counts", ctx do
    path = "/w/#{ctx.ws.slug}/p/#{ctx.project.slug}/papers/#{ctx.slug}"
    {:ok, public, _} = live(ctx.conn, path)
    render_click(public, "paper-toggle-edit", %{})

    for id <- ~w(diff filetree footnote code-tabs) do
      assert has_element?(public, "#technical-block-form-#{id}")
    end

    save_form(public, "diff", %{"diff" => "-old\n+new\n", "file" => "a.ex", "lang" => "elixir"})

    save_form(public, "filetree", %{"text" => "src/\n└── a.ex ● changed", "legend" => "● changed"})

    save_form(public, "footnote", %{"note-count" => "1", "note-0-text" => "Edited note"})

    save_form(public, "code-tabs", %{
      "tab-count" => "1",
      "tab-0-value" => "new code",
      "syncKey" => "examples"
    })

    assert by_id(stored_blocks(ctx), "diff")["diff"] == "-old\n+new\n"
    assert by_id(stored_blocks(ctx), "filetree")["text"] == "src/\n└── a.ex ● changed"

    assert [%{"id" => "fn1", "text" => "Edited note", "unknown" => "note-meta"}] =
             by_id(stored_blocks(ctx), "footnote")["notes"]

    assert [%{"code" => "new code", "unknown" => "tab-meta"}] =
             by_id(stored_blocks(ctx), "code-tabs")["tabs"]

    conn = Plug.Test.init_test_session(recycle(ctx.conn), %{"api_token" => ctx.raw})

    {:ok, studio, _} =
      live(conn, "/w/#{ctx.ws.slug}/p/#{ctx.project.slug}/d/production/studio/paper/#{ctx.slug}")

    if has_element?(studio, ~s([data-test-id="paper-edit-toggle"])),
      do: studio |> element(~s([data-test-id="paper-edit-toggle"])) |> render_click()

    save_form(studio, "code-tabs", %{"tab-count" => "1", "tab-action" => "add"})
    assert length(by_id(stored_blocks(ctx), "code-tabs")["tabs"]) == 2

    for view <- [public, studio] do
      before = stored_paper(ctx)
      request = Ecto.UUID.generate()

      render_hook(view, "paper-edit-block", %{
        "block_id" => "code-tabs",
        "tab-count" => "0",
        "request_id" => request,
        "if_rev" => mutation_rev(view)
      })

      assert_reply(view, %{saved: false, request_id: ^request})
      assert stored_paper(ctx).rev == before.rev
      assert stored_paper(ctx).content == before.content
    end

    conn = Plug.Test.init_test_session(recycle(ctx.conn), %{"api_token" => ctx.raw})
    {:ok, reloaded, _} = live(conn, path)
    render_click(reloaded, "paper-toggle-edit", %{})
    assert socket_of(reloaded).assigns.edit_blocks == stored_blocks(ctx)
  end

  defp save_form(view, block_id, params) do
    request_id = Ecto.UUID.generate()

    render_hook(
      view,
      "paper-edit-block",
      Map.merge(params, %{
        "block_id" => block_id,
        "if_rev" => mutation_rev(view),
        "request_id" => request_id
      })
    )

    assert_reply(view, %{saved: true, request_id: ^request_id})
  end

  defp stored_blocks(ctx) do
    ctx |> stored_paper() |> get_in([Access.key!(:content), "blocks"])
  end

  defp stored_paper(ctx),
    do:
      Content.get_paper(ctx.slug, @dataset,
        workspace_id: ctx.ws.id,
        project_id: ctx.project.id
      )

  defp by_id(blocks, id), do: Enum.find(blocks, &(&1["id"] == id))
  defp socket_of(view), do: :sys.get_state(view.pid).socket

  defp mutation_rev(view) do
    assigns = socket_of(view).assigns
    if assigns[:paper_doc], do: assigns.paper_rev, else: assigns.editor_doc.rev
  end

  defp fixture_blocks do
    [
      %{"id" => "diff", "type" => "diff", "diff" => "old", "unknown" => "diff-meta"},
      %{"id" => "filetree", "type" => "filetree", "text" => "src/", "unknown" => "tree-meta"},
      %{
        "id" => "footnote",
        "type" => "footnote",
        "notes" => [
          %{"id" => "fn1", "text" => "Original", "unknown" => "note-meta"}
        ]
      },
      %{
        "id" => "code-tabs",
        "type" => "code-tabs",
        "tabs" => [
          %{
            "label" => "Legacy",
            "language" => "text",
            "code" => "old code",
            "unknown" => "tab-meta"
          }
        ]
      },
      %{
        "id" => "number",
        "type" => "field-number",
        "label" => "Weight",
        "value" => 3,
        "unit" => "lb",
        "unknown" => "number-meta"
      },
      %{
        "id" => "quote",
        "type" => "blockquote",
        "content" => [
          %{
            "type" => "strong",
            "children" => [%{"type" => "text", "value" => "Marked quote"}]
          }
        ],
        "cite" => "Original author",
        "unknown" => "quote-meta"
      },
      %{
        "id" => "equation",
        "type" => "equation",
        "tex" => "x^2",
        "display" => false,
        "unknown" => "equation-meta"
      },
      %{
        "id" => "video",
        "type" => "video",
        "src" => "/media/original.mp4",
        "poster" => "/media/poster.jpg",
        "captions" => [
          %{"lang" => "en", "src" => "/captions/original.vtt", "unknown" => "caption-meta"}
        ],
        "unknown" => "video-meta"
      }
    ]
  end
end
