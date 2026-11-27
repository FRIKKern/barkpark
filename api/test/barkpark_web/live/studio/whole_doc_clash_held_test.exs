defmodule BarkparkWeb.Studio.WholeDocClashHeldTest do
  @moduledoc """
  task-f3e8c7b97e1239e3 (#29050 review N3): a remote save over a dirty form
  that names no unsaved field (`Lifecycle.keep_unsaved_fields/2`'s `:all`)
  keeps the whole buffer and raises the banner, with `editor_clash_fields`
  empty. `HeldFields.stored/3` saw no held field, so a write of the whole
  form (an array op, a tag, a pick, a slug) could carry A's buffer over B's
  save.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias BarkparkWeb.HeldWrites
  alias BarkparkWeb.ObjectRichText

  @moduletag :studio_live

  @dataset "production"
  @banner ~s([data-test-id="doc-conflict-banner"])

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "clash_all_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Clash all",
          "visibility" => "public",
          "fields" =>
            [
              %{"name" => "title", "title" => "Title", "type" => "string"},
              %{"name" => "notes", "title" => "Notes", "type" => "string"}
            ] ++ HeldWrites.fields()
        },
        @dataset
      )

    id = "clash-all-#{n}"

    {:ok, _} =
      Content.create_document(
        type,
        %{
          "doc_id" => id,
          "title" => "T0",
          "content" => Map.merge(%{"notes" => "n0"}, HeldWrites.content())
        },
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "clash-all-" <> Ecto.UUID.generate()

    {:ok, _} =
      Auth.create_token(
        raw,
        "clash-all",
        @dataset,
        ~w(read write admin),
        Tenancy.get_default_workspace().id
      )

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
    assert ObjectRichText.eventually(fn -> has_element?(view, "#editor-form") end)
    view
  end

  defp notes(c) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.id, @dataset)
    doc.content["notes"]
  end

  defp clash_fields(view), do: :sys.get_state(view.pid).socket.assigns[:editor_clash_fields]

  # A's buffer holds "A notes", unsaved, naming `keys` (none: the `:all`
  # state, which no writer reaches today; the rule holds if one does).
  defp dirty(view, keys) do
    :sys.replace_state(view.pid, fn state ->
      update_in(state.socket.assigns, fn assigns ->
        assigns
        |> Map.put(:editor_dirty, true)
        |> Map.put(:editor_unsaved_keys, MapSet.new(keys))
        |> Map.update!(:editor_form, &Map.put(&1, "notes", "A notes"))
      end)
    end)
  end

  defp b_saves_notes(c, surface) do
    b = open(c, surface)

    b
    |> element("#editor-form")
    |> render_change(%{
      "doc" => %{"title" => "T0", "notes" => "B notes"},
      "_target" => ["doc", "notes"]
    })

    assert ObjectRichText.eventually(fn -> notes(c) == "B notes" end)
  end

  for surface <- [:desk, :studio] do
    test "#{surface} a whole-doc clash names the fields A's buffer holds apart from the save",
         c do
      a = open(c, unquote(surface))
      dirty(a, [])
      b_saves_notes(c, unquote(surface))
      assert ObjectRichText.eventually(fn -> has_element?(a, @banner) end)
      assert "notes" in clash_fields(a)
      refute "items" in clash_fields(a)
      refute "tags" in clash_fields(a)
    end

    test "#{surface} control: a dirty buffer naming its field clashes on that field, as before",
         c do
      a = open(c, unquote(surface))
      dirty(a, ["notes"])
      b_saves_notes(c, unquote(surface))
      assert ObjectRichText.eventually(fn -> has_element?(a, @banner) end)
      assert clash_fields(a) == ["notes"]
      HeldWrites.run(a, c, :array_op)
      HeldWrites.landed(c, :array_op)
      assert notes(c) == "B notes"
      assert has_element?(a, @banner)
    end
  end

  for surface <- [:desk, :studio], path <- HeldWrites.paths() do
    test "#{surface} #{path} after a whole-doc clash: B's notes stay stored", c do
      a = open(c, unquote(surface))
      dirty(a, [])
      b = open(c, unquote(surface))

      b
      |> element("#editor-form")
      |> render_change(%{
        "doc" => %{"title" => "T0", "notes" => "B notes"},
        "_target" => ["doc", "notes"]
      })

      assert ObjectRichText.eventually(fn -> notes(c) == "B notes" end)
      assert ObjectRichText.eventually(fn -> has_element?(a, @banner) end)

      HeldWrites.run(a, c, unquote(path))
      HeldWrites.landed(c, unquote(path))
      assert notes(c) == "B notes", "the whole-form write carried A's buffer over B's save"
      assert has_element?(a, @banner)
    end
  end
end
