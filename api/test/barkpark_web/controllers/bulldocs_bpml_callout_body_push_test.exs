defmodule BarkparkWeb.BulldocsBpmlCalloutBodyPushTest do
  @moduledoc """
  `bp paper pull` → edit → `bp paper push` of a Paper whose callout has a body
  (task-4c27c15194ae9369), through the routes bp calls. Every Paper is a
  scratch slug the test writes; the blocks go straight to the row, as the
  paper editor stores them.

  An "old copy" is the text a pull gave before callouts printed their body:
  the callout inline, and no `print="2"` on `<paper>`.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.Content
  alias Barkpark.LabelFixtures
  alias Barkpark.PortableDoc.Bpml.Canonical
  alias Barkpark.Repo

  @token "barkpark-test-ingest-token"
  @ingest_path "/v1/plugins/bulldocs/papers"

  defp text(value), do: [%{"type" => "text", "value" => value}]
  defp p(id, value), do: %{"id" => id, "type" => "paragraph", "content" => text(value)}

  defp callout(id, words, body) do
    %{
      "id" => id,
      "type" => "callout",
      "tone" => "info",
      "content" => text(words),
      "slots" => %{"body" => body}
    }
  end

  defp blocks do
    [
      p("p1", "Opening paragraph."),
      callout("c1", "Read this first.", [p("c1-a", "The body paragraph.")]),
      p("p2", "Closing paragraph.")
    ]
  end

  @structured """
    <callout id="c1" tone="info">
      <content>Read this first.</content>
      <slot name="body">
        <p id="c1-a">The body paragraph.</p>
      </slot>
    </callout>
  """

  @inline ~s(  <callout id="c1" tone="info">Read this first.</callout>\n)

  defp authed(conn) do
    conn
    |> put_req_header("authorization", "Bearer #{@token}")
    |> put_req_header("content-type", "application/json")
  end

  defp with_blocks!(slug, blocks) do
    {:ok, paper} =
      Content.upsert_paper(
        LabelFixtures.paper_attrs(%{
          slug: slug,
          blocks: [%{"id" => "seed", "type" => "paragraph", "content" => text("Seed.")}]
        })
      )

    content = paper.content |> Map.put("blocks", blocks) |> Map.delete("body_html")
    paper |> Ecto.Changeset.change(content: content) |> Repo.update!()
    slug
  end

  defp pull!(slug) do
    conn = get(build_conn(), "/papers/#{slug}/source", %{"format" => "bpml"})
    [rev] = get_resp_header(conn, "x-paper-rev")
    {response(conn, 200), rev}
  end

  defp push_copy(slug, bpml, rev) do
    build_conn()
    |> authed()
    |> post("#{@ingest_path}/#{slug}/sync", %{"bpml" => bpml, "baseRev" => rev})
  end

  defp stored(slug), do: get_in(Content.get_paper(slug).content, ["blocks"])
  defp stored_callout(slug), do: Enum.find(stored(slug), &(&1["id"] == "c1"))

  defp old_copy(bpml),
    do: bpml |> String.replace(~s( print="2"), "") |> String.replace(@structured, @inline)

  defp new_slug, do: "callout-body-#{System.unique_integer([:positive])}"

  # A refusal path such as "blocks[1].blocks[0].slots", walked through the
  # stored blocks in their canonical spelling, reaches a map.
  defp resolves!(slug, path) do
    at =
      Regex.scan(~r/([^.\[\]]+)|\[(\d+)\]/, path)
      |> Enum.reduce(%{"blocks" => Canonical.normalize(stored(slug))}, fn
        [_, "", i], list when is_list(list) -> Enum.at(list, String.to_integer(i))
        [_, key], map when is_map(map) -> Map.get(map, key)
        _, _ -> nil
      end)

    assert is_map(at), "#{path} does not resolve in the stored blocks"
  end

  test "the pull prints the body and marks the Paper" do
    {bpml, _rev} = pull!(with_blocks!(new_slug(), blocks()))
    assert bpml =~ ~s(print="2")
    assert bpml =~ @structured
  end

  # P1
  test "an old copy pushed untouched keeps the stored body, and says so in one line" do
    slug = with_blocks!(new_slug(), blocks())
    {bpml, rev} = pull!(slug)
    before = stored(slug)

    answer = push_copy(slug, old_copy(bpml), rev) |> json_response(200)
    assert stored(slug) == before

    assert [note] = answer["notes"]
    assert note =~ "callout c1 kept its stored body"
    assert note =~ ~s(take <slot name="body"> out of the structured form)
  end

  test "an old copy that edits another block applies it and keeps the callout's body" do
    slug = with_blocks!(new_slug(), blocks())
    {bpml, rev} = pull!(slug)

    edited = bpml |> old_copy() |> String.replace("Closing paragraph.", "Closing words.")
    assert %{"ok" => true} = push_copy(slug, edited, rev) |> json_response(200)
    assert stored_callout(slug)["slots"]["body"] == [p("c1-a", "The body paragraph.")]
    assert Enum.at(stored(slug), 2)["content"] == text("Closing words.")
  end

  # P2
  test "an old copy that edits the callout is refused by name, writing nothing" do
    slug = with_blocks!(new_slug(), blocks())
    {bpml, rev} = pull!(slug)
    before = stored(slug)

    edited = bpml |> old_copy() |> String.replace("Read this first.", "Read this.")
    answer = push_copy(slug, edited, rev) |> json_response(422)

    assert answer["error"]["code"] == "bpml_stale_copy"
    assert answer["error"]["message"] =~ "callout c1 has a body your copy was pulled without"
    assert answer["error"]["paths"] == ["blocks[1].slots"]
    Enum.each(answer["error"]["paths"], &resolves!(slug, &1))
    assert stored(slug) == before
  end

  test "an old copy that edits a callout inside a container is refused with the body's stored path" do
    callout = callout("c1", "Read this first.", [p("c1-a", "The body paragraph.")])
    box = %{"id" => "x1", "type" => "expandable", "summary" => "More", "children" => [callout]}
    slug = with_blocks!(new_slug(), [p("p1", "Opening paragraph."), box])
    {bpml, rev} = pull!(slug)
    before = stored(slug)

    structured =
      ~r{<callout id="c1" tone="info">\s*<content>Read this first\.</content>\s*<slot name="body">.*?</slot>\s*</callout>}s

    edited =
      bpml
      |> String.replace(~s( print="2"), "")
      |> String.replace(structured, ~s(<callout id="c1" tone="info">Read this.</callout>))

    answer = push_copy(slug, edited, rev) |> json_response(422)

    assert answer["error"]["code"] == "bpml_stale_copy"
    assert answer["error"]["message"] =~ "callout c1 has a body your copy was pulled without"
    assert answer["error"]["paths"] == ["blocks[1].blocks[0].slots"]
    Enum.each(answer["error"]["paths"], &resolves!(slug, &1))
    assert stored(slug) == before
  end

  test "a callout inside a callout's body lies under the outer body's path" do
    inner = callout("c2", "Inner.", [p("c2-a", "Inner body.")])
    outer = callout("c1", "Read this first.", [p("c1-a", "The body paragraph."), inner])
    slug = with_blocks!(new_slug(), [p("p1", "Opening paragraph."), outer])
    {bpml, rev} = pull!(slug)
    before = stored(slug)

    edited =
      bpml
      |> String.replace(~s( print="2"), "")
      |> String.replace(
        ~r{<callout id="c1".*</callout>}s,
        ~s(<callout id="c1" tone="info">Read this.</callout>)
      )

    answer = push_copy(slug, edited, rev) |> json_response(422)

    assert answer["error"]["code"] == "bpml_stale_copy"

    assert answer["error"]["message"] =~
             "callout c1, callout c2 have a body your copy was pulled without"

    assert answer["error"]["paths"] == ["blocks[1].slots"]
    inner_body = "blocks[1].slots.body[1].slots"
    resolves!(slug, inner_body)
    assert String.starts_with?(inner_body, hd(answer["error"]["paths"]))
    assert stored(slug) == before
  end

  # P3
  test "in a marked copy the inline form keeps an unchanged body, and refuses a changed one" do
    slug = with_blocks!(new_slug(), blocks())
    {bpml, rev} = pull!(slug)
    before = stored(slug)

    inline = String.replace(bpml, @structured, @inline)
    answer = push_copy(slug, inline, rev) |> json_response(200)
    assert stored(slug) == before
    assert [note] = answer["notes"]
    assert note =~ "callout c1 kept its stored body"

    changed = String.replace(inline, "Read this first.", "Read this.")
    refused = push_copy(slug, changed, rev) |> json_response(422)
    assert refused["error"]["code"] == "bpml_inline_body"
    assert stored(slug) == before
  end

  # P4
  test "in a marked copy, taking the slot out deletes the body" do
    slug = with_blocks!(new_slug(), blocks())
    {bpml, rev} = pull!(slug)

    deleted =
      String.replace(bpml, @structured, """
        <callout id="c1" tone="info">
          <content>Read this first.</content>
        </callout>
      """)

    assert %{"ok" => true} = push_copy(slug, deleted, rev) |> json_response(200)
    refute Map.has_key?(stored_callout(slug), "slots")
    assert stored_callout(slug)["content"] == text("Read this first.")
  end

  test "in a marked copy, taking <content> out deletes the content" do
    slug = with_blocks!(new_slug(), blocks())
    {bpml, rev} = pull!(slug)

    assert %{"ok" => true} =
             push_copy(
               slug,
               String.replace(bpml, "    <content>Read this first.</content>\n", ""),
               rev
             )
             |> json_response(200)

    refute Map.has_key?(stored_callout(slug), "content")
    assert stored_callout(slug)["slots"]["body"] == [p("c1-a", "The body paragraph.")]
  end

  # P5
  describe "a callout BPML cannot write" do
    setup do
      image = %{"id" => "c1-i", "type" => "image", "src" => "/m/a.png", "alt" => "Bridge"}

      stored = [
        p("p1", "Opening paragraph."),
        callout("c1", "Look.", [image]),
        callout("c2", "Other words.", [p("c2-a", "Other body.")])
      ]

      slug = with_blocks!(new_slug(), stored)
      {bpml, rev} = pull!(slug)
      %{slug: slug, bpml: bpml, rev: rev, before: stored(slug)}
    end

    @kept_line ~s(  <kept id="c1" type="callout" why="callout c1: its body holds a block ) <>
                 ~s(BPML cannot write \(image\)"/>\n)

    test "pulls as one <kept> line, and an unedited push keeps its bytes", ctx do
      assert ctx.bpml =~ @kept_line
      assert %{"ok" => true} = push_copy(ctx.slug, ctx.bpml, ctx.rev) |> json_response(200)
      assert stored(ctx.slug) == ctx.before
    end

    test "may move between top-level positions, and keeps its bytes", ctx do
      moved =
        ctx.bpml
        |> String.replace(@kept_line, "")
        |> String.replace(~s(  <p id="p1">), @kept_line <> ~s(  <p id="p1">))

      assert %{"ok" => true} = push_copy(ctx.slug, moved, ctx.rev) |> json_response(200)
      assert [%{"id" => "c1"} = kept, %{"id" => "p1"}, _] = stored(ctx.slug)
      assert kept == Enum.find(ctx.before, &(&1["id"] == "c1"))
    end

    test "is refused when removed, or when its id or type changed", ctx do
      edits = [
        String.replace(ctx.bpml, @kept_line, ""),
        String.replace(ctx.bpml, ~s(<kept id="c1"), ~s(<kept id="c2")),
        String.replace(ctx.bpml, ~s(<kept id="c1"), ~s(<kept id="p1")),
        String.replace(ctx.bpml, ~s(type="callout" why), ~s(type="section" why))
      ]

      for edited <- edits do
        refute edited == ctx.bpml
        answer = push_copy(ctx.slug, edited, ctx.rev) |> json_response(422)
        assert answer["error"]["code"] == "bpml_kept"
        assert stored(ctx.slug) == ctx.before
      end
    end

    test "is refused when moved into another callout's body", ctx do
      moved =
        ctx.bpml
        |> String.replace(@kept_line, "")
        |> String.replace(
          ~s(<p id="c2-a">Other body.</p>),
          ~s(<p id="c2-a">Other body.</p>\n) <> String.trim(@kept_line)
        )

      answer = push_copy(ctx.slug, moved, ctx.rev) |> json_response(422)
      assert answer["error"]["code"] == "bpml_kept"
      assert stored(ctx.slug) == ctx.before
    end

    test "an old copy, pulled before <kept> lines, lands untouched or edited elsewhere; each body keeps its bytes",
         ctx do
      old =
        ctx.bpml
        |> String.replace(~s( print="2"), "")
        |> String.replace(@kept_line, ~s(  <callout id="c1" tone="info">Look.</callout>\n))
        |> then(
          &Regex.replace(
            ~r/  <callout id="c2".*?<\/callout>\n/s,
            &1,
            ~s(  <callout id="c2" tone="info">Other words.</callout>\n)
          )
        )

      refute old =~ "<kept"
      edited = String.replace(old, "Opening paragraph.", "Opening words.")

      for copy <- [old, edited] do
        assert %{"ok" => true} = push_copy(ctx.slug, copy, ctx.rev) |> json_response(200)
        assert tl(stored(ctx.slug)) == tl(ctx.before)
      end

      assert hd(stored(ctx.slug))["content"] == text("Opening words.")
    end

    test "an old copy, pulled before <kept> lines, that deletes the callout is refused by name",
         ctx do
      old =
        ctx.bpml
        |> String.replace(~s( print="2"), "")
        |> String.replace(@kept_line, "")

      answer = push_copy(ctx.slug, old, ctx.rev) |> json_response(422)
      assert answer["error"]["code"] == "bpml_stale_copy"
      assert answer["error"]["message"] =~ "callout c1 has a body your copy was pulled without"
      assert stored(ctx.slug) == ctx.before
    end

    test "bp paper push --check passes the pulled copy, and fails an edited <kept> by name",
         ctx do
      assert %{"valid" => true, "violations" => []} = check(ctx.bpml)

      edited = String.replace(ctx.bpml, ~s(<kept id="c1"), ~s(<kept id="c2"))
      assert %{"valid" => false, "violations" => [%{"code" => "bpml_kept"}]} = check(edited)
      assert stored(ctx.slug) == ctx.before
    end
  end

  defp check(bpml) do
    build_conn()
    |> authed()
    |> post("#{@ingest_path}/validate", %{"bpml" => bpml})
    |> json_response(200)
  end

  test "bp paper push --check fails a stale copy as the push would" do
    {bpml, _rev} = pull!(with_blocks!(new_slug(), blocks()))
    edited = bpml |> old_copy() |> String.replace("Read this first.", "Read this.")
    assert %{"valid" => false, "violations" => [%{"code" => "bpml_stale_copy"}]} = check(edited)
  end

  test "a --check of a copy naming no stored Paper answers as before" do
    copy = ~s(<paper slug="#{new_slug()}" title="Fresh">\n  <p id="p1">Hello.</p>\n</paper>\n)
    # A new Paper's only shortcoming here is the wall's: it has no description.
    assert %{"valid" => false, "violations" => [only]} = check(copy)
    assert only["code"] == "label_spine"
    assert only["details"]["field"] == "description"

    kept = String.replace(copy, ~s(<p id="p1">Hello.</p>), ~s(<kept id="c1" type="callout"/>))

    assert check(kept)["violations"] == [
             %{
               "code" => "bpml-kept",
               "line" => 1,
               "message" => ~s(<kept id="c1"> stands for a block this text cannot show),
               "hint" =>
                 "push it unchanged to the Paper it was pulled from; edit that block in Studio"
             }
           ]
  end

  test "the inline form over a body with no content key keeps the block byte for byte" do
    bodied = %{
      "id" => "c1",
      "type" => "callout",
      "tone" => "info",
      "slots" => %{"body" => [p("c1-a", "The body paragraph.")]}
    }

    slug = with_blocks!(new_slug(), [p("p1", "Opening paragraph."), bodied])
    {bpml, rev} = pull!(slug)
    before = stored(slug)
    refute bpml =~ "<content>"

    inline =
      Regex.replace(
        ~r/  <callout id="c1".*?<\/callout>\n/s,
        bpml,
        ~s(  <callout id="c1" tone="info"></callout>\n)
      )

    answer = push_copy(slug, inline, rev) |> json_response(200)
    assert answer["unchanged"] == true
    assert [_note] = answer["notes"]
    assert stored(slug) == before
  end

  # P6
  test "a copy whose print mark was deleted by hand is an old copy, never a delete" do
    slug = with_blocks!(new_slug(), blocks())
    {bpml, rev} = pull!(slug)
    before = stored(slug)
    unmarked = String.replace(bpml, ~s( print="2"), "")

    no_slot =
      String.replace(unmarked, @structured, """
        <callout id="c1" tone="info">
          <content>Read this first.</content>
        </callout>
      """)

    # The structured form does not spell as the old printer did: refused.
    answer = push_copy(slug, unmarked, rev) |> json_response(422)
    assert answer["error"]["code"] == "bpml_stale_copy"
    assert stored(slug) == before

    # With the slot taken out it does, so it is an untouched old copy: the body stays.
    answer = push_copy(slug, no_slot, rev) |> json_response(200)
    assert stored(slug) == before
    assert [_note] = answer["notes"]
  end

  test "a new Paper pushed with a <kept> line is refused" do
    bpml = ~s(<paper slug="x" title="X">\n  <kept id="c1" type="callout" why="w"/>\n</paper>\n)
    slug = new_slug()
    bpml = String.replace(bpml, ~s(slug="x"), ~s(slug="#{slug}"))
    answer = push_copy(slug, bpml, "0") |> json_response(422)
    assert answer["error"]["code"] == "bpml"
    assert Content.get_paper(slug) == nil
  end
end
