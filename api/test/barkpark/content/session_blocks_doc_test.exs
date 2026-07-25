defmodule Barkpark.Content.SessionBlocksDocTest do
  use Barkpark.DataCase, async: false
  alias Barkpark.Content

  @dataset "production"

  # The brief's Interfaces line: "Consumes: session schema from Task 1
  # (integration test registers it)." Mirrors the
  # `tasks_controller_test.exs` `register_schemas!/1` convention. The
  # write path itself doesn't require this (BlockOps bypasses plugin-level
  # schema validation — see the pdd-t3 doctrine comment in block_ops.ex), but
  # registering it is what the brief intended and keeps the field-encryption
  # chokepoint's schema lookup (`encrypt_blocks_for_type/4`) resolving a real
  # schema instead of `{:error, :not_found}`.
  setup do
    for schema_def <- Barkpark.Plugins.Bulldocs.register_schemas([]),
        schema_def.name == "session" do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, [])
    end

    :ok
  end

  test "blocks_types is the closed whitelist" do
    assert Content.blocks_types() == ["paper", "session"]
    assert Content.blocks_type?("session")
    refute Content.blocks_type?("post")
  end

  test "upsert_blocks_doc rejects non-whitelist types" do
    assert {:error, :not_a_blocks_type} =
             Content.upsert_blocks_doc("post", %{"slug" => "nope", "blocks" => []})
  end

  test "every member of blocks_types/0 is accepted by upsert_blocks_doc" do
    for type <- Content.blocks_types() do
      attrs = minimal_valid_attrs(type, "whitelist-accepts-#{type}")
      assert {:ok, doc} = Content.upsert_blocks_doc(type, attrs)
      assert doc.type == type
    end
  end

  test "upsert_blocks_doc creates a session and get_blocks_doc reads it back" do
    attrs = %{
      "slug" => "session-2026-07-25-test",
      "title" => "Test session",
      "blocks" => [%{"id" => "s1", "type" => "paragraph", "content" => ["hello"]}],
      "status" => "open"
    }

    assert {:ok, _} = Content.upsert_blocks_doc("session", attrs)
    doc = Content.get_blocks_doc("session-2026-07-25-test", "session", "production")
    assert doc
    assert doc.content["status"] == "open"
  end

  test "upsert_blocks_doc session allows metadata-only (no blocks)" do
    attrs = %{"slug" => "session-2026-07-25-meta-only", "title" => "Meta", "status" => "open"}
    assert {:ok, _} = Content.upsert_blocks_doc("session", attrs)
  end

  test "a session's title round-trips into content and the row title (fix: title was reserved)" do
    attrs = %{
      "slug" => "session-title-roundtrip",
      "title" => "My Session Title",
      "blocks" => [%{"id" => "s1", "type" => "paragraph", "content" => ["hi"]}],
      "status" => "open"
    }

    assert {:ok, doc} = Content.upsert_blocks_doc("session", attrs)
    assert doc.content["title"] == "My Session Title"
    assert doc.title == "My Session Title"

    reread = Content.get_blocks_doc("session-title-roundtrip", "session", @dataset)
    assert reread.content["title"] == "My Session Title"
    assert reread.title == "My Session Title"
  end

  test "a metadata-only session UPDATE preserves existing blocks/body_html/title (fix: was wiped to [])" do
    slug = "session-metadata-update-preserves-blocks"

    create_attrs = %{
      "slug" => slug,
      "title" => "Original Title",
      "blocks" => [%{"id" => "s1", "type" => "paragraph", "content" => ["original body"]}],
      "status" => "open"
    }

    assert {:ok, created} = Content.upsert_blocks_doc("session", create_attrs)
    assert created.content["blocks"] != []
    assert created.content["body_html"] =~ "original body"

    # A bare status change — no "blocks" key at all — must NOT wipe the
    # blocks/body_html a prior write persisted.
    update_attrs = %{"slug" => slug, "status" => "closed"}
    assert {:ok, updated} = Content.upsert_blocks_doc("session", update_attrs)

    assert updated.content["status"] == "closed"
    assert updated.content["title"] == "Original Title"
    assert updated.content["blocks"] == created.content["blocks"]
    assert updated.content["body_html"] =~ "original body"

    reread = Content.get_blocks_doc(slug, "session", @dataset)
    assert reread.content["blocks"] == created.content["blocks"]
    assert reread.content["body_html"] =~ "original body"
  end

  test "a paper and a session sharing the same slug stay isolated (get_existing_blocks_doc_for_write scopes by type)" do
    slug = "shared-slug-paper-vs-session"

    paper_attrs =
      Barkpark.LabelFixtures.paper_attrs(%{
        "slug" => slug,
        "title" => "The Paper",
        "blocks" => [%{"id" => "p1", "type" => "paragraph", "content" => ["paper body"]}]
      })

    assert {:ok, paper_doc} = Content.upsert_paper(paper_attrs)

    session_attrs = %{
      "slug" => slug,
      "title" => "The Session",
      "blocks" => [%{"id" => "s1", "type" => "paragraph", "content" => ["session body"]}],
      "status" => "open"
    }

    assert {:ok, session_doc} = Content.upsert_blocks_doc("session", session_attrs)

    assert paper_doc.type == "paper"
    assert session_doc.type == "session"
    assert paper_doc.id != session_doc.id

    # A SECOND write to the session (same slug) must find its OWN prior row
    # (type "session"), never the same-slug PAPER's — else it would either
    # clobber the paper or hit the (doc_id, type, dataset_id) unique
    # constraint on a stray INSERT.
    assert {:ok, session_updated} =
             Content.upsert_blocks_doc("session", %{"slug" => slug, "status" => "closed"})

    assert session_updated.id == session_doc.id
    assert session_updated.content["status"] == "closed"

    # The paper is untouched by the session's second write. (A plain
    # top-level "title" attr never reaches a PAPER's content — paper titles
    # come from a bound title-role block or the first heading, see
    # `paper_title/2` — so this paper's row title resolved to the slug at
    # creation; the isolation claim is that it's UNCHANGED, not that it's
    # any particular literal.)
    paper_reread = Content.get_paper(slug)
    assert paper_reread.id == paper_doc.id
    assert paper_reread.title == paper_doc.title
    assert paper_reread.content["blocks"] == paper_doc.content["blocks"]
  end

  test "upsert_paper still works unchanged" do
    # AuthoringWall (D26) walls fresh "paper" publishes on the label spine —
    # every OTHER upsert_paper test in this suite goes through this same
    # fixture wrap (test/support/label_fixtures.ex); this test mirrors that
    # convention so it exercises "unchanged behavior", not an unrelated wall
    # 422 the brief's literal attrs would otherwise hit.
    attrs =
      Barkpark.LabelFixtures.paper_attrs(%{
        "slug" => "plain-paper-regression",
        "title" => "P",
        "blocks" => [%{"id" => "p1", "type" => "paragraph", "content" => ["x"]}]
      })

    assert {:ok, _} = Content.upsert_paper(attrs)
    assert Content.get_paper("plain-paper-regression")
  end

  defp minimal_valid_attrs("paper", slug) do
    Barkpark.LabelFixtures.paper_attrs(%{
      "slug" => slug,
      "title" => "Whitelist paper",
      "blocks" => [%{"id" => "p1", "type" => "paragraph", "content" => ["x"]}]
    })
  end

  defp minimal_valid_attrs("session", slug) do
    %{"slug" => slug, "title" => "Whitelist session", "status" => "open"}
  end
end
