defmodule BarkparkWeb.Studio.NestedRowOwnerOuterKeyTest do
  @moduledoc """
  task-1a748ef7bc04ae49 (#29164 review, E14). A duplicated section's items
  share their `_key`s. B swaps two such sections; A's page, not yet redrawn,
  types in s1. A row's owner entry named only its own row's key, so the
  entry A's page drew at `sections[0]` (s1's i1, alpha) matched the form's
  `sections[0]` (now s2's i1, beta): s2's text was read against alpha's draw
  and A was held, nothing lost but nothing written. The entry now names the
  outer row keys too, and matches a form row only when every key on the way
  does.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BarkparkWeb.ObjectRichText

  alias Barkpark.Content
  alias BarkparkWeb.Studio.StudioLive.PostIdentity

  @moduletag :studio_live
  @rb "Someone else rewrote"

  defp rt, do: %{"name" => "rt", "title" => "rt", "type" => "richText"}

  defp member(name, fields),
    do: %{"type" => "composite", "name" => name, "title" => name, "fields" => fields}

  defp array(name, of), do: %{"name" => name, "title" => name, "type" => "arrayOf", "of" => [of]}

  setup %{conn: conn} do
    c = setup_doc(conn)

    fields = [
      %{"name" => "title", "title" => "Title", "type" => "string"},
      array("sections", member("section", [array("items", member("item", [rt()]))]))
    ]

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => c.type,
          "title" => "Nested rows",
          "visibility" => "public",
          "fields" => fields
        },
        "production"
      )

    c
  end

  defp put_doc(c, sections) do
    {:ok, _} =
      Content.upsert_document(
        c.type,
        %{"doc_id" => "drafts." <> c.id, "title" => "T0", "content" => %{"sections" => sections}},
        "production"
      )
  end

  defp sec(key, text),
    do: %{
      "_type" => "section",
      "_key" => key,
      "items" => [%{"_type" => "item", "_key" => "i1", "rt" => [block(key <> "b", text)]}]
    }

  defp tab(c, surface) do
    path =
      case surface do
        :desk -> "#{c.root}/_desk/#{c.type};#{c.id}"
        :studio -> "#{c.root}/#{c.type}/#{c.id}"
      end

    {:ok, view, _html} = live(c.conn, path)
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "#editor-form") end)
    view
  end

  defp form_keys(a), do: Enum.map(form(a)["sections"] || [], & &1["_key"])

  defp page_owners(view) do
    ~r/name="_bp_rt_owner\[\]" value="([^"]*)"/
    |> Regex.scan(render(view))
    |> Enum.map(fn [_, v] -> String.replace(v, "&quot;", "\"") end)
  end

  # B's save, taken by A's socket.
  defp b_saves(c, a, sections) do
    put_doc(c, sections)
    keys = Enum.map(sections, & &1["_key"])
    assert eventually(fn -> form_keys(a) == keys end), "A's socket did not take B's save: no test"
  end

  # A's post as its page sends it: `{section key, html}` by the index the
  # page drew them at.
  defp autosave(a, sections, owners) do
    %{editor_doc: d, dataset: ds} = :sys.get_state(a.pid).socket.assigns

    params =
      sections
      |> Enum.with_index()
      |> Enum.flat_map(fn {{key, html}, i} ->
        [
          {"doc[sections][#{i}]._type", "section"},
          {"doc[sections][#{i}]._key", key},
          {"doc[sections][#{i}].items[0]._type", "item"},
          {"doc[sections][#{i}].items[0]._key", "i1"},
          {"doc[sections][#{i}].items[0].rt", html}
        ]
      end)
      |> Map.new()
      |> Map.put("doc[title]", "T0")
      |> URI.encode_query()
      |> Plug.Conn.Query.decode()
      |> Map.merge(%{
        "_bp_doc" => PostIdentity.value(ds, d.type, d.doc_id),
        "_target" => ["doc[sections][0].items[0].rt"],
        "_bp_rt_owner" => owners
      })

    render_hook(a, "autosave", params)
  end

  defp stored_by_key(c),
    do: Map.new(stored(c)["sections"] || [], &{&1["_key"], words(hd(&1["items"])["rt"])})

  defp held(a), do: Map.keys(:sys.get_state(a.pid).socket.assigns[:editor_rt_held] || %{})

  # An entry as a page drawn before the outer keys posts it.
  defp old_entry(entry), do: entry |> Jason.decode!() |> Enum.take(3) |> Jason.encode!()

  for surface <- [:desk, :studio] do
    @surface surface

    test "#{surface} E14: B swaps sections sharing item key i1; A's old page types in s1: written",
         c do
      put_doc(c, [sec("s1", "alpha"), sec("s2", "beta")])
      a = tab(c, @surface)
      owners = page_owners(a)
      b_saves(c, a, [sec("s2", "beta"), sec("s1", "alpha")])

      html = autosave(a, [{"s1", "<p>alpha A</p>"}, {"s2", "<p>beta</p>"}], owners)

      # Before: A held on doc[sections][0].items[0].rt, s1 still "alpha".
      assert stored_by_key(c) == %{"s1" => ["alpha A"], "s2" => ["beta"]},
             "A's post was not written: #{inspect(stored_by_key(c))}"

      assert form_keys(a) == ["s2", "s1"]
      assert held(a) == []
      refute html =~ @rb
    end

    test "#{surface} E19: B swaps the sections and edits s1; A's old page types in s1: B kept, A held",
         c do
      put_doc(c, [sec("s1", "alpha"), sec("s2", "beta")])
      a = tab(c, @surface)
      owners = page_owners(a)
      b_saves(c, a, [sec("s2", "beta"), sec("s1", "alpha B")])

      html = autosave(a, [{"s1", "<p>alpha A</p>"}, {"s2", "<p>beta</p>"}], owners)

      assert stored_by_key(c) == %{"s1" => ["alpha B"], "s2" => ["beta"]},
             "A's post was written over B's edit to s1: #{inspect(stored_by_key(c))}"

      assert held(a) == ["doc[sections][1].items[0].rt"]
      assert html =~ "doc-conflict-banner"
    end

    test "#{surface} an entry without outer keys (a page drawn before): no move, A's post written",
         c do
      put_doc(c, [sec("s1", "alpha"), sec("s2", "beta")])
      a = tab(c, @surface)
      owners = Enum.map(page_owners(a), &old_entry/1)

      html = autosave(a, [{"s1", "<p>alpha A</p>"}, {"s2", "<p>beta</p>"}], owners)

      assert stored_by_key(c) == %{"s1" => ["alpha A"], "s2" => ["beta"]}
      assert held(a) == []
      refute html =~ @rb
    end
  end
end
