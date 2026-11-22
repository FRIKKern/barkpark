defmodule BarkparkWeb.BulldocsBpmlCalloutBodyOpsTest do
  @moduledoc """
  Every edit a BPML text can make to a top-level callout with a body
  (task-0b448ea0847a6b4f, `Bpml.PrintMark`), pushed through the route bp
  calls without a fingerprint, as every released bp pushes.

  A copy pulled before callouts printed their body (no print mark, the callout
  inline) brings the callout home once under its id, at any depth, spelled as
  it was pulled; it is kept as stored where it stands. Any other answer is
  refused by name (422 `bpml_stale_copy`), writing nothing. A copy that
  showed the body makes each edit.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.{Content, LabelFixtures, Repo}

  @token "barkpark-test-ingest-token"
  @ingest_path "/v1/plugins/bulldocs/papers"
  @pull_hint "bp paper pull, then make your edit again"

  defp text(value), do: [%{"type" => "text", "value" => value}]
  defp p(id, value), do: %{"id" => id, "type" => "paragraph", "content" => text(value)}

  defp callout do
    %{
      "id" => "c1",
      "type" => "callout",
      "tone" => "info",
      "content" => text("Read this first."),
      "slots" => %{"body" => [p("c1-a", "The body paragraph.")]}
    }
  end

  defp stored_blocks do
    [
      p("p1", "Opening."),
      %{"id" => "s0", "type" => "section", "blocks" => [p("s0p", "Inside.")]},
      callout(),
      p("p2", "Closing.")
    ]
  end

  @inline ~s(  <callout id="c1" tone="info">Read this first.</callout>)

  # The callout as this pull prints it, and as a pull before bodies printed.
  defp seg(t), do: hd(Regex.run(~r{  <callout id="c1".*?</callout>}s, t))
  defp old_text(t), do: t |> String.replace(~s( print="2"), "") |> String.replace(seg(t), @inline)

  defp indent(s), do: s |> String.split("\n") |> Enum.map_join("\n", &("  " <> &1))
  defp cut(t, s), do: String.replace(t, s <> "\n", "", global: false)
  defp closing, do: ~s(  <p id="p2">Closing.</p>)

  # Each op, and whether it lands from an old copy, the callout byte-equal.
  @ops [
    {"delete", false, "an old copy that deletes a callout is refused by name, writing nothing"},
    {"move into a section", true,
     "an old copy that moves a callout into a section lands; the callout keeps its body"},
    {"wrap in a section", true,
     "an old copy that wraps a callout in a new section lands; the callout keeps its body"},
    {"re-id", false,
     "an old copy that gives a callout a new id is refused by name, writing nothing"},
    {"split", false, "an old copy that splits a callout is refused by name, writing nothing"},
    {"merge a paragraph in", false,
     "an old copy that merges a paragraph into a callout is refused by name, writing nothing"},
    {"retype", false,
     "an old copy that turns a callout into another block type is refused by name, writing nothing"},
    {"reorder", true,
     "an old copy that moves a callout to another top-level place lands; the callout keeps its body"},
    {"duplicate", true,
     "an old copy that copies a callout under a new id lands; the stored callout keeps its body"}
  ]

  # {op, the edit of the text}
  defp ops do
    [
      {"delete", &cut(&1, seg(&1))},
      {"move into a section",
       fn t ->
         s = seg(t)

         t
         |> cut(s)
         |> String.replace("\n  </section>", "\n" <> indent(s) <> "\n  </section>", global: false)
       end},
      {"wrap in a section",
       &String.replace(
         &1,
         seg(&1),
         "  <section id=\"s9\">\n" <> indent(seg(&1)) <> "\n  </section>"
       )},
      {"re-id", &String.replace(&1, ~s(<callout id="c1"), ~s(<callout id="c1x"))},
      {"split",
       &String.replace(
         &1,
         seg(&1),
         ~s(  <callout id="c1" tone="info">Read this</callout>\n  <callout id="c1b" tone="info">first.</callout>)
       )},
      {"merge a paragraph in",
       fn t ->
         t
         |> cut(closing())
         |> String.replace(
           seg(t),
           String.replace(seg(t), "Read this first.", "Read this first. Closing.")
         )
       end},
      {"retype", &String.replace(&1, seg(&1), ~s(  <p id="c1">Read this first.</p>))},
      {"reorder",
       fn t -> t |> cut(seg(t)) |> String.replace(closing(), closing() <> "\n" <> seg(t)) end},
      {"duplicate",
       &String.replace(
         &1,
         seg(&1),
         seg(&1) <> "\n" <> String.replace(seg(&1), ~s(id="c1"), ~s(id="c1copy"))
       )}
    ]
  end

  defp authed(conn) do
    conn
    |> put_req_header("authorization", "Bearer #{@token}")
    |> put_req_header("content-type", "application/json")
  end

  defp paper! do
    slug = "callout-ops-#{System.unique_integer([:positive])}"
    seed = [p("seed", "Seed.")]
    {:ok, paper} = Content.upsert_paper(LabelFixtures.paper_attrs(%{slug: slug, blocks: seed}))
    content = paper.content |> Map.put("blocks", stored_blocks()) |> Map.delete("body_html")
    paper |> Ecto.Changeset.change(content: content) |> Repo.update!()
    slug
  end

  defp pull!(slug) do
    conn = get(build_conn(), "/papers/#{slug}/source", %{"format" => "bpml"})
    [rev] = get_resp_header(conn, "x-paper-rev")
    {response(conn, 200), rev}
  end

  defp sync_copy(slug, bpml, rev),
    do:
      build_conn()
      |> authed()
      |> post("#{@ingest_path}/#{slug}/sync", %{"bpml" => bpml, "baseRev" => rev})

  defp stored(slug), do: get_in(Content.get_paper(slug).content, ["blocks"])
  # The block `c1` wherever it stands, with the id of the block holding it.
  defp where(blocks, holder \\ nil) do
    Enum.find_value(blocks, fn
      %{"id" => "c1"} = c -> {holder, c}
      %{"blocks" => inner, "id" => id} -> where(inner, id)
      _ -> nil
    end)
  end

  # Where each op puts the callout.
  defp holder("move into a section"), do: "s0"
  defp holder("wrap in a section"), do: "s9"
  defp holder(_op), do: nil

  for {op, lands?, name} <- @ops do
    @op op
    if lands? do
      test "#{name}" do
        slug = paper!()
        assert where(stored(slug)) == {nil, callout()}
        {bpml, rev} = pull!(slug)

        assert %{"ok" => true} =
                 sync_copy(slug, edit(@op, old_text(bpml)), rev) |> json_response(200)

        assert where(stored(slug)) == {holder(@op), callout()}
      end
    else
      test "#{name}" do
        slug = paper!()
        before = stored(slug)
        {bpml, rev} = pull!(slug)

        answer = sync_copy(slug, edit(@op, old_text(bpml)), rev) |> json_response(422)
        assert answer["error"]["code"] == "bpml_stale_copy"
        assert answer["error"]["message"] =~ "callout c1 has a body your copy was pulled without"
        assert answer["error"]["hint"] == @pull_hint
        assert stored(slug) == before
      end
    end
  end

  # The id is found exactly once, on a callout.
  @inside ~s(<p id="s0p">Inside.</p>)

  defp finder_edit(:twice, t),
    do: String.replace(t, @inside, @inside <> "\n  " <> @inline)

  defp finder_edit(:other_kind, t),
    do:
      t
      |> cut(@inline)
      |> String.replace(@inside, @inside <> ~s(\n    <p id="c1">Read this first.</p>))

  for {name, edit} <- [
        {"holds a callout's id twice", :twice},
        {"gives a callout's id to a paragraph in a section", :other_kind}
      ] do
    @edit edit
    test "an old copy that #{name} is refused by name, writing nothing" do
      slug = paper!()
      before = stored(slug)
      {bpml, rev} = pull!(slug)
      copy = finder_edit(@edit, old_text(bpml))
      assert copy != old_text(bpml)

      answer = sync_copy(slug, copy, rev) |> json_response(422)
      assert answer["error"]["message"] =~ ~r/\bc1\b/
      assert stored(slug) == before
    end
  end

  # Control rows: a copy that showed the body makes the same edits.
  for op <- ["delete", "move into a section", "wrap in a section", "re-id"] do
    @op op
    test "a copy that showed the body: #{op} lands" do
      slug = paper!()
      {bpml, rev} = pull!(slug)
      assert bpml =~ ~s(print="2")
      assert %{"ok" => true} = sync_copy(slug, edit(@op, bpml), rev) |> json_response(200)

      if holder(@op), do: assert(where(stored(slug)) == {holder(@op), callout()})
    end
  end

  defp edit(op, bpml) do
    {^op, f} = List.keyfind(ops(), op, 0)
    edited = f.(bpml)
    assert edited != bpml, "#{op} did not apply"
    edited
  end
end
