defmodule BarkparkWeb.Studio.HeldOwnTopWriteTest do
  @moduledoc """
  task-ffb773f49c564973 (from #29050's "Not covered"): `HeldFields.stored/3`
  put the store's value back only in held fields other than the write's
  own top. An array op on `meta.rows` wrote the whole `meta`, so a held
  row's rich text (`meta.rows[0].rt`) or a held `meta.label` went out as
  A's words over B's save, and the banner cleared.

  A held path inside the write's own top now takes the store's value, the
  row found again by its `_key` after the op moved it; A's words go back
  into the form with the banner after the write.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BarkparkWeb.ObjectRichText

  alias Barkpark.Content
  alias BarkparkWeb.EditorPost

  @moduletag :studio_live

  @banner ~s([data-test-id="doc-conflict-banner"])
  @paused ~s([data-test-id="doc-conflict-paused"])
  @row "doc[meta].rows[0].rt"
  @label "doc[meta].label"
  @t0 "one two three"

  setup %{conn: conn}, do: setup_doc(conn)

  defp row_post(view, html, seen) do
    fields = %{
      "doc[meta].label" => "l0",
      "doc[meta].rows[0]._type" => "row",
      "doc[meta].rows[0]._key" => "r1",
      @row => html
    }

    fields = if seen, do: Map.put(fields, "_bp_rt_seen", ["#{@row}|#{seen}"]), else: fields
    send_post(view, @row, fields)
  end

  defp rows(c), do: stored(c)["meta"]["rows"]
  defp row(rows, key), do: Enum.find(rows, &(&1["_key"] == key))

  defp op(view, action, extra \\ %{}) do
    EditorPost.press(
      view,
      "array_op",
      Map.merge(%{"action" => action, "path" => "doc[meta].rows", "member" => "row"}, extra)
    )
  end

  # A's row r1 is held: B's "rowtexB" landed under A's "rowtextA".
  defp row_held(c) do
    {a, b} = {open(c), open(c)}

    inside(a, fn -> row_post(b, "<p>rowtexB</p>", nil) end, fn ->
      row_post(a, "<p>rowtextA</p>", 0)
    end)

    assert words(row(rows(c), "r1")["rt"]) == ["rowtexB"]
    {a, row(form(a)["meta"]["rows"], "r1")["rt"]}
  end

  defp put_label(c, label) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.id, "production")
    content = put_in(doc.content, ["meta", "label"], label)

    {:ok, _} =
      Content.upsert_document(
        c.type,
        %{"doc_id" => "drafts." <> c.id, "title" => doc.title, "content" => content},
        "production"
      )
  end

  # The page's `_bp_seen` as bp-array-focus.js keeps it.
  defp page(view) do
    [_, value] = Regex.run(~r/name="_bp_seen"[^>]*value="([^"]*)"/, render(view))
    seen = value |> String.replace("&quot;", ~s(")) |> Jason.decode!()
    assert_push_event(view, "bp:form-born", %{seqs: seqs, oks: oks}, 2_000)
    seen |> Map.merge(seqs) |> Map.put("v", 2) |> Map.put("ok", Map.merge(seen["ok"] || %{}, oks))
  end

  defp confirmed(view, seen) do
    assert_push_event(view, "bp:form-confirmed", %{oks: oks}, 2_000)
    Map.update!(seen, "ok", &Map.merge(&1, oks))
  end

  defp label_change(view, label, seen) do
    view
    |> element("#editor-form")
    |> render_change(%{
      "doc" => %{"title" => "T0"},
      @label => label,
      "_bp_seen" => Jason.encode!(seen),
      "_target" => [@label]
    })
  end

  # A's label is held: A typed " A1" and it landed, the socket dropped, B
  # saved "B5 …", and A's rejoined page typed " A7" on the old value
  # (`HeldWholeFormWriteTest`).
  defp label_held(c) do
    put_label(c, @t0)
    a = open(c)
    seen = page(a)
    label_change(a, @t0 <> " A1", seen)
    seen = confirmed(a, seen)
    GenServer.stop(a.pid, :normal)
    b = open(c)
    label_change(b, "B5 " <> @t0 <> " A1", page(b))
    GenServer.stop(b.pid, :normal)
    a2 = open(c)
    _ = page(a2)
    label_change(a2, @t0 <> " A1 A7", seen)
    assert stored(c)["meta"]["label"] == "B5 " <> @t0 <> " A1"
    assert has_element?(a2, @paused)
    a2
  end

  for surface <- [:desk, :studio] do
    test "#{surface}: a row added to meta.rows while a row's rich text is held keeps B's row",
         c do
      c = Map.put(c, :surface, unquote(surface))
      {a, view} = row_held(c)

      op(a, "add_row")

      assert eventually(fn -> length(rows(c)) == 2 end), "the added row was not written"
      # On main: A's "rowtextA" was written over B's row, the banner gone.
      assert words(row(rows(c), "r1")["rt"]) == ["rowtexB"]
      assert row(form(a)["meta"]["rows"], "r1")["rt"] == view
      assert has_element?(a, @banner)
    end

    test "#{surface}: the held row moved by the op is found by its _key", c do
      c = Map.put(c, :surface, unquote(surface))
      {a, view} = row_held(c)

      op(a, "add_row")
      assert eventually(fn -> length(rows(c)) == 2 end)
      op(a, "move_up", %{"index" => "1"})

      assert eventually(fn -> List.last(rows(c))["_key"] == "r1" end), "the move was not written"
      assert words(row(rows(c), "r1")["rt"]) == ["rowtexB"]
      assert List.last(form(a)["meta"]["rows"])["_key"] == "r1"
      assert row(form(a)["meta"]["rows"], "r1")["rt"] == view
      assert has_element?(a, @banner)
    end

    test "#{surface}: a row added to meta.rows while meta.label is held keeps B's label", c do
      c = Map.put(c, :surface, unquote(surface))
      a = label_held(c)
      before = length(rows(c) || [])

      op(a, "add_row")

      assert eventually(fn -> length(rows(c) || []) == before + 1 end),
             "the added row was not written"

      # On main: the label was written as A's "… A1 A7", the banner gone.
      assert stored(c)["meta"]["label"] == "B5 " <> @t0 <> " A1"
      assert form(a)["meta"]["label"] == @t0 <> " A1 A7"
      assert has_element?(a, @banner)
      assert has_element?(a, @paused)
    end

    test "#{surface} control: nothing held, a row added to meta.rows writes the form as before",
         c do
      c = Map.put(c, :surface, unquote(surface))
      a = open(c)
      row_post(a, "<p>rowtextA</p>", nil)
      assert eventually(fn -> words(row(rows(c), "r1")["rt"]) == ["rowtextA"] end)

      op(a, "add_row")

      assert eventually(fn -> length(rows(c)) == 2 end)
      assert words(row(rows(c), "r1")["rt"]) == ["rowtextA"]
      refute has_element?(a, @banner)
    end
  end
end
