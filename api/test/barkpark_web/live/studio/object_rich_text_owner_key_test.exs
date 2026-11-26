defmodule BarkparkWeb.Studio.ObjectRichTextOwnerKeyTest do
  @moduledoc """
  The owner `_key` an object rich text's editor was drawn under
  (`_bp_rt_owner[]`, inside the ignored wrapper, task-c29534c0655f0489):
  it is not an edit, any character in a key reads, and two objects in one
  form each read their own.
  """
  use BarkparkWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest
  import BarkparkWeb.ObjectRichText

  alias Barkpark.Content
  alias Barkpark.Content.PortableText, as: PT

  @banner "Someone else rewrote"

  setup %{conn: conn}, do: setup_doc(conn)

  defp rt2(t1, t2), do: [block("k1", t1), block("k2", t2)]
  defp held(a), do: Map.keys(:sys.get_state(a.pid).socket.assigns[:editor_rt_held] || %{})
  defp owner_of(name, key), do: Jason.encode!([name, key])

  defp put_field(c, field, f) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.id, "production")
    content = Map.update(doc.content || %{}, field, %{}, f)

    {:ok, _} =
      Content.upsert_document(
        c.type,
        %{"doc_id" => "drafts." <> c.id, "title" => doc.title, "content" => content},
        "production"
      )
  end

  test "a change whose target is the owner input is no edit: nothing written, not dirty", c do
    put_field(c, "meta", &Map.put(&1, "rt", rt2("one two", "anchor")))
    a = open(c)
    before = stored(c)

    log =
      capture_log(fn ->
        send_post(a, "_bp_rt_owner", %{})
        _ = render(a)
      end)

    assert stored(c) == before
    refute :sys.get_state(a.pid).socket.assigns[:editor_dirty]
    assert held(a) == []
    refute log =~ "_bp_rt_owner"
  end

  test "a key with a | in it: the post typed on it merges", c do
    put_field(c, "meta", &Map.put(&1, "rt", rt2("one two", "anchor")))
    a = open(c)
    key = "m|2"

    put_field(
      c,
      "meta",
      &(&1 |> Map.put("_key", key) |> Map.put("rt", rt2("one two", "anchor B")))
    )

    assert eventually(fn -> words(form(a)["meta"]["rt"]) == ["one two", "anchor B"] end)

    html =
      send_post(a, "doc[meta].rt", %{
        "doc[meta].label" => "l0",
        "doc[meta].rt" => PT.to_html(rt2("one two", "anchor B more")),
        "_bp_rt_owner" => [owner_of("doc[meta].rt", key), owner_of("doc[meta].rt2", key)]
      })

    assert words(stored(c)["meta"]["rt"]) == ["one two", "anchor B more"]
    refute html =~ @banner
  end

  describe "two objects in one form" do
    setup c do
      type = c.type <> "-two"
      rt = fn name -> %{"name" => name, "title" => name, "type" => "richText"} end

      obj = fn name ->
        %{"name" => name, "title" => name, "type" => "composite", "fields" => [rt.("rt")]}
      end

      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => type,
            "title" => "Two objects",
            "visibility" => "public",
            "fields" => [
              %{"name" => "title", "title" => "Title", "type" => "string"},
              obj.("one"),
              obj.("other")
            ]
          },
          "production"
        )

      id = c.id <> "-two"

      {:ok, _} =
        Content.create_document(
          type,
          %{
            "doc_id" => id,
            "title" => "T0",
            "content" => %{
              "one" => %{"rt" => rt2("one two", "anchor")},
              "other" => %{"rt" => rt2("x y", "z")}
            }
          },
          "production"
        )

      {:ok, type: type, id: id}
    end

    test "only one re-keyed: each reads its own owner entry", c do
      {:ok, a, _html} = live(c.conn, "#{c.root}/_desk/#{c.type};#{c.id}")
      render_async(a, 5_000)
      assert eventually(fn -> has_element?(a, "#editor-form") end)

      put_field(
        c,
        "one",
        &(&1 |> Map.put("_key", "o2") |> Map.put("rt", rt2("one two", "anchor B")))
      )

      put_field(c, "other", &Map.put(&1, "rt", rt2("x y", "z B")))

      assert eventually(fn ->
               words(form(a)["one"]["rt"]) == ["one two", "anchor B"] and
                 words(form(a)["other"]["rt"]) == ["x y", "z B"]
             end)

      # `one` is typed on its remount; `other` was never re-keyed, so its
      # page still shows "z", and A typed there on that.
      send_post(a, "doc[one].rt", %{
        "doc[one].rt" => PT.to_html(rt2("one two", "anchor B more")),
        "doc[other].rt" => PT.to_html(rt2("x y", "z more")),
        "_bp_rt_owner" => [owner_of("doc[one].rt", "o2"), owner_of("doc[other].rt", nil)]
      })

      s = stored(c)
      assert words(s["one"]["rt"]) == ["one two", "anchor B more"]
      assert Enum.at(words(s["other"]["rt"]), 1) =~ "B"
      assert held(a) == ["doc[other].rt"]
    end
  end
end
