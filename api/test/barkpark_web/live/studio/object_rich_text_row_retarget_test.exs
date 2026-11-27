defmodule BarkparkWeb.Studio.ObjectRichTextRowRetargetTest do
  @moduledoc """
  task-46bcc2dfb805acce (#29040 review, N1). B edits row r1 and inserts or
  moves rows; A's post, typed on the first draw, names r1 by its old index.
  The fold (#29036) puts A's fields into r1 by its posted `_key`, but the
  row's owner entry was looked up by the input name, whose index now holds
  another row: the row text was not read under the lock, and A's text was
  written over B's edit to r1 with no banner. A row's owner entry is now
  matched to the row by its `_key`.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BarkparkWeb.ObjectRichText

  alias Barkpark.Content
  alias BarkparkWeb.Studio.StudioLive.PostIdentity

  @moduletag :studio_live
  @rb "Someone else rewrote"

  setup %{conn: conn}, do: setup_doc(conn)

  defp put_rows(c, rows) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.id, "production")
    content = put_in(doc.content, ["meta", "rows"], rows)

    {:ok, _} =
      Content.upsert_document(
        c.type,
        %{"doc_id" => "drafts." <> c.id, "title" => doc.title, "content" => content},
        "production"
      )
  end

  defp r(key, blocks), do: %{"_type" => "row", "_key" => key, "rt" => blocks}
  defp r1(second), do: r("r1", [block("w1", "one"), block("w1b", second)])
  defp r2, do: r("r2", [block("w2", "three")])
  defp r0, do: r("r0", [block("w0", "zero")])

  defp held(a), do: Map.keys(:sys.get_state(a.pid).socket.assigns[:editor_rt_held] || %{})
  defp by_key(c), do: Map.new(stored(c)["meta"]["rows"] || [], &{&1["_key"], words(&1["rt"])})
  defp keys(c), do: Enum.map(stored(c)["meta"]["rows"] || [], & &1["_key"])
  defp form_rows(a), do: Enum.map(form(a)["meta"]["rows"] || [], &{&1["_key"], words(&1["rt"])})

  defp page_owners(view) do
    ~r/name="_bp_rt_owner\[\]" value="([^"]*)"/
    |> Regex.scan(render(view))
    |> Enum.map(fn [_, v] -> String.replace(v, "&quot;", "\"") end)
  end

  # A's post as the page sends it: `rows` are `{key, html}` by the index
  # the page drew them at.
  defp post(a, how, rows, owners) do
    %{editor_doc: d, dataset: ds} = :sys.get_state(a.pid).socket.assigns

    params =
      rows
      |> Enum.with_index()
      |> Enum.flat_map(fn {{k, html}, i} ->
        [
          {"doc[meta].rows[#{i}]._type", "row"},
          {"doc[meta].rows[#{i}]._key", k},
          {"doc[meta].rows[#{i}].rt", html}
        ]
      end)
      |> Map.new()
      |> Map.merge(%{"doc[meta].label" => "l0", "doc[title]" => "T0"})
      |> URI.encode_query()
      |> Plug.Conn.Query.decode()
      |> Map.merge(%{
        "_bp_doc" => PostIdentity.value(ds, d.type, d.doc_id),
        "_target" => ["doc[meta].rows[0].rt"],
        "_bp_rt_owner" => owners
      })

    render_hook(a, if(how == :auto, do: "autosave", else: "save"), params)
  end

  defp b(c, a, rows) do
    put_rows(c, rows)
    want = Enum.map(rows, &{&1["_key"], words(&1["rt"])})
    assert eventually(fn -> form_rows(a) == want end), "A's socket did not take B's save: no test"
  end

  # B's saves, by row: `:r1b` is r1 with B's edit to its second block.
  @cases [
    {"INS+EDIT", [[:r0, :r1b, :r2]]},
    {"SWAP+EDIT", [[:r2, :r1b]]},
    {"EDIT-INS", [[:r1b, :r2], [:r0, :r1b, :r2]]}
  ]

  defp row(:r0), do: r0()
  defp row(:r1b), do: r1("two B")
  defp row(:r2), do: r2()

  for surface <- [:desk, :studio], how <- [:auto, :save], {name, saves} <- @cases do
    @surface surface
    @how how
    @saves saves

    test "#{surface} #{how} #{name}: A's post typed before merges with B's edit to r1, no banner",
         c do
      put_rows(c, [r1("two"), r2()])
      a = c |> Map.put(:surface, @surface) |> open()
      owners = page_owners(a)
      for rows <- @saves, do: b(c, a, Enum.map(rows, &row/1))
      want_keys = @saves |> List.last() |> Enum.map(&(&1 |> row() |> Map.fetch!("_key")))

      html = post(a, @how, [{"r1", "<p>ONE</p><p>two</p>"}, {"r2", "<p>three</p>"}], owners)

      # Before: r1 = ["ONE", "two"], B's "two B" lost, no banner.
      assert by_key(c)["r1"] == ["ONE", "two B"],
             "A's post was written over B's edit to r1: #{inspect(by_key(c))}"

      assert keys(c) == want_keys
      assert by_key(c)["r2"] == ["three"]
      if "r0" in want_keys, do: assert(by_key(c)["r0"] == ["zero"])
      assert held(a) == []
      refute html =~ @rb
    end
  end

  for surface <- [:desk, :studio] do
    @surface surface

    test "#{surface} INS+EDIT, same block: B's r1 kept, A held", c do
      put_rows(c, [r1("two"), r2()])
      a = c |> Map.put(:surface, @surface) |> open()
      owners = page_owners(a)
      b(c, a, [r0(), r1("two B"), r2()])

      html = post(a, :auto, [{"r1", "<p>one</p><p>two A</p>"}, {"r2", "<p>three</p>"}], owners)

      assert by_key(c)["r1"] == ["one", "two B"],
             "A's post was written over B's edit to r1: #{inspect(by_key(c))}"

      assert held(a) == ["doc[meta].rows[1].rt"]
      assert html =~ "doc-conflict-banner"
    end

    test "#{surface} control: A alone types in r1: written, no banner", c do
      put_rows(c, [r1("two"), r2()])
      a = c |> Map.put(:surface, @surface) |> open()

      html =
        post(a, :auto, [{"r1", "<p>ONE</p><p>two</p>"}, {"r2", "<p>three</p>"}], page_owners(a))

      assert by_key(c)["r1"] == ["ONE", "two"]
      assert held(a) == []
      refute html =~ @rb
    end
  end
end
