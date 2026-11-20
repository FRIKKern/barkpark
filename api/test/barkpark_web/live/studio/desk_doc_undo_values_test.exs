defmodule BarkparkWeb.Studio.DeskDocUndoValuesTest do
  @moduledoc """
  task-0b9061cb95e89484 (live-edit.spec.ts:149): on the desk, Mod+Z takes
  back this editor's change of a slug, a select, a list and an object's
  nested field, as the TanStack Studio's undo does (`DocUndoValues`,
  `ValueUndo`), and another editor's change stays: a select they set since
  stays theirs, a list keeps their item while ours comes back. The undone
  rows are the stored rows they were, byte for byte.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias BarkparkWeb.Studio.StudioLive.PostIdentity

  @dataset "production"

  defp card(key, label), do: %{"_key" => key, "_type" => "card", "label" => label}

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "undo_values_#{n}"
    doc_id = "undo-values-#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Undo values",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{
              "name" => "choice",
              "title" => "Choice",
              "type" => "select",
              "options" => [
                %{"value" => "a", "title" => "Alpha"},
                %{"value" => "b", "title" => "Beta"},
                %{"value" => "c", "title" => "Gamma"}
              ]
            },
            %{"name" => "handle", "title" => "Handle", "type" => "slug"},
            %{
              "name" => "size",
              "title" => "Size",
              "type" => "select",
              "options" => [
                %{"value" => "small", "title" => "Small"},
                %{"value" => "x-small", "title" => "X-small"},
                %{"value" => "large", "title" => "Large"},
                %{"value" => "x-large", "title" => "X-large"}
              ]
            },
            %{
              "name" => "tone",
              "title" => "Tone",
              "type" => "string",
              "options" => %{"list" => ["draft", "draft_2", "in_review", "in_review_2"]}
            },
            %{
              "name" => "tags",
              "title" => "Tags",
              "type" => "arrayOf",
              "of" => %{"type" => "string"}
            },
            %{"name" => "site", "title" => "Site", "type" => "url"},
            %{
              "name" => "cards",
              "title" => "Cards",
              "type" => "arrayOf",
              "of" => %{
                "type" => "composite",
                "name" => "card",
                "fields" => [%{"name" => "label", "title" => "Label", "type" => "string"}]
              }
            },
            %{
              "name" => "address",
              "title" => "Address",
              "type" => "composite",
              "fields" => [
                %{"name" => "street", "title" => "Street", "type" => "string"},
                %{"name" => "city", "title" => "City", "type" => "string"},
                %{"name" => "on", "title" => "On", "type" => "date"},
                %{"name" => "at", "title" => "At", "type" => "datetime"}
              ]
            }
          ]
        },
        @dataset
      )

    {:ok, _} =
      Content.create_document(
        type,
        %{
          "doc_id" => "drafts." <> doc_id,
          "title" => "Undo probe",
          "content" => %{
            "choice" => "b",
            "handle" => %{"_type" => "slug", "current" => "my-slug"},
            "cards" => [card("c1", "One"), card("c2", "Two")],
            "address" => %{
              "street" => "Main 1",
              "city" => "Oslo",
              "on" => "2026-11-20",
              "at" => "2026-11-20T10:00"
            },
            "size" => "large",
            "tone" => "draft",
            "tags" => ["one", "two", "three"]
          }
        },
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "doc-undo-values-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "doc-undo-values", @dataset, ~w(read write admin), ws_id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"

    {:ok, conn: conn, desk: "#{base}/_desk/#{type};#{doc_id}", type: type, doc_id: doc_id}
  end

  defp open(c) do
    {:ok, view, _html} = live(c.conn, c.desk)
    render_async(view, 5_000)
    render(view)
    view
  end

  defp mark(c), do: %{PostIdentity.key() => PostIdentity.value(@dataset, c.type, c.doc_id)}

  # A post of the form, `_target` naming the input, as the page's.
  defp post(view, c, target, doc) do
    view
    |> element("#editor-form")
    |> render_change(Map.merge(mark(c), %{"_target" => ["doc" | target], "doc" => doc}))
  end

  # A nested input's post: its dotted name is the params key and the target.
  defp post_nested(view, c, name, value) do
    view
    |> element("#editor-form")
    |> render_change(Map.merge(mark(c), %{"_target" => [name], name => value}))
  end

  defp remove(view, c, list, index) do
    render_click(
      view,
      "array_op",
      Map.merge(mark(c), %{"action" => "remove_row", "path" => list, "index" => to_string(index)})
    )
  end

  defp undo(view, c, redo \\ false) do
    render_hook(view, "desk-undo", Map.put(mark(c), "redo", redo))
    render(view)
  end

  # The stored content, read back from the store.
  defp stored(c) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.doc_id, @dataset)
    doc.content || %{}
  end

  # Another editor's save, straight to the store.
  defp theirs(c, changes) do
    {:ok, _} =
      Content.upsert_document(
        c.type,
        %{
          "doc_id" => "drafts." <> c.doc_id,
          "title" => "Undo probe",
          "content" => Map.merge(stored(c), changes)
        },
        @dataset
      )
  end

  defp pause, do: Process.sleep(650)

  test "the form names the slug, the select, the list and the object, not the url", c do
    view = open(c)

    keys =
      view
      |> element("#editor-form")
      |> render()
      |> then(&Regex.run(~r/data-desk-undo-keys="([^"]*)"/, &1))

    assert ["doc[title]", "doc[choice]", "doc[handle]", "doc[cards]", "doc[address]"] --
             String.split(Enum.at(keys, 1)) == []

    refute Enum.at(keys, 1) =~ "doc[site]"
  end

  test "a select: Mod+Z puts this editor's pick back, and the page is told its option", c do
    view = open(c)
    post(view, c, ["choice"], %{"choice" => "c"})
    assert stored(c)["choice"] == "c"

    undo(view, c)
    assert stored(c)["choice"] == "b"
    assert_push_event(view, "desk:undone", %{field: "doc[choice]", value: "b", was: "c"})

    undo(view, c, true)
    assert stored(c)["choice"] == "c"
  end

  test "a select another editor set since stays theirs, and the step is gone", c do
    view = open(c)
    post(view, c, ["choice"], %{"choice" => "c"})
    theirs(c, %{"choice" => "a"})

    undo(view, c)
    assert stored(c)["choice"] == "a"
    refute_push_event(view, "desk:undone", %{field: "doc[choice]"})
  end

  # task-61c8a3663106486b: the undo reads the field, then writes it. A save by
  # another editor that lands in between, put there by a handler on the read's
  # own query in the LiveView, stays theirs; the undo is refused.
  test "another editor's save between the undo's read and its write stays theirs", c do
    view = open(c)
    post(view, c, ["choice"], %{"choice" => "c"})
    render(view)

    id = "undo-fence-#{c.doc_id}"
    write = fn -> theirs(c, %{"choice" => "a"}) end

    :ok =
      :telemetry.attach(id, [:barkpark, :repo, :query], &__MODULE__.between/4, %{
        pid: view.pid,
        id: id,
        write: write
      })

    try do
      undo(view, c)
    after
      :telemetry.detach(id)
    end

    assert stored(c)["choice"] == "a"
    refute_push_event(view, "desk:undone", %{field: "doc[choice]"})
  end

  @doc false
  # The first query on documents in the LiveView once armed: the undo's read.
  def between(_event, _measurements, %{source: "documents"}, %{pid: pid, id: id, write: write})
      when pid == self() do
    if :telemetry.detach(id) == :ok, do: write.()
  end

  def between(_event, _measurements, _meta, _config), do: :ok

  test "a slug: this editor's typing comes back out byte for byte; another editor's words stay",
       c do
    view = open(c)
    before = Jason.encode!(stored(c)["handle"])
    post(view, c, ["handle"], %{"handle" => "my-slug-x"})
    assert stored(c)["handle"]["current"] == "my-slug-x"

    undo(view, c)
    assert Jason.encode!(stored(c)["handle"]) == before

    assert_push_event(view, "desk:undone", %{
      field: "doc[handle]",
      value: "my-slug",
      was: "my-slug-x"
    })

    pause()

    post(view, c, ["handle"], %{"handle" => "my-slug-y"})
    theirs(c, %{"handle" => %{"_type" => "slug", "current" => "their-my-slug-y"}})

    # A slug is one value, not free text: theirs stays, and nothing is undone.
    undo(view, c)
    assert stored(c)["handle"] == %{"_type" => "slug", "current" => "their-my-slug-y"}
  end

  # task-0b9061cb95e89484 review B1: text-merged, each became a value neither
  # editor picked ("small", "draft_2", "2026-12-20").
  describe "a pick another editor changed since stays theirs, and nothing is undone" do
    test "a select whose options share text", c do
      view = open(c)
      post(view, c, ["size"], %{"size" => "x-large"})
      theirs(c, %{"size" => "x-small"})

      undo(view, c)
      assert stored(c)["size"] == "x-small"
      refute_push_event(view, "desk:undone", %{field: "doc[size]"})
    end

    test "a string with an options list", c do
      view = open(c)
      post(view, c, ["tone"], %{"tone" => "in_review"})
      theirs(c, %{"tone" => "in_review_2"})

      undo(view, c)
      assert stored(c)["tone"] == "in_review_2"
      refute_push_event(view, "desk:undone", %{field: "doc[tone]"})
    end

    test "a date and a datetime nested in an object", c do
      for {key, mine, other} <- [
            {"on", "2026-11-21", "2026-12-21"},
            {"at", "2026-11-20T10:30", "2026-11-21T11:30"}
          ] do
        view = open(c)
        post_nested(view, c, "doc[address].#{key}", mine)
        refute stored(c)["address"][key] in [nil, "2026-11-20", "2026-11-20T10:00"]
        theirs(c, %{"address" => Map.put(stored(c)["address"], key, other)})
        before_undo = stored(c)["address"]

        undo(view, c)
        assert stored(c)["address"] == before_undo
        refute_push_event(view, "desk:undone", %{path: "address"})
      end
    end
  end

  # task-0b9061cb95e89484 review B4: put back by index, "two" landed before "one".
  test "a list with no keys: another editor's item before mine refuses the undo, no position guessed",
       c do
    view = open(c)
    remove(view, c, "tags", 1)
    assert stored(c)["tags"] == ["one", "three"]
    theirs(c, %{"tags" => ["zero", "one", "three"]})

    undo(view, c)
    assert stored(c)["tags"] == ["zero", "one", "three"]
    refute_push_event(view, "desk:undone", %{path: "tags"})
  end

  test "a list: a removed item comes back where it was, another editor's item stays", c do
    view = open(c)

    # live-edit.spec.ts "F7: undo leaves another editor's select value and
    # list item", in its order: our pick, theirs over it, and a Mod+Z that
    # leaves theirs.
    post(view, c, ["choice"], %{"choice" => "c"})
    theirs(c, %{"choice" => "a"})
    undo(view, c)
    assert stored(c)["choice"] == "a"
    pause()

    # We remove One; they add Remote; undo brings One back first and keeps Remote.
    remove(view, c, "cards", 0)
    assert stored(c)["cards"] == [card("c2", "Two")]
    theirs(c, %{"cards" => [card("c2", "Two"), card("r", "Remote")]})

    undo(view, c)
    assert stored(c)["choice"] == "a"
    assert stored(c)["cards"] == [card("c1", "One"), card("c2", "Two"), card("r", "Remote")]
  end

  test "an object's nested field: this editor's change comes back, a sibling theirs since stays",
       c do
    view = open(c)

    post_nested(view, c, "doc[address].street", "Main 12")

    assert stored(c)["address"]["street"] == "Main 12"
    theirs(c, %{"address" => %{"street" => "Main 12", "city" => "Bergen"}})

    undo(view, c)

    assert Map.take(stored(c)["address"], ["street", "city"]) == %{
             "street" => "Main 1",
             "city" => "Bergen"
           }

    assert_push_event(view, "desk:undone", %{
      field: "doc[address].street",
      value: "Main 1",
      was: "Main 12"
    })
  end

  test "a list item's text: this editor's typing comes back out, the page is told the item", c do
    view = open(c)
    before = Jason.encode!(stored(c)["cards"])
    post_nested(view, c, "doc[cards][1].label", "Two!")
    assert Enum.at(stored(c)["cards"], 1)["label"] == "Two!"

    undo(view, c)
    assert Jason.encode!(stored(c)["cards"]) == before

    assert_push_event(view, "desk:undone", %{
      field: "doc[cards][1].label",
      value: "Two",
      was: "Two!"
    })
  end

  test "stored rows round-trip byte for byte: remove then undo leaves the list as it was", c do
    view = open(c)
    before = Jason.encode!(stored(c)["cards"])

    remove(view, c, "cards", 1)
    remove(view, c, "cards", 0)
    assert stored(c)["cards"] == []

    undo(view, c)
    assert Jason.encode!(stored(c)["cards"]) == before

    # A list's answer names the field itself, for the page to find it by.
    assert_push_event(view, "desk:undone", %{field: "doc[cards]", path: "cards"})
  end
end
