defmodule BarkparkWeb.BulldocsBpmlListItemsOpsTest do
  @moduledoc """
  Every edit a BPML text can make to a top-level list holding nested lists and
  item ids (task-0b448ea0847a6b4f), pushed through the route bp calls, with
  and without the fingerprint its pull served (`Bpml.PrintMark`).

  Without the fingerprint the push is read as main read it: the block comes
  home byte-equal and in place, or the push is refused (422 `bpml_unshown`)
  and nothing is written. That holds for a copy of this pull, a copy pulled
  before nested lists printed, and the same with a print mark typed in. With
  the fingerprint the copy shows every level, so each edit lands.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.{Content, LabelFixtures, Repo}
  alias Barkpark.Content.Papers.BpmlView
  alias Barkpark.PortableDoc.Bpml.WriteWall

  @token "barkpark-test-ingest-token"
  @ingest_path "/v1/plugins/bulldocs/papers"

  defp text(value), do: [%{"type" => "text", "value" => value}]
  defp p(id, value), do: %{"id" => id, "type" => "paragraph", "content" => text(value)}
  defp list(items), do: %{"type" => "list", "items" => items}
  defp list(id, items), do: %{"id" => id, "type" => "list", "items" => items}

  defp nested do
    list("l1", [
      %{
        "id" => "plan",
        "content" => text("Plan"),
        "children" => [
          %{
            "type" => "list",
            "ordered" => true,
            "items" => [
              %{
                "id" => "build",
                "content" => text("Build"),
                "children" => [list([text("Verify")])]
              },
              text("Ship")
            ]
          }
        ]
      },
      text("Flat sibling"),
      %{"id" => "done", "content" => text("Done"), "checked" => true}
    ])
  end

  defp stored_blocks do
    [
      p("p1", "Opening."),
      %{"id" => "s0", "type" => "section", "blocks" => [p("s0p", "Inside.")]},
      nested(),
      list("m2", [text("M one")]),
      p("p2", "Closing.")
    ]
  end

  # The list as the printer before nested lists and item ids spelled it.
  @old_l1 """
    <ul id="l1">
      <li>Plan</li>
      <li>Flat sibling</li>
      <li checked="true">Done</li>
    </ul>\
  """

  defp seg(t, id \\ "l1"), do: hd(Regex.run(~r{  <ul id="#{id}">.*?\n  </ul>}s, t))
  defp indent(s), do: s |> String.split("\n") |> Enum.map_join("\n", &("  " <> &1))
  defp cut(t, s), do: String.replace(t, s <> "\n", "", global: false)

  defp old_text(t), do: t |> String.replace(~s( print="3"), "") |> String.replace(seg(t), @old_l1)
  defp mark(t), do: String.replace(t, "<paper ", ~s(<paper print="3" ), global: false)

  @split "  <ul id=\"l1\">\n    <li>Plan</li>\n  </ul>\n  <ul id=\"l1b\">\n    <li>Flat sibling</li>\n  </ul>"

  # Each op, and whether it lands without the fingerprint (main's answer).
  @ops [
    {"edit", false},
    {"delete", false},
    {"move into a section", false},
    {"wrap in a section", false},
    {"split", false},
    {"merge another list in", false},
    {"re-id", false},
    {"retype", false},
    {"reorder", true},
    {"duplicate", true}
  ]

  # {op, the edit of the text}
  defp ops do
    [
      {"edit", &String.replace(&1, "Flat sibling", "Flat sibling, edited")},
      {"delete", &cut(&1, seg(&1))},
      {"move into a section",
       fn t ->
         s = seg(t)

         t
         |> cut(s)
         |> String.replace("\n  </section>", "\n" <> indent(s) <> "\n  </section>", global: false)
       end},
      {"wrap in a section",
       fn t ->
         String.replace(
           t,
           seg(t),
           "  <section id=\"s9\">\n" <> indent(seg(t)) <> "\n  </section>"
         )
       end},
      {"split", &String.replace(&1, seg(&1), @split)},
      {"merge another list in",
       fn t ->
         t
         |> cut(seg(t, "m2"))
         |> String.replace(
           seg(t),
           String.replace(seg(t), ~r{\n  </ul>$}, "\n    <li>M one</li>\n  </ul>")
         )
       end},
      {"re-id", &String.replace(&1, ~s(<ul id="l1">), ~s(<ul id="l1x">))},
      {"retype", &String.replace(&1, seg(&1), ~s(  <p id="l1">Plan. Flat sibling. Done.</p>))},
      {"reorder",
       fn t ->
         s = seg(t)

         t
         |> cut(s)
         |> String.replace(~s(  <p id="p2">Closing.</p>), ~s(  <p id="p2">Closing.</p>\n) <> s)
       end},
      {"duplicate", &String.replace(&1, seg(&1), seg(&1) <> "\n" <> retag(seg(&1)))}
    ]
  end

  # A copy of the list under a new id, its item ids left out.
  defp retag(s),
    do: s |> String.replace(~s(id="l1"), ~s(id="l1copy")) |> String.replace(~r{ id="[a-z]+"}, "")

  defp authed(conn) do
    conn
    |> put_req_header("authorization", "Bearer #{@token}")
    |> put_req_header("content-type", "application/json")
  end

  defp paper! do
    slug = "nested-list-ops-#{System.unique_integer([:positive])}"
    seed = [p("seed", "Seed.")]
    {:ok, paper} = Content.upsert_paper(LabelFixtures.paper_attrs(%{slug: slug, blocks: seed}))
    content = paper.content |> Map.put("blocks", stored_blocks()) |> Map.delete("body_html")
    paper |> Ecto.Changeset.change(content: content) |> Repo.update!()
    slug
  end

  defp pull!(slug) do
    conn = get(build_conn(), "/papers/#{slug}/source", %{"format" => "bpml"})
    [rev] = get_resp_header(conn, "x-paper-rev")
    [view] = get_resp_header(conn, "x-bpml-view")
    {response(conn, 200), rev, view}
  end

  defp push(slug, bpml, rev, view) do
    params = %{"bpml" => bpml, "baseRev" => rev}
    params = if view, do: Map.put(params, "bpmlView", view), else: params
    build_conn() |> authed() |> post("#{@ingest_path}/#{slug}/sync", params)
  end

  defp stored(slug), do: get_in(Content.get_paper(slug).content, ["blocks"])
  defp block(blocks, id), do: Enum.find(blocks, &(&1["id"] == id))

  # A refusal "by name" names the stored list, and writes nothing.
  defp refused_by_name!(slug, before, resp) do
    assert resp.status in [412, 422]
    answer = Jason.decode!(resp.resp_body)
    if resp.status == 422, do: assert(answer["error"]["message"] =~ ~s(block "l1"))
    assert stored(slug) == before
    answer
  end

  defp lands_with_list_bytes!(slug, before, resp) do
    assert json_response(resp, 200)
    assert block(stored(slug), "l1") == block(before, "l1")
  end

  # ── a copy pulled before nested lists printed, without a fingerprint ────────

  for {op, lands?, name} <- [
        {"edit", false,
         "an old copy that edits a nested list is refused by name, writing nothing"},
        {"delete", false,
         "an old copy that deletes a nested list is refused by name, writing nothing"},
        {"move into a section", false,
         "an old copy that moves a nested list into a section is refused by name, writing nothing"},
        {"wrap in a section", false,
         "an old copy that wraps a nested list in a new section is refused by name, writing nothing"},
        {"split", false,
         "an old copy that splits a nested list is refused by name, writing nothing"},
        {"merge another list in", false,
         "an old copy that merges a list into a nested list is refused by name, writing nothing"},
        {"re-id", false,
         "an old copy that gives a nested list a new id is refused by name, writing nothing"},
        {"retype", false,
         "an old copy that turns a nested list into another block type is refused by name, writing nothing"},
        {"reorder", true,
         "an old copy that moves a nested list to another top-level place lands; the list keeps its bytes"},
        {"duplicate", true,
         "an old copy that copies a nested list under a new id lands; the stored list keeps its bytes"}
      ] do
    @op op
    @lands lands?
    test name do
      slug = paper!()
      before = stored(slug)
      {bpml, rev, _view} = pull!(slug)
      resp = push(slug, edit(@op, old_text(bpml)), rev, nil)

      if @lands,
        do: lands_with_list_bytes!(slug, before, resp),
        else: refused_by_name!(slug, before, resp)
    end
  end

  test "an old copy with its fingerprint is refused for every op, writing nothing" do
    for {op, _lands?} <- @ops do
      slug = paper!()
      before = stored(slug)
      {bpml, rev, _view} = pull!(slug)
      old = old_text(bpml)
      refused_by_name!(slug, before, push(slug, edit(op, old), rev, BpmlView.hash(old)))
    end
  end

  test "a typed print mark does not make an old copy current for nested lists: each op is answered as main answers it" do
    for {op, lands?} <- @ops do
      slug = paper!()
      before = stored(slug)
      {bpml, rev, _view} = pull!(slug)
      resp = push(slug, edit(op, bpml |> old_text() |> mark()), rev, nil)

      if lands?,
        do: lands_with_list_bytes!(slug, before, resp),
        else: refused_by_name!(slug, before, resp)
    end
  end

  # ── a copy of this pull ───────────────────────────────────────────────────────

  test "a copy of this pull pushed without its fingerprint is answered for every op as main answers an old copy" do
    for {op, lands?} <- @ops do
      slug = paper!()
      before = stored(slug)
      {bpml, rev, _view} = pull!(slug)
      resp = push(slug, edit(op, bpml), rev, nil)

      if lands?,
        do: lands_with_list_bytes!(slug, before, resp),
        else: refused_by_name!(slug, before, resp)
    end
  end

  test "a push without the fingerprint that would change a nested list says to update bp" do
    slug = paper!()
    {bpml, rev, _view} = pull!(slug)

    answer = push(slug, edit("edit", bpml), rev, nil) |> json_response(422)
    assert answer["error"]["code"] == WriteWall.code()
    assert answer["error"]["hint"] == "update bp, then bp paper pull and make your edit again"
  end

  test "a copy of this pull with its fingerprint lands every op" do
    for {op, _lands?} <- @ops do
      slug = paper!()
      {bpml, rev, view} = pull!(slug)
      assert %{"ok" => true} = push(slug, edit(op, bpml), rev, view) |> json_response(200)
    end
  end

  test "a copy of this pull with its fingerprint edits the list and keeps every level and item id" do
    slug = paper!()
    {bpml, rev, view} = pull!(slug)
    copy = String.replace(bpml, "Flat sibling", "Flat sibling, edited")

    assert %{"ok" => true} = push(slug, copy, rev, view) |> json_response(200)

    assert block(stored(slug), "l1") ==
             put_in(nested(), ["items", Access.at(1)], text("Flat sibling, edited"))
  end

  defp edit(op, bpml) do
    {^op, f} = List.keyfind(ops(), op, 0)
    f.(bpml)
  end
end
