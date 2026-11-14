defmodule BarkparkWeb.Components.ArrayRowOpenTest do
  @moduledoc """
  task-7f47b7ad78b08048: typing in an opened array row closed the row on the
  next save and dropped the focus; the keys after it went nowhere. Each
  render worked `open` out again (open while the row is empty or carries a
  finding), so the save after the first keys closed a new row, and any save
  closed a row the person had opened.

  Whether a row is open is now the person's, as Sanity's: `open` is how a
  row is first drawn, and the row tells LiveView to leave the browser's
  `open` alone on every patch after that (`JS.ignore_attributes`). A finding
  that arrives later still opens it: the row carries `data-row-finding`,
  which `bp-array-focus.js` opens (`__array_focus.test.mjs`). The browser
  half (20 keys typed slowly into an opened row and into a new one, none
  lost) is in the PR.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Barkpark.Content.SchemaDefinition.Field
  alias BarkparkWeb.Components.Fields.ArrayField

  defp sections do
    %Field{
      name: "sections",
      type: "arrayOf",
      ordered: true,
      of: %Field{
        name: "sec",
        type: "composite",
        title: "Section",
        fields: [
          %Field{name: "heading", type: "string"},
          %Field{name: "note", type: "text"},
          %Field{
            name: "links",
            type: "arrayOf",
            of: %Field{
              name: "link",
              type: "composite",
              fields: [%Field{name: "label", type: "string"}]
            }
          }
        ]
      }
    }
  end

  # Each row as {id, drawn open?, carries a finding?, its phx-mounted}.
  defp rows(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("details.bp-array-item")
    |> Enum.map(fn el ->
      one = fn name -> el |> LazyHTML.attribute(name) |> List.first() end
      {one.("id"), one.("open") != nil, one.("data-row-finding") != nil, one.("phx-mounted")}
    end)
  end

  defp keeps_open?(phx_mounted) do
    case phx_mounted && Jason.decode(phx_mounted) do
      {:ok, ops} -> Enum.any?(ops, &match?(["ignore_attrs", %{"attrs" => ["open"]}], &1))
      _ -> false
    end
  end

  test "every row leaves its open state to the browser after it is first drawn" do
    value = [
      %{"heading" => "Typed into", "links" => [%{"label" => "Inner"}, %{}]},
      %{}
    ]

    found =
      render_component(&ArrayField.array_field/1, %{field: sections(), value: value}) |> rows()

    # Outer rows and the nested array's rows alike.
    assert length(found) == 4

    for {id, _open, _finding, mounted} <- found do
      assert keeps_open?(mounted), "#{id} lets a patch re-decide its open state"
    end

    # How each is first drawn: an empty row open, one with content closed.
    assert [{_, false, _, _}, {_, false, _, _}, {_, true, _, _}, {_, true, _, _}] = found
  end

  test "a row with a finding is drawn open and says so to the browser" do
    value = [%{"heading" => "One"}, %{"heading" => "Two"}]
    errors = %{1 => %{"heading" => ["is too long"]}}

    found =
      render_component(&ArrayField.array_field/1, %{
        field: sections(),
        value: value,
        errors: errors
      })
      |> rows()

    assert [{_, false, false, _}, {_, true, true, _}] = found
  end

  # "Note text" typed into a new row's rich text kept "N": the empty field was
  # a text input until its first save and the rich editor after, so that save
  # swapped the element under the caret.
  test "an empty rich text field in a row is the rich editor from the start" do
    field = %Field{
      name: "sections",
      type: "arrayOf",
      of: %Field{
        name: "sec",
        type: "composite",
        fields: [%Field{name: "heading", type: "string"}, %Field{name: "note", type: "richText"}]
      }
    }

    for value <- [
          [%{"_key" => "s1"}],
          [%{"_key" => "s1", "note" => ""}],
          [%{"_key" => "s1", "note" => []}]
        ] do
      doc =
        render_component(&ArrayField.array_field/1, %{field: field, value: value})
        |> LazyHTML.from_fragment()

      note = LazyHTML.query(doc, ~s([data-subfield-name="note"]))
      assert Enum.count(LazyHTML.query(note, "bp-rich-text-editor")) == 1, inspect(value)
      assert Enum.count(LazyHTML.query(note, ~s(input[type="text"]))) == 0, inspect(value)
      assert LazyHTML.query(note, ~s(input[type="hidden"])) |> LazyHTML.attribute("value") == [""]
    end
  end

  # #26148 review: the browser keeps `open` on the element LiveView matches by
  # id. An index id left it at the position: move the open S1 down and S2
  # opened; remove S1 and S2 opened. A keyed row's id is its key's.
  test "a keyed row keeps its id across a move and a remove, so its open state goes with it" do
    ids = fn value ->
      render_component(&ArrayField.array_field/1, %{field: sections(), value: value})
      |> rows()
      |> Enum.map(&elem(&1, 0))
    end

    k1 = %{"_key" => "k1", "_type" => "sec", "heading" => "One"}
    k2 = %{"_key" => "k2", "_type" => "sec", "heading" => "Two"}
    k3 = %{"_key" => "k3", "_type" => "sec", "heading" => "Three"}

    [a, b, c] = ids.([k1, k2, k3])
    assert ids.([k2, k1, k3]) == [b, a, c], "a move takes the row's id with it"
    assert ids.([k2, k3]) == [b, c], "a remove leaves the others' ids as they were"
    assert length(Enum.uniq([a, b, c])) == 3

    # Two rows sharing a key (pasted data) keep index ids: no id twice.
    shared = ids.([k1, %{k2 | "_key" => "k1"}])
    assert length(Enum.uniq(shared)) == 2
  end

  test "a typed array's rows (several member types) leave it to the browser too" do
    field = %Field{
      name: "blocks",
      type: "arrayOf",
      of_types: %{
        "hero" => %Field{
          name: "hero",
          type: "composite",
          fields: [%Field{name: "title", type: "string"}]
        }
      }
    }

    html =
      render_component(&ArrayField.array_field/1, %{
        field: field,
        value: [%{"_type" => "hero", "_key" => "k1", "title" => "Big"}]
      })

    assert [{_, _, _, mounted}] = rows(html)
    assert keeps_open?(mounted)
  end
end
