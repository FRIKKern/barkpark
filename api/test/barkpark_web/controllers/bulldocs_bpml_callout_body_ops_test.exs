defmodule BarkparkWeb.BulldocsBpmlCalloutBodyOpsTest do
  @moduledoc """
  Every edit a BPML text can make to a top-level callout with a body
  (task-0b448ea0847a6b4f, `Bpml.PrintMark`), pushed through the route bp
  calls without a fingerprint, as every released bp pushes.

  A copy pulled before callouts printed their body (no print mark, the callout
  inline) brings the callout home as one top-level block with its id, spelled
  as it was pulled, and it is kept as stored; any other answer is refused by
  name (422 `bpml_stale_copy`), writing nothing. A copy that showed the body
  makes each edit.
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

  # Each op, and whether it lands from an old copy.
  @ops [
    {"delete", false},
    {"move into a section", false},
    {"wrap in a section", false},
    {"re-id", false},
    {"split", false},
    {"merge a paragraph in", false},
    {"retype", false},
    {"reorder", true},
    {"duplicate", true}
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

  defp push(slug, bpml, rev),
    do:
      build_conn()
      |> authed()
      |> post("#{@ingest_path}/#{slug}/sync", %{"bpml" => bpml, "baseRev" => rev})

  defp stored(slug), do: get_in(Content.get_paper(slug).content, ["blocks"])
  defp stored_callout(slug), do: Enum.find(stored(slug), &(&1["id"] == "c1"))

  for {op, lands?} <- @ops do
    @op op
    if lands? do
      test "an old copy without a fingerprint: #{op} lands, and the callout keeps its body" do
        slug = paper!()
        {bpml, rev} = pull!(slug)
        assert %{"ok" => true} = push(slug, edit(@op, old_text(bpml)), rev) |> json_response(200)
        assert stored_callout(slug) == callout()
      end
    else
      test "an old copy without a fingerprint: #{op} is refused by name, and the body stays" do
        slug = paper!()
        before = stored(slug)
        {bpml, rev} = pull!(slug)

        answer = push(slug, edit(@op, old_text(bpml)), rev) |> json_response(422)
        assert answer["error"]["code"] == "bpml_stale_copy"
        assert answer["error"]["message"] =~ "callout c1 has a body your copy was pulled without"
        assert answer["error"]["hint"] == @pull_hint
        assert stored(slug) == before
      end
    end
  end

  # Control rows: a copy that showed the body makes the same edits.
  for op <- ["delete", "move into a section", "wrap in a section", "re-id"] do
    @op op
    test "a copy that showed the body: #{op} lands" do
      slug = paper!()
      {bpml, rev} = pull!(slug)
      assert bpml =~ ~s(print="2")
      assert %{"ok" => true} = push(slug, edit(@op, bpml), rev) |> json_response(200)
    end
  end

  defp edit(op, bpml) do
    {^op, f} = List.keyfind(ops(), op, 0)
    edited = f.(bpml)
    assert edited != bpml, "#{op} did not apply"
    edited
  end
end
