defmodule Barkpark.Content.SessionBlocksDocTest do
  use Barkpark.DataCase, async: false
  alias Barkpark.Content

  test "blocks_types is the closed whitelist" do
    assert Content.blocks_types() == ["paper", "session"]
    assert Content.blocks_type?("session")
    refute Content.blocks_type?("post")
  end

  test "upsert_blocks_doc rejects non-whitelist types" do
    assert {:error, :not_a_blocks_type} =
             Content.upsert_blocks_doc("post", %{"slug" => "nope", "blocks" => []})
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
end
