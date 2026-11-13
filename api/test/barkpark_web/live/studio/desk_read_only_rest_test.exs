defmodule BarkparkWeb.Studio.DeskReadOnlyRestTest do
  @moduledoc """
  The read-only document pane's last differences from TanStack's form:

  - a footer bar with the edit pane's words, "Edited 5m ago" or "Last
    published 2h ago", and no Publish;
  - each reference is TanStack's card (`.ref-box`): the type's tile, the
    title, the type under it;
  - an empty value is an empty box, as TanStack's disabled input, not a dash.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"
  @pane ~s([data-pane-index="2"])
  @css BarkparkWeb.Studio.Desk.Style.sheet(%{}) |> rendered_to_string()

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "rr_#{n}"
    target = "rr_t_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => target,
          "title" => "Writer #{n}",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Name", "type" => "string"}]
        },
        @dataset
      )

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Story #{n}",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "excerpt", "title" => "Excerpt", "type" => "text"},
            %{"name" => "author", "title" => "Author", "type" => "reference", "to" => [target]},
            %{"name" => "editor", "title" => "Editor", "type" => "reference", "to" => [target]}
          ]
        },
        @dataset
      )

    author = "rr-a-#{n}"
    {:ok, _} = Content.create_document(target, %{"doc_id" => author, "title" => "Ada"}, @dataset)

    id = "rr-#{n}"

    # No excerpt and no editor: two empty values.
    {:ok, _} =
      Content.create_document(
        type,
        %{
          "doc_id" => id,
          "title" => "First story",
          "content" => %{"author" => %{"_ref" => author, "_type" => "reference"}}
        },
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"
    raw = "desk-rr-" <> Ecto.UUID.generate()

    {:ok, _} =
      Auth.create_token(
        raw,
        "desk-rr",
        @dataset,
        ~w(read write admin),
        Tenancy.get_default_workspace().id
      )

    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})

    # The story, then its author opened beside it: the story is read-only.
    path = "#{base}/#{type};#{id};#{author},type=#{target},parentRefPath=author"
    {:ok, conn: conn, path: path, n: n}
  end

  defp open(c) do
    {:ok, view, _html} = live(c.conn, c.path)
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "#{@pane} dl.dk-fields") end)
    view
  end

  defp eventually(fun), do: Enum.any?(1..200, fn _ -> fun.() or (Process.sleep(10) && false) end)

  # The declaration block of the rule whose selector list is exactly `selector`.
  defp rule(selector) do
    case Regex.run(~r/(?:^|[}\s])#{Regex.escape(selector)}\s*\{([^}]*)\}/, @css) do
      [_, body] -> body
      nil -> flunk("no rule for #{selector}")
    end
  end

  test "the read-only pane ends in a footer with the edit pane's words and no Publish", c do
    view = open(c)

    refute has_element?(view, "#{@pane}[data-pane-editing]")

    footer =
      view |> element("#{@pane} > .dk-edit-footer.dk-ro-footer[data-desk-ro-footer]") |> render()

    assert footer =~
             ~r/data-desk-footer-status[^>]*>\s*(Edited|Last published) (just now|\S+ ago)\s*</

    refute footer =~ "data-desk-publish"
    refute footer =~ "<button"
  end

  test "a reference is TanStack's card: the type's tile, the title, the type", c do
    view = open(c)
    card = "#{@pane} dd.dk-refs > a.dk-ref.ref-box.ref-row[data-desk-ref][aria-current=true]"

    assert has_element?(view, "#{card} > .preview > .dk-media[aria-hidden=true] svg")
    assert has_element?(view, "#{card} > .preview > .text > .t", "Ada")
    assert has_element?(view, "#{card} > .preview > .text > .s", "Writer #{c.n}")

    assert rule(".dk .dk-fields .dk-refs > .ref-box") =~ "display: flex"
    assert rule(".dk .dk-fields .ref-box > .preview") =~ "min-height: 49px"
  end

  test "an empty value is an empty box, not a dash", c do
    view = open(c)
    html = view |> element("#{@pane} dl.dk-fields") |> render()

    assert html =~ ~r{<dt>Excerpt</dt>\s*<dd>\s*</dd>}

    assert html =~
             ~r{<dt>Editor</dt>\s*<dd class="dk-refs">\s*<span class="dk-ref-none">\s*</span>}

    refute html =~ "—"
  end
end
