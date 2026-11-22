defmodule BarkparkWeb.Studio.UntypedArrayOfTest do
  @moduledoc """
  task-04004b6d634dd535: an `arrayOf` whose `of` names no `type`
  (`of: {"name": "w"}`) crashed the editor on open, with a
  FunctionClauseError in `Plugins.Adapter.to_field_struct/1`. TanStack's
  `Fields.tsx` draws such an array read-only, one chip per item. The editor
  now opens, the field draws its items read-only, and a save of another
  field leaves it as stored.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "untyped_of_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Untyped of",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "notes", "title" => "Notes", "type" => "string"},
            %{
              "name" => "words",
              "title" => "Words",
              "type" => "arrayOf",
              "of" => %{"name" => "w"}
            },
            %{
              "name" => "tagged",
              "title" => "Tagged",
              "type" => "arrayOf",
              "of" => %{"name" => "w"},
              "options" => %{"layout" => "tags"}
            }
          ]
        },
        @dataset
      )

    id = "untyped-of-#{n}"

    {:ok, _} =
      Content.create_document(
        type,
        %{
          "doc_id" => id,
          "title" => "Untyped",
          "content" => %{
            "notes" => "n",
            "words" => ["alpha", "beta"],
            "tagged" => ["gamma", %{"k" => 1}]
          }
        },
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "untyped-of-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "untyped-of", @dataset, ~w(read write admin), ws_id)
    root = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"

    {:ok,
     conn: Plug.Test.init_test_session(conn, %{"api_token" => raw}),
     type: type,
     id: id,
     paths: %{desk: "#{root}/_desk/#{type};#{id}", studio: "#{root}/#{type}/#{id}"}}
  end

  defp open(c, surface) do
    {:ok, view, _html} = live(c.conn, c.paths[surface])
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "#editor-form") end)
    view
  end

  defp eventually(fun), do: Enum.any?(1..200, fn _ -> fun.() or (Process.sleep(10) && false) end)

  defp stored(c) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.id, @dataset)
    doc.content
  end

  defp field(name), do: ~s(#editor-form [data-field-name="#{name}"])

  for surface <- [:desk, :studio] do
    @surface surface

    test "#{surface}: the editor opens and draws the items read-only", c do
      view = open(c, @surface)

      for {name, items} <- [{"words", ~w(alpha beta)}, {"tagged", ["gamma"]}] do
        html = render(element(view, field(name)))
        for item <- items, do: assert(html =~ item)
        refute has_element?(view, field(name) <> " input:not([type=hidden])")
        refute has_element?(view, field(name) <> " button")
      end
    end

    test "#{surface}: a save of another field keeps the array as stored", c do
      view = open(c, @surface)

      view
      |> element("#editor-form")
      |> render_change(%{"_target" => ["doc", "notes"], "doc" => %{"notes" => "n2"}})

      assert eventually(fn -> stored(c)["notes"] == "n2" end)
      assert stored(c)["words"] == ["alpha", "beta"]
      assert stored(c)["tagged"] == ["gamma", %{"k" => 1}]
    end
  end
end
