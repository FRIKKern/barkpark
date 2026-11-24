defmodule BarkparkWeb.BulldocsBpmlWriteWallTest do
  @moduledoc """
  A BPML push may not change what its pull did not show. Each case pulls a
  Paper through the public source route, pushes the bytes back (edited or
  not) and reads the stored row.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Content, LabelFixtures, Repo, Tenancy}
  alias Barkpark.Content.Papers.BpmlView

  @ds "production"
  @token "barkpark-test-ingest-token"
  @ingest_path "/v1/plugins/bulldocs/papers"

  defp t(v), do: %{"type" => "text", "value" => v}

  defp slug(name), do: "bpml-write-wall-#{name}-#{System.unique_integer([:positive])}"

  defp paper!(slug, blocks) do
    {:ok, paper} = Content.upsert_paper(LabelFixtures.paper_attrs(%{slug: slug, blocks: blocks}))
    content = paper.content |> Map.put("blocks", blocks) |> Map.delete("body_html")
    paper |> Ecto.Changeset.change(content: content) |> Repo.update!()
  end

  defp paper_schema!(fields) do
    scope = [
      workspace_id: Tenancy.get_default_workspace().id,
      project_id: Tenancy.get_default_project().id
    ]

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "paper", "title" => "Papers", "visibility" => "public", "fields" => fields},
        @ds,
        scope
      )
  end

  defp pull(slug) do
    resp = get(scoped_conn(), "/papers/#{slug}/source", %{"format" => "bpml"})
    [rev] = get_resp_header(resp, "x-paper-rev")
    {response(resp, 200), rev}
  end

  defp sync(slug, bpml, rev) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{@token}")
    |> put_req_header("content-type", "application/json")
    |> post("#{@ingest_path}/#{slug}/sync", %{"bpml" => bpml, "baseRev" => rev})
  end

  defp stored_blocks(slug), do: get_in(Content.get_paper(slug).content, ["blocks"])

  setup do
    LabelFixtures.register_tags!(@ds)
    :ok
  end

  test "an unedited push of a Paper whose pull redacts a nested block field keeps the stored field" do
    paper_schema!([
      %{"name" => "title", "type" => "string"},
      %{
        "name" => "blocks",
        "type" => "array",
        "of" => [
          %{
            "type" => "object",
            "fields" => [%{"name" => "text", "type" => "string", "private" => true}]
          }
        ]
      }
    ])

    slug = slug("redacted")
    heading = %{"id" => "h", "type" => "heading", "level" => 2, "text" => "PRIVATE_HEADING"}
    paper!(slug, [heading, %{"id" => "p", "type" => "paragraph", "content" => [t("Visible.")]}])

    {bpml, rev} = pull(slug)
    assert bpml =~ ~s(<h2 id="h"></h2>)

    sync(slug, bpml, rev)

    assert [^heading, _] = stored_blocks(slug)
  end

  # ── what a push may not change ──────────────────────────────────────────────

  # A paragraph whose `role` the text cannot spell: shown text, unshown role.
  defp lede,
    do: %{"id" => "lede", "type" => "paragraph", "role" => "lede", "content" => [t("Lede.")]}

  defp plain, do: %{"id" => "p1", "type" => "paragraph", "content" => [t("Plain.")]}

  defp pushed(slug, edit) do
    {bpml, rev} = pull(slug)
    sync(slug, edit.(bpml), rev)
  end

  defp refused!(resp, block) do
    body = json_response(resp, 422)
    assert body["error"]["code"] == "bpml_unshown"
    assert body["error"]["message"] =~ block
    body
  end

  defp at_path!(body, path) do
    assert body["error"]["message"] =~ path, inspect(body["error"])
    assert path in body["error"]["paths"], inspect(body["error"]["paths"])
  end

  test "editing a block that holds unshown content is refused; the block stays" do
    slug = slug("edit")
    paper!(slug, [lede(), plain()])

    resp = pushed(slug, &String.replace(&1, "Lede.", "Lede, edited."))

    assert refused!(resp, ~s(block "lede"))["error"]["message"] =~ "blocks[0].role"
    assert [lede(), plain()] == stored_blocks(slug)
  end

  test "deleting a block that holds unshown content is refused" do
    slug = slug("delete")
    paper!(slug, [lede(), plain()])

    pushed(slug, &String.replace(&1, ~s(<p id="lede">Lede.</p>), ""))
    |> refused!(~s(block "lede"))
    |> at_path!("blocks[0].role")

    assert [lede(), plain()] == stored_blocks(slug)
  end

  test "re-adding a block that holds unshown content without its id is refused" do
    slug = slug("re-add")
    paper!(slug, [lede(), plain()])

    pushed(slug, &String.replace(&1, ~s(<p id="lede">), "<p>")) |> refused!(~s(block "lede"))
    assert [lede(), plain()] == stored_blocks(slug)
  end

  test "pushing the id of a block that holds unshown content twice is refused" do
    slug = slug("twice")
    paper!(slug, [lede(), plain()])

    resp =
      pushed(slug, &String.replace(&1, ~s(<p id="p1">Plain.</p>), ~s(<p id="lede">Lede.</p>)))

    assert resp.status == 422
    assert [lede(), plain()] == stored_blocks(slug)
  end

  # The pull prints a list item's words and child lists but not a child
  # paragraph, so an edit of the list may not write it back without it.
  test "editing a list whose item holds child blocks the pull never showed is refused; the children stay" do
    slug = slug("item-children")

    list = %{
      "id" => "l",
      "type" => "list",
      "items" => [
        %{
          "id" => "i1",
          "content" => [t("parent")],
          "children" => [
            %{"type" => "list", "items" => [[t("NESTED")]]},
            %{"type" => "paragraph", "content" => [t("CHILD PARAGRAPH")]}
          ]
        }
      ]
    }

    paper!(slug, [list, plain()])

    pushed(slug, &String.replace(&1, "parent", "parent, edited"))
    |> refused!(~s(block "l"))
    |> at_path!("blocks[0].items[0].children[1]")

    assert [list, plain()] == stored_blocks(slug)
  end

  test "an id-less stored block holding an item child is refused, not lost" do
    slug = slug("idless")

    list = %{
      "type" => "list",
      "items" => [
        %{
          "content" => [t("parent")],
          "children" => [
            %{
              "type" => "list",
              "items" => [%{"id" => "child", "content" => [t("CHILD")], "audit" => true}]
            }
          ]
        }
      ]
    }

    paper!(slug, [list, plain()])

    pushed(slug, &String.replace(&1, "Plain.", "Plain, edited."))
    |> refused!("block 1 (it has no id)")

    assert [list, plain()] == stored_blocks(slug)
  end

  test "a templated title edit by BPML is refused" do
    slug = slug("title")
    title = hd(Barkpark.Content.Papers.Template.template_blocks("Templated title"))
    paper!(slug, [title, plain()])

    pushed(slug, &String.replace(&1, ">Templated title<", ">A new title<"))
    |> refused!(~s(block "tpl-title"))

    assert [^title, _] = stored_blocks(slug)
  end

  test "a mark node holding more than its children is unshown, so editing it is refused" do
    slug = slug("mark-node")
    node = %{"type" => "strong", "children" => [t("seen")], "value" => "HIDDEN"}
    para = %{"id" => "m", "type" => "paragraph", "content" => [t("Text "), node]}
    paper!(slug, [para])

    pushed(slug, &String.replace(&1, "Text ", "Text, edited ")) |> refused!(~s(block "m"))
    assert [^para] = stored_blocks(slug)
  end

  test "setting a description the pull hid is refused" do
    paper_schema!([
      %{"name" => "title", "type" => "string"},
      %{"name" => "description", "type" => "text", "private" => true}
    ])

    slug = slug("hidden-description")
    paper!(slug, [plain()])
    before = Content.get_paper(slug).content["description"]

    resp =
      pushed(slug, fn bpml ->
        String.replace(bpml, "<meta>", "<meta>\n    <description>Replaced.</description>")
      end)

    assert json_response(resp, 422)["error"]["code"] == "bpml_unshown"
    assert Content.get_paper(slug).content["description"] == before
  end

  test "a copy printed from another row cannot change the written row's unshown content" do
    slug = slug("other-row")
    paper!(slug, [lede(), plain()])
    {_published, rev} = pull(slug)

    # A copy that shows the same block ids with other text (a draft, say).
    draft = [Map.put(Map.delete(lede(), "role"), "content", [t("Draft text.")]), plain()]

    copy =
      Barkpark.PortableDoc.Bpml.print_paper(%{"slug" => slug, "title" => slug, "blocks" => draft})

    sync(slug, copy, rev) |> refused!(~s(block "lede"))
    assert [lede(), plain()] == stored_blocks(slug)
  end

  # ── what a push may still do ────────────────────────────────────────────────

  test "an unedited push of a Paper with unshown content changes nothing" do
    slug = slug("unchanged")
    paper!(slug, [lede(), plain()])

    assert json_response(pushed(slug, & &1), 200)["unchanged"] == true
    assert [lede(), plain()] == stored_blocks(slug)
  end

  test "reordering blocks keeps a block with unshown content byte-equal" do
    slug = slug("reorder")
    paper!(slug, [lede(), plain()])

    json_response(
      pushed(slug, fn bpml ->
        bpml
        |> String.replace(~s(  <p id="lede">Lede.</p>\n), "")
        |> String.replace(
          ~s(<p id="p1">Plain.</p>),
          ~s(<p id="p1">Plain.</p>\n  <p id="lede">Lede.</p>)
        )
      end),
      200
    )

    assert [plain(), lede()] == stored_blocks(slug)
  end

  test "deleting and editing shown-only blocks beside one with unshown content lands" do
    slug = slug("beside")
    other = %{"id" => "p2", "type" => "paragraph", "content" => [t("Other.")]}
    paper!(slug, [lede(), plain(), other])

    json_response(
      pushed(slug, fn bpml ->
        bpml
        |> String.replace("Plain.", "Plain, edited.")
        |> String.replace(~s(  <p id="p2">Other.</p>\n), "")
      end),
      200
    )

    assert [kept, %{"id" => "p1", "content" => [%{"value" => "Plain, edited."}]}] =
             stored_blocks(slug)

    assert kept == lede()
  end

  # ── the view a copy was pulled from ─────────────────────────────────────────

  defp pull_view(slug) do
    resp = get(scoped_conn(), "/papers/#{slug}/source", %{"format" => "bpml"})
    [rev] = get_resp_header(resp, "x-paper-rev")
    [view] = get_resp_header(resp, "x-bpml-view")
    {response(resp, 200), rev, view}
  end

  defp sync_view(slug, bpml, rev, view) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{@token}")
    |> put_req_header("content-type", "application/json")
    |> post("#{@ingest_path}/#{slug}/sync", %{
      "bpml" => bpml,
      "baseRev" => rev,
      "bpmlView" => view
    })
  end

  defp nested_private!(private?) do
    paper_schema!([
      %{"name" => "title", "type" => "string"},
      %{
        "name" => "blocks",
        "type" => "array",
        "of" => [
          %{
            "type" => "object",
            "fields" => [%{"name" => "text", "type" => "string", "private" => private?}]
          }
        ]
      }
    ])
  end

  defp heading, do: %{"id" => "h", "type" => "heading", "level" => 2, "text" => "PRIVATE_HEADING"}

  test "a push whose pull no longer matches the row's view answers 412 (a field made public at the same rev)" do
    nested_private!(true)
    slug = slug("view-changed")
    paper!(slug, [heading(), plain()])
    {bpml, rev, view} = pull_view(slug)

    nested_private!(false)
    resp = sync_view(slug, String.replace(bpml, "Plain.", "Plain, edited."), rev, view)

    assert json_response(resp, 412)["error"]["code"] == "precondition_failed"
    assert [heading(), plain()] == stored_blocks(slug)
  end

  test "a forged view fingerprint answers 412, never the fallback" do
    slug = slug("forged")
    paper!(slug, [plain()])
    {bpml, rev, _view} = pull_view(slug)

    resp = sync_view(slug, String.replace(bpml, "Plain.", "Plain, edited."), rev, "forged")
    assert json_response(resp, 412)["error"]["code"] == "precondition_failed"
  end

  test "an applied push answers the new fingerprint, and the next push with it lands" do
    slug = slug("next-push")
    paper!(slug, [plain()])
    {bpml, rev, view} = pull_view(slug)

    first =
      sync_view(slug, String.replace(bpml, "Plain.", "One."), rev, view) |> json_response(200)

    assert is_binary(first["bpmlView"]) and first["bpmlView"] != view

    second =
      sync_view(
        slug,
        String.replace(first["bpml"], "One.", "Two."),
        first["rev"],
        first["bpmlView"]
      )

    assert json_response(second, 200)["ok"] == true
    assert [%{"content" => [%{"value" => "Two."}]}] = stored_blocks(slug)
  end

  # KNOWN GAP, kept on purpose: a copy without the fingerprint (a bp from
  # before it) gets the block rules alone. When the view changed at the same
  # rev, the rules see the field as shown, and the push writes over it.
  test "without a fingerprint, a field made public between pull and push is written over (known gap)" do
    nested_private!(true)
    slug = slug("no-fingerprint")
    paper!(slug, [heading(), plain()])
    {bpml, rev} = pull(slug)

    nested_private!(false)
    json_response(sync(slug, bpml, rev), 200)

    assert [%{"id" => "h", "text" => ""}, _] = stored_blocks(slug)
  end

  # ── what an answer may carry, and what the write keeps ─────────────────────

  test "the answer to an applied push is the pull's view: no hidden text, and its fingerprint is of those bytes" do
    nested_private!(true)
    slug = slug("answer-view")
    paper!(slug, [heading(), plain()])
    {bpml, rev, view} = pull_view(slug)

    answer =
      sync_view(slug, String.replace(bpml, "Plain.", "One."), rev, view) |> json_response(200)

    # The title attribute still carries the heading text, in the pull too
    # (task-f08c1d1a0144b4a2, its own PR); the block itself is redacted.
    refute answer["bpml"] =~ ~s(<h2 id="h">PRIVATE_HEADING)
    assert answer["bpmlView"] == BpmlView.hash(answer["bpml"])
    assert {answer["bpml"], answer["rev"], answer["bpmlView"]} == pull_view(slug)

    again =
      sync_view(
        slug,
        String.replace(answer["bpml"], "One.", "Two."),
        answer["rev"],
        answer["bpmlView"]
      )

    assert json_response(again, 200)["ok"] == true

    assert [%{"text" => "PRIVATE_HEADING"}, %{"content" => [%{"value" => "Two."}]}] =
             stored_blocks(slug)
  end

  test "the answer to a push that creates a Paper is the pull's view" do
    # A full document (meta included) printed from another Paper, gone before
    # the push so it is no near-duplicate, and before the field turns private.
    source = slug("create-source")
    paper!(source, [heading(), plain()])
    {bpml, _rev} = pull(source)
    Repo.delete!(Content.get_paper(source))
    nested_private!(true)

    slug = slug("create-view")
    answer = sync(slug, String.replace(bpml, source, slug), "0") |> json_response(200)
    assert answer["created"] == true
    refute answer["bpml"] =~ ~s(<h2 id="h">PRIVATE_HEADING)
    assert answer["bpmlView"] == BpmlView.hash(answer["bpml"])
  end

  test "a heading run holding a key besides type, value and marks is unshown, so editing it is refused" do
    run = %{"type" => "text", "value" => "Head", "_key" => "k1"}
    head = %{"id" => "h", "type" => "heading", "level" => 2, "content" => [run]}
    slug = slug("plain-key")
    paper!(slug, [head, plain()])

    {bpml, rev} = pull(slug)
    refused!(sync(slug, String.replace(bpml, ">Head<", ">Head edited<"), rev), ~s(block "h"))
    assert hd(stored_blocks(slug)) == head
  end

  test "a code run holding an unknown key is unshown, so editing it is refused" do
    code = %{
      "id" => "c",
      "type" => "code",
      "code" => [%{"type" => "text", "value" => "x = 1", "note" => "KEEP"}]
    }

    slug = slug("plain-note")
    paper!(slug, [code])

    {bpml, rev} = pull(slug)
    refused!(sync(slug, String.replace(bpml, "x = 1", "x = 2"), rev), ~s(block "c"))
    assert stored_blocks(slug) == [code]
  end

  test "a protected block stored in an older shape keeps its bytes when a neighbour is edited" do
    list = %{
      "id" => "l",
      "type" => "list",
      "role" => "keep",
      "items" => ["bare a", %{"text" => "text b"}]
    }

    slug = slug("reshape")
    paper!(slug, [list, plain()])

    {bpml, rev} = pull(slug)
    json_response(sync(slug, String.replace(bpml, "Plain.", "Plain, edited."), rev), 200)

    assert [^list, %{"id" => "p1", "content" => [%{"value" => "Plain, edited."}]}] =
             stored_blocks(slug)
  end

  test "a stored repeated id is named as stored, not as pushed" do
    a = %{"id" => "d", "type" => "paragraph", "content" => [t("A.")]}
    b = %{"id" => "d", "type" => "paragraph", "content" => [t("B.")]}
    slug = slug("stored-dup")
    paper!(slug, [a, b])

    {bpml, rev} = pull(slug)
    error = json_response(sync(slug, String.replace(bpml, "B.", "B edited."), rev), 422)["error"]
    assert error["message"] =~ "stored paper"
    assert stored_blocks(slug) == [a, b]
  end
end
